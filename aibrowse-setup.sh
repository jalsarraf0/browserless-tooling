#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly ROOT_DIR="/docker/aibrowse"
readonly PORT_MIN=20000
readonly PORT_MAX=39999
readonly MAX_PORT_ATTEMPTS=25
readonly FIREWALL_ZONE="trusted"
readonly SMOKE_TEST_SIZE_THRESHOLD=10240

log() {
  local level="$1"
  shift
  printf '[%s] %s\n' "$level" "$*" >&2
}

log_info() {
  log "INFO" "$@"
}

log_warn() {
  log "WARN" "$@"
}

log_error() {
  log "ERROR" "$@"
}

fail() {
  log_error "$@"
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Run ${SCRIPT_NAME} with sudo or as root."
  fi
}

require_command() {
  local binary="$1"
  if ! command -v "${binary}" >/dev/null 2>&1; then
    fail "Missing dependency: ${binary}"
  fi
}

declare -a compose_cmd=()

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    compose_cmd=(docker compose)
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    compose_cmd=(docker-compose)
    return
  fi

  fail "Neither docker compose plugin nor docker-compose binary is available."
}

validate_name() {
  local candidate="$1"
  if [[ -z "${candidate}" ]]; then
    fail "Instance name is required."
  fi

  if [[ ! "${candidate}" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; then
    fail "Instance name must be lowercase alphanumeric with optional dashes or underscores."
  fi
}

port_available() {
  local port="$1"

  if ss -Htan "( sport = :${port} )" >/dev/null 2>&1; then
    return 1
  fi

  if docker ps --format '{{.Ports}}' | grep -Fq ":${port}->"; then
    return 1
  fi

  return 0
}

pick_port() {
  local attempt=1
  while (( attempt <= MAX_PORT_ATTEMPTS )); do
    local candidate
    candidate="$(shuf -i "${PORT_MIN}"-"${PORT_MAX}" -n 1)"
    if port_available "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    (( attempt++ ))
  done

  fail "Unable to find a free port after ${MAX_PORT_ATTEMPTS} attempts."
}

ensure_directories() {
  local instance_dir="$1"
  shift

  install -d -m 0750 "${instance_dir}"

  local dir
  for dir in "$@"; do
    install -d -m 0750 "${dir}"
  done
}

generate_env_files() {
  local instance_dir="$1"
  local name="$2"
  local port="$3"
  local token="$4"

  install -m 0640 /dev/null "${instance_dir}/.env"
  cat >"${instance_dir}/.env" <<EOF
BROWSERLESS_NAME=${name}
BROWSERLESS_TOKEN=${token}
BROWSERLESS_PORT=${port}
BROWSERLESS_BIND_ADDRESS=
DOWNLOAD_DIR=${instance_dir}/downloads
LOG_DIR=${instance_dir}/logs
EOF

  install -m 0640 /dev/null "${instance_dir}/.compose.env"
  cat >"${instance_dir}/.compose.env" <<EOF
COMPOSE_PROJECT_NAME=aibrowse-${name}
BROWSERLESS_PORT=${port}
EOF
}

generate_compose_file() {
  local instance_dir="$1"
  local name="$2"

  cat >"${instance_dir}/docker-compose.yml" <<EOF
version: "3.9"

services:
  browserless:
    image: ghcr.io/browserless/chrome:latest
    container_name: browserless-${name}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      - DEBUG=
      - CONNECTION_TIMEOUT=60000
      - MAX_CONCURRENT_SESSIONS=5
      - TOKEN=${BROWSERLESS_TOKEN:-}
    volumes:
      - ./profiles:/usr/src/app/profiles
      - ./downloads:/usr/src/app/downloads
      - ./logs:/usr/src/app/logs
    ports:
      - "\${BROWSERLESS_PORT}:3000"
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"
EOF
}

generate_client_example() {
  local instance_dir="$1"
  local port="$2"
  local token="$3"

  cat >"${instance_dir}/client_examples/playwright_connect.py" <<EOF
#!/usr/bin/env python3
import os

from playwright.sync_api import sync_playwright


def main() -> None:
  endpoint = os.environ.get("BROWSERLESS_ENDPOINT", "ws://localhost:${port}?token=${token}")
  with sync_playwright() as p:
    browser = p.chromium.connect_over_cdp(endpoint)
    page = browser.contexts[0].new_page()
    page.goto("https://example.org", wait_until="networkidle")
    page.screenshot(path=os.path.join("${instance_dir}/downloads", "client-test.png"))
    browser.close()


if __name__ == "__main__":
  main()
EOF

  chmod 0750 "${instance_dir}/client_examples/playwright_connect.py"
}

start_stack() {
  local instance_dir="$1"
  local project_name="$2"

  "${compose_cmd[@]}" \
    --env-file "${instance_dir}/.compose.env" \
    --project-directory "${instance_dir}" \
    --project-name "${project_name}" \
    pull

  "${compose_cmd[@]}" \
    --env-file "${instance_dir}/.compose.env" \
    --project-directory "${instance_dir}" \
    --project-name "${project_name}" \
    up -d --remove-orphans
}

wait_for_service() {
  local port="$1"
  local token="$2"
  local attempts=30

  while (( attempts > 0 )); do
    if curl -fsS --max-time 5 "http://localhost:${port}/metrics?token=${token}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    (( attempts-- ))
  done

  return 1
}

run_smoke_test() {
  local downloads_dir="$1"
  local port="$2"
  local token="$3"
  local output="${downloads_dir}/smoke-test.png"

  curl -fsS --retry 5 --retry-delay 2 \
    "http://localhost:${port}/screenshot?token=${token}&url=https://example.org" \
    --output "${output}"

  local size
  size="$(stat --format '%s' "${output}")"
  if (( size < SMOKE_TEST_SIZE_THRESHOLD )); then
    log_warn "Smoke test screenshot appears smaller than expected (${size} bytes)."
  fi
}

configure_firewalld() {
  local port="$1"

  if ! command -v firewall-cmd >/dev/null 2>&1; then
    log_info "firewalld not found; skipping firewall configuration."
    return
  fi

  if ! firewall-cmd --state >/dev/null 2>&1; then
    log_warn "firewalld is installed but inactive; skipping firewall configuration."
    return
  fi

  firewall-cmd --permanent --zone="${FIREWALL_ZONE}" --add-port="${port}/tcp" >/dev/null
  firewall-cmd --reload >/dev/null
  log_info "Opened port ${port}/tcp in ${FIREWALL_ZONE} zone."
}

main() {
  require_root
  require_command curl
  require_command docker
  require_command openssl
  require_command ss
  detect_compose

  local instance_name="${1:-}"
  validate_name "${instance_name}"

  local instance_dir="${ROOT_DIR}/${instance_name}"
  local downloads_dir="${instance_dir}/downloads"
  local logs_dir="${instance_dir}/logs"
  local profiles_dir="${instance_dir}/profiles"
  local client_dir="${instance_dir}/client_examples"

  ensure_directories "${instance_dir}" "${downloads_dir}" "${logs_dir}" "${profiles_dir}" "${client_dir}"

  local browserless_port
  local browserless_token

  if [[ -f "${instance_dir}/.env" ]]; then
    # shellcheck disable=SC1090
    source "${instance_dir}/.env"
    browserless_port="${BROWSERLESS_PORT:-}"
    browserless_token="${BROWSERLESS_TOKEN:-}"
    if [[ -z "${browserless_port}" ]] || [[ -z "${browserless_token}" ]]; then
      fail "Existing environment file is missing required values."
    fi
    log_info "Reusing existing configuration for ${instance_name}."
  else
    browserless_port="$(pick_port)"
    browserless_token="$(openssl rand -hex 24)"
    export BROWSERLESS_TOKEN="${browserless_token}"
    generate_env_files "${instance_dir}" "${instance_name}" "${browserless_port}" "${browserless_token}"
    log_info "Generated new credentials and configuration."
  fi

  export BROWSERLESS_TOKEN="${browserless_token}"
  generate_compose_file "${instance_dir}" "${instance_name}"
  generate_client_example "${instance_dir}" "${browserless_port}" "${browserless_token}"

  configure_firewalld "${browserless_port}"

  local project="aibrowse-${instance_name}"
  start_stack "${instance_dir}" "${project}"

  if ! wait_for_service "${browserless_port}" "${browserless_token}"; then
    fail "Browserless service failed health checks."
  fi

  run_smoke_test "${downloads_dir}" "${browserless_port}" "${browserless_token}"

  log_info "Browserless instance ${instance_name} is ready on port ${browserless_port}."
  log_info "Credentials stored in ${instance_dir}/.env (permissions 0640)."
  log_info "Smoke test image: ${downloads_dir}/smoke-test.png"
}

main "$@"

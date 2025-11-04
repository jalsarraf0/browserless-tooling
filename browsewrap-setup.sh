#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly ROOT_DIR="/docker/browsewrap"
readonly AIBROWSE_ROOT="/docker/aibrowse"
readonly PORT_MIN=41000
readonly PORT_MAX=58999
readonly MAX_PORT_ATTEMPTS=25
readonly FIREWALL_ZONE="trusted"
readonly NODE_VERSION="22-bookworm-slim"

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

load_browserless_env() {
  local browserless_name="$1"
  local browserless_env="${AIBROWSE_ROOT}/${browserless_name}/.env"

  if [[ ! -f "${browserless_env}" ]]; then
    fail "Browserless configuration not found at ${browserless_env}. Run aibrowse-setup.sh first."
  fi

  # shellcheck disable=SC1090
  source "${browserless_env}"

  if [[ -z "${BROWSERLESS_PORT:-}" ]] || [[ -z "${BROWSERLESS_TOKEN:-}" ]]; then
    fail "Browserless configuration is missing expected variables."
  fi
}

generate_env_files() {
  local instance_dir="$1"
  local name="$2"
  local wrapper_port="$3"
  local browserless_port="$4"
  local browserless_token="$5"

  install -m 0640 /dev/null "${instance_dir}/.env"
  cat >"${instance_dir}/.env" <<EOF
WRAPPER_NAME=${name}
WRAPPER_PORT=${wrapper_port}
BROWSERLESS_ENDPOINT=http://localhost:${browserless_port}?token=${browserless_token}
LOG_DIR=${instance_dir}/logs
EOF

  install -m 0640 /dev/null "${instance_dir}/.compose.env"
  cat >"${instance_dir}/.compose.env" <<EOF
COMPOSE_PROJECT_NAME=browsewrap-${name}
WRAPPER_PORT=${wrapper_port}
EOF
}

generate_dockerfile() {
  local app_dir="$1"

  cat >"${app_dir}/Dockerfile" <<EOF
FROM node:${NODE_VERSION}

ENV NODE_ENV=production

WORKDIR /app

COPY package.json package.json
COPY src src

EXPOSE 0

CMD ["node", "src/server.mjs"]
EOF
}

generate_package_json() {
  local app_dir="$1"
  local name="$2"

  cat >"${app_dir}/package.json" <<EOF
{
  "name": "browsewrap-${name}",
  "version": "1.0.0",
  "private": true,
  "type": "module"
}
EOF
}

generate_server() {
  local app_dir="$1"

  install -d -m 0750 "${app_dir}/src"
  cat >"${app_dir}/src/server.mjs" <<'EOF'
import { createServer } from 'node:http';
import { appendFileSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';

const port = Number.parseInt(process.env.WRAPPER_PORT ?? '', 10) || 48000;
const browserlessEndpoint = process.env.BROWSERLESS_ENDPOINT ?? '';
const logDir = process.env.LOG_DIR ?? '/logs';
const logFile = resolve(logDir, 'wrapper.log');

mkdirSync(logDir, { recursive: true });

const log = (message) => {
  const line = `[${new Date().toISOString()}] ${message}\n`;
  appendFileSync(logFile, line, { encoding: 'utf8' });
};

const server = createServer(async (req, res) => {
  if (!req.url) {
    res.writeHead(400, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ status: 'error', message: 'invalid request' }));
    return;
  }

  if (req.url.startsWith('/healthz')) {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      status: 'ok',
      browserless_endpoint: browserlessEndpoint,
      uptime_seconds: process.uptime()
    }));
    return;
  }

  res.writeHead(404, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ status: 'error', message: 'not found' }));
});

server.listen(port, () => {
  log(`browsewrap ready on port ${port}`);
});
EOF
}

generate_compose_file() {
  local instance_dir="$1"
  local name="$2"

  cat >"${instance_dir}/docker-compose.yml" <<EOF
version: "3.9"

services:
  browsewrap:
    build:
      context: ./app
    container_name: browsewrap-${name}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      - WRAPPER_PORT=\${WRAPPER_PORT}
    volumes:
      - ./logs:/logs
    ports:
      - "\${WRAPPER_PORT}:\${WRAPPER_PORT}"
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"
EOF
}

start_stack() {
  local instance_dir="$1"
  local project_name="$2"

  "${compose_cmd[@]}" \
    --env-file "${instance_dir}/.compose.env" \
    --project-directory "${instance_dir}" \
    --project-name "${project_name}" \
    build --pull

  "${compose_cmd[@]}" \
    --env-file "${instance_dir}/.compose.env" \
    --project-directory "${instance_dir}" \
    --project-name "${project_name}" \
    up -d --remove-orphans
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

wait_for_wrapper() {
  local port="$1"
  local attempts=30

  while (( attempts > 0 )); do
    if curl -fsS --max-time 5 "http://localhost:${port}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    (( attempts-- ))
  done

  return 1
}

update_mcp_config() {
  local name="$1"
  local port="$2"
  local token="$3"
  local config="${HOME}/mcp.json"
  local tmp
  tmp="$(mktemp)"

  CONFIG="${config}" NAME="${name}" PORT="${port}" TOKEN="${token}" python3 <<'PY' >"${tmp}"
import json
import os
import sys

config_path = os.environ["CONFIG"]
entry = {
    "id": f"browsewrap-{os.environ['NAME']}",
    "label": f"browsewrap {os.environ['NAME']}",
    "endpoint": f"http://localhost:{os.environ['PORT']}",
    "token": os.environ['TOKEN']
}

if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except json.JSONDecodeError:
        data = {}
else:
    data = {}

clients = data.get("clients", [])
clients = [client for client in clients if client.get("id") != entry["id"]]
clients.append(entry)
data["clients"] = clients

json.dump(data, sys.stdout, indent=2)
sys.stdout.write("\n")
PY

  install -m 0644 /dev/null "${config}"
  mv "${tmp}" "${config}"
}

main() {
  require_root
  require_command curl
  require_command docker
  require_command python3
  require_command ss
  detect_compose

  local instance_name="${1:-}"
  validate_name "${instance_name}"

  load_browserless_env "${instance_name}"

  local instance_dir="${ROOT_DIR}/${instance_name}"
  local logs_dir="${instance_dir}/logs"
  local app_dir="${instance_dir}/app"

  ensure_directories "${instance_dir}" "${logs_dir}" "${app_dir}"

  local wrapper_port
  if [[ -f "${instance_dir}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${instance_dir}/.env"
    wrapper_port="${WRAPPER_PORT:-}"
    if [[ -z "${wrapper_port}" ]]; then
      fail "Existing wrapper configuration is incomplete."
    fi
    log_info "Reusing existing wrapper configuration for ${instance_name}."
  else
    wrapper_port="$(pick_port)"
  fi

  generate_env_files "${instance_dir}" "${instance_name}" "${wrapper_port}" "${BROWSERLESS_PORT}" "${BROWSERLESS_TOKEN}"
  generate_package_json "${app_dir}" "${instance_name}"
  generate_server "${app_dir}"
  generate_dockerfile "${app_dir}"
  generate_compose_file "${instance_dir}" "${instance_name}"

  install -m 0640 /dev/null "${logs_dir}/wrapper.log"

  configure_firewalld "${wrapper_port}"

  local project="browsewrap-${instance_name}"
  start_stack "${instance_dir}" "${project}"

  if ! wait_for_wrapper "${wrapper_port}"; then
    fail "Wrapper service failed health checks."
  fi

  update_mcp_config "${instance_name}" "${wrapper_port}" "${BROWSERLESS_TOKEN}"

  log_info "Wrapper ${instance_name} is ready on port ${wrapper_port}."
  log_info "Health endpoint: http://localhost:${wrapper_port}/healthz"
  log_info "Configuration stored in ${instance_dir}/.env"
}

main "$@"

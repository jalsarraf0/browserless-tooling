# Browserless Tooling

> Hardened provisioning for Browserless Chromium and LM Studio MCP wrappers,
> engineered with security-first defaults, deterministic outputs, and bash you
> can hand to an SRE.

![](https://img.shields.io/badge/bash-set%20-Eeuo%20pipefail-0a0a0a?style=flat-square&labelColor=353535)
![](https://img.shields.io/badge/security-firewall__aware-0a0a0a?style=flat-square&labelColor=353535)
![](https://img.shields.io/badge/automation-idempotent-0a0a0a?style=flat-square&labelColor=353535)

---

## Why This Exists

Provisioning Browserless is easy; operating it safely on a real network is not.
This toolkit codifies the opinionated runbook I use for client deployments:

- bootstrap a hardened Browserless Chromium instance in minutes,
- layer a Node 22 MCP wrapper with host networking and observability, and
- keep credentials and firewall rules in lock-step without manual drift.

The scripts are meant to be read, audited, and trusted — not treated as a black
box.

---

## TL;DR Provisioning Flow

```bash
# 1. Hardened Browserless bring-up
sudo bash aibrowse-setup.sh demo

# 2. Sanity check the service
curl -fsS http://localhost:<port>/metrics?token=<token>

# 3. Add the MCP wrapper tier
sudo bash browsewrap-setup.sh demo
```

Look for `/docker/aibrowse/demo/downloads/smoke-test.png` (>10 KB) and the
wrapper’s `/healthz` payload in `/docker/browsewrap/demo/logs/wrapper.log`.

---

## What You Get

| Script | Role | Key Moves |
| --- | --- | --- |
| `aibrowse-setup.sh` | Boots Browserless Chromium with persistent profiles, downloads, logs, and client samples. | Idempotent `.env`/`.compose.env` generation, random high-port selection, docker health gating, smoke-test screenshot, adaptive firewalld policy, Playwright CDP example. |
| `browsewrap-setup.sh` | Deploys the MCP wrapper Node app for LM Studio, tailors logging, and updates `~/mcp.json`. | Reuses Browserless secrets, scaffolds production Node 22 app, composes host networking, hydrates wrapper logs, emits readiness checks, exposes `/healthz`. |

---

## Operating Playbook

```text
┌─────────────────────┐    ┌────────────────────────┐
│  aibrowse-setup.sh  │    │  browsewrap-setup.sh   │
│  (root required)    │    │  (depends on Browserless) │
├─────────────────────┤    ├────────────────────────┤
│ • dependency guard  │    │ • dependency guard      │
│ • env + compose     │    │ • wrapper env           │
│ • docker compose up │    │ • npm install / build   │
│ • health & smoke    │    │ • docker compose up     │
│ • firewalld rules   │    │ • health assertions     │
└─────────┬───────────┘    └────────────┬───────────┘
          │                             │
          ▼                             ▼
   `/docker/aibrowse/<name>`     `/docker/browsewrap/<name>`
```

- Treat everything under `/docker/*/<name>` as script-owned infrastructure.
  Regenerate by rerunning the scripts; never hand-edit the files.
- Both scripts surface colorised logging via the shared `log` helpers for fast
  SRE-ready troubleshooting.
- Port allocation stays in safe ranges (20k–39k for Browserless, 41k–58k for
  wrappers) with collision detection for local processes **and** containers.

---

## Observability & Verification

- `sudo docker ps --filter name=browserless`
- `sudo docker logs browserless --tail 50`
- `sudo docker ps --filter name=browsewrap`
- `sudo docker logs browsewrap-<name> --tail 50`
- Watch `~/mcp.json` for the connector payload emitted by `browsewrap-setup.sh`.
- Regenerated smoke-test screenshot lives at
  `/docker/aibrowse/<name>/downloads/smoke-test.png`.

---

## Validation Matrix

```bash
shellcheck aibrowse-setup.sh browsewrap-setup.sh
bash -n aibrowse-setup.sh
bash -n browsewrap-setup.sh
```

Functional validation requires a disposable host with Docker and firewalld:

1. Run both scripts as outlined above.
2. Hit the Browserless metrics endpoint with the emitted token.
3. Confirm `/healthz` from the wrapper and a >10 KB `smoke-test.png`.

---

## Security Posture

- `BROWSERLESS_TOKEN` is generated with `openssl rand -hex 24` and stored with
  `0640` permissions in both `.env` files.
- Firewalld rules restrict Browserless exposure by defaulting to trusted zones,
  adding explicit drop rules for everything else.
- Docker volumes bind to `/docker` paths with controlled ownership for the
  Chromium profile and download artifacts.
- No secrets leave the host; publication happens through the Playwright sample,
  not raw token disclosure.

---

## Crafted Skillset

- Bash that embraces `set -Eeuo pipefail`, rigorous guard clauses, and graceful
  error handling.
- Deterministic file generation via here-docs, avoiding permission drift.
- Dynamic firewall choreography (IPv4 + IPv6) aware of local zones.
- Observability baked in: health checks, log capture, and post-run summaries.
- Secure automation patterns drawn from production rollouts and incident
  postmortems.

---

## Repository Map

```text
.
├── aibrowse-setup.sh       # Browserless provisioning script
├── browsewrap-setup.sh     # MCP wrapper deployment script
└── AGENTS.md               # Auxiliary documentation for LM Studio agents
```

---

## Maintainers

Crafted and maintained by the Browserless Tooling contributors — blending
DevOps rigour, security hardening, and developer ergonomics to ship automation
that can survive production. Looking to extend the stack (metrics ingestion,
policy tooling, dashboards)? Open an issue or reach out through the repository.

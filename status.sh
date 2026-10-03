#!/usr/bin/env bash
#
# status.sh - one screen of "is my agent healthy?": OpenClaw status, Gateway
# service + probe, channel reachability, browser, and host resources.
#
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"
load_env "${HOME}/.openclaw/.env" || true

GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
BROWSER_PORT=$((GATEWAY_PORT + 2))

have openclaw || die "openclaw not on PATH. Run as the openclaw user: sudo -u openclaw -i"

step "OpenClaw"
openclaw status || warn "openclaw status returned non-zero"

step "Gateway service"
openclaw gateway status || warn "gateway status returned non-zero"

step "Gateway probes (loopback)"
for probe in healthz startupz readyz; do
  if code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 \
             "http://127.0.0.1:${GATEWAY_PORT}/${probe}" 2>/dev/null)"; then
    log "/${probe} -> ${code}"
  else
    warn "/${probe} -> unreachable"
  fi
done

step "Channels"
openclaw channels status --probe || warn "channel probe failed"

step "Browser control service (127.0.0.1:${BROWSER_PORT})"
if have jq; then
  curl -fsS --max-time 5 "http://127.0.0.1:${BROWSER_PORT}/" 2>/dev/null \
    | jq '{running, pid, chosenBrowser, headless}' \
    || warn "browser control service not answering"
else
  curl -fsS --max-time 5 "http://127.0.0.1:${BROWSER_PORT}/" || warn "browser control service not answering"
fi
openclaw browser status || true

step "systemd --user units"
systemctl --user --no-pager --plain list-units 'openclaw*' || true

step "Host"
printf '%s\n' "uptime: $(uptime -p 2>/dev/null || true)"
free -h
df -h / | tail -n +1
if have swapon; then swapon --show || true; fi

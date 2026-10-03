#!/usr/bin/env bash
#
# openclaw-healthcheck.sh - probe the Gateway, restart it if it is wedged, and
# tell me on Telegram. Driven by openclaw-healthcheck.timer every 5 minutes.
#
# Probe semantics (docs: Gateway > Health):
#   /healthz  the HTTP server is live        -> process liveness
#   /readyz   sidecars settled, agent DBs ok, channels pass deep readiness
#             -> what actually matters for "can my phone talk to it"
#
# A restart is only attempted when /readyz has failed FAIL_THRESHOLD runs in a
# row, so a single slow startup or a brief channel blip does not bounce the
# daemon. Alerts are rate-limited to one per ALERT_COOLDOWN seconds.
#
set -euo pipefail

STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/openclaw-healthcheck"
FAIL_FILE="${STATE_DIR}/consecutive-failures"
ALERT_FILE="${STATE_DIR}/last-alert"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"
ALERT_COOLDOWN="${ALERT_COOLDOWN:-1800}"   # 30 min
PROBE_TIMEOUT="${PROBE_TIMEOUT:-10}"

mkdir -p "$STATE_DIR"

# ~/.openclaw/.env holds the bot token, chat id and gateway port.
if [[ -f "${HOME}/.openclaw/.env" ]]; then
  set -a
  # shellcheck disable=SC1091  # operator-managed secrets file
  source "${HOME}/.openclaw/.env"
  set +a
fi

GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
BASE="http://127.0.0.1:${GATEWAY_PORT}"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"

log() { printf '%s openclaw-healthcheck: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

notify() {
  local text="$1" now last
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || {
    log "no TELEGRAM_CHAT_ID; alert not sent: ${text}"
    return 0
  }
  now="$(date +%s)"
  last="$(cat "$ALERT_FILE" 2>/dev/null || echo 0)"
  if (( now - last < ALERT_COOLDOWN )); then
    log "alert suppressed by cooldown: ${text}"
    return 0
  fi
  if curl -fsS --max-time 15 -o /dev/null \
      -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=[${HOSTNAME_SHORT}] ${text}" \
      --data-urlencode "disable_web_page_preview=true"; then
    printf '%s\n' "$now" > "$ALERT_FILE"
    log "alert sent"
  else
    log "alert delivery failed"
  fi
}

probe() { curl -fsS -o /dev/null --max-time "$PROBE_TIMEOUT" "${BASE}/$1"; }

read_failures() { cat "$FAIL_FILE" 2>/dev/null || echo 0; }

# --- probe ------------------------------------------------------------------
if probe readyz; then
  if (( $(read_failures) > 0 )); then
    log "recovered"
    notify "OpenClaw gateway recovered and is ready again."
  fi
  printf '0\n' > "$FAIL_FILE"
  exit 0
fi

failures=$(( $(read_failures) + 1 ))
printf '%s\n' "$failures" > "$FAIL_FILE"

liveness="down"
probe healthz && liveness="up"
log "readyz failed (attempt ${failures}/${FAIL_THRESHOLD}); healthz=${liveness}"

if (( failures < FAIL_THRESHOLD )); then
  exit 0
fi

# --- recover ----------------------------------------------------------------
log "restarting the gateway"
restart_ok=0
if command -v openclaw >/dev/null 2>&1 && openclaw gateway restart >/dev/null 2>&1; then
  restart_ok=1
elif systemctl --user restart openclaw-gateway.service >/dev/null 2>&1; then
  restart_ok=1
fi

# Give the Gateway up to 90s to settle before judging the restart.
ready=0
for _ in $(seq 1 30); do
  if probe readyz; then ready=1; break; fi
  sleep 3
done

if (( ready )); then
  printf '0\n' > "$FAIL_FILE"
  # Bring the headless browser back up too; the agent is useless without it.
  command -v openclaw >/dev/null 2>&1 && openclaw browser start --headless >/dev/null 2>&1 || true
  log "restart succeeded"
  notify "OpenClaw gateway was unresponsive and has been restarted. It is ready again."
  exit 0
fi

log "restart did not recover the gateway (restart_ok=${restart_ok})"
notify "OpenClaw gateway is DOWN and a restart did not help. SSH in and run: openclaw doctor"
exit 1

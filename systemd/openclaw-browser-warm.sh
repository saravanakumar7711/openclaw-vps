#!/usr/bin/env bash
#
# openclaw-browser-warm.sh - wait for the Gateway to be ready, then launch the
# managed headless browser once so the agent's first web request is not a cold
# Chrome start. Run by openclaw-browser-warm.service at boot.
#
set -euo pipefail

if [[ -f "${HOME}/.openclaw/.env" ]]; then
  set -a
  # shellcheck disable=SC1091  # operator-managed secrets file
  source "${HOME}/.openclaw/.env"
  set +a
fi

GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

# Up to 3 minutes for the Gateway's channels and sidecars to settle.
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${GATEWAY_PORT}/readyz"; then
    break
  fi
  sleep 3
done

# `--headless` applies to this one start request; browser.headless=true in
# openclaw.json is what makes every managed launch headless.
exec openclaw browser start --headless

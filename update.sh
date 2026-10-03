#!/usr/bin/env bash
#
# update.sh - safely update OpenClaw and the OS, then verify the agent is back.
#
#   ./update.sh            interactive (asks before each mutating phase)
#   ./update.sh --yes      no prompts, for cron
#   ./update.sh --os-only | --openclaw-only
#
# Takes a config backup first, so a bad update is recoverable.
#
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"

# Print the header comment block as usage text.
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

load_env "${HOME}/.openclaw/.env" || true

DO_OS=1
DO_OC=1
for arg in "$@"; do
  case "$arg" in
    --yes|-y)        ASSUME_YES=1 ;;
    --os-only)       DO_OC=0 ;;
    --openclaw-only) DO_OS=0 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "Unknown argument: ${arg}" ;;
  esac
done
export ASSUME_YES="${ASSUME_YES:-0}"

# --- backup first -----------------------------------------------------------
if have openclaw; then
  step "Pre-update backup"
  "${REPO_DIR}/backup.sh" || warn "Backup failed; continuing is your call."
fi

# --- OpenClaw ---------------------------------------------------------------
if (( DO_OC )); then
  have openclaw || die "openclaw not on PATH. Run as the openclaw user: sudo -u openclaw -i"
  step "OpenClaw update"
  openclaw update status || true
  if confirm "Update OpenClaw now? (restarts the Gateway)"; then
    # `openclaw update` restarts the Gateway and waits for readiness unless
    # --no-restart is passed.
    if have jq; then
      openclaw update --yes --json | jq '.' \
        || die "openclaw update failed. 'openclaw update repair' is the documented recovery."
    else
      openclaw update --yes \
        || die "openclaw update failed. 'openclaw update repair' is the documented recovery."
    fi
    log "OpenClaw updated: $(openclaw --version | tail -1)"
  else
    info "Skipped OpenClaw update."
  fi
fi

# --- OS ---------------------------------------------------------------------
if (( DO_OS )); then
  step "OS packages"
  SUDO=""
  if [[ "$(id -u)" -ne 0 ]]; then
    SUDO="sudo"
    sudo -n true 2>/dev/null || warn "sudo needs a password for this account (by design). Run update.sh as root for the OS phase."
  fi
  if confirm "Apply OS updates now?"; then
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -q
    # --force-confold keeps our managed sshd/fail2ban/apt drop-ins intact.
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -y \
      -o Dpkg::Options::=--force-confold upgrade
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -y autoremove
    log "OS packages updated"
    if [[ -f /var/run/reboot-required ]]; then
      warn "A reboot is required: $(cat /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')"
      warn "Reboot when convenient; linger brings the Gateway back automatically."
    fi
  else
    info "Skipped OS update."
  fi
fi

# --- verify -----------------------------------------------------------------
step "Post-update verification"
if have openclaw; then
  openclaw gateway restart || openclaw gateway start || warn "Gateway did not restart cleanly"
  GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
  for _ in $(seq 1 30); do
    curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${GATEWAY_PORT}/readyz" && break
    sleep 2
  done
  if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${GATEWAY_PORT}/readyz"; then
    log "Gateway is ready"
  else
    warn "Gateway is not ready. Run: openclaw doctor"
  fi
  openclaw browser start --headless >/dev/null 2>&1 || warn "Browser did not restart; run 'openclaw browser doctor'."
  openclaw doctor || warn "openclaw doctor reported findings"
fi
log "Update run complete"

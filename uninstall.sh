#!/usr/bin/env bash
#
# uninstall.sh - remove OpenClaw from this host. Destructive, so it confirms
# every scope separately and takes a backup first.
#
#   ./uninstall.sh                 service only (keeps config + workspace)
#   ./uninstall.sh --all           service + state + workspace + the user
#   ./uninstall.sh --dry-run       show what would happen
#
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"

# Print the header comment block as usage text.
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }


MODE="service"
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --all)     MODE="all" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         die "Unknown argument: ${arg}" ;;
  esac
done

have openclaw || die "openclaw not on PATH. Run as the openclaw user: sudo -u openclaw -i"

if (( DRY_RUN )); then
  step "Dry run"
  openclaw uninstall --dry-run
  exit 0
fi

step "Backup before removal"
"${REPO_DIR}/backup.sh" || warn "Backup failed."

step "Stopping the health check and browser units"
systemctl --user disable --now openclaw-healthcheck.timer 2>/dev/null || true
systemctl --user disable --now openclaw-browser-warm.service 2>/dev/null || true

if [[ "$MODE" == "service" ]]; then
  confirm "Remove the OpenClaw Gateway service (config and workspace are kept)?" \
    || die "Aborted."
  openclaw uninstall --service --yes --non-interactive
  log "Gateway service removed. ~/.openclaw and the workspace are untouched."
  exit 0
fi

err "--all removes the Gateway service, ALL OpenClaw state (~/.openclaw,"
err "including credentials and session history) and the agent workspace."
confirm "This cannot be undone. Proceed?" || die "Aborted."
confirm "Really proceed? Type y once more." || die "Aborted."

openclaw uninstall --all --yes --non-interactive
log "OpenClaw state removed."

cat <<'LEFTOVERS'

Still on the host (removed by hand if you want a clean box):

  systemd user units .... ~/.config/systemd/user/openclaw-*.{service,timer}
  helper scripts ........ ~/bin/openclaw-*.sh
  backups ............... ~/backups
  Node.js ............... sudo apt-get purge nodejs && sudo rm /etc/apt/sources.list.d/nodesource.list
  Google Chrome ......... sudo apt-get purge google-chrome-stable && sudo rm /etc/apt/sources.list.d/google-chrome.list
  Tailscale ............. sudo tailscale logout && sudo apt-get purge tailscale
  sshd hardening ........ sudo rm /etc/ssh/sshd_config.d/99-openclaw-hardening.conf && sudo systemctl reload ssh
  fail2ban jail ......... sudo rm /etc/fail2ban/jail.d/openclaw-sshd.local
  swap file ............. sudo swapoff /swapfile && sudo rm /swapfile  (and the /etc/fstab line)
  runtime user .......... sudo loginctl disable-linger openclaw && sudo deluser --remove-home openclaw

LEFTOVERS

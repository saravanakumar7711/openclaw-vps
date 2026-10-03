#!/usr/bin/env bash
#
# backup.sh - snapshot the OpenClaw config to ~/backups, keep the last 7.
#
# Prefers `openclaw backup create --only-config`, which produces a verified
# tar.gz and knows what belongs in a restorable snapshot. Falls back to a
# plain tar of ~/.openclaw when the CLI is unavailable.
#
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"

BACKUP_DIR="${BACKUP_DIR:-${HOME}/backups}"
CONFIG_DIR="${HOME}/.openclaw"
KEEP="${KEEP:-7}"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

step "Backing up OpenClaw config to ${BACKUP_DIR}"

if have openclaw && openclaw backup create --only-config --verify --output "$BACKUP_DIR"; then
  log "openclaw backup create succeeded"
else
  warn "Falling back to tar of ${CONFIG_DIR}"
  [[ -d "$CONFIG_DIR" ]] || die "No ${CONFIG_DIR} to back up."
  stamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
  archive="${BACKUP_DIR}/${stamp}-openclaw-config.tar.gz"
  # Exclude caches and the browser profile: large, regenerable, and full of
  # session cookies we do not want lying around in backups.
  tar -czf "$archive" \
    --exclude='./browser' \
    --exclude='./cache' \
    --exclude='./logs' \
    -C "$CONFIG_DIR" .
  chmod 600 "$archive"
  log "Wrote ${archive} ($(du -h "$archive" | cut -f1))"
fi

# --- rotation ---------------------------------------------------------------
step "Rotating (keeping the newest ${KEEP})"
mapfile -t archives < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' \
  | sort -rn | cut -d' ' -f2-)
if (( ${#archives[@]} > KEEP )); then
  for stale in "${archives[@]:KEEP}"; do
    rm -f -- "$stale"
    dim "removed $(basename "$stale")"
  done
fi
log "${BACKUP_DIR} holds $(find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz' | wc -l | tr -d ' ') archive(s)"
dim "Restore with: openclaw backup restore <archive> --target ./restored-openclaw"

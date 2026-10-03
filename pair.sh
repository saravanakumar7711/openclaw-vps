#!/usr/bin/env bash
#
# pair.sh - approve your phone's Telegram DM pairing request.
#
#   ./pair.sh            list pending pairing requests
#   ./pair.sh <CODE>     approve that code and notify the requester
#
# Telegram's default dmPolicy is `pairing`: an unknown sender gets a pairing
# code instead of an answer. Approve it once and your phone is in.
#
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"

have openclaw || die "openclaw not on PATH. Run this as the openclaw user: sudo -u openclaw -i"

CODE="${1:-}"

if [[ -z "$CODE" ]]; then
  step "Pending Telegram pairing requests"
  openclaw pairing list telegram
  cat <<'HINT'

If the list is empty, send any message to your bot from your phone first.
Then approve the code you got back:

    ./pair.sh <CODE>

HINT
  exit 0
fi

step "Approving Telegram pairing code ${CODE}"
openclaw pairing approve telegram "$CODE" --notify
log "Approved. Your phone should get a confirmation message."
dim "Note: pairing grants DM access only. For owner-only commands your numeric"
dim "Telegram user ID must also be in commands.ownerAllowFrom - set TELEGRAM_USER_ID"
dim "in .env and re-run setup.sh to pin it down."

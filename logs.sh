#!/usr/bin/env bash
#
# logs.sh - follow the OpenClaw log stream. Extra args pass straight through
# to `openclaw logs` (e.g. ./logs.sh --limit 500, ./logs.sh --json).
#
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"

have openclaw || die "openclaw not on PATH. Run as the openclaw user: sudo -u openclaw -i"

if [[ $# -gt 0 ]]; then
  exec openclaw logs "$@"
fi
exec openclaw logs --follow

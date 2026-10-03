#!/usr/bin/env bash
# Shared helpers for the openclaw-vps scripts: colored logging, env loading,
# confirmation prompts. Sourced, never executed directly.

# --- colors (disabled when stdout is not a TTY or NO_COLOR is set) -----------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'; C_DIM=$'\033[2m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''
fi

log()  { printf '%s[ok]%s   %s\n'   "$C_GREEN"  "$C_RESET" "$*"; }
info() { printf '%s[info]%s %s\n'   "$C_BLUE"   "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n'   "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[err]%s  %s\n'   "$C_RED"    "$C_RESET" "$*" >&2; }
dim()  { printf '%s%s%s\n'          "$C_DIM"    "$*"       "$C_RESET"; }
die()  { err "$*"; exit 1; }

# step "Title" -> a visually separated section header
step() {
  printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BLUE" "$*" "$C_RESET"
}

have() { command -v "$1" >/dev/null 2>&1; }

# load_env <path> : export every KEY=VALUE from a .env file without running it.
# Blank lines, comments and `export ` prefixes are tolerated.
load_env() {
  local file="$1" line key value
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"        # ltrim
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"           # rtrim key
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    # strip one layer of matching quotes
    if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    export "$key=$value"
  done < "$file"
  return 0
}

# confirm "question" : returns 0 on yes. Auto-yes when ASSUME_YES=1.
confirm() {
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  local reply
  printf '%s[?]%s %s [y/N] ' "$C_YELLOW" "$C_RESET" "$*"
  read -r reply || return 1
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

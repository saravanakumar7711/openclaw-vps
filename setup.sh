#!/usr/bin/env bash
#
# setup.sh - one-command bootstrap for a self-hosted OpenClaw agent on a fresh
# Ubuntu 24.04 VPS, driven from Telegram, backed by the free Gemini API.
#
# Idempotent: every step checks for its own end state first, so re-running is
# safe and cheap. Run as root on the fresh box:
#
#   sudo ./setup.sh
#
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------
ENV_FILE="${ENV_FILE:-${REPO_DIR}/.env}"
APT_PACKAGES=(
  curl ca-certificates gnupg git jq ufw fail2ban unattended-upgrades
  apt-transport-https software-properties-common
)
NODE_MAJOR=24
NODE_MIN_VERSION="24.16.0"   # OpenClaw requires Node 24.16+ or 26.1+

main() {
  require_root
  load_config
  step "1/14  System packages"        ; apt_bootstrap
  step "2/14  Swap"                   ; ensure_swap
  step "3/14  Runtime user"           ; ensure_user
  step "4/14  SSH hardening"          ; harden_ssh
  step "5/14  fail2ban"               ; configure_fail2ban
  step "6/14  Unattended upgrades"    ; configure_unattended_upgrades
  step "7/14  Node.js ${NODE_MAJOR}"  ; install_node
  step "8/14  Headless browser"       ; install_browser
  step "9/14  Tailscale"              ; install_tailscale
  step "10/14 UFW firewall"           ; configure_ufw
  step "11/14 User session linger"    ; enable_linger
  step "12/14 OpenClaw install"       ; install_openclaw
  step "13/14 OpenClaw onboarding"    ; onboard_openclaw
  step "14/14 Health check timer"     ; install_healthcheck
  final_report
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo ./setup.sh"
  have apt-get || die "This script targets Ubuntu 24.04 (apt-get not found)."
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || warn "Expected Ubuntu, found ID=${ID:-unknown}; continuing."
    [[ "${VERSION_ID:-}" == "24.04" ]] || warn "Tested on Ubuntu 24.04, found ${VERSION_ID:-unknown}; continuing."
  fi
}

load_config() {
  [[ -f "$ENV_FILE" ]] || die "Missing ${ENV_FILE}. Copy .env.example to .env and fill it in."
  load_env "$ENV_FILE" || die "Could not read ${ENV_FILE}"
  chmod 600 "$ENV_FILE"

  OC_USER="${OPENCLAW_USER:-openclaw}"
  OC_HOME="/home/${OC_USER}"
  OC_CONFIG_DIR="${OC_HOME}/.openclaw"
  GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
  BROWSER_ENGINE="${BROWSER_ENGINE:-chrome}"
  SWAP_SIZE="${SWAP_SIZE-2G}"
  MODEL_REF="${OPENCLAW_MODEL:-gemini-3.8-flash}"
  [[ "$MODEL_REF" == */* ]] || MODEL_REF="google/${MODEL_REF}"

  [[ -n "${GEMINI_API_KEY:-}" ]]     || die "GEMINI_API_KEY is empty in ${ENV_FILE}"
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || die "TELEGRAM_BOT_TOKEN is empty in ${ENV_FILE}"

  # Generate a Gateway token once and persist it so re-runs stay stable.
  if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    OPENCLAW_GATEWAY_TOKEN="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | cut -c1-40)"
    export OPENCLAW_GATEWAY_TOKEN
    if grep -q '^OPENCLAW_GATEWAY_TOKEN=' "$ENV_FILE"; then
      sed -i "s|^OPENCLAW_GATEWAY_TOKEN=.*|OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}|" "$ENV_FILE"
    else
      printf 'OPENCLAW_GATEWAY_TOKEN=%s\n' "$OPENCLAW_GATEWAY_TOKEN" >> "$ENV_FILE"
    fi
    info "Generated a Gateway auth token and saved it to ${ENV_FILE}"
  fi

  ARCH="$(dpkg --print-architecture)"
  if [[ "$ARCH" != "amd64" && "$BROWSER_ENGINE" == "chrome" ]]; then
    warn "Google Chrome has no ${ARCH} package; switching BROWSER_ENGINE to playwright."
    BROWSER_ENGINE="playwright"
  fi
}

# Run a command as the runtime user inside its own systemd user session.
# Linger must already be on so /run/user/<uid> exists.
as_oc() {
  local uid; uid="$(id -u "$OC_USER")"
  # Secrets travel as environment, never on the command line, so they do not
  # show up in `ps` output.
  runuser -u "$OC_USER" -- env \
    HOME="$OC_HOME" \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    PATH="${OC_HOME}/.npm-global/bin:${OC_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
    OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}" \
    OPENCLAW_GATEWAY_PORT="${GATEWAY_PORT:-18789}" \
    bash -lc "$1"
}

# ---------------------------------------------------------------------------
# 1. packages
# ---------------------------------------------------------------------------
apt_bootstrap() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get -y -o Dpkg::Options::=--force-confold upgrade
  apt-get install -y "${APT_PACKAGES[@]}"
  log "Base packages installed"
}

# ---------------------------------------------------------------------------
# 2. swap
# ---------------------------------------------------------------------------
ensure_swap() {
  if [[ -z "$SWAP_SIZE" ]]; then
    info "SWAP_SIZE is empty; skipping swap."
    return
  fi
  local mem_kb mem_mb
  mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  mem_mb=$(( mem_kb / 1024 ))
  if (( mem_mb >= 4000 )); then
    info "Host has ${mem_mb} MB RAM (>= 4 GB); no swap file needed."
    return
  fi
  if [[ -f /swapfile ]] && swapon --show=NAME --noheadings | grep -qx /swapfile; then
    info "/swapfile already active."
    return
  fi
  info "Host has ${mem_mb} MB RAM; creating a ${SWAP_SIZE} swap file."
  if [[ ! -f /swapfile ]]; then
    # dd is the fallback for filesystems where fallocate cannot reserve blocks.
    local mb="${SWAP_SIZE%[Gg]}"
    [[ "$mb" == "$SWAP_SIZE" ]] && mb="${SWAP_SIZE%[Mm]}" || mb=$(( mb * 1024 ))
    fallocate -l "$SWAP_SIZE" /swapfile \
      || dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none
  fi
  chmod 600 /swapfile
  swapon --show=NAME --noheadings | grep -qx /swapfile || { mkswap /swapfile >/dev/null; swapon /swapfile; }
  grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  # Agent workloads are bursty; prefer RAM but allow the swap to absorb spikes.
  sysctl -q -w vm.swappiness=10
  grep -q '^vm.swappiness' /etc/sysctl.d/99-openclaw.conf 2>/dev/null \
    || printf 'vm.swappiness=10\n' > /etc/sysctl.d/99-openclaw.conf
  log "Swap active: $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')"
}

# ---------------------------------------------------------------------------
# 3. runtime user
# ---------------------------------------------------------------------------
ensure_user() {
  if id -u "$OC_USER" >/dev/null 2>&1; then
    info "User ${OC_USER} already exists."
  else
    adduser --disabled-password --gecos "OpenClaw agent" "$OC_USER"
    log "Created user ${OC_USER}"
  fi
  # Group membership only. Ubuntu's %sudo rule requires a password, and this
  # account has none, so the agent runtime cannot escalate non-interactively.
  # To use sudo yourself: `sudo passwd openclaw` from root.
  usermod -aG sudo "$OC_USER"
  install -d -m 0700 -o "$OC_USER" -g "$OC_USER" "${OC_HOME}/.ssh"
  install -d -m 0700 -o "$OC_USER" -g "$OC_USER" "$OC_CONFIG_DIR"
  log "User ${OC_USER} is in the sudo group (password required, none set)"
}

# ---------------------------------------------------------------------------
# 4. ssh
# ---------------------------------------------------------------------------
# Collect every key that can already reach this box, so hardening cannot lock
# the operator out.
collect_authorized_keys() {
  local out="$1" src
  : > "$out"
  for src in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -f "$src" ]] && cat "$src" >> "$out"
  done
  grep -E '^(ssh-|ecdsa-|sk-)' "$out" | sort -u > "${out}.clean" || true
  mv "${out}.clean" "$out"
  wc -l < "$out"
}

harden_ssh() {
  local keyfile="${OC_HOME}/.ssh/authorized_keys" tmp key_count
  tmp="$(mktemp)"
  key_count="$(collect_authorized_keys "$tmp")"
  if [[ -s "$tmp" ]]; then
    install -m 0600 -o "$OC_USER" -g "$OC_USER" "$tmp" "$keyfile"
    log "Installed ${key_count} SSH public key(s) for ${OC_USER}"
  fi
  rm -f "$tmp"

  if [[ ! -s "$keyfile" && "${FORCE_SSH_HARDENING:-0}" != "1" ]]; then
    warn "No SSH public key found for ${OC_USER}."
    warn "Refusing to disable password auth - that would lock you out."
    warn "Add a key to ${keyfile}, then re-run setup.sh (or set FORCE_SSH_HARDENING=1)."
    return
  fi

  local conf=/etc/ssh/sshd_config.d/99-openclaw-hardening.conf
  cat > "$conf" <<'SSHCONF'
# Managed by openclaw-vps setup.sh
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
SSHCONF
  chmod 644 "$conf"
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl restart ssh
    log "sshd hardened: no root login, key auth only"
  else
    rm -f "$conf"
    sshd -t || true
    die "sshd rejected the hardening config; reverted. Fix /etc/ssh/sshd_config and re-run."
  fi
}

# ---------------------------------------------------------------------------
# 5. fail2ban
# ---------------------------------------------------------------------------
configure_fail2ban() {
  cat > /etc/fail2ban/jail.d/openclaw-sshd.local <<'F2B'
# Managed by openclaw-vps setup.sh
[sshd]
enabled  = true
backend  = systemd
port     = ssh
maxretry = 4
findtime = 10m
bantime  = 1h
F2B
  systemctl enable --now fail2ban >/dev/null
  systemctl restart fail2ban
  log "fail2ban sshd jail active"
}

# ---------------------------------------------------------------------------
# 6. unattended upgrades
# ---------------------------------------------------------------------------
configure_unattended_upgrades() {
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUTOUP'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTOUP
  # Security updates only; no automatic reboots on an interactive agent host.
  cat > /etc/apt/apt.conf.d/51openclaw-unattended <<'AUTOUP2'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
AUTOUP2
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  log "unattended-upgrades enabled (security updates, no auto-reboot)"
}

# ---------------------------------------------------------------------------
# 7. node
# ---------------------------------------------------------------------------
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

install_node() {
  if have node && version_ge "$(node -v | tr -d v)" "$NODE_MIN_VERSION"; then
    info "Node $(node -v) already satisfies >= ${NODE_MIN_VERSION}."
  else
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  fi
  version_ge "$(node -v | tr -d v)" "$NODE_MIN_VERSION" \
    || die "Node $(node -v) is below OpenClaw's minimum ${NODE_MIN_VERSION}."
  log "Node $(node -v), npm $(npm -v)"

  # Per-user npm prefix so the runtime user can install global CLIs without sudo.
  install -d -m 0755 -o "$OC_USER" -g "$OC_USER" "${OC_HOME}/.npm-global"
  runuser -u "$OC_USER" -- npm config set prefix "${OC_HOME}/.npm-global"
  local profile="${OC_HOME}/.profile"
  if ! grep -q '.npm-global/bin' "$profile" 2>/dev/null; then
    # shellcheck disable=SC2016  # $HOME must stay literal inside .profile
    printf '\n# openclaw-vps\nexport PATH="$HOME/.npm-global/bin:$PATH"\n' >> "$profile"
    chown "$OC_USER:$OC_USER" "$profile"
  fi
}

# ---------------------------------------------------------------------------
# 8. browser
# ---------------------------------------------------------------------------
install_chrome_stable() {
  if ! have google-chrome-stable; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor --yes -o /etc/apt/keyrings/google-chrome.gpg
    printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main\n' \
      > /etc/apt/sources.list.d/google-chrome.list
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-stable
  fi
  CHROME_PATH="$(command -v google-chrome-stable)"
  log "Chrome: $("$CHROME_PATH" --version)"
}

install_playwright_chromium() {
  # `--with-deps` installs the apt libraries a headless Chromium needs.
  DEBIAN_FRONTEND=noninteractive npx --yes playwright@latest install --with-deps chromium
  # Install the browser into the runtime user's own cache so OpenClaw's
  # auto-detect (~/.cache/ms-playwright) finds it.
  as_oc 'npx --yes playwright@latest install chromium'
  CHROME_PATH=""
  log "Playwright Chromium installed for ${OC_USER}"
}

install_browser() {
  # Fonts + utils that a headless Chrome needs for sane rendering.
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    fonts-liberation fonts-noto-color-emoji xdg-utils
  case "$BROWSER_ENGINE" in
    chrome)     install_chrome_stable ;;
    playwright) install_playwright_chromium ;;
    *) die "BROWSER_ENGINE must be 'chrome' or 'playwright', got '${BROWSER_ENGINE}'." ;;
  esac
}

# ---------------------------------------------------------------------------
# 9. tailscale
# ---------------------------------------------------------------------------
install_tailscale() {
  have tailscale || curl -fsSL https://tailscale.com/install.sh | sh
  local state
  state="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"')"
  if [[ "$state" == "Running" ]]; then
    info "Tailscale already up as $(tailscale status --json | jq -r '.Self.DNSName')"
    return
  fi
  if [[ -z "${TAILSCALE_AUTHKEY:-}" ]]; then
    warn "TAILSCALE_AUTHKEY is empty. Tailscale is installed but not connected."
    warn "Finish it later with: sudo tailscale up --hostname ${TAILSCALE_HOSTNAME:-openclaw-vps}"
    return
  fi
  tailscale up \
    --authkey "$TAILSCALE_AUTHKEY" \
    --hostname "${TAILSCALE_HOSTNAME:-openclaw-vps}" \
    --accept-dns=false
  log "Tailscale up: $(tailscale ip -4 2>/dev/null | head -1)"
}

# ---------------------------------------------------------------------------
# 10. ufw
# ---------------------------------------------------------------------------
configure_ufw() {
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow OpenSSH >/dev/null
  # Everything administrative (Gateway, Control UI, browser control) is reached
  # over the tailnet, never the public interface.
  if ip link show tailscale0 >/dev/null 2>&1; then
    ufw allow in on tailscale0 to any >/dev/null
    log "UFW: allow in on tailscale0"
  else
    warn "tailscale0 interface not present yet; re-run setup.sh after 'tailscale up' to add the rule."
  fi
  ufw --force enable >/dev/null
  # Belt and braces: the Gateway binds to loopback, and this rule documents it.
  ufw deny "${GATEWAY_PORT}/tcp" >/dev/null
  log "UFW enabled: deny incoming, OpenSSH + tailscale0 only, ${GATEWAY_PORT} never public"
}

# ---------------------------------------------------------------------------
# 11. linger
# ---------------------------------------------------------------------------
enable_linger() {
  loginctl enable-linger "$OC_USER"
  local uid; uid="$(id -u "$OC_USER")"
  for _ in $(seq 1 20); do
    [[ -d "/run/user/${uid}" ]] && break
    sleep 1
  done
  [[ -d "/run/user/${uid}" ]] || die "/run/user/${uid} never appeared; systemd --user cannot start."
  log "Linger enabled for ${OC_USER} (daemon survives logout and reboots)"
}

# ---------------------------------------------------------------------------
# 12. openclaw
# ---------------------------------------------------------------------------
write_openclaw_env() {
  # The Gateway daemon loads ~/.openclaw/.env, which is how the agent gets its
  # provider key without any secret living in openclaw.json.
  local target="${OC_CONFIG_DIR}/.env" tmp
  tmp="$(mktemp)"
  {
    printf '# Written by openclaw-vps setup.sh. Do not commit.\n'
    printf 'GEMINI_API_KEY=%s\n'          "$GEMINI_API_KEY"
    printf 'TELEGRAM_BOT_TOKEN=%s\n'      "$TELEGRAM_BOT_TOKEN"
    printf 'OPENCLAW_GATEWAY_TOKEN=%s\n'  "$OPENCLAW_GATEWAY_TOKEN"
    printf 'OPENCLAW_GATEWAY_PORT=%s\n'   "$GATEWAY_PORT"
    printf 'OPENCLAW_BROWSER_HEADLESS=1\n'
    [[ -n "${TELEGRAM_CHAT_ID:-}" ]] && printf 'TELEGRAM_CHAT_ID=%s\n' "$TELEGRAM_CHAT_ID"
    [[ -n "${TELEGRAM_USER_ID:-}" ]] && printf 'TELEGRAM_USER_ID=%s\n' "$TELEGRAM_USER_ID"
  } > "$tmp"
  install -m 0600 -o "$OC_USER" -g "$OC_USER" "$tmp" "$target"
  rm -f "$tmp"
  log "Wrote ${target} (0600)"
}

install_openclaw() {
  write_openclaw_env
  if as_oc 'command -v openclaw >/dev/null 2>&1'; then
    info "OpenClaw already installed: $(as_oc 'openclaw --version' | tail -1)"
    return
  fi
  info "Running the official installer (onboarding deferred to the next step)."
  if ! as_oc 'curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard'; then
    warn "Official installer failed; falling back to npm."
  fi
  if ! as_oc 'command -v openclaw >/dev/null 2>&1'; then
    local flag=""
    npm install --help 2>/dev/null | grep -q -- '--allow-scripts' && flag="--allow-scripts=openclaw"
    as_oc "npm install -g openclaw@latest ${flag}" \
      || die "Could not install OpenClaw. See https://docs.openclaw.ai/install"
  fi
  log "OpenClaw installed: $(as_oc 'openclaw --version' | tail -1)"
}

# ---------------------------------------------------------------------------
# 13. onboarding + configuration
# ---------------------------------------------------------------------------
onboard_openclaw() {
  if [[ -f "${OC_CONFIG_DIR}/openclaw.json" ]] \
     && as_oc 'openclaw config get gateway.mode >/dev/null 2>&1'; then
    info "Existing OpenClaw config found; skipping onboarding and re-applying settings."
  else
    run_onboard
  fi
  configure_openclaw
}

run_onboard() {
  # Flags verified against docs.openclaw.ai/cli/onboard and /providers/google.
  # --secret-input-mode ref + --gateway-token-ref-env keeps the Gateway token
  # out of the config file and out of the service's env metadata.
  local args=(
    onboard
    --non-interactive --accept-risk
    --mode local
    --install-daemon
    --daemon-runtime node
    --agent-name main
    --workspace "${OC_HOME}/workspace"
    --auth-choice gemini-api-key
    --gemini-api-key __GEMINI_KEY__
    --gateway-auth token
    --secret-input-mode ref
    --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN
    --gateway-port "$GATEWAY_PORT"
    --skip-channels
    --skip-ui
    --skip-hooks
    --skip-search
  )
  install -d -m 0750 -o "$OC_USER" -g "$OC_USER" "${OC_HOME}/workspace"

  # The placeholder is swapped for a shell expansion that resolves inside the
  # runtime user's shell, where GEMINI_API_KEY arrives via the environment.
  local cmd
  cmd="openclaw $(printf '%q ' "${args[@]}")"
  cmd="${cmd//__GEMINI_KEY__/\"\$GEMINI_API_KEY\"}"

  info "Running: openclaw onboard --non-interactive --accept-risk --install-daemon --auth-choice gemini-api-key ... (key redacted)"
  if as_oc "$cmd"; then
    log "Non-interactive onboarding finished"
    return
  fi
  warn "Onboarding failed with the health wait; retrying with --skip-health."
  if as_oc "${cmd} --skip-health"; then
    log "Onboarding finished (health wait skipped)"
    return
  fi
  print_manual_onboarding
  die "Non-interactive onboarding failed. Follow the wizard steps printed above."
}

print_manual_onboarding() {
  cat <<MANUAL

${C_YELLOW}Interactive fallback${C_RESET} - run this as the ${OC_USER} user:

    sudo -u ${OC_USER} -i
    openclaw onboard --install-daemon

and pick exactly these answers:

    Setup flow ................ QuickStart
    Model provider ............ Google (Gemini)   -> paste your GEMINI_API_KEY
    Default model ............. ${MODEL_REF#google/}
    Gateway mode .............. local
    Gateway auth .............. token  (accept the generated one)
    Install daemon ............ yes
    Channels .................. Telegram (Bot API) -> paste your TELEGRAM_BOT_TOKEN
    Control UI / TUI .......... skip
    Hooks / webhooks .......... skip
    Extra skills / search ..... skip

Then re-run ./setup.sh to apply the remaining configuration.

MANUAL
}

oc_config_set() {
  local key="$1" value="$2" extra="${3:-}"
  as_oc "openclaw config set $(printf '%q' "$key") $(printf '%q' "$value") ${extra}" \
    || warn "config set ${key} failed (key may differ in your OpenClaw version; check 'openclaw config schema')."
}

configure_openclaw() {
  # --- model --------------------------------------------------------------
  oc_config_set agents.defaults.model.primary "$MODEL_REF"

  # --- gateway: loopback only, never reachable from the public interface ---
  oc_config_set gateway.bind loopback
  oc_config_set gateway.port "$GATEWAY_PORT" --strict-json

  # --- telegram -----------------------------------------------------------
  if as_oc 'openclaw config get channels.telegram.enabled 2>/dev/null | grep -q true'; then
    info "Telegram channel already configured."
  else
    # shellcheck disable=SC2016  # expands in the runtime user's shell, not here
    as_oc 'openclaw channels add --channel telegram --token "$TELEGRAM_BOT_TOKEN"' \
      || warn "'openclaw channels add' failed; run 'openclaw channels add --channel telegram --token <token>' by hand."
  fi

  if [[ -n "${TELEGRAM_USER_ID:-}" ]]; then
    # One-owner bot: the docs prefer an explicit numeric allowlist over
    # depending on a previous pairing approval.
    oc_config_set channels.telegram.dmPolicy allowlist
    oc_config_set channels.telegram.allowFrom "[\"${TELEGRAM_USER_ID}\"]"
    oc_config_set channels.telegram.groupPolicy allowlist
    oc_config_set commands.ownerAllowFrom "[\"telegram:${TELEGRAM_USER_ID}\"]"
    log "Telegram locked to user ID ${TELEGRAM_USER_ID} (dmPolicy=allowlist)"
  else
    oc_config_set channels.telegram.dmPolicy pairing
    info "Telegram left on dmPolicy=pairing. DM the bot, then run ./pair.sh."
  fi

  # --- headless browser ---------------------------------------------------
  oc_config_set browser.enabled true
  oc_config_set browser.headless true
  # The VPS has no desktop session and the agent runs unprivileged; Chrome's
  # sandbox needs either user namespaces or this opt-out.
  oc_config_set browser.noSandbox true
  if [[ -n "${CHROME_PATH:-}" ]]; then
    oc_config_set browser.executablePath "$CHROME_PATH"
  else
    info "No explicit executablePath; OpenClaw will auto-detect the Playwright Chromium."
  fi

  as_oc 'openclaw config validate' || warn "openclaw config validate reported problems; run 'openclaw doctor'."
  as_oc 'openclaw gateway restart' || as_oc 'openclaw gateway start' || warn "Could not restart the Gateway; check ./status.sh"

  # Warm the managed browser once so the first Telegram request is not slow.
  as_oc 'openclaw browser start --headless' || warn "Browser warm-up failed; 'openclaw browser doctor' explains why."
  log "OpenClaw configured: model=${MODEL_REF}, headless browser, loopback gateway"
}

# ---------------------------------------------------------------------------
# 14. health check timer
# ---------------------------------------------------------------------------
install_healthcheck() {
  local unit_dir="${OC_HOME}/.config/systemd/user"
  install -d -m 0755 -o "$OC_USER" -g "$OC_USER" "${OC_HOME}/.config" "${OC_HOME}/.config/systemd" "$unit_dir"
  install -d -m 0755 -o "$OC_USER" -g "$OC_USER" "${OC_HOME}/bin"

  install -m 0755 -o "$OC_USER" -g "$OC_USER" \
    "${REPO_DIR}/healthcheck/openclaw-healthcheck.sh" "${OC_HOME}/bin/openclaw-healthcheck.sh"
  install -m 0644 -o "$OC_USER" -g "$OC_USER" \
    "${REPO_DIR}/healthcheck/openclaw-healthcheck.service" "${unit_dir}/openclaw-healthcheck.service"
  install -m 0644 -o "$OC_USER" -g "$OC_USER" \
    "${REPO_DIR}/healthcheck/openclaw-healthcheck.timer" "${unit_dir}/openclaw-healthcheck.timer"
  install -m 0755 -o "$OC_USER" -g "$OC_USER" \
    "${REPO_DIR}/systemd/openclaw-browser-warm.sh" "${OC_HOME}/bin/openclaw-browser-warm.sh"
  install -m 0644 -o "$OC_USER" -g "$OC_USER" \
    "${REPO_DIR}/systemd/openclaw-browser-warm.service" "${unit_dir}/openclaw-browser-warm.service"

  as_oc 'systemctl --user daemon-reload'
  as_oc 'systemctl --user enable --now openclaw-healthcheck.timer'
  as_oc 'systemctl --user enable openclaw-browser-warm.service'
  log "Health check timer active (every 5 min) + browser warm-up on boot"
}

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
final_report() {
  step "Done"
  as_oc 'openclaw gateway status' || true
  cat <<REPORT

${C_GREEN}OpenClaw is installed.${C_RESET}

  runtime user ..... ${OC_USER}  (sudo group, no password set -> no silent escalation)
  config ........... ${OC_CONFIG_DIR}/openclaw.json
  secrets .......... ${OC_CONFIG_DIR}/.env (0600)
  workspace ........ ${OC_HOME}/workspace
  model ............ ${MODEL_REF}
  gateway .......... 127.0.0.1:${GATEWAY_PORT} (loopback only)
  browser control .. 127.0.0.1:$((GATEWAY_PORT + 2)) (loopback only)
  service .......... systemctl --user status openclaw-gateway.service

Next:
REPORT
  if [[ -z "${TELEGRAM_USER_ID:-}" ]]; then
    printf '  1. DM your bot on Telegram, then run:  ./pair.sh\n'
    printf '  2. Ask it:  Open patrimoniouruguay.net and list free events tomorrow\n'
  else
    printf '  1. DM your bot on Telegram - you are already on the allowlist.\n'
    printf '  2. Ask it:  Open patrimoniouruguay.net and list free events tomorrow\n'
  fi
  printf '  3. Watch it work:  ./logs.sh\n\n'
  if [[ -z "${TAILSCALE_AUTHKEY:-}" ]]; then
    warn "Tailscale is not connected. Run: sudo tailscale up --hostname ${TAILSCALE_HOSTNAME:-openclaw-vps}"
    warn "Then re-run ./setup.sh so UFW gets the tailscale0 rule."
  fi
}

main "$@"

# openclaw-vps

Self-host [OpenClaw](https://openclaw.ai) on a fresh Ubuntu 24.04 VPS, drive it
from your phone over Telegram, and let it browse the web with a headless Chrome.
One command on a clean box, reachable only by you.

```
sudo ./setup.sh
```

- **Model**: Google Gemini via the free AI Studio API key.
- **Control plane**: Telegram bot, locked to your numeric user ID.
- **Admin plane**: Tailscale only. The Gateway binds to `127.0.0.1` and UFW
  denies everything inbound except SSH and the tailnet.
- **Survives reboots and logouts**: the Gateway is a systemd *user* service with
  `loginctl enable-linger`.
- **Self-heals**: a user timer probes `/readyz` every 5 minutes, restarts the
  Gateway if it is wedged, and messages you on Telegram.

---

## Contents

| Path | What it does |
| --- | --- |
| `setup.sh` | Idempotent bootstrap: packages, swap, user, sshd, fail2ban, Node 24, Chrome, Tailscale, UFW, linger, OpenClaw install + onboarding, health timer. |
| `pair.sh` | List and approve Telegram pairing requests. |
| `status.sh` | OpenClaw status, Gateway service + probes, channels, browser, host resources. |
| `logs.sh` | `openclaw logs --follow` (extra args pass through). |
| `update.sh` | Backup, then update OpenClaw and the OS, restart, verify. |
| `backup.sh` | Config snapshot to `~/backups`, keeps the last 7. |
| `uninstall.sh` | Confirm-gated removal, with a list of leftovers. |
| `healthcheck/` | Probe script + systemd user service and 5-minute timer. |
| `systemd/` | One-shot unit that warms the headless browser after boot. |
| `lib/common.sh` | Shared logging, `.env` loading, confirmation prompts. |
| `.env.example` | Every knob, documented. |
| `terraform/` | Optional AWS EC2 `t3.medium` + SSH-from-your-IP-only + `user_data` that runs `setup.sh`. |

---

## Prerequisites

1. **A fresh Ubuntu 24.04 VPS** with 2 GB RAM minimum (4 GB recommended — a
   headless Chrome is hungry) and an SSH key already in `authorized_keys`.
2. **Gemini API key** — https://aistudio.google.com/apikey → *Create API key*.
   The free tier is enough to start.
3. **Telegram bot token** — DM [@BotFather](https://t.me/BotFather), send
   `/newbot`, pick a name and a `_bot` username, copy the token.
4. **Your numeric Telegram user ID** (recommended, not required). Easiest safe
   way: leave `TELEGRAM_USER_ID` empty for the first run, DM your bot, and read
   `Your Telegram user id` out of the bot's pairing reply. Then put it in `.env`
   and re-run `setup.sh`. Alternatives: `curl
   "https://api.telegram.org/bot<token>/getUpdates"`, or `openclaw logs --follow`
   and look for `senderUserId` in the `telegram pairing request` entry.
5. **Tailscale auth key** (recommended) —
   https://login.tailscale.com/admin/settings/keys → reusable, pre-authorized,
   not ephemeral.

---

## Run order

```bash
# 1. On your laptop or on the VPS, get the repo onto the box.
git clone <this-repo> openclaw-vps && cd openclaw-vps

# 2. Fill in the config.
cp .env.example .env
chmod 600 .env
$EDITOR .env            # GEMINI_API_KEY, TELEGRAM_BOT_TOKEN, TAILSCALE_AUTHKEY

# 3. Bootstrap. ~8-12 minutes on a t3.medium, mostly apt and npm.
sudo ./setup.sh

# 4. Check it came up.
sudo -u openclaw -i          # become the runtime user
cd /path/to/openclaw-vps
./status.sh
```

`setup.sh` is safe to re-run. Every step checks its own end state first, so a
second run only applies what changed — which is exactly how you add
`TELEGRAM_USER_ID` or a Tailscale key after the fact.

### What setup.sh does, in order

1. `apt update` + `upgrade`, then `curl git jq ufw fail2ban unattended-upgrades`.
2. A 2 GB swap file when the host has under 4 GB RAM (`vm.swappiness=10`).
3. Creates the `openclaw` user, adds it to the `sudo` group, and creates
   `~/.openclaw` at `0700`.
4. Hardens sshd: no root login, no password auth, key auth only, `MaxAuthTries 3`.
   **It copies every `authorized_keys` it can find to the `openclaw` user first,
   and refuses to harden if that leaves zero keys** — locking yourself out of a
   VPS is not a recoverable mistake. Override with `FORCE_SSH_HARDENING=1` if you
   really know better.
5. fail2ban `sshd` jail (systemd backend, 4 retries, 1 h ban).
6. `unattended-upgrades` on, automatic reboots off.
7. Node.js 24 from NodeSource, then asserts `>= 24.16.0` (OpenClaw's floor) and
   points npm's global prefix at `~/.npm-global` so the runtime user never needs
   `sudo` to install a CLI.
8. Google Chrome stable from Google's apt repo — see
   [Browser engine](#browser-engine-why-chrome-and-not-apt-install-chromium).
9. Tailscale, then `tailscale up --authkey` when `TAILSCALE_AUTHKEY` is set.
10. UFW: default deny in, allow out, `allow OpenSSH`, `allow in on tailscale0`,
    and an explicit `deny 18789/tcp` as documentation.
11. `loginctl enable-linger openclaw` and waits for `/run/user/<uid>`.
12. OpenClaw via the official installer (`--no-onboard`), with an
    `npm install -g openclaw@latest` fallback.
13. Non-interactive onboarding, then applies model / Telegram / browser config.
14. Installs the health-check timer and the browser warm-up unit as systemd
    **user** units.

---

## Pair your phone

If you set `TELEGRAM_USER_ID` in `.env`, you are already on the allowlist — just
DM the bot.

Otherwise Telegram's default `dmPolicy` is `pairing`: an unknown sender gets a
pairing code instead of an answer.

```bash
# On your phone: send any message to your bot. It replies with a code.
./pair.sh              # lists pending requests
./pair.sh 123456       # approves and notifies you
```

Then harden it properly — the docs prefer an explicit allowlist over relying on
a past pairing approval for a one-owner bot:

```bash
# put your numeric ID in .env, then
sudo ./setup.sh        # sets dmPolicy=allowlist, allowFrom, commands.ownerAllowFrom
```

> Pairing grants **DM access only**. Owner-only commands and exec approvals come
> from `commands.ownerAllowFrom`, which must contain `telegram:<your user id>`.

---

## Test it

From Telegram, send:

```
Open patrimoniouruguay.net and list free events tomorrow
```

You should see the agent open a tab, snapshot the page, and answer. Watch it
happen from the VPS:

```bash
./logs.sh
```

Smaller smoke tests, in increasing order of what they prove:

```bash
# 1. The model works at all.
#    From Telegram: "what model are you running?"

# 2. The browser works.
openclaw browser status
openclaw browser open https://example.com
openclaw browser snapshot

# 3. The whole loop works.
#    From Telegram: "Open patrimoniouruguay.net and list free events tomorrow"
```

---

## Day-two operations

```bash
./status.sh            # is it healthy?
./logs.sh              # follow the stream
./logs.sh --limit 500  # or any openclaw logs flag
./backup.sh            # snapshot config, rotate to 7
./update.sh            # backup -> update OpenClaw -> update OS -> verify
./update.sh --yes      # unattended, for cron
```

### The health check

`healthcheck/openclaw-healthcheck.sh` runs as a systemd user timer every 5
minutes. It probes the Gateway's own documented endpoints:

| Endpoint | Meaning |
| --- | --- |
| `/healthz` | the HTTP server is live (process liveness) |
| `/startupz` | startup sidecars and agent DB prep have settled |
| `/readyz` | sidecars settled, agent DBs healthy, **and channels pass deep readiness** |

The timer judges on `/readyz`, because a Gateway that is running but whose
Telegram account is broken is useless to you. It only restarts after
`FAIL_THRESHOLD` (default 2) consecutive failures, so one slow startup does not
bounce the daemon, and it rate-limits Telegram alerts to one per 30 minutes.

```bash
systemctl --user list-timers 'openclaw*'
systemctl --user status openclaw-healthcheck.service
journalctl --user -u openclaw-healthcheck.service -n 50
```

Alerts need `TELEGRAM_CHAT_ID` in `.env` (normally the same as
`TELEGRAM_USER_ID`). Without it the script logs the alert and carries on.

---

## Security model

**Network.** The Gateway binds to loopback (`gateway.bind=loopback`, OpenClaw's
default on a regular host install) on port 18789, and the browser control
service on 18791. Neither is ever opened in UFW or in the Terraform security
group. Administration goes over Tailscale; if you want the Control UI, tunnel
it rather than binding it wider:

```bash
ssh -N -L 18789:127.0.0.1:18789 openclaw@<tailscale-ip>
# then open http://127.0.0.1:18789/
```

**Host.** Root SSH off, password auth off, fail2ban on sshd, unattended security
upgrades, UFW default-deny inbound.

**Runtime privileges.** The `openclaw` user is in the `sudo` group (so you can
administer the box through it) but **has no password**. Ubuntu's `%sudo` rule
requires one, so the agent runtime cannot escalate non-interactively — there is
no `NOPASSWD` drop-in anywhere in this repo. If you want interactive sudo:

```bash
sudo passwd openclaw       # as root
```

Run `update.sh` as root for the OS phase, or set that password.

**Secrets.** Nothing is hardcoded. `.env` is `chmod 600`; `setup.sh` installs a
`0600` copy at `/home/openclaw/.openclaw/.env`, which is the env file the
Gateway daemon reads. The Gateway auth token is stored as an env *SecretRef*
(`--secret-input-mode ref --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN`), so it
is not written as plaintext into `openclaw.json` or the service's env metadata.

**Agent blast radius.** Headless Chrome runs with `noSandbox: true` because
there is no desktop session and the user is unprivileged. Treat the browser as
hostile-input-facing: OpenClaw's SSRF policy blocks private-network targets by
default, and you should leave it that way.

### What NOT to give this agent

This agent reads attacker-controlled web pages and acts on them. Prompt
injection from a page it visits is a realistic threat, not a hypothetical. So:

- **No bank, broker, crypto or payment logins.** Not in the browser profile, not
  in a password manager it can reach, not as a "just this once" paste.
- **No work SSO, no corporate email, no company VPN.** One injected instruction
  and you have an incident report to write.
- **No personal email account you use for password resets.** Email access is
  account-recovery access to everything else.
- **No cloud provider credentials** beyond what this one box needs. Never attach
  an AWS instance profile with write permissions (the Terraform here attaches
  none, and pins IMDSv2 for the same reason).
- **No SSH keys to other hosts** in `~/.ssh` on this box.
- **No shared household or family accounts** — the blast radius is not only
  yours.

What it is fine to give it: public web browsing, scratch files in its own
workspace, a throwaway account on a service you do not care about, and
read-only API keys with a spend cap.

If you want more containment than that, read
[Sandboxing](https://docs.openclaw.ai/gateway/sandboxing) and
[Sandbox vs tool policy vs elevated](https://docs.openclaw.ai/gateway/sandbox-vs-tool-policy-vs-elevated),
and narrow the tool policy per DM with
`channels.telegram.direct.<chatId>.tools`.

---

## Browser engine: why Chrome and not `apt install chromium`

OpenClaw's own Linux troubleshooting page is blunt about this: on Ubuntu,
`apt install chromium` installs a **snap wrapper**, and snap's AppArmor
confinement interferes with how OpenClaw spawns and monitors the browser. The
symptom is `Failed to start Chrome CDP on port 18800`. The documented fix is
Google Chrome, so that is the default here (`BROWSER_ENGINE=chrome`), installed
from Google's apt repo so it keeps getting updates. The applied config is:

```json
{
  "browser": {
    "enabled": true,
    "headless": true,
    "noSandbox": true,
    "executablePath": "/usr/bin/google-chrome-stable"
  }
}
```

`BROWSER_ENGINE=playwright` is the alternative: it runs
`npx playwright install --with-deps chromium` (which is what pulls in the apt
libraries a headless browser needs) and installs the browser into the runtime
user's `~/.cache/ms-playwright`, where OpenClaw's auto-detect finds it. This is
forced on `arm64`, since Google ships no arm64 Chrome `.deb`.

On headless mode: `browser.headless: true` in the config is what makes **every**
managed launch headless, and OpenClaw also falls back to headless on Linux when
`DISPLAY` and `WAYLAND_DISPLAY` are both unset. `openclaw browser start
--headless` applies to that one start request only — there is no flag that ties
the browser's lifecycle to the daemon, so `systemd/openclaw-browser-warm.service`
issues that one-shot start after the Gateway reports ready, purely so your first
Telegram request is not a cold Chrome launch.

---

## Model choice

`.env` sets `OPENCLAW_MODEL`, applied to `agents.defaults.model.primary`. A bare
id is prefixed with `google/`.

**`gemini-2.5-flash` is not in OpenClaw's current Google catalog.** From 2.5
only `google/gemini-2.5-pro` and the `gemini-2.5-*-preview-tts` voices remain
listed. The verified flash-tier text ids are **`gemini-3.8-flash`** (the default
here) and `gemini-3.6-flash`. Confirm what your install actually offers:

```bash
openclaw models list --provider google
```

Then change it without re-running setup:

```bash
openclaw config set agents.defaults.model.primary google/gemini-3.8-flash
openclaw gateway restart
```

OpenClaw accepts `GEMINI_API_KEY` or `GOOGLE_API_KEY` for the `google` provider.

---

## Troubleshooting

**Start here.**

```bash
openclaw doctor            # diagnoses config, service, token, plugins
openclaw doctor --fix      # applies the repairs it can
./status.sh
./logs.sh
```

| Symptom | Where to look |
| --- | --- |
| Bot never answers | `openclaw channels status --probe`, then `./logs.sh`. Check `dmPolicy` and whether your ID is in `allowFrom`. |
| `Failed to start Chrome CDP on port 18800` | Snap Chromium. See [Browser engine](#browser-engine-why-chrome-and-not-apt-install-chromium); `openclaw browser doctor`. |
| `/readyz` returns 503, `/healthz` is fine | A channel or agent DB is unhealthy, not the HTTP server. `openclaw channels status --probe`. |
| Gateway dies after you log out | Linger. `loginctl show-user openclaw` and check `Linger=yes`, then `sudo loginctl enable-linger openclaw`. |
| `openclaw: command not found` as the openclaw user | `~/.npm-global/bin` missing from PATH. `source ~/.profile`. |
| Model errors / quota | `openclaw models list --provider google`; check the key at aistudio.google.com. |
| Daemon cannot see `GEMINI_API_KEY` | It must be in `~/.openclaw/.env` (setup.sh puts it there). `openclaw gateway restart` after editing. |
| Changed `gateway.port` | `openclaw doctor --fix` or `openclaw gateway install --force`, so systemd starts on the new port. |
| Out of memory during install | The 2 GB swap file. `swapon --show`; re-run `sudo ./setup.sh`. |

Service-level digging:

```bash
systemctl --user status openclaw-gateway.service
journalctl --user -u openclaw-gateway.service -n 200 --no-pager
openclaw gateway status --deep --json | jq .
openclaw config validate
```

---

## Uninstall

```bash
./uninstall.sh --dry-run    # show what would go
./uninstall.sh              # remove the Gateway service, keep config + workspace
./uninstall.sh --all        # remove service + all state + workspace (two confirmations)
```

Both paths take a backup first. `--all` prints the list of host-level leftovers
(Node, Chrome, Tailscale, the sshd drop-in, fail2ban jail, swap file, the user)
with the exact command for each.

---

## Optional: Terraform (AWS EC2)

Creates one `t3.medium` Ubuntu 24.04 instance whose security group allows **only
SSH from your IP**, with `user_data` that clones this repo, writes `.env`, and
runs `setup.sh`. No ingress rule exists for 18789 or 18791, by design. The root
volume is encrypted and IMDSv2 is required — this box runs a browser that
fetches arbitrary URLs, so a token-less metadata endpoint is not acceptable.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
chmod 600 terraform.tfvars
$EDITOR terraform.tfvars      # my_ip, key_pair_name, repo_url, the three secrets

terraform init
terraform plan
terraform apply

terraform output bootstrap_log   # the command to watch setup.sh run
```

`repo_url` must be reachable from the instance. For a private repo, either make
it public, use a deploy-token URL, or bake the repo into an AMI instead.

Secrets land in `terraform.tfvars` and in Terraform state — state is sensitive,
so use an encrypted remote backend if this is anything but a personal box.

Tear down with `terraform destroy`. That deletes the instance and its EBS
volume, so run `./backup.sh` and copy the archive off the box first.

---

## Notes on command verification

Every OpenClaw command and flag in this repo was checked against
[docs.openclaw.ai](https://docs.openclaw.ai) before use. Where the docs and the
original plan disagreed, the docs won:

| Planned | What the docs say | What this repo does |
| --- | --- | --- |
| `openclaw onboard --install-daemon` non-interactively | Supported. `--non-interactive` **requires `--accept-risk`**. | Passes both, plus `--mode local`, `--auth-choice gemini-api-key`, `--gemini-api-key`, `--gateway-auth token`, `--secret-input-mode ref`, `--gateway-token-ref-env`, `--skip-channels/-ui/-hooks/-search`. Retries with `--skip-health`, then prints the exact wizard answers. |
| `openclaw pairing approve telegram <CODE> --notify` | Exists verbatim. | Used as-is. |
| `openclaw logs --follow` | Exists. | Used as-is. |
| `OPENCLAW_MODEL=gemini-2.5-flash` | Not in the Google catalog. | Defaults to `google/gemini-3.8-flash`, overridable. |
| `apt install chromium` + Playwright `--with-deps` | Ubuntu's `chromium` is a snap wrapper that breaks OpenClaw's CDP launch; Chrome is the documented fix. | Chrome by default; `BROWSER_ENGINE=playwright` keeps the `--with-deps chromium` path. |
| `openclaw browser start --headless` starts with the daemon | The flag is **per-start-request only**; `browser.headless` is the persistent setting. | Sets `browser.headless: true` and adds a one-shot warm-up unit after the Gateway is ready. |
| "tar the config dir" | `openclaw backup create --only-config --verify --output <dir>` exists and is restorable. | Uses the CLI, falls back to `tar` of `~/.openclaw`. |
| Gateway exposed for health checks | Three documented unauthenticated probe pairs: `/healthz`, `/startupz`, `/readyz`. | Probes them on loopback; nothing is exposed. |
| Node 24 | OpenClaw needs **24.16+ or 26.1+**. | Installs Node 24 from NodeSource and asserts `>= 24.16.0`. |

All shell scripts pass `shellcheck -x -S style` cleanly. The only suppressions are
two `SC2016` disables on lines that deliberately keep `$HOME` and
`$TELEGRAM_BOT_TOKEN` unexpanded so they resolve in the runtime user's shell
instead of leaking a secret onto a command line.

### Reference

- [Install](https://docs.openclaw.ai/install) · [Linux platform](https://docs.openclaw.ai/platforms/linux)
- [`openclaw onboard`](https://docs.openclaw.ai/cli/onboard) · [CLI reference](https://docs.openclaw.ai/cli)
- [Google (Gemini) provider](https://docs.openclaw.ai/providers/google)
- [Telegram setup](https://docs.openclaw.ai/channels/telegram/setup) · [Telegram access control](https://docs.openclaw.ai/channels/telegram/access-control)
- [`openclaw pairing`](https://docs.openclaw.ai/cli/pairing) · [`openclaw logs`](https://docs.openclaw.ai/cli/logs) · [`openclaw config`](https://docs.openclaw.ai/cli/config) · [`openclaw update`](https://docs.openclaw.ai/cli/update) · [`openclaw backup`](https://docs.openclaw.ai/cli/backup) · [`openclaw uninstall`](https://docs.openclaw.ai/cli/uninstall)
- [Gateway service](https://docs.openclaw.ai/cli/gateway/service) · [Gateway queries](https://docs.openclaw.ai/cli/gateway/query) · [Gateway health](https://docs.openclaw.ai/gateway/health) · [Gateway security](https://docs.openclaw.ai/gateway/security)
- [Browser configuration](https://docs.openclaw.ai/tools/browser/configuration) · [Browser troubleshooting (Linux)](https://docs.openclaw.ai/tools/browser-linux-troubleshooting) · [`openclaw browser`](https://docs.openclaw.ai/cli/browser)

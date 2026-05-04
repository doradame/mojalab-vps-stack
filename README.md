# mojalab-vps-stack

> A browser-first homelab on a single VPS. Files, terminal, services — all behind one SSO+2FA gate.

This repository is a working Docker Compose stack you can clone, configure, and deploy on any reasonably-sized VPS — a homelab where every useful thing is reachable from a browser, behind a real authentication gate, on a server you fully control.

The stack is small on purpose: nine containers, one network, one Caddyfile.

---

## What's in the box

| Service | Purpose | Subdomain |
|---|---|---|
| **Caddy** | Reverse proxy with automatic HTTPS (custom build with `replace-response` for the mobile keyboard overlay) | _routes everything_ |
| **Authelia** | Single sign-on with TOTP 2FA | `auth.{your-domain}` |
| **Home** | Landing page with links to every service (served by Caddy) | `home.{your-domain}` |
| **Filestash** | Web file manager | `files.{your-domain}` |
| **Zellij** | Persistent web terminal + dev container (Node 20, Python, [Claude Code](https://github.com/anthropics/claude-code)) | `term.{your-domain}` |
| **wetty** | Mobile-friendly terminal (web SSH) with virtual keyboard overlay, attaches to same Zellij session | `mterm.{your-domain}` |
| **Glances** | System metrics dashboard | `stats.{your-domain}` |
| **Watchtower** | Update notifications (monitor-only) | _via Telegram bot_ |
| **tgbot** | Interactive Telegram bot: status commands + proactive alerts (disk/RAM/load, SSH/Authelia logins, heartbeat) | _Telegram_ |
| **dockerproxy** | Read-only Docker socket for Watchtower & Glances | _internal_ |

---

## Disclaimer (please read)

This is a **personal homelab setup**, published as-is for educational purposes. It works on my Hetzner CX22 and on similar VPSes I've tested. It is **not**:

- Production-grade infrastructure for a team or company
- Audited for compliance with any regulation (GDPR, ISO 27001, SOC2, etc.)
- A replacement for proper backups (it doesn't back anything up)
- Zero-trust (one gate covers everything behind it)

If you deploy this on the public internet, you are responsible for the security of your VPS, your data, and any traffic that flows through it. Read the configs before running them. **Don't blindly trust someone else's homelab repo on GitHub** — including this one.

The MIT license at the bottom is real: do whatever you want, no warranty of any kind.

---

## Prerequisites

Before you start, you should have:

1. **A VPS running Ubuntu 22.04 or 24.04** (or any modern Linux with systemd and Docker support). Tested on Hetzner CX22 (€4.51/month, Falkenstein/Helsinki). Should work on DigitalOcean, OVH, Linode, etc.
2. **A domain you control**, with the ability to add A records. You'll create six subdomains: `auth.{domain}`, `home.{domain}`, `files.{domain}`, `term.{domain}`, `mterm.{domain}`, `stats.{domain}`. All six must point to your VPS public IP.
3. **Docker and Docker Compose v2 installed** on the VPS. If your VPS is bare, install Docker Engine following the [official guide](https://docs.docker.com/engine/install/).
4. **A Telegram bot** for Watchtower notifications. Talk to [@BotFather](https://t.me/BotFather) to create one. Optional but recommended.
5. **An authenticator app** on your phone (Aegis, Authy, 1Password, Google Authenticator) for the TOTP second factor.

---

## Quickstart (the easy path)

If you'd rather not run the steps below by hand, the repo ships an interactive installer that does everything: prompts for domain/email/Telegram/user, optionally creates DNS A records via Cloudflare, configures UFW, generates secrets, hashes the password, renders the Authelia config, waits for DNS propagation, brings the stack up, and prints the Zellij token.

```bash
git clone https://github.com/doradame/mojalab-vps-stack.git
cd mojalab-vps-stack
./scripts/install.sh
```

The installer is idempotent — re-run it after fixing a problem. Read on for the manual path if you prefer to understand each step.

---

## Setup, end to end

The whole process takes 30–60 minutes the first time, mostly waiting for DNS propagation and Let's Encrypt cert issuance.

### 1. Clone the repo on your VPS

```bash
git clone https://github.com/doradame/mojalab-vps-stack.git
cd mojalab-vps-stack
```

### 2. Configure your domain

Copy the env template and fill it in:

```bash
cp .env.example .env
vim .env
```

Set:
- `DOMAIN` — e.g. `lab.example.com`. Your subdomains will be `auth.lab.example.com`, `files.lab.example.com`, etc.
- `TZ` — your timezone, e.g. `Europe/Rome`.
- `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` — for Watchtower digests. Leave empty if you'll skip Telegram for now.
- `SMTP_HOST` / `SMTP_PORT` / `SMTP_USERNAME` / `SMTP_PASSWORD` / `SMTP_SENDER` — used by Authelia to deliver the TOTP enrollment email. Defaults target [Resend](https://resend.com); leave `SMTP_HOST` empty to fall back to the filesystem notifier (codes readable with `docker compose exec authelia cat /config/notification.txt`). On Hetzner port `465` is often blocked outbound — use `587` if you see timeouts.

### 3. Create the six DNS A records

In your DNS provider's dashboard, create:

```
auth.lab.example.com   A   <YOUR_VPS_PUBLIC_IP>
home.lab.example.com   A   <YOUR_VPS_PUBLIC_IP>
files.lab.example.com  A   <YOUR_VPS_PUBLIC_IP>
term.lab.example.com   A   <YOUR_VPS_PUBLIC_IP>
mterm.lab.example.com  A   <YOUR_VPS_PUBLIC_IP>
stats.lab.example.com  A   <YOUR_VPS_PUBLIC_IP>
```

Wait 5–10 minutes for propagation. Verify with `dig auth.lab.example.com +short` — it should return your VPS IP.

### 4. Bootstrap Authelia secrets

Authelia needs three random secrets (JWT, session, storage encryption). The included script generates them once and stores them under `authelia/secrets/`, which is gitignored.

```bash
./scripts/bootstrap-secrets.sh
```

### 5. Create your user

Generate an argon2 password hash:

```bash
./scripts/generate-password-hash.sh
```

Enter your password when prompted (input is hidden). Copy the resulting hash.

Now create the user database:

```bash
cp authelia/users_database.yml.example authelia/users_database.yml
vim authelia/users_database.yml
```

Paste the hash you just generated, set your username and email.

### 6. Render the Authelia configuration with your domain

The Authelia config lives as a template at `authelia/configuration.yml.template`. It uses `${DOMAIN}` placeholders that are substituted at render time:

```bash
./scripts/render-authelia-config.sh
```

This produces `authelia/configuration.yml` (gitignored). Re-run any time you change `DOMAIN` in `.env`.

### 7. Prepare the shared data directory and lab state dir

The stack uses **two** host directories:

- **`/srv`** — public workspace, mounted into Filestash *and* Zellij. Anything you put here is browseable from the file manager and editable from the terminal.
- **`/var/lib/mojalab/lab`** (override with `LAB_STATE_DIR` in `.env`) — private dev state for the `lab` user inside the Zellij container: pip `--user` installs, npm globals, `~/.config`, Claude Code auth, npm cache, `secrets.env` (API keys). Kept **out of `/srv` on purpose** so Filestash cannot expose your credentials to the web.

Create them with the right ownership (UID 1000 = `lab` inside the container):

```bash
sudo mkdir -p /srv
sudo chown 1000:1000 /srv
sudo chmod 2775 /srv          # group-write + setgid so new files inherit the group

sudo mkdir -p /var/lib/mojalab/lab/{local,config,claude,npm}
sudo chown -R 1000:1000 /var/lib/mojalab/lab
sudo chmod 700 /var/lib/mojalab/lab/claude
```

(The interactive `./scripts/install.sh` does all of this for you.)

### 8. Start the stack

```bash
docker compose up -d
```

The first start takes 3–5 minutes. Caddy is built locally (multi-stage `xcaddy` build to add the `replace-response` module) and then requests TLS certificates from Let's Encrypt for all six subdomains. If anything fails at this stage, see **Troubleshooting** below.

Verify everything is up:

```bash
docker compose ps
```

All services should show `running` or `healthy`.

### 9. First login + TOTP enrollment

Open `https://files.lab.example.com` in your browser. You should be redirected to Authelia (`auth.lab.example.com`). Log in with the username and password you set.

After password authentication, Authelia will prompt you to set up a second factor. Click "Methods" → "Time-based One-Time Password" → "Register Device". Authelia shows a QR code. Scan it with your authenticator app. Enter the 6-digit code to confirm.

You're now fully enrolled. From this point on, every login requires password + TOTP code.

### 10. Generate a Zellij web token

Zellij's web client requires its own token in addition to Authelia. Generate one inside the Zellij container:

```bash
docker compose exec zellij zellij web --create-token
```

Copy the token. The first time you visit `term.lab.example.com` (after authenticating via Authelia), Zellij will ask for this token. Paste it. The token is stored as a hash; it never gets logged in plaintext.

The token is persisted in the `zellij_cache` named volume, so it survives container rebuilds. To force a fresh token, remove the volume: `docker compose down && docker volume rm mojalab-vps-stack_zellij_cache`.

**Mobile access.** From your phone, open `mterm.lab.example.com` instead. It serves a touch-friendly web terminal (wetty) that SSHs into the Zellij container as user `lab` and auto-attaches to the **same** session named `main`. Whatever a desktop client is running — Claude Code, OpenCode, a long build — you see it live on the phone. No Zellij token needed there: Authelia gates the route, the SSH key is generated on first boot and never leaves the internal Docker network.

A virtual keyboard overlay sits at the bottom of the wetty page on touch devices: arrows, Tab, Esc, sticky **Ctrl/Alt** (tap = single-shot, long-press = lock), and three swipeable key sets — **zellij** (pane/tab shortcuts), **vim** (motions, save/quit), **F1–F12**. Swipe left/right on the overlay to cycle sets. See [Mobile keyboard overlay](#mobile-keyboard-overlay) below for details.

### Dev container (Node, Python, Claude Code)

The Zellij container is also a ready-to-use development environment:

- **Node 20** + global npm prefix at `~/.local` (so `npm install -g` works without sudo)
- **Python 3** + `pipx` (`PIP_USER=1`, `PYTHONUSERBASE=~/.local`)
- **[Claude Code](https://github.com/anthropics/claude-code)** preinstalled (`@anthropic-ai/claude-code`)
- **Standard tools**: `git`, `curl`, `jq`, `fd-find`, `ripgrep`, `build-essential`, `socat`
- **API keys persist** across container rebuilds: drop `export ANTHROPIC_API_KEY=…` into `~/.local/share/secrets.env` (mode 600, sourced by `~/.bashrc`)
- **Project workspace** at `~/workspace` → bind-mounted from the host's `/srv/workspace` (so Filestash can see the projects, but **not** the credentials)

A `docker compose up -d --build zellij` rebuilds the image without losing any of the user state, because everything that matters lives in bind mounts under `${LAB_STATE_DIR}` and the named volumes for Zellij data.

### 11. (Optional) Verify Telegram notifications

Watchtower runs its first check at 5 AM UTC the next day. To verify the Telegram setup works *now*, send a test notification:

```bash
docker compose exec watchtower /watchtower --run-once --debug
```

You should receive a Telegram message within a few seconds.

Then send `/ping` to your bot from Telegram — the **tgbot** service should answer immediately. Try `/help` for the full command list (see [Telegram bot](#telegram-bot) below).

You're done. Open `files.lab.example.com` from your phone, your laptop, your friend's tablet — anywhere with a browser — log in once, and the workshop is yours.

---

## Telegram bot

The **tgbot** container provides two things:

### Interactive commands

Send any of these to your bot from Telegram:

| Command | Action |
|---|---|
| `/ping` | Bot alive check |
| `/stats` | CPU, RAM, swap, load, uptime |
| `/df` | Disk usage per filesystem |
| `/uptime` | Uptime + load averages |
| `/alerts` | Show alert thresholds |
| `/mute N` | Silence proactive alerts for N minutes (default 60) |
| `/resume` | Un-mute alerts |
| `/help` | Command list |

### Proactive alerts

A background watcher pushes a Telegram message when something interesting happens. All thresholds are configurable in `.env`:

| Variable | Default | What it does |
|---|---|---|
| `ALERT_DISK_PCT` | `85` | Warn when any filesystem reaches this % full |
| `ALERT_MEM_PCT` | `90` | Warn when RAM usage exceeds this % |
| `ALERT_LOAD` | `0` | Warn when 1-min load avg ≥ this integer (0 = off) |
| `HEARTBEAT_HOURS` | `3` | Send an "all good" summary every N hours (0 = no heartbeat) |
| `ALERT_SSH` | `1` | Alert on every successful SSH login to the host |
| `ALERT_AUTHELIA` | `1` | Alert on every Authelia 1FA/2FA login event |
| `ALERT_COOLDOWN` | `3600` | Seconds between repeats of the same alert |

Set any to `0` to disable that watcher. Mute everything temporarily with `/mute 30`.

---

## Mobile keyboard overlay

Mobile soft keyboards don't ship Esc, Tab, arrows, Ctrl, or function keys — exactly the keys a terminal user needs. The `mterm.{domain}` route injects a small JS/CSS overlay into the wetty page that adds them back.

**How to use it:**

- **Always-on row**: arrows, Esc, Tab, `~`, `|`, `/`, the set indicator, swipe affordance
- **Sticky modifiers** — tap `Ctrl` once for single-shot (next key is sent with Ctrl, then Ctrl auto-releases). Long-press (≥0.5s) to **lock** Ctrl on until tapped off again. Same for `Alt`. Visual states: `armed` (orange pulse) and `locked` (solid red).
- **Three key sets** (swipe left/right on the overlay to cycle, or tap the indicator):
  - **zellij** — pane/tab/move shortcuts (`Alt+n`, `Alt+arrows`, `Ctrl+p`, `Ctrl+t`…)
  - **vim** — `:`, `Esc`, `:w`, `:q`, `:wq`, `gg`, `G`, motions
  - **fkeys** — `F1`–`F12`

The overlay is pure vanilla JS, no framework, ~10 KB total. It's bind-mounted into Caddy at `/srv/wetty-overlay` and injected into wetty's HTML via Caddy's `replace-response` module — so wetty itself stays untouched and any future wetty release just works.

Source: [`caddy/overlay/wetty-overlay.js`](./caddy/overlay/wetty-overlay.js), [`caddy/overlay/wetty-overlay.css`](./caddy/overlay/wetty-overlay.css).

---

## Daily operations

**Updating containers.** When Watchtower's daily digest tells you something has a new version, read the project's release notes, then on the VPS:

```bash
cd mojalab-vps-stack
docker compose pull
docker compose up -d
docker image prune -f   # remove old images
```

**Backing up.** This stack does *not* back up your data. The directories that matter are:
- `authelia/` (your user DB and TOTP secrets)
- `/srv/` (whatever services running behind Authelia store there)
- The Caddy data volume (TLS certificates — re-issuable, but nice to keep)

I use a CryptoSync-style setup against a Wasabi bucket. See the [CryptoSync repo](https://github.com/doradame/CryptoSync) for one approach. Use whatever you like, but **back up something**.

**Adding a new service.** Add the service to `docker-compose.yml` on the `lab` network, expose its port internally only (not in `ports:`), then add a block to `Caddyfile`:

```caddy
newservice.{$DOMAIN} {
    forward_auth authelia:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }
    reverse_proxy newservice:PORT
}
```

Add the corresponding DNS A record. Reload:

```bash
docker compose up -d
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

The new service inherits the auth layer for free.

---

## Troubleshooting

**Caddy can't get a certificate.** Check that the six subdomains resolve to your VPS IP (`dig +short auth.lab.example.com`). Check that ports 80 and 443 are open in your VPS firewall and not bound by anything else. Check Caddy logs: `docker compose logs caddy`.

**Caddy keeps restarting after a config change.** The `mterm` block uses the `replace-response` module which is bundled into a custom Caddy image (`mojalab/caddy:replace-response`). If you edited the Caddyfile and Caddy refuses to start, run `docker compose build caddy && docker compose up -d caddy` and check `docker compose logs caddy` for the exact syntax error.

**wetty shows "permission denied (publickey)" or logs in as the wrong user.** wetty SSHes into the Zellij container as `lab` using a key generated on first boot. Make sure the Caddyfile `mterm` block strips Authelia's `Remote-User` header (`header_up -Remote-User` inside the `reverse_proxy` block) — otherwise wetty tries to use *your* Authelia username as the SSH login.

**Arrow keys / Ctrl / function keys don't work in wetty.** The `wetty` service must export `TERM=xterm-256color` and the Zellij container's `sshd_config` must include `AcceptEnv LANG LC_* TERM`. Both are set in this repo; verify with `docker compose exec zellij grep AcceptEnv /etc/ssh/sshd_config`.

**Authelia won't start.** Most often a config typo in `configuration.yml` or missing secret files. Run `./scripts/bootstrap-secrets.sh` again (it's idempotent), and check `docker compose logs authelia`.

**TOTP code doesn't work.** Your phone's clock is probably out of sync. TOTP relies on time. Toggle automatic time on/off on your phone, retry.

**Filestash shows "Backend not configured".** Filestash needs a one-time admin setup the first time you reach it. Visit `files.lab.example.com/admin` (yes, after Authelia auth), set an admin password, then add a "Local backend" pointing at `/mnt/data` (which is mapped to `/srv` on the host).

**Zellij web client says "Invalid token".** Generate a new one with `docker compose exec zellij zellij web --create-token`.

**Watchtower doesn't send Telegram messages.** Check that `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are correct in `.env`. Test with `docker compose exec watchtower /watchtower --run-once --debug`. Make sure you've sent at least one message *to* the bot (not from it) before trying — bots can't initiate conversations.

---

## Security notes

A few things worth knowing about the security model of this stack:

### Threat model

This stack is designed for a **single-user homelab on a public VPS**. It defends against:

- **Unauthenticated internet traffic** (anything that can't get past Authelia + TOTP)
- **Casual scanners and bots** (catch-all 404, no service banners, HSTS, security headers)
- **SSH brute-force** on the host (optional fail2ban via the installer)
- **Login brute-force** on Authelia (built-in regulation: 3 fails → 10 min ban)
- **Resource exhaustion** from a single misbehaving container (per-service `memory`/`cpu` limits)
- **Lateral movement from a compromised peripheral container to the Docker host** (Watchtower & Glances go through `dockerproxy` with `POST=0`, no direct socket mount)

It does **not** defend against:

- A compromised Authelia password + TOTP seed (game over for everything behind the gate)
- Supply-chain attacks on upstream Docker images (use `:latest` consciously, watch the digest)
- Kernel-level container escapes (single Linux kernel, single trust boundary)
- An attacker who already has shell on the host

### Implementation details

1. **Auth is at the gate.** Once Authelia approves a request, *anything* behind it trusts that approval. This is appropriate for a single-user homelab; it would not be appropriate for multi-tenant systems.
2. **TOTP is the minimum.** Don't run this with password-only auth, even temporarily. The Zellij web client gives a remote shell on your VPS; without 2FA, you're one phishing away from total compromise.
3. **Zellij has a second token gate.** Even if Authelia is bypassed somehow, Zellij requires its own token. Defense in depth.
4. **Zellij user has passwordless sudo inside its container.** Combined with `/srv` mounted rw, anyone who gets past Authelia + Zellij token effectively has root in that container. The two gates above are what's holding the line.
5. **Watchtower & Glances do not see the host Docker socket directly.** They go through `dockerproxy` (a read-only Docker API proxy) which denies all write/exec calls. If either container is compromised, it cannot start, stop, or exec into other containers.
6. **Watchtower runs in monitor-only mode by default.** It does not auto-update anything. I strongly recommend you keep it that way: surprise updates on production-ish services are exactly the kind of 3 AM fun you don't want.
7. **Authelia secrets live in `authelia/secrets/`** which is gitignored. If you fork this repo and accidentally commit those files, treat them as compromised: regenerate everything, force-rotate sessions.
8. **The host `/srv` directory is mounted into both Filestash and Zellij.** Anything writable there is editable from either browser interface. Be deliberate about what you put there.
9. **`generate-password-hash.sh` passes the password as a CLI arg to a docker container.** It is briefly visible in the host's process list. Acceptable on a single-user VPS; if you don't trust other host users, run the script on your laptop and copy only the resulting hash up.

---

## What this stack is not

- A multi-user platform. The Authelia config assumes one (or a couple of) admin user(s).
- A high-availability setup. Single VPS, single Caddy, no failover.
- A zero-trust environment. One gate covers everything behind it.
- A replacement for proper observability. Glances is a snapshot tool, not Prometheus.
- An LDAP/OIDC provider. Authelia *can* act as an OIDC provider, but this repo doesn't configure that path.

If you need any of those things, this isn't the right starting point. It's a workshop for one, deliberately so.

---

## Roadmap

Done:

- [x] Docker socket proxy in front of Watchtower and Glances (reduce privilege)
- [x] Mobile-friendly web terminal (wetty + Zellij session sharing)
- [x] Virtual keyboard overlay for wetty (sticky Ctrl/Alt, swipeable key sets, F-keys)
- [x] Dev container in Zellij (Node 20, Python, Claude Code, persistent state)
- [x] Bind-mount persistence under `${LAB_STATE_DIR}` (survives image rebuilds, kept out of Filestash's `/srv`)
- [x] Custom Caddy build with `replace-response` module
- [x] Interactive Telegram bot (status commands + proactive alerts: disk/RAM/load, SSH & Authelia logins, heartbeat, mute/resume)

Ideas I might add over time, no promises:

- [ ] Optional WebAuthn / hardware key support for Authelia
- [ ] Automated backup script (Authelia DB + Caddy data + `${LAB_STATE_DIR}` → Wasabi via CryptoSync)
- [ ] Optional Crowdsec integration for IP-level abuse blocking
- [ ] OpenCode integration as a Zellij-managed service

Pull requests and issues welcome. No SLA on responses, but I read everything.

---

## License

MIT. See [LICENSE](./LICENSE).

---

*Made in [MojaLab](https://mojalab.com). The workshop's open. Just knock first.* 🐸

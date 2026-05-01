#!/bin/bash
# ============================================================================
# install.sh — guided installer for mojalab-vps-stack
# ============================================================================
# Goes from a fresh VPS (with Docker installed) to a fully working stack:
#
#   1. Sanity checks (Docker, Compose plugin, root/sudo if needed for UFW)
#   2. Interactive Q&A: domain, timezone, ACME email, Telegram, user account
#   3. Optional: create DNS A records via Cloudflare API
#   4. Optional: configure UFW firewall (open 22/80/443)
#   5. Write .env, render Authelia config, generate secrets
#   6. Hash password, create users_database.yml
#   7. Wait for DNS propagation of all four subdomains
#   8. docker compose up -d, wait for healthchecks
#   9. Generate Zellij web token and print it
#  10. (optional) Telegram smoke test
#
# Idempotent where reasonable. Re-run after fixing a problem.
# ============================================================================

set -euo pipefail

# --- Paths --------------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
ENV_EXAMPLE="${ROOT_DIR}/.env.example"
USERS_DB="${ROOT_DIR}/authelia/users_database.yml"
USERS_DB_EXAMPLE="${ROOT_DIR}/authelia/users_database.yml.example"

cd "${ROOT_DIR}"

# --- UI helpers ---------------------------------------------------------------
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

step()  { echo ""; echo "${BOLD}${BLUE}==>${RESET} ${BOLD}$*${RESET}"; }
info()  { echo "    $*"; }
ok()    { echo "    ${GREEN}✓${RESET} $*"; }
warn()  { echo "    ${YELLOW}!${RESET} $*"; }
err()   { echo "    ${RED}✗${RESET} $*" >&2; }
die()   { err "$*"; exit 1; }

ask() {
    # ask <prompt> <var_name> [default]
    local prompt="$1" var="$2" default="${3:-}"
    local ans
    if [[ -n "$default" ]]; then
        read -rp "    $prompt [$default]: " ans
        ans="${ans:-$default}"
    else
        read -rp "    $prompt: " ans
    fi
    printf -v "$var" '%s' "$ans"
}

ask_secret() {
    local prompt="$1" var="$2"
    local ans
    read -rsp "    $prompt: " ans; echo
    printf -v "$var" '%s' "$ans"
}

ask_yes_no() {
    local prompt="$1" default="${2:-n}" ans
    local hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    read -rp "    $prompt $hint: " ans
    ans="${ans:-$default}"
    [[ "$ans" =~ ^[Yy]$ ]]
}

# --- 1. Sanity checks ---------------------------------------------------------
step "Sanity checks"

command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install it first."
docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon. Are you in the docker group, or running as root?"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 plugin is missing."
command -v openssl >/dev/null 2>&1 || die "openssl is required."
command -v envsubst >/dev/null 2>&1 || die "envsubst (gettext-base) is required. apt-get install gettext-base"
command -v dig >/dev/null 2>&1 || warn "dig not found — DNS verification will be limited."
command -v curl >/dev/null 2>&1 || die "curl is required."

ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"
ok "Compose $(docker compose version --short 2>/dev/null || echo unknown)"

# --- 2. Q&A -------------------------------------------------------------------
step "Configuration"

# Reuse existing .env if present
if [[ -f "$ENV_FILE" ]]; then
    info "Found existing .env — values shown as defaults."
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

ask "Your base domain (e.g. lab.example.com)"   DOMAIN          "${DOMAIN:-}"
[[ -n "$DOMAIN" ]] || die "DOMAIN cannot be empty."
ask "Timezone"                                  TZ              "${TZ:-Europe/Rome}"
ask "Email for Let's Encrypt notifications"     ACME_EMAIL      "${ACME_EMAIL:-admin@${DOMAIN}}"

if ask_yes_no "Set up Telegram notifications for Watchtower?" "y"; then
    ask "Telegram bot token"  TELEGRAM_BOT_TOKEN "${TELEGRAM_BOT_TOKEN:-}"
    ask "Telegram chat ID"    TELEGRAM_CHAT_ID   "${TELEGRAM_CHAT_ID:-}"
else
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-disabled}"
    TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-0}"
fi

step "SMTP (for Authelia password resets and TOTP enrollment OTPs)"
info "Without SMTP, Authelia writes notifications to a file inside the container"
info "and the 2FA enrollment flow can't deliver the verification email."
if ask_yes_no "Configure SMTP now?" "y"; then
    info "Resend (https://resend.com) defaults are pre-filled."
    info "Verify your sending domain in Resend before using this; otherwise mail will be rejected."
    SMTP_PASSWORD_PREV="${SMTP_PASSWORD:-}"
    ask "SMTP host"        SMTP_HOST     "${SMTP_HOST:-smtp.resend.com}"
    ask "SMTP port"        SMTP_PORT     "${SMTP_PORT:-465}"
    ask "SMTP username"    SMTP_USERNAME "${SMTP_USERNAME:-resend}"
    if [[ -n "$SMTP_PASSWORD_PREV" ]]; then
        if ask_yes_no "Keep existing SMTP password from .env?" "y"; then
            SMTP_PASSWORD="$SMTP_PASSWORD_PREV"
        else
            ask_secret "SMTP password / API key" SMTP_PASSWORD
        fi
    else
        ask_secret "SMTP password / API key" SMTP_PASSWORD
    fi
    ask "From address"     SMTP_SENDER   "${SMTP_SENDER:-Authelia <noreply@${DOMAIN}>}"
else
    SMTP_HOST=""; SMTP_PORT=""; SMTP_USERNAME=""; SMTP_PASSWORD=""; SMTP_SENDER=""
    info "Skipping SMTP. Authelia will use the filesystem notifier; read codes with:"
    info "  docker compose exec authelia cat /config/notification.txt"
fi

step "Authelia user account"
ask "Username (lowercase, no spaces)"           AU_USERNAME      "${AU_USERNAME:-admin}"
ask "Display name"                              AU_DISPLAYNAME   "${AU_DISPLAYNAME:-Admin}"
ask "Email"                                     AU_EMAIL         "${AU_EMAIL:-${ACME_EMAIL}}"

NEED_PASSWORD=true
if [[ -f "$USERS_DB" ]] && grep -q '^\s*password:.*\$argon2id\$' "$USERS_DB"; then
    if ask_yes_no "An existing password hash was found in users_database.yml. Keep it?" "y"; then
        NEED_PASSWORD=false
    fi
fi

if $NEED_PASSWORD; then
    while :; do
        ask_secret "Account password (>= 12 chars)" PW1
        ask_secret "Confirm password"               PW2
        if [[ "$PW1" != "$PW2" ]]; then
            err "Passwords do not match. Try again."; continue
        fi
        if [[ ${#PW1} -lt 12 ]]; then
            ask_yes_no "Password is shorter than 12 chars. Use anyway?" "n" || continue
        fi
        break
    done
fi

# --- 3. DNS (optional Cloudflare) --------------------------------------------
DNS_VIA_CF=false
if ask_yes_no "Create DNS A records automatically via Cloudflare API?" "n"; then
    ask_secret "Cloudflare API token (Zone:DNS:Edit)" CF_API_TOKEN
    ask "Cloudflare Zone ID"                          CF_ZONE_ID
    ask "Public IP of this VPS (auto-detected if blank)" PUBLIC_IP "$(curl -fsS https://api.ipify.org 2>/dev/null || echo '')"
    [[ -n "$PUBLIC_IP" ]] || die "Public IP is required."
    DNS_VIA_CF=true
fi

# --- 4. UFW firewall ----------------------------------------------------------
SETUP_UFW=false
SSH_PORT=""
if command -v ufw >/dev/null 2>&1; then
    # Best-effort SSH port detection so we don't lock the user out of a custom
    # sshd port (e.g. 1978 instead of 22).
    DETECTED_SSH_PORT=""
    # 1) From the currently-connected SSH session, if any.
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        DETECTED_SSH_PORT="$(awk '{print $4}' <<<"$SSH_CONNECTION" 2>/dev/null || true)"
    fi
    # 2) From sshd_config (uncommented Port directive).
    if [[ -z "$DETECTED_SSH_PORT" && -r /etc/ssh/sshd_config ]]; then
        DETECTED_SSH_PORT="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
    fi
    # 3) From a listening sshd, if available.
    if [[ -z "$DETECTED_SSH_PORT" ]] && command -v ss >/dev/null 2>&1; then
        DETECTED_SSH_PORT="$(ss -ltnp 2>/dev/null | awk '/sshd/ {split($4,a,":"); print a[length(a)]; exit}' || true)"
    fi
    DETECTED_SSH_PORT="${DETECTED_SSH_PORT:-22}"

    info "UFW will set: default deny incoming, allow outgoing, open SSH + 80 + 443 (HTTP/3 UDP)."
    info "Detected SSH port: ${DETECTED_SSH_PORT}. CHANGE THIS if your sshd listens elsewhere"
    info "— the wrong value will lock you out as soon as UFW is enabled."
    if ask_yes_no "Configure UFW now?" "y"; then
        ask "SSH port to keep open" SSH_PORT "${DETECTED_SSH_PORT}"
        if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
            die "Invalid SSH port: ${SSH_PORT}"
        fi
        info "About to apply these UFW rules:"
        info "  default deny incoming / allow outgoing"
        info "  allow ${SSH_PORT}/tcp  (SSH)"
        info "  allow 80/tcp           (HTTP / ACME)"
        info "  allow 443/tcp          (HTTPS)"
        info "  allow 443/udp          (HTTP/3 QUIC)"
        if ask_yes_no "Confirm and enable UFW?" "y"; then
            SETUP_UFW=true
        else
            warn "UFW step cancelled by user."
        fi
    fi
fi

# --- 5. fail2ban (host-level SSH brute-force protection) ---------------------
SETUP_FAIL2BAN=false
if ask_yes_no "Install and enable fail2ban for SSH brute-force protection on the host?" "y"; then
    SETUP_FAIL2BAN=true
fi

# ============================================================================
# Apply
# ============================================================================

# --- Write .env ---------------------------------------------------------------
step "Writing .env"
[[ -f "$ENV_EXAMPLE" ]] || die "Missing $ENV_EXAMPLE"
cat > "$ENV_FILE" <<EOF
# Generated by scripts/install.sh on $(date -u +%FT%TZ)
DOMAIN=${DOMAIN}
TZ=${TZ}
ACME_EMAIL=${ACME_EMAIL}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
SMTP_HOST=${SMTP_HOST:-}
SMTP_PORT=${SMTP_PORT:-}
SMTP_USERNAME=${SMTP_USERNAME:-}
SMTP_PASSWORD=${SMTP_PASSWORD:-}
SMTP_SENDER=${SMTP_SENDER:-}
EOF
chmod 600 "$ENV_FILE"
ok ".env written"

# --- DNS via Cloudflare -------------------------------------------------------
if $DNS_VIA_CF; then
    step "Creating DNS A records via Cloudflare"
    for sub in auth files term mterm stats home; do
        fqdn="${sub}.${DOMAIN}"
        info "Upserting ${fqdn} → ${PUBLIC_IP}"
        # Look up existing record
        existing=$(curl -fsS -H "Authorization: Bearer ${CF_API_TOKEN}" \
            "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${fqdn}" \
            | grep -o '"id":"[^"]*"' | head -n1 | cut -d'"' -f4 || true)
        body=$(printf '{"type":"A","name":"%s","content":"%s","ttl":120,"proxied":false}' "$fqdn" "$PUBLIC_IP")
        if [[ -n "$existing" ]]; then
            curl -fsS -X PUT -H "Authorization: Bearer ${CF_API_TOKEN}" \
                -H "Content-Type: application/json" --data "$body" \
                "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${existing}" >/dev/null \
                && ok "Updated ${fqdn}" || warn "Update failed for ${fqdn}"
        else
            curl -fsS -X POST -H "Authorization: Bearer ${CF_API_TOKEN}" \
                -H "Content-Type: application/json" --data "$body" \
                "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" >/dev/null \
                && ok "Created ${fqdn}" || warn "Create failed for ${fqdn}"
        fi
    done
else
    info "Skipping DNS automation. Make sure these A records exist:"
    for sub in auth files term mterm stats home; do
        info "  ${sub}.${DOMAIN}  →  <your VPS public IP>"
    done
fi

# --- UFW ---------------------------------------------------------------------
if $SETUP_UFW; then
    step "Configuring UFW"
    SUDO=""; [[ $EUID -eq 0 ]] || SUDO="sudo"
    $SUDO ufw default deny incoming || true
    $SUDO ufw default allow outgoing || true
    $SUDO ufw allow "${SSH_PORT}/tcp" comment 'SSH' || true
    $SUDO ufw allow 80/tcp comment 'HTTP (Caddy / ACME)' || true
    $SUDO ufw allow 443/tcp comment 'HTTPS (Caddy)' || true
    $SUDO ufw allow 443/udp comment 'HTTP/3 QUIC' || true
    yes | $SUDO ufw enable >/dev/null 2>&1 || true
    ok "UFW active. Rules:"
    $SUDO ufw status numbered | sed 's/^/      /'
fi

# --- fail2ban ----------------------------------------------------------------
if $SETUP_FAIL2BAN; then
    step "Installing fail2ban"
    F2B_SUDO=""; [[ $EUID -eq 0 ]] || F2B_SUDO="sudo"
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            $F2B_SUDO apt-get update -qq && $F2B_SUDO apt-get install -y -qq fail2ban || warn "apt install failed"
        else
            warn "apt-get not available; install fail2ban manually."
        fi
    fi
    if command -v fail2ban-client >/dev/null 2>&1; then
        # Minimal jail.local enabling sshd jail with sane defaults; idempotent.
        JAIL=/etc/fail2ban/jail.local
        if [[ ! -f "$JAIL" ]] || ! grep -q '^\[sshd\]' "$JAIL"; then
            $F2B_SUDO tee "$JAIL" >/dev/null <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
EOF
        fi
        $F2B_SUDO systemctl enable --now fail2ban >/dev/null 2>&1 || true
        $F2B_SUDO systemctl restart fail2ban >/dev/null 2>&1 || true
        ok "fail2ban active (jail: sshd)"
    fi
fi

# --- Authelia secrets ---------------------------------------------------------
step "Generating Authelia secrets"
"${ROOT_DIR}/scripts/bootstrap-secrets.sh"

# --- Render Authelia config ---------------------------------------------------
step "Rendering Authelia configuration"
"${ROOT_DIR}/scripts/render-authelia-config.sh"

# --- Users database ----------------------------------------------------------
step "Writing users_database.yml"
if $NEED_PASSWORD; then
    info "Hashing password (argon2id, this takes a few seconds)…"
    HASH=$(PASSWORD="$PW1" "${ROOT_DIR}/scripts/generate-password-hash.sh" 2>/dev/null | tail -n1)
    unset PW1 PW2
    [[ "$HASH" == \$argon2id\$* ]] || die "Hash generation failed."
    cat > "$USERS_DB" <<EOF
# Generated by scripts/install.sh on $(date -u +%FT%TZ)
users:
  ${AU_USERNAME}:
    displayname: '${AU_DISPLAYNAME}'
    password: '${HASH}'
    email: '${AU_EMAIL}'
    groups:
      - 'admins'
EOF
    chmod 600 "$USERS_DB"
    ok "Wrote $USERS_DB"
else
    info "Keeping existing users_database.yml"
fi

# --- DNS propagation wait -----------------------------------------------------
step "Verifying DNS resolution"
if command -v dig >/dev/null 2>&1; then
    expected_ip="${PUBLIC_IP:-$(curl -fsS https://api.ipify.org 2>/dev/null || echo '')}"
    if [[ -z "$expected_ip" ]]; then
        warn "Could not detect public IP; skipping strict check."
    fi
    deadline=$((SECONDS + 600))   # 10 min max
    for sub in auth files term mterm stats home; do
        fqdn="${sub}.${DOMAIN}"
        info "Waiting for ${fqdn}…"
        while :; do
            resolved=$(dig +short A "${fqdn}" @1.1.1.1 | tail -n1 || true)
            if [[ -n "$resolved" ]]; then
                if [[ -z "$expected_ip" || "$resolved" == "$expected_ip" ]]; then
                    ok "${fqdn} → ${resolved}"; break
                fi
                warn "${fqdn} resolves to ${resolved} (expected ${expected_ip}). Will keep waiting…"
            fi
            if (( SECONDS > deadline )); then
                warn "Timeout waiting for ${fqdn}. Continuing anyway — Caddy will retry the cert."
                break
            fi
            sleep 10
        done
    done
else
    warn "dig not available; skipping DNS check."
fi

# --- Shared data dir ----------------------------------------------------------
# /srv is bind-mounted into both Filestash (as root) and Zellij (as UID 1000
# 'lab'). Without this step, files created by one are unwritable from the
# other. Make /srv owned by 1000:1000 with group-write + setgid so new files
# inherit the group.
step "Preparing /srv (shared Filestash + Zellij data dir)"
SRV_SUDO=""; [[ $EUID -eq 0 ]] || SRV_SUDO="sudo"
$SRV_SUDO mkdir -p /srv
$SRV_SUDO chown 1000:1000 /srv
$SRV_SUDO chmod 2775 /srv
ok "/srv is owned by 1000:1000 with mode 2775"

# --- Bring up the stack -------------------------------------------------------
step "Starting the stack"
docker compose pull
docker compose up -d --build

step "Waiting for services to become healthy"
deadline=$((SECONDS + 300))
all_ok=false
while (( SECONDS < deadline )); do
    # State is "running"/"exited"/etc; Status contains "(healthy)", "(unhealthy)", "(health: starting)" or nothing.
    bad=$(docker compose ps --format '{{.Name}}|{{.State}}|{{.Status}}' \
        | awk -F'|' '$2 != "running" || $3 ~ /unhealthy|health: starting/' || true)
    if [[ -z "$bad" ]]; then
        all_ok=true; break
    fi
    sleep 5
done
docker compose ps
$all_ok || warn "Some services are not healthy yet. Inspect with: docker compose logs"

# --- Zellij token -------------------------------------------------------------
step "Generating Zellij web token"
if docker compose ps zellij --format '{{.Status}}' | grep -q running; then
    TOKEN_OUT=$(docker compose exec -T zellij zellij web --create-token 2>&1 || true)
    echo "$TOKEN_OUT" | sed 's/^/      /'
    info "Save this token — you'll paste it on first visit to https://term.${DOMAIN}"
else
    warn "Zellij is not running yet; create the token later with:"
    info "  docker compose exec zellij zellij web --create-token"
fi

# --- Telegram smoke test ------------------------------------------------------
if [[ "$TELEGRAM_BOT_TOKEN" != "disabled" ]] && ask_yes_no "Send a Watchtower test notification to Telegram now?" "n"; then
    step "Triggering Watchtower test run"
    docker compose exec -T watchtower /watchtower --run-once --debug || warn "Watchtower run-once failed"
fi

# --- Done ---------------------------------------------------------------------
echo ""
echo "${BOLD}${GREEN}Setup complete.${RESET}"
echo ""
info "Open ${BOLD}https://home.${DOMAIN}${RESET}  ← dashboard with links to every service"
info "Log in as ${BOLD}${AU_USERNAME}${RESET} and enroll TOTP on first login."
info "Useful commands:"
info "  docker compose ps"
info "  docker compose logs -f caddy authelia"
info "  docker compose exec zellij zellij web --create-token"
echo ""

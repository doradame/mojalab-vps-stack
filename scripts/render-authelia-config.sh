#!/bin/bash
# ============================================================================
# render-authelia-config.sh — render authelia/configuration.yml.template
# ============================================================================
# Substitutes ${DOMAIN} (and any other env vars) in the template, producing
# the actual configuration.yml that Authelia will load.
#
# Loads variables from the project's .env file (next to docker-compose.yml).
# Run it any time you change DOMAIN.
# ============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
TEMPLATE="${ROOT_DIR}/authelia/configuration.yml.template"
OUTPUT="${ROOT_DIR}/authelia/configuration.yml"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Error: ${ENV_FILE} not found. Run 'cp .env.example .env' and edit it first." >&2
    exit 1
fi

if [[ ! -f "${TEMPLATE}" ]]; then
    echo "Error: ${TEMPLATE} not found." >&2
    exit 1
fi

# shellcheck disable=SC1090
set -a
source "${ENV_FILE}"
set +a

if [[ -z "${DOMAIN:-}" ]]; then
    echo "Error: DOMAIN is empty in .env" >&2
    exit 1
fi

# Build the notifier block. SMTP if configured, filesystem otherwise.
if [[ -n "${SMTP_HOST:-}" ]]; then
    : "${SMTP_PORT:?SMTP_PORT must be set when SMTP_HOST is set}"
    : "${SMTP_USERNAME:?SMTP_USERNAME must be set when SMTP_HOST is set}"
    : "${SMTP_SENDER:?SMTP_SENDER must be set when SMTP_HOST is set}"
    # Pick scheme by port: 465 = implicit TLS, 587 = STARTTLS, others = plain.
    case "${SMTP_PORT}" in
        465)  SMTP_SCHEME="submissions" ;;
        587)  SMTP_SCHEME="submission" ;;
        25)   SMTP_SCHEME="smtp" ;;
        *)    SMTP_SCHEME="submissions" ;;
    esac
    NOTIFIER_BLOCK=$(cat <<EOF
notifier:
  # Skip the startup connectivity check: many VPS providers (e.g. Hetzner)
  # block outbound SMTP by default. Authelia will attempt the actual send
  # only when needed, and surface errors then instead of refusing to boot.
  disable_startup_check: true
  smtp:
    address: '${SMTP_SCHEME}://${SMTP_HOST}:${SMTP_PORT}'
    username: '${SMTP_USERNAME}'
    sender: '${SMTP_SENDER}'
    subject: '[Authelia] {title}'
EOF
)
    echo "→ Notifier: SMTP (${SMTP_HOST}:${SMTP_PORT})"
else
    NOTIFIER_BLOCK=$(cat <<'EOF'
notifier:
  disable_startup_check: false
  filesystem:
    filename: '/config/notification.txt'
EOF
)
    echo "→ Notifier: filesystem (no SMTP_HOST in .env)"
fi

# First substitute DOMAIN, then swap the @@NOTIFIER@@ placeholder.
rendered=$(envsubst '${DOMAIN}' < "${TEMPLATE}")
# Use awk to replace the placeholder with the multi-line block safely.
NOTIFIER_BLOCK="${NOTIFIER_BLOCK}" awk '
    /^# @@NOTIFIER@@$/ { print ENVIRON["NOTIFIER_BLOCK"]; next }
    { print }
' <<< "${rendered}" > "${OUTPUT}"
chmod 640 "${OUTPUT}"

echo "✓ Rendered ${OUTPUT} (DOMAIN=${DOMAIN})"

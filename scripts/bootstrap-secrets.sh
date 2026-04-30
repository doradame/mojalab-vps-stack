#!/bin/bash
# ============================================================================
# bootstrap-secrets.sh — generate Authelia secrets
# ============================================================================
# Creates the three secret files Authelia needs:
#   - JWT secret (used for password reset tokens)
#   - Session secret (used for session cookie encryption)
#   - Storage encryption key (used for sensitive DB columns)
#
# Files are written to authelia/secrets/ and are NOT committed to git.
# Run this ONCE, before the first `docker compose up`.
# ============================================================================

set -euo pipefail

SECRETS_DIR="$(dirname "$0")/../authelia/secrets"
mkdir -p "${SECRETS_DIR}"

generate_secret() {
    local name="$1"
    local file="${SECRETS_DIR}/${name}"

    if [[ -f "${file}" ]]; then
        echo "✓ ${name} already exists, skipping"
        return
    fi

    openssl rand -hex 64 > "${file}"
    chmod 600 "${file}"
    echo "✓ Generated ${name}"
}

echo "Generating Authelia secrets in ${SECRETS_DIR}..."
echo ""

generate_secret "jwt_secret"
generate_secret "session_secret"
generate_secret "storage_encryption_key"

# ----------------------------------------------------------------------------
# SMTP password — read from .env (if present) and stored as a secret file so
# Authelia can pick it up via AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE.
# ----------------------------------------------------------------------------
ENV_FILE="$(dirname "$0")/../.env"
SMTP_PASSWORD_FILE="${SECRETS_DIR}/smtp_password"

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a; source "${ENV_FILE}"; set +a
fi

if [[ -n "${SMTP_PASSWORD:-}" ]]; then
    printf '%s' "${SMTP_PASSWORD}" > "${SMTP_PASSWORD_FILE}"
    chmod 600 "${SMTP_PASSWORD_FILE}"
    echo "✓ Wrote smtp_password from .env"
elif [[ ! -f "${SMTP_PASSWORD_FILE}" ]]; then
    # Authelia still requires the file to exist when the env var points to it,
    # even if SMTP is disabled. Touch an empty placeholder.
    : > "${SMTP_PASSWORD_FILE}"
    chmod 600 "${SMTP_PASSWORD_FILE}"
    echo "✓ Created empty smtp_password placeholder (no SMTP_PASSWORD in .env)"
else
    echo "✓ smtp_password already exists, skipping"
fi

echo ""
echo "Done. These files are gitignored and will not be committed."
echo "If you ever need to regenerate them, delete the files and re-run this script."

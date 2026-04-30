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

echo ""
echo "Done. These files are gitignored and will not be committed."
echo "If you ever need to regenerate them, delete the files and re-run this script."

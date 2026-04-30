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

# Only expand the variables we explicitly reference; safer than a blind envsubst.
envsubst '${DOMAIN}' < "${TEMPLATE}" > "${OUTPUT}"
chmod 640 "${OUTPUT}"

echo "✓ Rendered ${OUTPUT} (DOMAIN=${DOMAIN})"

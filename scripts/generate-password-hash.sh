#!/bin/bash
# ============================================================================
# generate-password-hash.sh — produce an argon2 hash for Authelia
# ============================================================================
# Wraps the Authelia CLI to generate a password hash you can paste into
# users_database.yml. Reads the password from stdin (no shell history leak).
#
# SECURITY NOTE: the password is briefly visible in the docker container's
# argv. On a single-tenant VPS this is generally acceptable. If you don't
# trust other users on the host, run this on your laptop instead and copy
# only the resulting hash up to the server.
#
# Usage:
#   ./scripts/generate-password-hash.sh                 # interactive
#   PASSWORD=secret ./scripts/generate-password-hash.sh # for automation
# ============================================================================

set -euo pipefail

if [[ -z "${PASSWORD:-}" ]]; then
    echo "Enter the password (input is hidden, no shell history will record it):"
    read -rs PASSWORD
    echo ""
    echo "Confirm password:"
    read -rs PASSWORD2
    echo ""
    if [[ "${PASSWORD}" != "${PASSWORD2}" ]]; then
        echo "Error: passwords do not match" >&2
        exit 1
    fi
    unset PASSWORD2
fi

if [[ -z "${PASSWORD}" ]]; then
    echo "Error: empty password" >&2
    exit 1
fi

if [[ ${#PASSWORD} -lt 12 ]]; then
    echo "Warning: password is shorter than 12 characters." >&2
fi

HASH=$(docker run --rm -i authelia/authelia:4 \
    authelia crypto hash generate argon2 --password "${PASSWORD}" \
    | grep -E '^Digest:' \
    | sed 's/Digest: //')

unset PASSWORD

if [[ -z "${HASH}" ]]; then
    echo "Error: failed to generate hash" >&2
    exit 1
fi

# If stdout is a terminal, print the friendly banner; otherwise print just the
# hash (so the script can be used in pipelines, e.g. by install.sh).
if [[ -t 1 ]]; then
    echo "Generated argon2id hash:"
    echo ""
    echo "${HASH}"
    echo ""
    echo "Copy the hash above (the long string starting with \$argon2id\$...)"
    echo "and paste it as the 'password:' value in authelia/users_database.yml"
else
    echo "${HASH}"
fi

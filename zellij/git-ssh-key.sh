#!/bin/bash
# ============================================================================
# git-ssh-key — generate (once) and print an SSH key for GitHub / GitLab / any forge
# ============================================================================
# Keys live in ~/.local/share/ssh (persistent bind mount), NOT in ~/.ssh:
# ~/.ssh is recreated empty on every container rebuild. The entrypoint re-links
# ~/.ssh/config to the persistent copy, so git keeps working after rebuilds.
# One key per host, all wired up in the same persistent ssh config.
#
# Usage:
#   git-ssh-key                       GitHub (github.com) — the default
#   git-ssh-key gitlab                GitLab (gitlab.com)
#   git-ssh-key git.mycompany.com     any self-hosted forge
#   git-ssh-key [host] --test         also run 'ssh -T git@<host>' to verify
# ============================================================================

set -euo pipefail

HOST="github.com"
TEST=false
for arg in "$@"; do
    case "$arg" in
        github)    HOST="github.com" ;;
        gitlab)    HOST="gitlab.com" ;;
        --test)    TEST=true ;;
        -h|--help)
            cat <<'EOF'
Usage:
  git-ssh-key                       GitHub (github.com) — the default
  git-ssh-key gitlab                GitLab (gitlab.com)
  git-ssh-key git.mycompany.com     any self-hosted forge
  git-ssh-key [host] --test         also run 'ssh -T git@<host>' to verify
EOF
            exit 0 ;;
        *)         HOST="$arg" ;;
    esac
done

SSH_DIR="$HOME/.local/share/ssh"
KEY="$SSH_DIR/$(tr '.' '_' <<< "$HOST")_ed25519"
CONF="$SSH_DIR/config"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ ! -f "$KEY" ]]; then
    comment="lab@${LAB_BRAND:-mojalab}-vps (${HOST})"
    echo "Generating a new ed25519 key (${comment})…"
    ssh-keygen -t ed25519 -N '' -C "$comment" -f "$KEY" >/dev/null
    echo ""
fi

# Persistent ssh client config: one Host block per forge, known_hosts kept in
# the persistent dir too (so host keys survive rebuilds).
if [[ ! -f "$CONF" ]] || ! grep -qF "IdentityFile $KEY" "$CONF"; then
    cat >> "$CONF" <<EOF

Host $HOST
    User git
    IdentityFile $KEY
    IdentitiesOnly yes
    UserKnownHostsFile $SSH_DIR/known_hosts
    StrictHostKeyChecking accept-new
EOF
    chmod 600 "$CONF"
fi

# Live link for the current boot (the entrypoint recreates it after rebuilds).
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
ln -sfn "$CONF" "$HOME/.ssh/config"

case "$HOST" in
    github.com) ADD_URL="https://github.com/settings/ssh/new" ;;
    *gitlab*)   ADD_URL="https://${HOST}/-/user_settings/ssh_keys" ;;
    *)          ADD_URL="your forge's SSH keys settings page" ;;
esac

echo "Public key for ${HOST} — add it at ${ADD_URL} :"
echo ""
cat "${KEY}.pub"
echo ""
echo "Fingerprint: $(ssh-keygen -lf "${KEY}.pub" | awk '{print $2}')"
echo ""
echo "Then verify with:  git-ssh-key ${HOST} --test"

if $TEST; then
    echo ""
    # Forges close the connection after the greeting → exit code 1 is normal.
    ssh -T "git@${HOST}" 2>&1 | tail -n1 || true
fi

#!/bin/bash
# ============================================================================
# Zellij web + sshd entrypoint
# ============================================================================
# Two services in one container:
#   - zellij web (native client) on 127.0.0.1:8083, exposed at 0.0.0.0:8082
#     via socat (zellij-org/zellij#4347 workaround).
#   - sshd on :22, used by the wetty container to give a mobile-friendly
#     web terminal that auto-attaches to the same Zellij session.
#
# wetty authenticates with a private key generated on first boot and shared
# via the named volume mounted at /ssh-keys.
# ============================================================================

set -euo pipefail

# --- Permissions on persistent volumes --------------------------------------
# Named volumes are created owned by root the first time they're mounted.
# Reclaim them for the 'lab' user so zellij/sshd/dev tools can write.
for d in /home/lab/.config/zellij /home/lab/.cache/zellij \
         /home/lab/.local /home/lab/.local/share/zellij \
         /home/lab/.config /home/lab/.claude /home/lab/.npm \
         /home/lab/workspace /home/lab/.ssh /ssh-keys; do
    sudo mkdir -p "$d"
    sudo chown -R lab:lab "$d"
done
chmod 700 /home/lab/.ssh /ssh-keys

# --- Persist single-file dotfiles via symlinks ------------------------------
# ~/.claude.json is a *file* Claude Code writes config to. Volumes can't mount
# single files cleanly, so we redirect via a symlink into the persistent
# ~/.local volume.
mkdir -p /home/lab/.local/state
[[ -e /home/lab/.local/state/claude.json ]] || : > /home/lab/.local/state/claude.json
ln -sfn /home/lab/.local/state/claude.json /home/lab/.claude.json

# --- Secrets loader: API keys persist across rebuilds -----------------------
# Put exports here once, e.g.:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   export OPENAI_API_KEY=sk-...
# The file is sourced by .bashrc on every interactive shell.
if [[ ! -f /home/lab/.local/share/secrets.env ]]; then
    mkdir -p /home/lab/.local/share
    cat > /home/lab/.local/share/secrets.env <<'EOF'
# API keys & secrets for the lab user. Sourced by ~/.bashrc.
# Add lines like: export ANTHROPIC_API_KEY=sk-ant-...
EOF
    chmod 600 /home/lab/.local/share/secrets.env
fi
chown -R lab:lab /home/lab/.local /home/lab/.claude.json 2>/dev/null || true

# --- sshd setup --------------------------------------------------------------
# Host keys: generated on first boot in the image. They are not persisted
# across rebuilds, so wetty must accept new host keys (handled by its
# ~/.ssh/config: StrictHostKeyChecking=no).
if ! sudo test -f /etc/ssh/ssh_host_ed25519_key; then
    sudo ssh-keygen -A
fi
sudo mkdir -p /run/sshd
sudo tee /etc/ssh/sshd_config.d/lab.conf >/dev/null <<'EOF'
Port 22
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AllowUsers lab
UseDNS no
PrintMotd no
AcceptEnv LANG LC_* TERM
EOF

# --- Wetty SSH key -----------------------------------------------------------
# Generate a dedicated keypair on first boot and authorize it for the lab
# user. The private key lives in the shared volume mounted RO into wetty.
if [[ ! -f /ssh-keys/wetty_id_ed25519 ]]; then
    ssh-keygen -t ed25519 -N '' -C wetty -f /ssh-keys/wetty_id_ed25519
fi
chmod 600 /ssh-keys/wetty_id_ed25519
chmod 644 /ssh-keys/wetty_id_ed25519.pub
install -m 600 -o lab -g lab /ssh-keys/wetty_id_ed25519.pub /home/lab/.ssh/authorized_keys

# Start sshd (daemonized).
sudo /usr/sbin/sshd

# --- Zellij web server -------------------------------------------------------
mkdir -p /home/lab/.config/zellij

echo "Starting Zellij web server on 127.0.0.1:8083 (socat bridges 0.0.0.0:8082 -> 127.0.0.1:8083)..."
echo "sshd listening on :22 — wetty connects with key /ssh-keys/wetty_id_ed25519"
echo ""
echo "If this is the first run of the native client, create a login token with:"
echo "  docker compose exec zellij zellij web --create-token"
echo ""

# Forward 0.0.0.0:8082 -> 127.0.0.1:8083 in the background (Zellij native client).
socat TCP-LISTEN:8082,bind=0.0.0.0,reuseaddr,fork TCP:127.0.0.1:8083 &
SOCAT_PID=$!

trap 'kill ${SOCAT_PID} 2>/dev/null || true; sudo pkill sshd 2>/dev/null || true' EXIT INT TERM

exec zellij web --ip 127.0.0.1 --port 8083

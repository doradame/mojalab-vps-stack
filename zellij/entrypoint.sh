#!/bin/bash
# ============================================================================
# Zellij web server entrypoint
# ============================================================================
# Zellij's web client refuses to bind on non-loopback IPs without serving TLS
# itself (issue zellij-org/zellij#4347). Workaround: bind Zellij on 127.0.0.1
# inside the container and use socat to forward 0.0.0.0:8082 -> 127.0.0.1:8082
# so Caddy (on the lab network) can reach it. TLS is terminated upstream by
# Caddy; Authelia + the Zellij token gate every request.
# ============================================================================

set -euo pipefail

mkdir -p /home/lab/.config/zellij

echo "Starting Zellij web server on 127.0.0.1:8082 (socat bridges 0.0.0.0:8082)..."
echo ""
echo "If this is the first run, you'll need to create a login token."
echo "Open a shell into this container and run:"
echo "  zellij web --create-token"
echo ""

# Forward 0.0.0.0:8082 -> 127.0.0.1:8082 in the background.
socat TCP-LISTEN:8082,bind=0.0.0.0,reuseaddr,fork TCP:127.0.0.1:8082 &
SOCAT_PID=$!

# Stop socat cleanly when zellij exits.
trap 'kill ${SOCAT_PID} 2>/dev/null || true' EXIT INT TERM

exec zellij web --ip 127.0.0.1 --port 8082

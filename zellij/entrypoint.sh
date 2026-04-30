#!/bin/bash
# ============================================================================
# Zellij web server entrypoint
# ============================================================================
# Starts Zellij's built-in web client server on port 8082, bound to 0.0.0.0
# so Caddy can proxy to it. The login token must be created interactively
# the first time (see README → "First-time setup → Zellij web token").
# ============================================================================

set -euo pipefail

mkdir -p /home/lab/.config/zellij

echo "Starting Zellij web server on 0.0.0.0:8082..."
echo ""
echo "If this is the first run, you'll need to create a login token."
echo "Open a shell into this container and run:"
echo "  zellij web --create-token"
echo ""

# --unsafe-listen-on-all-interfaces: required since zellij ≥0.42 to listen on
# 0.0.0.0 without serving TLS itself. Safe here because Caddy terminates TLS
# upstream and Authelia + Zellij token gate every request before it reaches us.
exec zellij web --ip 0.0.0.0 --port 8082 --unsafe-listen-on-all-interfaces

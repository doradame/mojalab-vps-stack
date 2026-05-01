#!/bin/bash
# ============================================================================
# Zellij web server entrypoint
# ============================================================================
# Zellij's web client refuses to bind on non-loopback IPs without serving TLS
# itself (issue zellij-org/zellij#4347). Workaround: Zellij listens on
# 127.0.0.1:8083 and socat forwards 0.0.0.0:8082 -> 127.0.0.1:8083 so Caddy
# (on the lab network) can reach it on the published port 8082. We use two
# different ports because binding socat on 0.0.0.0:8082 also occupies
# 127.0.0.1:8082, which would collide with zellij. TLS is terminated upstream
# by Caddy; Authelia + the Zellij token gate every request.
# ============================================================================

set -euo pipefail

mkdir -p /home/lab/.config/zellij

echo "Starting Zellij web server on 127.0.0.1:8083 (socat bridges 0.0.0.0:8082 -> 127.0.0.1:8083)..."
echo "Starting ttyd (mobile-friendly) on 0.0.0.0:7681, attaching to zellij session 'main'."
echo ""
echo "If this is the first run of the native client, create a login token with:"
echo "  docker compose exec zellij zellij web --create-token"
echo ""

# Forward 0.0.0.0:8082 -> 127.0.0.1:8083 in the background (Zellij native client).
socat TCP-LISTEN:8082,bind=0.0.0.0,reuseaddr,fork TCP:127.0.0.1:8083 &
SOCAT_PID=$!

# ttyd serves a mobile-friendly web terminal that auto-attaches to a shared
# Zellij session named 'main'. Open it from desktop and phone to see the same
# pane in real time. No auth here — Caddy + Authelia gate the route.
ttyd \
    --port 7681 \
    --interface 0.0.0.0 \
    --writable \
    --terminal-type xterm-256color \
    -t 'fontSize=14' \
    -t 'cursorStyle=bar' \
    -t 'titleFixed=mojalab term' \
    -t 'theme={"background":"#1e1e2e","foreground":"#cdd6f4"}' \
    bash -lc 'exec zellij attach -c main' &
TTYD_PID=$!

# Stop sidecars cleanly when zellij exits.
trap 'kill ${SOCAT_PID} ${TTYD_PID} 2>/dev/null || true' EXIT INT TERM

exec zellij web --ip 127.0.0.1 --port 8083

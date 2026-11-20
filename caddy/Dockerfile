# ============================================================================
# Caddy — custom build with the replace-response module.
# ============================================================================
# We need replace-response to inject a virtual-keyboard overlay into wetty's
# HTML on the fly (mterm.{$DOMAIN}), without modifying the upstream wetty
# image. The stock 'caddy:*-alpine' image does NOT include this module, so
# we build with xcaddy.
#
# Everything is pinned to exact versions: the Caddy patch release (both
# stages must match) and the replace-response module, which publishes no
# tags — so it is pinned to a commit via its Go pseudo-version. To update:
#   Caddy:   https://github.com/caddyserver/caddy/releases
#   module:  curl -fsS https://proxy.golang.org/github.com/caddyserver/replace-response/@latest
# ============================================================================

FROM caddy:2.9.1-builder-alpine AS builder

RUN xcaddy build \
    --with github.com/caddyserver/replace-response@v0.0.0-20250618171559-80962887e4c6

FROM caddy:2.9.1-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

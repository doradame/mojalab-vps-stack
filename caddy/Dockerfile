# ============================================================================
# Caddy — custom build with the replace-response module.
# ============================================================================
# We need replace-response to inject a virtual-keyboard overlay into wetty's
# HTML on the fly (mterm.{$DOMAIN}), without modifying the upstream wetty
# image. The base 'caddy:2.8-alpine' image does NOT include this module, so
# we build with xcaddy.
# ============================================================================

FROM caddy:2.9-builder-alpine AS builder

RUN xcaddy build \
    --with github.com/caddyserver/replace-response

FROM caddy:2.9-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

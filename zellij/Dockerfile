# ============================================================================
# Zellij container — mojalab-vps-stack
# ============================================================================
# Zellij with built-in web client, running as non-root user.
#
# To pin a specific binary release, set ZELLIJ_SHA256 at build time:
#   docker compose build --build-arg ZELLIJ_SHA256=<hex>
# Retrieve the expected hash from:
#   https://github.com/zellij-org/zellij/releases/download/v${VER}/zellij-x86_64-unknown-linux-musl.tar.gz
# (compute with `sha256sum` on a trusted machine, or compare across releases).
# If left empty, the build SKIPS verification (acceptable for a homelab, not for prod).
# ============================================================================

FROM debian:bookworm-slim

ARG ZELLIJ_VERSION=0.43.0
ARG ZELLIJ_SHA256=""

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl bash sudo procps xz-utils iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Install Zellij from official binary release, optionally verifying the SHA256.
RUN set -eux; \
    curl -fsSL "https://github.com/zellij-org/zellij/releases/download/v${ZELLIJ_VERSION}/zellij-x86_64-unknown-linux-musl.tar.gz" \
        -o /tmp/zellij.tar.gz; \
    if [ -n "${ZELLIJ_SHA256}" ]; then \
        echo "${ZELLIJ_SHA256}  /tmp/zellij.tar.gz" | sha256sum -c -; \
    else \
        echo "WARNING: ZELLIJ_SHA256 not set, skipping checksum verification" >&2; \
    fi; \
    tar -xzf /tmp/zellij.tar.gz -C /usr/local/bin/; \
    chmod +x /usr/local/bin/zellij; \
    rm /tmp/zellij.tar.gz

# Non-root user inside container.
# NOTE: 'lab' has passwordless sudo. /srv is bind-mounted rw, so an attacker
# with web access (past Authelia + Zellij token) effectively has root in this
# container. Documented in README → Security notes.
RUN useradd -m -s /bin/bash -u 1000 lab \
    && echo "lab ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER lab
WORKDIR /home/lab

# Copy entrypoint that starts the Zellij web server
COPY --chown=lab:lab entrypoint.sh /home/lab/entrypoint.sh
RUN chmod +x /home/lab/entrypoint.sh

EXPOSE 8082

ENTRYPOINT ["/home/lab/entrypoint.sh"]

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

ARG ZELLIJ_VERSION=0.44.1
ARG ZELLIJ_SHA256=""
ARG TTYD_VERSION=1.7.7

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl bash bash-completion sudo procps xz-utils iproute2 socat \
        git vim nano less htop ncdu tree jq file man-db \
    && rm -rf /var/lib/apt/lists/*

# ttyd is not in Debian bookworm; fetch the official static x86_64 binary.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) ttyd_arch=x86_64 ;; \
        arm64) ttyd_arch=aarch64 ;; \
        armhf) ttyd_arch=armhf ;; \
        *) echo "Unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ttyd_arch}" \
        -o /usr/local/bin/ttyd; \
    chmod +x /usr/local/bin/ttyd; \
    /usr/local/bin/ttyd --version

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

# Make sure Zellij spawns bash (not /bin/sh) and that TUI apps know what
# terminal they are running on.
ENV SHELL=/bin/bash \
    TERM=xterm-256color \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Copy entrypoint that starts the Zellij web server
COPY --chown=lab:lab entrypoint.sh /home/lab/entrypoint.sh
RUN chmod +x /home/lab/entrypoint.sh

# Pretty bash defaults: colored prompt, aliases, history, banner.
COPY --chown=lab:lab bashrc /home/lab/.bashrc
RUN printf '%s\n' \
        "# Source .bashrc for login shells too" \
        "[ -f ~/.bashrc ] && . ~/.bashrc" > /home/lab/.bash_profile \
    && chown lab:lab /home/lab/.bash_profile

EXPOSE 8082 7681

ENTRYPOINT ["/home/lab/entrypoint.sh"]

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

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg bash bash-completion sudo procps xz-utils \
        iproute2 socat openssh-server openssh-client \
        git vim nano less htop ncdu tree jq file man-db unzip zip rsync tmux \
        ripgrep fd-find \
        build-essential pkg-config \
        python3 python3-pip python3-venv python3-dev pipx \
    && mkdir -p /run/sshd \
    && rm -rf /var/lib/apt/lists/*

# Node.js 20 LTS from NodeSource (Debian's nodejs is too old for modern tooling).
RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*

# Claude Code CLI (Anthropic). Installed system-wide so it survives rebuilds;
# user state lives in ~/.claude (persistent volume).
RUN npm install -g @anthropic-ai/claude-code || \
    echo "claude-code install failed (non-fatal, install manually with: npm i -g @anthropic-ai/claude-code)"

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
    LC_ALL=C.UTF-8 \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    PIP_USER=1 \
    PYTHONUSERBASE=/home/lab/.local \
    PIPX_HOME=/home/lab/.local/pipx \
    PIPX_BIN_DIR=/home/lab/.local/bin \
    NPM_CONFIG_PREFIX=/home/lab/.local \
    PATH=/home/lab/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Copy entrypoint that starts the Zellij web server
COPY --chown=lab:lab entrypoint.sh /home/lab/entrypoint.sh
RUN chmod +x /home/lab/entrypoint.sh

# Pretty bash defaults: colored prompt, aliases, history, banner.
COPY --chown=lab:lab bashrc /home/lab/.bashrc
RUN printf '%s\n' \
        "# Source .bashrc for login shells too" \
        "[ -f ~/.bashrc ] && . ~/.bashrc" > /home/lab/.bash_profile \
    && chown lab:lab /home/lab/.bash_profile

EXPOSE 8082 22

ENTRYPOINT ["/home/lab/entrypoint.sh"]

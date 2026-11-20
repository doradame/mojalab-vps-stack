# ============================================================================
# Zellij container — mojalab-vps-stack
# ============================================================================
# Zellij with built-in web client, running as non-root user.
#
# The Zellij tarball is verified against a SHA256:
#   - default version (ZELLIJ_DEFAULT_VERSION below): hashes for both
#     architectures are baked in, verification is automatic;
#   - any other ZELLIJ_VERSION: set ZELLIJ_SHA256 (in .env, or with
#     --build-arg) to the hash of the tarball for YOUR arch, e.g.
#       curl -fsSL https://github.com/zellij-org/zellij/releases/download/v${VER}/zellij-x86_64-unknown-linux-musl.tar.gz | sha256sum
#     If left empty the build SKIPS verification with a warning (acceptable
#     for a homelab, not for prod).
# When bumping the default version, update the three ZELLIJ_DEFAULT_* args.
# ============================================================================

# Debian 13 "trixie": bookworm went oldstable in Aug 2025 and its standard
# security support is ending; trixie also ships a current toolchain (Python
# 3.13, GCC 14) and `gh` in main — this is the dev workbench, it matters.
FROM debian:trixie-slim

ARG ZELLIJ_VERSION=0.44.1
ARG ZELLIJ_SHA256=""
# Known-good hashes for the default version (release assets on GitHub).
ARG ZELLIJ_DEFAULT_VERSION=0.44.1
ARG ZELLIJ_DEFAULT_SHA256_X86_64=669825021d529fca5d939888263c9d2a90762145191fa07581a15250e8af2b49
ARG ZELLIJ_DEFAULT_SHA256_AARCH64=6f028bb569d29be968c961249c5f80d5336ad4ad4b3cd79af8e32afab57b0948

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg bash bash-completion sudo procps xz-utils \
        iproute2 socat openssh-server openssh-client \
        git gh vim nano less htop ncdu tree jq file man-db unzip zip rsync tmux \
        ripgrep fd-find sqlite3 \
        build-essential pkg-config \
        python3 python3-pip python3-venv python3-dev python-is-python3 pipx \
    && mkdir -p /run/sshd \
    && rm -rf /var/lib/apt/lists/*

# Debian renames fd → fdfind. The bashrc alias only covers interactive shells;
# coding agents run `fd` through `sh -c` and would get "command not found".
RUN ln -s "$(command -v fdfind)" /usr/local/bin/fd

# uv — the Python package/venv manager modern agents expect. System-wide so
# it survives ~/.local wipes. Copied from the official image at a pinned
# version instead of piping the install script into sh. To update: bump the
# tag (https://github.com/astral-sh/uv/releases).
COPY --from=ghcr.io/astral-sh/uv:0.13.9 /uv /uvx /usr/local/bin/

# Node.js 22 LTS from NodeSource (Node 20 went EOL in April 2026; modern
# agent CLIs — Codex included — expect >= 22).
RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*

# Claude Code CLI (Anthropic), baked in as a first-boot convenience only.
# Day-to-day updates happen with `update-agents` (below), which installs into
# ~/.local/bin — first in PATH, so it shadows this copy. User state lives in
# ~/.claude (persistent volume).
RUN npm install -g @anthropic-ai/claude-code || \
    echo "claude-code install failed (non-fatal, install manually with: update-agents claude)"

# Agent updater — installs/updates coding CLIs (Claude Code, Codex, opencode,
# kiro-cli self-updater) into ~/.local so they persist across rebuilds and
# never require `docker compose build`. Run `update-agents` inside the container.
COPY update-agents.sh /usr/local/bin/update-agents
RUN chmod +x /usr/local/bin/update-agents

# Git SSH key helper — generates persistent ed25519 keys for GitHub/GitLab/
# any forge (~/.local/share/ssh, survives rebuilds) and prints the pub key.
COPY git-ssh-key.sh /usr/local/bin/git-ssh-key
RUN chmod +x /usr/local/bin/git-ssh-key

# Install Zellij from official binary release, picking the right arch.
# Optionally verify SHA256 (set ZELLIJ_SHA256 at build time — must match the
# tarball for the target architecture).
RUN set -eux; \
    case "$(uname -m)" in \
        x86_64|amd64)       zellijArch="x86_64-unknown-linux-musl";  defaultSha="${ZELLIJ_DEFAULT_SHA256_X86_64}" ;; \
        aarch64|arm64)      zellijArch="aarch64-unknown-linux-musl"; defaultSha="${ZELLIJ_DEFAULT_SHA256_AARCH64}" ;; \
        *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    expectedSha="${ZELLIJ_SHA256}"; \
    if [ -z "${expectedSha}" ] && [ "${ZELLIJ_VERSION}" = "${ZELLIJ_DEFAULT_VERSION}" ]; then \
        expectedSha="${defaultSha}"; \
    fi; \
    curl -fsSL "https://github.com/zellij-org/zellij/releases/download/v${ZELLIJ_VERSION}/zellij-${zellijArch}.tar.gz" \
        -o /tmp/zellij.tar.gz; \
    if [ -n "${expectedSha}" ]; then \
        echo "${expectedSha}  /tmp/zellij.tar.gz" | sha256sum -c -; \
    else \
        echo "WARNING: no checksum known for zellij ${ZELLIJ_VERSION} and ZELLIJ_SHA256 not set — skipping verification" >&2; \
    fi; \
    tar -xzf /tmp/zellij.tar.gz -C /usr/local/bin/; \
    chmod +x /usr/local/bin/zellij; \
    file /usr/local/bin/zellij; \
    /usr/local/bin/zellij --version; \
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

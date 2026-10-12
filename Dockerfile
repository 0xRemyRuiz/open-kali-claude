# syntax=docker/dockerfile:1
#
# open-kali-claude
# ----------------
# A headless Kali Linux box that runs the opencode HTTP API (an AI coding/agent
# server) backed by Claude, with Claude Code also installed. The opencode server
# is reachable over HTTP so you can send it instructions and stream, in realtime,
# everything it is doing (SSE at GET /event).
#
# Auth (API keys AND OAuth tokens) lives in /root/.local/share/opencode/auth.json
# which is backed by a Docker volume so the login survives container recreation.

FROM kalilinux/kali-rolling

# --- Build-time knobs (override with: docker build --build-arg NAME=value ...) ---

# Which Kali metapackage to install:
#   kali-linux-headless  full headless arsenal, no GUI (big: several GB)   <- default
#   kali-linux-core      essential tools only (much smaller / faster)
#   none                 base image + Node + the two npm tools only
ARG KALI_METAPACKAGE=kali-linux-headless

# Node.js major version (from NodeSource). opencode + Claude Code need modern Node.
ARG NODE_MAJOR=22

# npm package versions ("latest" or a pinned semver).
ARG OPENCODE_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# --- Base utilities + Node.js + (optional) Kali toolset ----------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg git openssh-client \
        procps less jq nano vim-tiny \
        iproute2 iputils-ping dnsutils \
        python3 python3-pip pipx \
        build-essential; \
    \
    # Node.js from NodeSource (distro-agnostic "nodistro" channel)
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs; \
    \
    # Optional Kali metapackage
    if [ "${KALI_METAPACKAGE}" != "none" ] && [ -n "${KALI_METAPACKAGE}" ]; then \
        apt-get install -y --no-install-recommends "${KALI_METAPACKAGE}"; \
    fi; \
    \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# --- opencode (served API) + Claude Code, installed globally via npm ---------
RUN set -eux; \
    npm install -g --no-fund --no-audit \
        "opencode-ai@${OPENCODE_VERSION}" \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    npm cache clean --force; \
    opencode --version; \
    claude --version || true

# --- Runtime configuration ---------------------------------------------------
# XDG dirs so opencode's data/config land where we expect. The data dir (which
# holds auth.json) is the one we persist with a volume.
ENV XDG_DATA_HOME=/root/.local/share \
    XDG_CONFIG_HOME=/root/.config \
    OPENCODE_DATA=/root/.local/share/opencode

# Default model/provider. "dev uses Claude" -> anthropic. Fully overridable at
# runtime via -e OPENCODE_MODEL / OPENCODE_PROVIDER (see entrypoint + README).
ENV OPENCODE_PROVIDER=anthropic \
    OPENCODE_MODEL=claude-sonnet-4-5 \
    OPENCODE_PORT=4096 \
    OPENCODE_HOSTNAME=0.0.0.0

RUN mkdir -p /root/.local/share/opencode /root/.config/opencode /work
VOLUME ["/root/.local/share/opencode"]
WORKDIR /work

EXPOSE 4096

# Reachable (any HTTP status, incl. 401 when a server password is set) == healthy.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -s -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:${OPENCODE_PORT:-4096}/global/health" | grep -qv '^000$'

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["serve"]

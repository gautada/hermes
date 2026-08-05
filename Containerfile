ARG DEBIAN_IMAGE=docker.io/gautada/debian:13.6
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.11.6
ARG NODE_IMAGE=docker.io/library/node:22-bookworm-slim

FROM ${UV_IMAGE} AS uv
FROM ${NODE_IMAGE} AS node
FROM ${DEBIAN_IMAGE}

LABEL org.opencontainers.image.title="hermes"
LABEL org.opencontainers.image.description="Hermes Agent on the gautada Debian base image"
LABEL org.opencontainers.image.source="https://github.com/gautada/hermes"
LABEL org.opencontainers.image.licenses="MIT"

ARG HERMES_REPOSITORY=https://github.com/nousresearch/hermes-agent.git
ARG HERMES_REF=main

ENV DEBIAN_FRONTEND=noninteractive \
    HERMES_HOME=/mnt/volumes/data/hermes \
    HERMES_WRITE_SAFE_ROOT=/mnt/volumes/data/hermes \
    HERMES_DISABLE_LAZY_INSTALLS=1 \
    HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist \
    HERMES_TUI_DIR=/opt/hermes/ui-tui \
    PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
    UV_PYTHON_INSTALL_DIR=/opt/hermes/.uv-python \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH=/opt/hermes/.venv/bin:/usr/local/bin:/usr/bin:/bin

# Hermes needs Python, build tools for native Python extensions, Git-backed
# tools, ffmpeg, ripgrep, SSH, and the Docker client. The base image already
# provides s6, curl, certificates, cron, sudo, and common administration tools.
RUN apt-get -o Acquire::Retries=3 update \
 && apt-get -o Acquire::Retries=3 install --yes --no-install-recommends \
      build-essential \
      cmake \
      docker-cli \
      ffmpeg \
      git \
      iputils-ping \
      libffi-dev \
      libolm-dev \
      openssh-client \
      procps \
      python-is-python3 \
      python3 \
      python3-dev \
      python3-venv \
      ripgrep \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /uvx /usr/local/bin/
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && ln -s /usr/local/lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack

WORKDIR /opt/hermes

# HERMES_REF may be a branch, tag, or commit. Pin it to a commit or release tag
# in production so rebuilds are reproducible.
RUN git clone --filter=blob:none "${HERMES_REPOSITORY}" . \
 && git checkout "${HERMES_REF}" \
 && git submodule update --init --recursive \
 && uv sync --frozen --no-install-project \
      --extra all \
      --extra messaging \
      --extra anthropic \
      --extra bedrock \
      --extra azure-identity \
      --extra hindsight \
      --extra matrix \
 && uv pip install --no-cache-dir --no-deps -e . \
 && npm install --prefer-offline --no-audit \
 && npm --prefix web run build \
 && npm --prefix ui-tui run build \
 && npm cache clean --force \
 && rm -rf /root/.cache /root/.npm .git

# Override the base image's Debian version reporter with the application
# version expected by the container version and health mechanisms.
COPY usr/bin/container-version /usr/bin/container-version
RUN chmod 0755 /usr/bin/container-version

# The gautada/debian base runs s6 over /etc/services.d. Add Hermes as a
# supervised service and keep the base image's crond service intact.
RUN mkdir -p "${HERMES_HOME}" /etc/services.d/hermes \
 && chown -R debian:debian "${HERMES_HOME}" \
 && printf '%s\n' \
      '#!/bin/sh' \
      'exec 2>&1' \
      'exec s6-setuidgid debian /opt/hermes/.venv/bin/hermes gateway run' \
      > /etc/services.d/hermes/run \
 && chmod 0755 /etc/services.d/hermes/run

EXPOSE 8080/tcp 9119/tcp
WORKDIR /mnt/volumes/data/hermes

# ENTRYPOINT is inherited from gautada/debian:
# ["/usr/bin/s6-svscan", "/etc/services.d"]

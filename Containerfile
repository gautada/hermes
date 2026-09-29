ARG NODE_VERSION=24.20.0
ARG UV_IMAGE=ghcr.io/astral-sh/uv:latest
FROM ${UV_IMAGE} AS uv

FROM docker.io/gautada/node:${NODE_VERSION} as build
ARG HERMES_REPOSITORY=https://github.com/nousresearch/hermes-agent.git
ARG HERMES_VERSION=main

RUN apt-get update \
 && apt-get install --yes --no-install-recommends \
      build-essential \
      cmake \
      git \
      libffi-dev \
      libolm-dev \
      openssh-client \
      python-is-python3 \
      python3 \
      python3-dev \
      python3-venv \
      python3-uv \
 && apt-get upgrade --yes \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*
# ╭――――――――――――――――――╮
# │ UV               │
# ╰――――――――――――――――――╯
# uv is the one dependency manager this image is opinionated about. It ships
# as a single static binary, so pulling it in costs almost nothing in image
# size and needs no compiler toolchain.
COPY --from=uv /uv /uvx /usr/local/bin/


# COPY --from=node /usr/local/bin/node /usr/local/bin/node
# COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
# RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
#  && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
#  && ln -s /usr/local/lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack

WORKDIR /opt
RUN git clone --branch "v${HERMES_VERSION}" "${HERMES_REPOSITORY}" hermes
WORKDIR /opt/hermes
RUN git submodule update --init --recursive \
 && uv sync --frozen --no-install-project \
      --extra all \
      --extra messaging \
      --extra anthropic \
      --extra bedrock \
      --extra azure-identity \
      --extra hindsight \
      --extra matrix \
 && uv pip install --no-cache-dir --no-deps -e . \
 && npm install --prefer-offline --no-audit --workspace=web \
 && npm --prefix web run build \
 && npm cache clean --force \
 && rm -rf /root/.cache /root/.npm .git /opt/hermes/ui-tui /opt/hermes/apps /opt/hermes/tests-js

# COPY patches/* /tmp/
# RUN patch -p1 /opt/hermes/gateway/platforms/bluebubbles.py < /tmp/bluebubbles.patch

# # ╭――――――――――――――――――――――――――――╮
# # │ FINAL                       │
# # ╰――――――――――――――――――――――――――――╯
# # Only what a running headless Hermes gateway + web dashboard actually needs.
# # No compilers, no dev headers — building C/Python/JS code on request is
# # delegated to on-demand podman/docker build environments via the docker
# # tool, not baked into this always-on image.
# FROM docker.io/gautada/debian:${PYTHON_VERSION} as final
#
# LABEL org.opencontainers.image.title="hermes"
# LABEL org.opencontainers.image.description="Hermes Agent on the gautada Debian base image"
# LABEL org.opencontainers.image.source="https://github.com/gautada/hermes"
# LABEL org.opencontainers.image.licenses="MIT"
#
# ENV DEBIAN_FRONTEND=noninteractive \
#     HERMES_WRITE_SAFE_ROOT=/home/hermes/.hermes \
#     HERMES_DISABLE_LAZY_INSTALLS=1 \
#     HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist \
#     PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
#     PYTHONUNBUFFERED=1 \
#     PYTHONDONTWRITEBYTECODE=1 \
#     PATH=/opt/hermes/.venv/bin:/usr/local/bin:/usr/bin:/bin \
#     NODE_OPTIONS=--dns-result-order=ipv4first
#
# # Runtime-only packages, backing actual Hermes tools rather than the build:
# # docker-cli (docker tool / delegated build environments), ffmpeg (voice,
# # video), git + openssh-client (git/skills/project tools), procps (terminal,
# # process tools), ripgrep (file search), iputils-ping (network diagnostics),
# # zlib1g (dynamically linked by Pillow's vendored image codecs). No compiler,
# # no dev headers, no system Python — the copied .venv brings its own
# # self-contained interpreter.
# RUN apt-get -o Acquire::Retries=3 update \
#  && apt-get -o Acquire::Retries=3 install --yes --no-install-recommends \
#       docker-cli \
#       ffmpeg \
#       git \
#       iputils-ping \
#       openssh-client \
#       procps \
#       ripgrep \
#       zlib1g \
#       sqlite3 \
#  && apt-get clean \
#  && rm -rf /var/lib/apt/lists/*
#
# # ╭――――――――――――――――――――╮
# # │ USER               │
# # ╰――――――――――――――――――――╯
# # Rename the base debian user to hermes. Follows the same pattern as other
# # gautada containers (e.g. gautada/homepage).
# ARG OLDUSER=monty
# ARG USER=hermes
# RUN /usr/sbin/usermod -l $USER $OLDUSER \
#  && /usr/sbin/usermod -d /home/$USER -m $USER \
#  && /usr/sbin/groupmod -n $USER $OLDUSER \
#  && /bin/echo "$USER:$USER" | /usr/sbin/chpasswd \
#  && ln -fsv /mnt/volumes/data /home/${USER}/.hermes
#
# COPY --from=node /usr/local/bin/node /usr/local/bin/node
# COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
# RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
#  && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
#  && ln -s /usr/local/lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack
# COPY --from=builder --chown=hermes:hermes /opt/hermes /opt/hermes
#
# # ╭――――――――――――――――――╮
# # │ VERSION          │
# # ╰――――――――――――――――――╯
# # Override the base image's Debian version reporter with the application
# # version expected by the container version and health mechanisms.
# # COPY usr/bin/container-version /usr/bin/container-version
# # RUN chmod 0755 /usr/bin/container-version
# #
# # # The gautada/debian base runs s6 over /etc/services.d. Add Hermes as a
# # # supervised service and keep the base image's crond service intact.
# # # HERMES_HOME is intentionally left unset — Hermes defaults to ~/.hermes,
# # # which for the hermes user resolves to /home/hermes/.hermes. That path is
# # # symlinked to the volume mount point so persistent state (config, sessions,
# # # skills) survives container replacement without baking the mount path into
# # # the image.
# # # RUN mkdir -p /etc/services.d/hermes \
# # #  && ln -s /mnt/volumes/data /home/hermes/.hermes \
# # #  && chown -h hermes:hermes /home/hermes/.hermes \
# # #  && printf '%s\n' \
# # #       '#!/bin/sh' \
# # #       'exec 2>&1' \
# # #       'exec s6-setuidgid hermes /opt/hermes/.venv/bin/hermes gateway run' \
# # #       > /etc/services.d/hermes/run \
# # COPY etc/services.d/hermes/run /etc/services.d/hermes/run
# # RUN chmod 0755 /etc/services.d/hermes/run
# #
# # COPY etc/crontab /etc/crontab
# # COPY _local/bin/backup /home/hermes/.local/bin/backup
# # COPY _local/bin/restore /home/hermes/.local/bin/restore
# #
# #
# # EXPOSE 8080/tcp 9119/tcp 8645/tcp
# # WORKDIR /home/hermes/.hermes
# # RUN mkdir -p /home/${USER}/.local/bin \
# #  && ln -fsv /opt/hermes/.venv/bin/hermes /home/${USER}/.local/bin/hermes \
# #  && chown ${USER}:${USER} -R /opt/hermes /home/${USER} /mnt/volumes/data
# # ENV PATH="/home/${USER}/.local/bin:${PATH}"
# #
# # # ENTRYPOINT is inherited from gautada/debian:
# # # ["/usr/bin/s6-svscan", "/etc/services.d"]

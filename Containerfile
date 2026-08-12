ARG BASE_IMAGE=docker.io/gautada/python:latest
ARG NODE_IMAGE=docker.io/library/node:22-bookworm-slim

FROM ${NODE_IMAGE} AS node

# ╭――――――――――――――――――――――――――――╮
# │ BUILDER                     │
# ╰――――――――――――――――――――――――――――╯
# Everything needed to compile Hermes and its native extensions. Discarded
# after the final stage COPYs the built output — its size doesn't matter.
FROM ${BASE_IMAGE} AS builder

ARG HERMES_REPOSITORY=https://github.com/nousresearch/hermes-agent.git
ARG HERMES_REF=main

# ╭――――――――――――――――――――――――――――╮
# │ NETWORK DIAGNOSTIC          │
# ╰――――――――――――――――――――――――――――╯
# Builds have intermittently failed with "network is unreachable" / EAI_AGAIN
# during apt-get, npm, and uv steps alike — across different tools, which
# points at the build container's network path itself rather than any one
# tool's DNS handling. This step proves, in the build log, whether IPv4 and
# IPv6 egress actually work from inside podman's build network before any
# real package manager runs. Uses raw sockets (no curl/apt involved) so the
# result isn't confused by an individual tool's own retry/fallback behavior.
# RUN python3 - <<'PY'
# import socket
# import sys
#
# def probe(af, addr, port, label):
#     s = socket.socket(af, socket.SOCK_STREAM)
#     s.settimeout(5)
#     try:
#         s.connect((addr, port))
#         print(f"[NET DIAG] {label}: OK ({addr}:{port})")
#         return True
#     except Exception as e:
#         print(f"[NET DIAG] {label}: FAIL ({addr}:{port}) -> {e}")
#         return False
#     finally:
#         s.close()
#
# ipv4_ok = probe(socket.AF_INET, "1.1.1.1", 443, "IPv4 direct")
# ipv6_ok = probe(socket.AF_INET6, "2606:4700:4700::1111", 443, "IPv6 direct")
#
# try:
#     infos = socket.getaddrinfo("deb.debian.org", 443, proto=socket.IPPROTO_TCP)
#     families = sorted({"IPv6" if i[0] == socket.AF_INET6 else "IPv4" for i in infos})
#     print(f"[NET DIAG] deb.debian.org resolves to: {families}")
# except Exception as e:
#     print(f"[NET DIAG] deb.debian.org DNS FAILED -> {e}")
#
# print(f"[NET DIAG] SUMMARY: ipv4={'OK' if ipv4_ok else 'FAIL'} ipv6={'OK' if ipv6_ok else 'FAIL'}")
# if not ipv4_ok:
#     print("[NET DIAG] FATAL: no IPv4 egress — build cannot proceed regardless of IPv6.")
#     sys.exit(1)
# if not ipv6_ok:
#     print("[NET DIAG] IPv6 egress is broken in this build environment. Any step that "
#           "resolves a dual-stack host (apt, npm, uv, git) may intermittently fail if "
#           "DNS hands back an AAAA record first, even though the underlying tool is fine.")
# PY

# Confirmed cluster-wide (not just this build): pods here have no IPv6 route,
# so any tool that gets an AAAA record back before an A record can fail with
# "network is unreachable" instead of falling back to IPv4. This affects every
# glibc-resolved tool — apt, curl, git, wget, uv — not just Node. Telling
# glibc to prefer IPv4-mapped addresses (RFC 3484 precedence table) fixes DNS
# ordering for all of them at once.
RUN printf '%s\n' 'precedence ::ffff:0:0/96 100' >> /etc/gai.conf

ENV DEBIAN_FRONTEND=noninteractive \
    UV_PYTHON_INSTALL_DIR=/opt/hermes/.uv-python \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    NODE_OPTIONS=--dns-result-order=ipv4first \
    PATH=/opt/hermes/.venv/bin:/usr/local/bin:/usr/bin:/bin

# Compilers and dev headers here exist only to build Hermes's native
# extensions (node-pty, python-olm, etc.) and are never copied into the
# final stage. Confirmed empirically: the built .venv's Python is a fully
# self-contained portable interpreter (links only base glibc), and every
# compiled .so in it either statically links or vendors its own copy of
# whatever it needed at build time — nothing in the final image dynamically
# depends on libffi/libolm/build-essential's output.
RUN apt-get -o Acquire::Retries=3 update \
 && apt-get -o Acquire::Retries=3 install --yes --no-install-recommends \
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
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

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
 && npm install --prefer-offline --no-audit --workspace=web \
 && npm --prefix web run build \
 && npm cache clean --force \
 && rm -rf /root/.cache /root/.npm .git /opt/hermes/ui-tui /opt/hermes/apps /opt/hermes/tests-js

COPY patches ./
# Dry run first — confirms it'll apply cleanly without touching anything
RUN patch --dry-run -p1 < ./patches/bluebubbles_webhook_proxy.patch \
 && patch -p1 < ./patches/bluebubbles_webhook_proxy.patch \
 && rm -rf ./patches
# ╭――――――――――――――――――――――――――――╮
# │ FINAL                       │
# ╰――――――――――――――――――――――――――――╯
# Only what a running headless Hermes gateway + web dashboard actually needs.
# No compilers, no dev headers — building C/Python/JS code on request is
# delegated to on-demand podman/docker build environments via the docker
# tool, not baked into this always-on image.
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="hermes"
LABEL org.opencontainers.image.description="Hermes Agent on the gautada Debian base image"
LABEL org.opencontainers.image.source="https://github.com/gautada/hermes"
LABEL org.opencontainers.image.licenses="MIT"

RUN printf '%s\n' 'precedence ::ffff:0:0/96 100' >> /etc/gai.conf

ENV DEBIAN_FRONTEND=noninteractive \
    HERMES_WRITE_SAFE_ROOT=/home/hermes/.hermes \
    HERMES_DISABLE_LAZY_INSTALLS=1 \
    HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist \
    PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH=/opt/hermes/.venv/bin:/usr/local/bin:/usr/bin:/bin \
    NODE_OPTIONS=--dns-result-order=ipv4first

# Runtime-only packages, backing actual Hermes tools rather than the build:
# docker-cli (docker tool / delegated build environments), ffmpeg (voice,
# video), git + openssh-client (git/skills/project tools), procps (terminal,
# process tools), ripgrep (file search), iputils-ping (network diagnostics),
# zlib1g (dynamically linked by Pillow's vendored image codecs). No compiler,
# no dev headers, no system Python — the copied .venv brings its own
# self-contained interpreter.
RUN apt-get -o Acquire::Retries=3 update \
 && apt-get -o Acquire::Retries=3 install --yes --no-install-recommends \
      docker-cli \
      ffmpeg \
      git \
      iputils-ping \
      openssh-client \
      procps \
      ripgrep \
      zlib1g \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# ╭――――――――――――――――――――╮
# │ USER               │
# ╰――――――――――――――――――――╯
# Rename the base debian user to hermes. Follows the same pattern as other
# gautada containers (e.g. gautada/homepage).
ARG USER=hermes
RUN /usr/sbin/usermod -l $USER monty \
 && /usr/sbin/usermod -d /home/$USER -m $USER \
 && /usr/sbin/groupmod -n $USER monty \
 && /bin/echo "$USER:$USER" | /usr/sbin/chpasswd \
 && ln -fsv /mnt/volumes/data /home/${USER}/.hermes

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && ln -s /usr/local/lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack
COPY --from=builder --chown=hermes:hermes /opt/hermes /opt/hermes

# ╭――――――――――――――――――╮
# │ VERSION          │
# ╰――――――――――――――――――╯
# Override the base image's Debian version reporter with the application
# version expected by the container version and health mechanisms.
COPY usr/bin/container-version /usr/bin/container-version
RUN chmod 0755 /usr/bin/container-version

# The gautada/debian base runs s6 over /etc/services.d. Add Hermes as a
# supervised service and keep the base image's crond service intact.
# HERMES_HOME is intentionally left unset — Hermes defaults to ~/.hermes,
# which for the hermes user resolves to /home/hermes/.hermes. That path is
# symlinked to the volume mount point so persistent state (config, sessions,
# skills) survives container replacement without baking the mount path into
# the image.
# RUN mkdir -p /etc/services.d/hermes \
#  && ln -s /mnt/volumes/data /home/hermes/.hermes \
#  && chown -h hermes:hermes /home/hermes/.hermes \
#  && printf '%s\n' \
#       '#!/bin/sh' \
#       'exec 2>&1' \
#       'exec s6-setuidgid hermes /opt/hermes/.venv/bin/hermes gateway run' \
#       > /etc/services.d/hermes/run \
COPY etc/services.d/hermes/run /etc/services.d/hermes/run
RUN chmod 0755 /etc/services.d/hermes/run



EXPOSE 8080/tcp 9119/tcp 8645/tcp
WORKDIR /home/hermes/.hermes
RUN chown ${USER}:${USER} -R /opt/hermes /home/${USER} /mnt/volumes/data


# ENTRYPOINT is inherited from gautada/debian:
# ["/usr/bin/s6-svscan", "/etc/services.d"]

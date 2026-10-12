# Hermes

Container packaging for
[Nous Research Hermes Agent](https://github.com/nousresearch/hermes-agent),
built on
[`docker.io/gautada/debian:13.6`](https://hub.docker.com/r/gautada/debian).

The image installs the Hermes CLI, gateway, web interface, and terminal UI. At
runtime, the `gautada/debian` s6 supervisor starts both the base image's cron
service and:

```text
hermes gateway run
```

Hermes runs as the unprivileged `hermes` user (the base image's `debian` user,
renamed — following the same pattern as other `gautada` containers). Its home
directory, `/home/hermes/.hermes`, is symlinked to the volume mount point, so
configuration, credentials, sessions, skills, and other persistent state
belong under `/mnt/volumes/data`.

## Build

Build the current Hermes Agent `main` branch with Podman:

```sh
podman build --tag localhost/hermes:ai --file Containerfile .
```

Docker uses the equivalent command:

```sh
docker build --tag hermes:ai --file Containerfile .
```

The default upstream branch can move between builds. For a reproducible image,
pin `HERMES_REF` to a release tag or commit SHA:

```sh
podman build \
  --build-arg HERMES_REF=<tag-or-commit> \
  --tag localhost/hermes:<version> \
  --file Containerfile .
```

The upstream repository and source images can also be overridden with the
`HERMES_REPOSITORY`, `DEBIAN_IMAGE`, `UV_IMAGE`, and `NODE_IMAGE` build
arguments.

## Initial deployment

Create a named volume and start the container:

```sh
podman volume create hermes-data

podman run --detach \
  --name hermes \
  --restart unless-stopped \
  --volume hermes-data:/mnt/volumes/data \
  localhost/hermes:ai
```

For Docker, replace `podman` with `docker` and use the tag built above.

The gateway may restart until its initial configuration exists. Run the
interactive setup as the image's unprivileged user:

```sh
podman exec --interactive --tty --user hermes hermes hermes setup
```

Then restart the container so the supervised gateway reloads the completed
configuration:

```sh
podman restart hermes
podman logs --follow hermes
```

API keys can be entered during `hermes setup` or supplied through environment
variables or mounted secrets according to the
[Hermes Agent configuration documentation](https://hermes-agent.nousresearch.com/docs/).
Avoid placing credentials in the image or committing them to this repository.

## Storage

The named volume is mounted at `/mnt/volumes/data`, one of the persistent mount
points provided by the base image. It is symlinked to the `hermes` user's
home directory (`/home/hermes/.hermes`), which is where Hermes stores its
configuration, credentials, sessions, and skills by default.

Back up this volume to retain configuration and agent state across container
replacement. The base image also defines mount points for configuration,
backup, and secrets at:

```text
/mnt/volumes/configuration
/mnt/volumes/backup
/mnt/volumes/secrets
```

## Networking

The image declares TCP ports `8080` and `9119`. Publishing a port alone does
not enable or secure an API or dashboard; those services must be configured
explicitly. Do not expose an unauthenticated Hermes interface directly to the
internet.

To publish a configured service, add the appropriate mapping when creating the
container, for example:

```sh
podman run --detach \
  --name hermes \
  --restart unless-stopped \
  --volume hermes-data:/mnt/volumes/data \
  --publish 127.0.0.1:9119:9119 \
  localhost/hermes:ai
```

Binding to `127.0.0.1` keeps the port local to the container host. Use an
authenticated reverse proxy or SSH tunnel for remote access.

## Administration

Useful commands:

```sh
# Show logs
podman logs --follow hermes

# Check Hermes configuration and dependencies
podman exec --interactive --tty --user hermes hermes hermes doctor

# Open a shell as the Hermes runtime user
podman exec --interactive --tty --user hermes hermes zsh

# Stop and remove the container without deleting persistent data
podman stop hermes
podman rm hermes
```

The `hermes-data` volume is intentionally retained when the container is
removed.

## Security — tirith

The image ships a working [tirith](https://tirith.sh/) installation (v0.4.2)
at `/usr/local/bin/tirith`. Hermes uses tirith as a pre-execution scanner: every
shell command issued through the terminal tool is analysed for security risks
before it runs.

The base policy is the upstream `ai-agent-heavy` template — tuned for
environments where AI agents run many shell commands. It ships with `paranoia: 3`,
strict-warn enabled, pipe-to-shell patterns escalated to CRITICAL, and approval
rules that block after a 120-second timeout.

### What every agent gets for free

A fresh downstream image (e.g. `gautada/nyxcalder`, `gautada/rennakatomi`)
inherits all of the following with no extra configuration:

- **tirith binary** on PATH — Hermes auto-detects it via the default
  `security.tirith_path` setting.
- **Hardened policy** at `/home/hermes/.config/tirith/policy.yaml`:
  `paranoia: 3`, `strict_warn: true`, `gateway_profile: secure`,
  pipe-to-shell escalations, and the `analysis_incomplete: info` severity
  override that prevents `$(cat ...)` subshell patterns from blocking
  unattended runs.
- **Shell hooks** materialized at build time in
  `~/.local/share/tirith/shell/lib/` — available for interactive sessions.
- **Threat database** seeded at build time (~11 MB) and auto-updates every
  24 hours at runtime.
- **pcp-api.sh** at `/home/hermes/.local/bin/pcp-api.sh` — a Paperclip API
  wrapper that avoids tirith's subshell detection for Bearer-token headers.
- **Approval rules** with `timeout_secs: 120, fallback: block` — an
  unattended agent with no approval responder gets a clean block after two
  minutes instead of burning its entire run window.

### Overriding the policy downstream

The base image's policy is baked into the image layer at
`/home/hermes/.config/tirith/policy.yaml`. It is intentionally NOT on the data
volume, so downstream images always inherit a known-good default.

To customise the policy for a specific agent:

1. Place a policy file on the agent's durable volume, e.g.
   `/mnt/volumes/data/tirith/policy.yaml`.
2. In the agent's bootstrap hook, symlink it into the config directory:
   ```sh
   mkdir -p "$HOME/.config/tirith"
   ln -sf /mnt/volumes/data/tirith/policy.yaml "$HOME/.config/tirith/policy.yaml"
   ```
3. The symlink takes precedence over the baked-in file. If the volume is
   empty or the symlink is removed, the image layer's default is restored
   automatically.

### Extending the policy without breaking inheritance

- **Add trusted domains**: use `tirith trust add <domain>` instead of editing
  the base image's `allowlist`. Trust entries have a 30-day TTL by default;
  broader scope requires an explicit `--broad` flag. Manage with
  `tirith trust list`, `tirith trust explain`, `tirith trust diff`,
  `tirith trust remove`, `tirith trust gc`.
- **Tighten rules**: a repo-scoped `.tirith/policy.yaml` can only tighten
  (blocklist, deny), never loosen (its allowlist is ignored by design).
  Loosening must go in the user-scoped `~/.config/tirith/policy.yaml`.
- **Add approval rules**: same approach — add them to the agent's override.

### Policy precedence — important

Policy discovery order is:

1. `.tirith/policy.yaml` in the current directory, walking up to the repo root
2. `~/.config/tirith/policy.yaml`

The first match **wins outright — it does not merge**. An agent working inside a
repo that contains its own `.tirith/policy.yaml` **silently loses the entire base
posture** with no warning. A repo-level policy must be written as a complete
superset of the base, not a fragment.

### State vs config — what lives where

| Kind | Location | Layer |
|---|---|---|
| Policy | `~/.config/tirith/policy.yaml` | Image (inherited) |
| Shell hooks | `~/.local/share/tirith/shell/lib/` | Image (materialized at build) |
| Threat DB | `~/.local/share/tirith/tirith-threatdb.dat` | Image (seeded), runtime updates |
| Audit JSONL | `~/.local/state/tirith/` | Data volume (mutable) |
| Trust store | `~/.local/share/tirith/trust/` | Data volume (mutable) |
| AI config snapshots | per-repo | Data volume (mutable) |
| Run receipts | `~/.local/state/tirith/` | Data volume (mutable) |

Mutable state belongs on the data volume so it survives container replacement.
Config and hooks belong in the image layer so they are inherited.

### Known gotchas

- `$(cat ...)` in curl commands triggers `analysis_incomplete` at HIGH. The
  base policy downgrades this to `info`. If you reset `severity_overrides` in
  your override, re-add `analysis_incomplete: info` or authenticated API
  calls will block in unattended mode.
- Repo-scoped `.tirith/policy.yaml` allowlist entries are ignored by design.
  Only the user-scoped policy at `~/.config/tirith/policy.yaml` controls
  allowed domains.
- `allow_bypass_env: false` means **`TIRITH=0` does not work** — interactive
  or not. This is intentional in the agent-heavy preset. Fix the policy or
  add a trust entry instead of reaching for the env var.
- `tirith_fail_open: true` (the Hermes default) means a crashed or timed-out
  tirith silently provides no protection. The build-time `tirith doctor
  --quick` check validates the installation, but there is no runtime health
  check.

### AI config drift detection (recommended)

`tirith ai` watches files that steer agent behaviour — `CLAUDE.md`,
`AGENTS.md`, `.claude/*`, `.mcp.json` — and diffs them against a last-known-safe
snapshot for hidden-instruction injection and tool-use escalation. This is not
enabled by default in the base image.

To use it in a repo:
```sh
tirith ai snapshot --update   # record a baseline
tirith ai diff                # check for drift
```

### Recommended Hermes config setting

For agents dispatched by Paperclip, `approvals.unattended_mode: smart` is
recommended in the agent's Hermes config. This is not set in the base image
because it affects approval behaviour fleet-wide — each agent should opt in
explicitly.

## Current status

This is an initial container definition. It follows the `gautada/debian`
service and storage conventions but has not yet been hardened or validated as a
production release. Before production use, pin all source image digests and
`HERMES_REF`, complete an image build and smoke test, and define
deployment-specific health checks, resource limits, networking, and secret
management.

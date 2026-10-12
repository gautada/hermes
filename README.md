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

## Current status

This is an initial container definition. It follows the `gautada/debian`
service and storage conventions but has not yet been hardened or validated as a
production release. Before production use, pin all source image digests and
`HERMES_REF`, complete an image build and smoke test, and define
deployment-specific health checks, resource limits, networking, and secret
management.

## Security — tirith

The image ships [tirith](https://tirith.sh) 0.4.2, a terminal security tool
that intercepts and analyzes shell commands before execution. Every downstream
agent image inherits a working, policied tirith with zero configuration.

### What you get for free

- **tirith on PATH** at `/usr/local/bin/tirith`. The Hermes default
  `tirith_path: tirith` resolves it automatically — no `security.tirith_path`
  override needed.
- **The `ai-agent-heavy` policy** baked into the image layer at
  `~/.config/tirith/policy.yaml`. This is upstream's curated preset for
  environments where AI agents run many shell commands: `paranoia: 3`,
  `allow_bypass_env: false`, `strict_warn: true`, five approval rules with
  120 s timeout and `fallback: block`, two escalation triggers covering
  pipe-to-shell, typosquat, secret-exfil, and remote-exec families.
- **The shell hook** installed via `eval "$(tirith init --shell bash)"` in
  the hermes bash profile. This is what actually calls tirith before each
  command. Without it the binary on PATH does nothing.
- **An empty allowlist.** The base image does not pre-trust any domains. Each
  agent adds its own entries downstream via `tirith trust add`.

### Configuration vs state split

**In the image layer** (survives container replacement only via rebuild):
- Policy: `~/.config/tirith/policy.yaml`
- Shell hook library: `~/.local/share/tirith/`
- Binary: `/usr/local/bin/tirith`

**On the data volume** (`/mnt/volumes/data` aka `/home/hermes/.hermes`):
- Audit log (JSONL)
- Trust store (`tirith trust` entries)
- Threat database
- `ai` config snapshots
- `run` receipts

### Policy precedence — read this

tirith discovers policy in this order:

1. `.tirith/policy.yaml` in the current directory, walking up to the repo root
2. `~/.config/tirith/policy.yaml` (the base image file)

The first match **wins outright — it does not merge**. A repo that ships its
own `.tirith/policy.yaml` **silently replaces the entire base posture** with no
warning. If you need a repo-level policy, write it as a **superset** of the
base policy, not a fragment. Copy the base file, then add to it.

### Adding per-agent exceptions

Use `tirith trust add`, not the base image's `allowlist`:

```sh
tirith trust add example.com          # 30-day TTL by default
tirith trust add --broad internal.net # broader scope, explicit opt-in
tirith trust list                     # show active trust entries
tirith trust explain example.com      # why is this trusted?
tirith trust diff                     # changes since last snapshot
tirith trust remove example.com
tirith trust gc                       # expire stale entries
```

Editing the base image's `allowlist` array is fleet-wide and permanent. The
trust mechanism is narrower, time-limited, and auditable.

### Behaviours that will surprise you

- **`TIRITH=0` does not work.** The `ai-agent-heavy` preset sets
  `allow_bypass_env: false`, so the env-var escape hatch is disabled. Fix the
  policy or add a trust entry instead.
- **Approval timeout is 120 seconds, then block.** An unattended agent with
  no approval responder gets a clean block after two minutes instead of
  burning its entire run window. This is by design — it prevents the EUR-5
  failure mode where a gated command consumed a full 600 s run.

### Threat database

The threat database is **not** seeded at build time to avoid GitHub rate limits
across parallel builds. It auto-populates on first run (24 h schedule, opt-out).
Set `TIRITH_OFFLINE=1` to suppress network updates entirely.

### Recommended: `tirith ai` for config-drift detection

`tirith ai` watches the files that steer agents — `CLAUDE.md`, `AGENTS.md`,
`.claude/*`, `.mcp.json` — and diffs them against a known-safe snapshot for
hidden-instruction injection and tool-use escalation.

```sh
tirith ai snapshot --update   # record a baseline
tirith ai diff                # check for drift
```

This is a per-repo recommendation, not a base-image default.

### Recommended: `unattended_mode` for Paperclip agents

Agents dispatched by Paperclip or any unattended orchestrator should add to
their Hermes configuration:

```yaml
approvals:
  unattended_mode: smart
```

This is **not** set in the base image. It changes approval behaviour
fleet-wide, so each operator enables it per agent after review. Without it, an
unattended agent cannot answer an approval prompt, so a gated command burns
its whole run window.

### Overriding the policy downstream

Ship your own `~/.config/tirith/policy.yaml` in your downstream image layer.
The base image file is a complete, validated policy — copy it, then modify.
Do **not** move the policy onto the data volume. The volume would mask the
baked-in default, and any agent that has not created its own copy would
silently lose the baseline.

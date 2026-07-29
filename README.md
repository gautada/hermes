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

Hermes runs as the unprivileged `debian` user. Its configuration, credentials,
sessions, skills, and other persistent state belong under
`/mnt/volumes/data/hermes`.

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
podman exec --interactive --tty --user debian hermes hermes setup
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
points provided by the base image. Hermes uses the following directory inside
it:

```text
/mnt/volumes/data/hermes
```

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
podman exec --interactive --tty --user debian hermes hermes doctor

# Open a shell as the Hermes runtime user
podman exec --interactive --tty --user debian hermes zsh

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

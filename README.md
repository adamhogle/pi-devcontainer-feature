# pi devcontainer feature

Installs the [pi](https://github.com/earendil-works/pi-coding-agent) coding agent into a dev
container, so pi can run **inside** the sandbox instead of on the host routing tools in.

The point of this feature is that **nothing pi-related ever enters a repo's
`devcontainer.json`**. It is applied at provisioning time by the host script `dev-up`, via
`--additional-features`, and the repo stays unaware that pi exists.

## Design

- **Private Node runtime.** Node is installed to `/opt/pi/node` and deliberately kept **off
  `PATH`**. The only thing on `PATH` is `/usr/local/bin/pi`, a wrapper that invokes it by
  absolute path. Consequences:
  - works on any glibc image, whether or not Node is present;
  - cannot shadow the workspace's own toolchain — commands the agent runs still see the
    project's node;
  - no `dependsOn` on the Node feature, and no per-project `installNode` knob.
- **Config dir is a fixed path.** `PI_CODING_AGENT_DIR=/opt/pi/agent`, where `dev-up`
  bind-mounts the host's `~/.pi/agent`. A fixed, user-independent target means provisioning
  does not need to know `remoteUser` before the container exists.
- **No credentials.** The feature handles none. `dev-pi` injects them per session with
  `podman exec -e`, so they are fresh each time and never baked into the container.

## Install the host scripts

```sh
git clone git@code.siemens.com:ogleah/pi-devcontainer-feature.git
cd pi-devcontainer-feature && ./install.sh
```

Symlinks `bin/dev-up`, `bin/dev-pi` and `bin/dev-down` into `~/.local/bin`. Because they are
symlinks, `git pull` is the release mechanism for the host side. Only `src/` is published to
the registry.

Usage:

```sh
envchain gitlab dev-up          # provision (needs GITLAB_TOKEN to pull the feature)
envchain sdc,gitlab dev-pi      # attach and run pi inside the container
dev-down                        # remove the container
```

## Publish

Published to the project's own GitLab container registry:

```sh
podman login cr.siemens.com          # or a deploy token / CI job token

cd ~/source/pi-devcontainer-feature
devcontainer features publish ./src \
  --registry cr.siemens.com \
  --namespace ogleah/pi-devcontainer-feature
```

That publishes `cr.siemens.com/ogleah/pi-devcontainer-feature/pi`, tagged with the exact
version plus every enclosing prefix — `1.0.0`, `1.0`, `1` and `latest`. `dev-up` pins the
floating major `pi:1`, so a publish moves `:1` to the new digest.

Bump `version` in `devcontainer-feature.json` on every change: publishing an
already-published version is a no-op, so an un-bumped change never reaches consumers. CI
enforces this on merge requests. See [AGENTS.md](AGENTS.md#versioning).

> Stay on `1.x`. A `0.x` version would publish a floating `:0` tag, and under semver-0 a
> `0.1 → 0.2` bump is allowed to be breaking — so `:0` would move across breaking changes
> and the pin would be worthless.

Point `dev-up` at a different build with `DEV_PI_FEATURE=<registry>/<ns>/pi:<tag>`.

> **Auth note.** The project is `internal`, so pulling the feature needs credentials. The
> devcontainer CLI resolves them through the Docker config (`~/.docker/config.json`), while
> rootless podman writes `$XDG_RUNTIME_DIR/containers/auth.json`. If `dev-up` fails to pull
> the feature while `podman pull` works, that mismatch is why — point `REGISTRY_AUTH_FILE`
> at the Docker config, or log in with `podman login --authfile ~/.docker/config.json`.

## Verify without publishing

```sh
{ cat src/pi/install.sh; echo 'pi --version'; } \
  | podman run --rm -i --user root -e VERSION=0.84.2 -e _REMOTE_USER=root \
      debian:trixie-slim sh -s
```

## Options

| Option | Default | Notes |
|---|---|---|
| `version` | `latest` | npm version of `@earendil-works/pi-coding-agent`. `dev-up` pins this to the host's pi version, so the image hash changes exactly when you upgrade and never otherwise. |
| `nodeVersion` | `24.19.0` | Private Node runtime under `/opt/pi/node`, never on `PATH`. Must satisfy pi's `engines: node >=22.19.0`. |
| `ripgrepVersion` | `15.2.0` | ripgrep at `/usr/local/bin/rg`, deliberately **on** `PATH`. pi otherwise downloads it from GitHub at runtime. Statically linked musl build. |
| `fdVersion` | `10.4.2` | fd at `/usr/local/bin/fd`, same rationale as ripgrep. Statically linked musl build. |

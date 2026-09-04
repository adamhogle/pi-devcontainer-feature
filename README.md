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

## Subagent panes under herdr

pi's interactive-subagent extension renders each subagent in a multiplexer pane. With pi
inside the container and [herdr](https://herdr.dev) on the host, the container sees no
multiplexer and the extension silently degrades to headless: subagents still run and return
results, but no pane ever appears.

If `dev-up` finds herdr installed **and running** it bridges the two. Three bind mounts at
provisioning time -- herdr's API socket at `/opt/pi/herdr.sock`, the binary at
`/opt/pi/herdr` (statically linked, so the host copy runs on any base image) and
`share/herdr-shim` at `/usr/local/bin/herdr` -- plus the `HERDR_*` environment forwarded per
session by `dev-pi`. Subagents then split real panes in your herdr workspace, show up as
`pi` in the sidebar with live status, and close when done.

The shim exists because a subagent pane's shell is on the **host**, while pi composes its
launch command out of **container** paths. `herdr pane run` is rewritten to re-enter the
container with `podman exec`; everything else passes straight through to the real binary.

The bridge is opt-in on herdr being present: no herdr, or herdr not running, means no mounts
and headless as before. It never stops a container coming up. Note that forwarding the
socket gives the container full control of your herdr session -- fine for a personal machine,
worth knowing before it goes into a shared image.

## Install the host scripts

```sh
git clone https://github.com/adamhogle/pi-devcontainer-feature
cd pi-devcontainer-feature && ./install.sh
```

Symlinks `bin/dev-up`, `bin/dev-pi` and `bin/dev-down` into `~/.local/bin`. Because they are
symlinks, `git pull` is the release mechanism for the host side. Only `src/` is published to
the registry.

Usage:

```sh
dev-up                          # provision (anonymous pull; the package is public)
envchain sdc,gitlab DEV_PI_FORWARD=ANTHROPIC_API_KEY dev-pi
dev-down                        # remove the container
```

`DEV_PI_FORWARD` is now required: `dev-pi` no longer ships a built-in credential
allowlist. Set it in your shell profile to a comma-separated list of variable
*names* — never values. Running `dev-pi` with the variable unset prints the old
23-name list, ready for pasting, if you want it as a starting point;
`DEV_PI_FORWARD=""` forwards nothing on purpose. The provider keys
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`) are
noticed, not required: pi can authenticate with no env key at all — stored auth
or a provider configured in `models.json` rides the `~/.pi/agent` mount into
the container — so a missing or unforwarded provider key earns a warning, and
whatever pi needs, its own startup tells you. `envchain` is unchanged — it
puts the *values* in the host env, and `DEV_PI_FORWARD` filters them by name.

`dev-up` pulls without credentials. It honours a `GHCR_TOKEN` (with
`DEV_PI_REGISTRY_USER` set to your GitHub login) as an optional fallback if the
package ever goes private, if you are hitting ghcr rate limits, or if you pull
through a mirror. The `envchain` prefix on `dev-pi` is the example user's own
credential workflow for the day job, not something this feature requires — any
way of getting `SSH_AUTH_SOCK` and the forwarded env vars into the shell works.

## Publish

Published by GitHub Actions on merge to main, whenever a change touches `src/`.
The `publish` workflow runs `devcontainer features publish src` against
ghcr.io with `secrets.GITHUB_TOKEN` — the package lives in the same repository's
namespace, so no hand-minted credential is needed. `workflow_dispatch` gives the
operator a manual re-publish for the bootstrap run and for recovery.

That publishes `ghcr.io/adamhogle/pi-devcontainer-feature/pi`, tagged with the
exact version plus every enclosing prefix — `1.1.0`, `1.1`, `1` and `latest`.
`dev-up` pins the floating major `pi:1`, so a publish moves `:1` to the new digest.

Bump `version` in `devcontainer-feature.json` on every change under `src/`:
publishing an already-published version is a no-op, so an un-bumped change never
reaches consumers. CI enforces this on pull requests. See
[AGENTS.md](AGENTS.md#versioning).

> Stay on `1.x`. A `0.x` version would publish a floating `:0` tag, and under semver-0 a
> `0.1 → 0.2` bump is allowed to be breaking — so `:0` would move across breaking changes
> and the pin would be worthless.

Point `dev-up` at a different build with `DEV_PI_FEATURE=<registry>/<ns>/pi:<tag>`.

> **Registry note.** The package is public, so an anonymous pull needs no
> credential. If the package ever goes private, the devcontainer CLI resolves
> them through the Docker config (`~/.docker/config.json`), while rootless podman
> writes `$XDG_RUNTIME_DIR/containers/auth.json`. If `dev-up` fails to pull the
> feature while `podman pull` works, that mismatch is why — point
> `REGISTRY_AUTH_FILE` at the Docker config, or log in with
> `podman login --authfile ~/.docker/config.json`.

## Verify without publishing

CI runs `install.sh` on every pull request — the `smoke` job in
`.github/workflows/validate.yml` executes it in `debian:trixie-slim` and asserts
`pi --version`, `node` off `PATH`, and `rg`/`fd` present. The same check,
locally, via podman:

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

## License

GPL-3.0-only. See [LICENSE](LICENSE) for the full text.

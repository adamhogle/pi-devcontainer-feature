# AGENTS.md

## What this repo is

Everything needed to run pi *inside* a dev container instead of on the host:

* **`src/pi`** — a [dev container feature](https://containers.dev/implementors/features/) that
  installs pi into the image, published to `ghcr.io/adamhogle/pi-devcontainer-feature/pi`.
* **`bin/dev-up`, `bin/dev-pi`, `bin/dev-down`** — the host scripts that provision, attach to,
  and tear down the container.

It exists so that **nothing pi-related ever has to appear in a consumer repo's
`devcontainer.json`**. `dev-up` applies the feature at provisioning time via
`--additional-features`, pinned to the floating major tag `pi:1`, and owns every other
coupling to the host (the `~/.pi/agent` mount, the ssh-agent socket, the `pi.box.folder`
label). `dev-pi` then attaches with `podman exec`, injecting credentials per session.
Never suggest adding pi, this feature, or a `~/.pi` mount to a consumer project's config.

### The shared contract

The three components have **no runtime coupling** — they agree by convention on a handful of
strings, and nothing would notice at runtime if one drifted. `dev-pi` would simply stop
finding containers `dev-up` created, or verify a mount nobody makes.

| Shared | Written by | Read by |
| --- | --- | --- |
| `/opt/pi/agent` | feature `containerEnv`, `install.sh` | `dev-up` mount target, `dev-pi` verify |
| `/ssh-agent` | `dev-up` mount target | `dev-pi` sets `SSH_AUTH_SOCK` to it |
| `pi.box.folder=<root>` | `dev-up` `--id-label` | `dev-pi` container lookup, `dev-down` cleanup |
| `resolve_root()` | shared by all three | `dev-pi` and `dev-down` — must be **byte-identical** |

`scripts/check-contract.sh` enforces all of it in CI. Run it after touching any of them.

## Two release tracks

One repo, two independent things to ship. Do not conflate them:

| Track | Artefact | Released by |
| --- | --- | --- |
| `src/**` | OCI feature at `ghcr.io/adamhogle/pi-devcontainer-feature/pi` | CI, on merge to main |
| `bin/**` | Host scripts symlinked into `~/.local/bin` by `./install.sh` | `git pull` — the install is symlinks, so a pull *is* the release |

The `version-bump` and `publish` workflows are scoped by `paths: ['src/**']`. A change that
only touches `bin/` must **not** bump the feature version: it would republish a
byte-identical feature and move `:1` for nothing. Conversely, any change under `src/` must
bump it.

## Versioning

Two versions live in this repo. Do not confuse them:

| Version | Where | Meaning |
| --- | --- | --- |
| **Feature version** | `version` in `src/pi/devcontainer-feature.json` | The version *of this feature*. **This is the one you bump.** |
| pi version | `options.version` | Which pi npm release gets installed. `dev-up` overrides it per invocation, pinning it to the host's `pi --version`. Leave the default at `latest`; do **not** bump it to chase pi releases. |

### Bump the feature version on every change that reaches main

Consumers pin `pi:1`, a floating major tag. `devcontainer features publish` skips a version
that is already published, so **a change merged without a version bump is silently never
published** — `:1` keeps resolving to the old digest and no consumer sees the change.

Pick the increment by what it does to a consumer pinned to `:1`:

| Increment | When |
| --- | --- |
| **patch** (`1.0.0` → `1.0.1`) | `install.sh` fix with no change to the feature's contract |
| **minor** (`1.0.0` → `1.1.0`) | New option, new behaviour, backwards compatible |
| **major** (`1.0.0` → `2.0.0`) | Anything that breaks a `:1` consumer: renaming or removing an option, moving `/opt/pi/node`, `/opt/pi/agent` or `/usr/local/bin/pi`, putting node on `PATH`, changing `containerEnv` |

Never go back to `0.x`. Publishing `0.y.z` produces a floating `:0` tag, and under semver-0
a `0.1 → 0.2` bump is allowed to be breaking — the pin would move across breaking changes
and be worthless.

A **major** bump also moves the published major tag to `:2`, which `dev-up` does not track.
Coordinate the change to `PI_FEATURE` in `~/.local/bin/dev-up` in the same session, and say
so explicitly in the pull request description.

CI enforces the bump on every pull request (`version-bump` workflow), comparing against the
base branch. It cannot enforce that you picked the *right* increment — that is your job.

## Merging

* **Squash every pull request into a single commit.** One PR = one commit on main.
  Enable *Squash commits* on the PR and keep the squash commit message meaningful — it is
  the only thing that survives.
* **Never push directly to main.** Work on a branch, open a PR, let CI run. The
  `version-bump` workflow is path-scoped to `src/**` and only runs on pull request events,
  so a direct push bypasses it.
* Commit messages follow [Conventional Commits](https://www.conventionalcommits.org),
  `type(scope): short imperative summary`. Useful scopes here: `feature`, `ci`, `docs`.

## Verify install.sh

GitHub-hosted runners have Docker, so CI executes `install.sh` on every pull request: the
`smoke` job in `.github/workflows/validate.yml` pipes it into `debian:trixie-slim`, where it
installs pi and asserts `pi --version`, `node` off `PATH`, and `rg`/`fd` on `PATH`.

The same smoke test, locally, via podman:

```sh
{ cat src/pi/install.sh; echo 'command -v node || echo "node off PATH: correct"'; echo 'pi --version'; } \
  | podman run --rm -i --user root --network=pasta:--ipv4-only \
      -e VERSION=0.84.2 -e _REMOTE_USER=root \
      debian:trixie-slim sh -s
```

It passes when pi prints a version **and** `node` is absent from `PATH`. Use a base image
without node (`debian:trixie-slim`) — that is the case the private-runtime design exists for.

Run the checks CI runs (the `shellcheck` job installs shellcheck on `debian:trixie-slim`;
locally, use the same recipe or `sudo apt-get install -y shellcheck`):

```sh
node scripts/check-feature-metadata.mjs
bash scripts/check-contract.sh
podman run --rm -v "$PWD:/w:ro,Z" -w /w docker.io/library/debian:trixie-slim sh -c \
  'apt-get update -qq && apt-get install -y -qq --no-install-recommends shellcheck \
    && shellcheck --shell=sh src/pi/install.sh \
    && shellcheck --shell=bash bin/dev-up bin/dev-pi bin/dev-down install.sh scripts/*.sh'
```

Changes to `bin/` take effect immediately — `install.sh` creates symlinks, so the checkout is
what runs. Test a script change by using it: `dev-up` in a scratch workspace, then `dev-pi`.

## Host script invariants

* **`dev-pi` never falls back to the host.** No container, wrong container, missing pi or a
  version mismatch must all be hard failures naming the fix. A silent host fallback would
  leave the user believing they are sandboxed when they are not.
* **Credentials never reach argv.** `podman exec -e NAME` (no `=`) passes the value through
  from the environment; `NAME=value` would expose it in `ps aux`. This is also why `dev-pi`
  uses `podman exec` rather than `devcontainer exec`, whose `--remote-env` takes `name=value`.
* **The allowlist lives in `bin/dev-pi`.** It is a list of variable *names*, never values, and
  it must stay in a host file the container cannot write to.
* **`dev-up` owns creation-time state.** Bind mounts cannot be added to a running container,
  so anything requiring a mount belongs in `dev-up`, never `dev-pi`.

## Invariants

Do not break these without a **major** bump:

* **Node stays off `PATH`.** It lives at `/opt/pi/node` and is reached only by absolute path
  from the `/usr/local/bin/pi` wrapper. This is what lets the feature work on any glibc image
  and stops it shadowing the workspace toolchain — the agent's own shell commands must keep
  resolving the *project's* node.
* **ripgrep and fd, by contrast, go *on* `PATH`** at `/usr/local/bin/{rg,fd}`, and that asymmetry is
  deliberate. pi resolves each by checking its tools dir, then `PATH`, and otherwise
  **downloads it from GitHub at runtime** — slow or impossible behind a proxy. Nothing pins a
  project to a specific ripgrep or fd the way it pins a node version, so there is no shadowing risk
  to weigh against it. Use the statically linked musl build so it works on any base image.

### Known limitation: host binaries shadow the baked-in ones

`$PI_CODING_AGENT_DIR/bin` is the bind-mounted host `~/.pi/agent/bin`, and **pi prepends it to
`PATH` for every command it spawns**. Any tool the host downloaded there therefore wins over
the copy baked into the image — for the agent's shell commands, not just pi's internal tool
lookup. Measured in a `javascript-node` container:

```text
pi's own shell commands   fd -> /opt/pi/agent/bin/fd    (host binary, via the mount)
plain podman exec         fd -> /usr/local/bin/fd       (baked in; the container's own PATH
                                                         does not contain the tools dir)
```

This is **accepted, not a bug to fix**. It is benign while the host and the container are the
same platform — linux/x86-64 glibc on both sides, usually the identical release, since the
feature pins the same versions pi would fetch.

It breaks when they diverge: on a musl base image (Alpine) or a differing architecture, a host
glibc binary lands on `PATH` inside the container and fails to execute. The symptom is a tool
erroring only inside pi while `podman exec` runs it fine. If that happens, mask the directory
with a container-local volume in `dev-up` so pi's tools dir starts empty and resolution falls
through to the image:

```sh
--mount type=volume,target=/opt/pi/agent/bin
```

That is deliberately *not* done by default: it would stop the host and container sharing
downloaded tools, which costs a re-download per volume for no benefit on a matched platform.

A corollary: baking `rg` and `fd` into the image still matters even though the host copies
usually win. They are the correct-arch fallback, they cover machines whose
`~/.pi/agent/bin` is empty, and they are what non-pi shells in the container resolve.
* **No credentials, ever.** The feature handles none. `dev-pi` injects them per session with
  `podman exec -e`. `check-feature-metadata.mjs` rejects credential-shaped `containerEnv` keys.
* **`PI_CODING_AGENT_DIR` is `/opt/pi/agent`**, a fixed user-independent path. `dev-up`
  bind-mounts the host's `~/.pi/agent` there. A fixed target is what removes the need to
  resolve `remoteUser` before the container exists.
* **`install.sh` is POSIX `sh`** and shellcheck-clean under `--shell=sh`. It runs during the
  feature install step, where bash is not guaranteed.
* **`nodeVersion` is pinned exactly**, never floating. A moving runtime would change the built
  image without changing the feature version.

## Layout

```text
src/pi/devcontainer-feature.json   feature metadata, options, containerEnv
src/pi/install.sh                  install step (POSIX sh, runs as root at build time)
bin/dev-up                         provision: feature + mounts + identity label
bin/dev-pi                         strict attach: verify, then podman exec pi
bin/dev-down                       remove containers for a workspace folder
install.sh                         symlink bin/* into ~/.local/bin
scripts/check-feature-metadata.mjs metadata gate
scripts/check-version-bump.sh      version gate (pull requests, src/ only)
scripts/check-contract.sh          cross-component contract gate
.github/workflows/                 CI: validate, version-bump, publish to ghcr.io
```

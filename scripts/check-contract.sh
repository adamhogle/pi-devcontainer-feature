#!/usr/bin/env bash
# Assert that the components agree on the contract they share.
#
# The feature, dev-up, dev-pi and dev-down are separate artefacts with no runtime
# coupling: dev-up writes a label and mounts paths, dev-pi looks them up, dev-down
# reads the label to find what to remove, the feature bakes the same paths into
# the image. Nothing at runtime would notice if one of them drifted -- dev-pi
# would simply stop finding containers dev-up created, dev-down would remove
# containers under the wrong identity, or dev-pi would verify a mount nobody
# makes. This is the check that catches that.
set -euo pipefail

fail=0
err() {
  printf 'contract: %s\n' "$1" >&2
  fail=1
}

# --- resolve_root() must be identical -------------------------------------
# All three scripts must agree on what "the workspace root" means, or dev-pi
# looks up a pi.box.folder value dev-up never wrote, and dev-down tears down
# containers under an identity neither of them wrote.
extract_fn() { awk '/^resolve_root\(\) \{/,/^\}/' "$1"; }

up_fn=$(extract_fn bin/dev-up)
pi_fn=$(extract_fn bin/dev-pi)
down_fn=$(extract_fn bin/dev-down)

[ -n "$up_fn" ] || err "resolve_root() not found in bin/dev-up"
[ -n "$pi_fn" ] || err "resolve_root() not found in bin/dev-pi"
[ -n "$down_fn" ] || err "resolve_root() not found in bin/dev-down"
if [ -n "$up_fn" ] && [ -n "$pi_fn" ] && [ -n "$down_fn" ] \
   && { [ "$up_fn" != "$pi_fn" ] || [ "$up_fn" != "$down_fn" ]; }; then
  err "resolve_root() differs between bin/dev-up, bin/dev-pi and bin/dev-down; folder identity would drift"
  diff <(printf '%s\n' "$up_fn") <(printf '%s\n' "$pi_fn") >&2 || true
  diff <(printf '%s\n' "$up_fn") <(printf '%s\n' "$down_fn") >&2 || true
fi

# --- shared literals must appear everywhere they are relied on ------------
expect_in() {
  value=$1
  shift
  for file in "$@"; do
    grep -qF -- "$value" "$file" || err "$file does not mention '$value'"
  done
}

expect_in /ssh-agent bin/dev-up bin/dev-pi
expect_in pi.box.folder bin/dev-up bin/dev-pi bin/dev-down

# --- herdr bridge: the three sides must name the same paths -----------------
# dev-up mounts the binary and socket; dev-pi verifies both and points
# HERDR_SOCKET_PATH at the socket; the shim defaults PI_HERDR_REAL to the binary.
# The shim's mount target must be a `herdr` on PATH, or pi's hasCommand("herdr")
# fails and the bridge is silently headless despite every mount being present.
expect_in /opt/pi/herdr.sock bin/dev-up bin/dev-pi
expect_in /opt/pi/herdr bin/dev-up bin/dev-pi share/herdr-shim
expect_in /usr/local/bin/herdr bin/dev-up
[ -x share/herdr-shim ] || err "share/herdr-shim is not executable; the mount would be a herdr that cannot run"

# Every PI_BOX_* / PI_HERDR_* variable the shim reads must be one dev-pi sets.
# A rename on one side would leave the shim reading an empty value and, for
# PI_BOX_CONTAINER_ID, degrading to a pass-through that fails visibly on the host.
# shellcheck disable=SC2016  # matching the literal ${VAR text in the shim, not expanding it
shim_vars=$(grep -oE '\$\{(PI_BOX_[A-Z_]+|PI_HERDR_[A-Z_]+)' share/herdr-shim | tr -d '${' | sort -u)
for var in $shim_vars; do
  grep -qE -- "-e \"?$var=" bin/dev-pi || err "share/herdr-shim reads $var but bin/dev-pi never forwards it"
done

# --- the agent dir must resolve to the same path everywhere -----------------
# Compare resolved values, not literals: install.sh composes its paths from
# $PREFIX, so grepping for /opt/pi/agent there would fail on a correct file.
feature_agent_dir=$(node -pe '
  JSON.parse(require("fs").readFileSync("src/pi/devcontainer-feature.json", "utf8"))
    .containerEnv.PI_CODING_AGENT_DIR
')

for script in bin/dev-up bin/dev-pi; do
  script_target=$(sed -n 's/^PI_AGENT_TARGET=//p' "$script")
  [ -n "$script_target" ] || { err "$script does not define PI_AGENT_TARGET"; continue; }
  [ "$script_target" = "$feature_agent_dir" ] || err \
    "$script PI_AGENT_TARGET=$script_target but feature containerEnv.PI_CODING_AGENT_DIR=$feature_agent_dir"
done

# install.sh builds /opt/pi/{agent,node} out of $PREFIX; resolve it and compare.
install_prefix=$(sed -n 's/^PREFIX=//p' src/pi/install.sh)
if [ -z "$install_prefix" ]; then
  err "src/pi/install.sh does not define PREFIX"
else
  [ "$install_prefix/agent" = "$feature_agent_dir" ] || err \
    "install.sh creates $install_prefix/agent but the feature declares $feature_agent_dir"
  # shellcheck disable=SC2016  # matching the literal ${PREFIX}, not expanding it
  grep -q '\${PREFIX}/agent' src/pi/install.sh || err \
    "install.sh never creates \${PREFIX}/agent, so the bind mount has no target"
  # shellcheck disable=SC2016
  grep -q '\${PREFIX}/node/bin/node' src/pi/install.sh || err \
    "install.sh must invoke node by absolute path under \${PREFIX}/node (never via PATH)"
fi

# --- the private node must stay off PATH ------------------------------------
# The whole reason the feature works on any image is that /usr/local/bin/pi is a
# wrapper. If install.sh ever exported PREFIX/node/bin onto PATH it would shadow
# the workspace toolchain.
# A command-scoped `PATH=... cmd` prefix is fine (it dies with the command); an
# `export` would persist into the image and shadow the workspace toolchain.
if grep -qE '^[[:space:]]*export[[:space:]]+PATH=' src/pi/install.sh; then
  err "install.sh exports PATH; the private node must never be on PATH in the image"
fi

# --- dev-up must point at the feature this repo publishes ------------------
# shellcheck disable=SC2016  # sed script matches the literal ${DEV_PI_FEATURE:-...}
feature_ref=$(sed -n 's/^PI_FEATURE=\${DEV_PI_FEATURE:-\(.*\)}$/\1/p' bin/dev-up)
feature_id=$(node -pe '
  JSON.parse(require("fs").readFileSync("src/pi/devcontainer-feature.json", "utf8")).id
')
[ -n "$feature_ref" ] || err "could not read the PI_FEATURE default from bin/dev-up"
case "$feature_ref" in
  */"$feature_id":*) ;;
  *) err "bin/dev-up points at '$feature_ref', which does not name the feature id '$feature_id'" ;;
esac

if [ "$fail" -eq 0 ]; then
  echo "contract ok: resolve_root identical, shared paths agree, dev-up -> $feature_ref"
fi
exit "$fail"

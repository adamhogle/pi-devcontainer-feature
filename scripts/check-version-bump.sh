#!/usr/bin/env bash
# Fail unless the feature version is greater than the one on the target branch.
#
# Consumers pin the floating major tag (pi:1). Publishing an already-published
# version is a no-op, so an un-bumped change would never reach anyone.
set -euo pipefail

FEATURE_JSON=${FEATURE_JSON:-src/pi/devcontainer-feature.json}
target=${GITHUB_BASE_REF:-main}

read_version() {
  node -e '
    const fs = require("fs");
    try {
      process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version));
    } catch {
      process.stdout.write("0.0.0");
    }
  ' "$1"
}

old_file=$(mktemp)
trap 'rm -f "$old_file"' EXIT

git fetch --quiet --depth=1 origin "$target"
if ! git show "FETCH_HEAD:$FEATURE_JSON" >"$old_file" 2>/dev/null; then
  # Feature does not exist on the target branch yet: any version is a bump.
  printf '%s\n' '{"version":"0.0.0"}' >"$old_file"
fi

old=$(read_version "$old_file")
new=$(read_version "$FEATURE_JSON")

if node -e '
  const parse = (v) => v.split(".").map((n) => parseInt(n, 10) || 0);
  const [next, prev] = [parse(process.argv[1]), parse(process.argv[2])];
  for (let i = 0; i < 3; i++) {
    if (next[i] !== prev[i]) process.exit(next[i] > prev[i] ? 0 : 1);
  }
  process.exit(1);
' "$new" "$old"; then
  echo "version bump ok: $old -> $new"
else
  cat >&2 <<EOF
version not bumped: $target has $old, this branch has $new.

Bump "version" in $FEATURE_JSON. That field is the version OF THE FEATURE, not the
version of pi it installs (that is options.version, which dev-up overrides per run).

  patch  install.sh fix, no change to the feature's contract
  minor  new option or new behaviour, backwards compatible
  major  breaks a consumer pinned to :1 -- renamed/removed option, moved
         /opt/pi/{node,agent} or /usr/local/bin/pi, node put on PATH, changed containerEnv
EOF
  exit 1
fi

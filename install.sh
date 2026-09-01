#!/usr/bin/env bash
# Symlink the host scripts into a bin directory on PATH (default ~/.local/bin).
#
# Symlinks, not copies: `git pull` then updates the installed scripts, and there is
# no second copy to drift from the one the contract check validates.
#
# Usage: ./install.sh [target-dir]
set -euo pipefail

target=${1:-$HOME/.local/bin}
repo=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$target"

for source in "$repo"/bin/*; do
  name=$(basename "$source")
  ln -sfn "$source" "$target/$name"
  printf '%s -> %s\n' "$target/$name" "$source"
done

case ":$PATH:" in
  *":$target:"*) ;;
  *) printf '\nwarning: %s is not on PATH\n' "$target" >&2 ;;
esac

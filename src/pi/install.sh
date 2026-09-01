#!/bin/sh
# Install pi with its own private Node runtime.
#
# Node goes to /opt/pi/node and is deliberately NOT added to PATH: the only
# thing on PATH is a wrapper that invokes it by absolute path. That means this
# feature works on any glibc image regardless of whether Node is present, and
# can never shadow the workspace's own toolchain. Commands the agent runs still
# see the project's node, not this one.
set -eu

PI_VERSION="${VERSION:-latest}"
NODE_VERSION="${NODEVERSION:-24.19.0}"
RIPGREP_VERSION="${RIPGREPVERSION:-15.2.0}"
FD_VERSION="${FDVERSION:-10.4.2}"
PREFIX=/opt/pi

case "$(uname -m)" in
  x86_64|amd64) NODE_ARCH=x64; TOOL_ARCH=x86_64 ;;
  aarch64|arm64) NODE_ARCH=arm64; TOOL_ARCH=aarch64 ;;
  *) echo "pi-feature: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

if command -v apt-get >/dev/null 2>&1; then
  if ! command -v curl >/dev/null 2>&1 || ! command -v xz >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates curl xz-utils
    rm -rf /var/lib/apt/lists/*
  fi
fi

echo "pi-feature: installing private node ${NODE_VERSION} (${NODE_ARCH})"
mkdir -p "${PREFIX}/node"
curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
  | tar -xJ -C "${PREFIX}/node" --strip-components=1

echo "pi-feature: installing pi ${PI_VERSION}"
# --ignore-scripts matches pi's own containerization guidance; the package ships
# prebuilt native binaries and needs no postinstall step.
PATH="${PREFIX}/node/bin:${PATH}" \
  "${PREFIX}/node/bin/npm" install -g \
    --prefix "${PREFIX}" \
    --ignore-scripts \
    --no-fund --no-audit \
    "@earendil-works/pi-coding-agent@${PI_VERSION}"

CLI="${PREFIX}/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
[ -f "${CLI}" ] || { echo "pi-feature: expected CLI not found at ${CLI}" >&2; exit 1; }

cat > /usr/local/bin/pi <<EOF
#!/bin/sh
exec ${PREFIX}/node/bin/node ${CLI} "\$@"
EOF
chmod 0755 /usr/local/bin/pi

# ripgrep and fd, on PATH. Unlike node these are deliberately normal system tools:
#
#   * pi's tool manager resolves each by looking in its tools dir, then PATH, and
#     otherwise downloads it from GitHub at runtime -- which is slow or fails
#     outright behind a proxy. Baking them in makes that never happen.
#   * there is no shadowing risk to weigh against it. Nothing pins a project to a
#     particular ripgrep or fd the way it pins a node version, and pi's own
#     containerization guide installs ripgrep into the image the same way.
#
# The musl builds are statically linked, so they work on any base image.
install_release_binary() {
  binary_name=$1
  archive_url=$2
  tool_tmp=$(mktemp -d)
  curl -fsSL "${archive_url}" | tar -xz -C "${tool_tmp}" --strip-components=1
  cp "${tool_tmp}/${binary_name}" "/usr/local/bin/${binary_name}"
  chmod 0755 "/usr/local/bin/${binary_name}"
  rm -rf "${tool_tmp}"
}

# Note the differing tag conventions: ripgrep tags are bare, fd tags are v-prefixed.
echo "pi-feature: installing ripgrep ${RIPGREP_VERSION} (${TOOL_ARCH})"
install_release_binary rg \
  "https://github.com/BurntSushi/ripgrep/releases/download/${RIPGREP_VERSION}/ripgrep-${RIPGREP_VERSION}-${TOOL_ARCH}-unknown-linux-musl.tar.gz"

echo "pi-feature: installing fd ${FD_VERSION} (${TOOL_ARCH})"
install_release_binary fd \
  "https://github.com/sharkdp/fd/releases/download/v${FD_VERSION}/fd-v${FD_VERSION}-${TOOL_ARCH}-unknown-linux-musl.tar.gz"

# Mount point for the host's ~/.pi/agent, bound in by dev-up. Created here so
# the target exists and is owned sanely even before anything is mounted onto it.
mkdir -p "${PREFIX}/agent"
if [ -n "${_REMOTE_USER:-}" ] && [ "${_REMOTE_USER}" != "root" ]; then
  chown "${_REMOTE_USER}" "${PREFIX}/agent" || true
fi

echo "pi-feature: installed pi $(/usr/local/bin/pi --version)," \
  "$(/usr/local/bin/rg --version | head -1), $(/usr/local/bin/fd --version)"

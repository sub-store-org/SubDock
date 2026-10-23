#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_root/tool/versions.sh"
target=${1:?usage: tool/prepare_runtime.sh <linux-x64|windows-x64|darwin-arm64|darwin-x64>}
output_dir="$repo_root/.subdock/runtime/$target"
work_dir=$(mktemp -d)
manifest="$repo_root/.subdock/backend/runtime-manifest.json"

if test -z "$SUBDOCK_NODE_VERSION"; then
  test -f "$manifest"
  SUBDOCK_NODE_VERSION=$(sed -n \
    's/.*"testedNode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest")
fi
node_version=${SUBDOCK_NODE_VERSION#v}
test -n "$node_version"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup 0 HUP INT TERM

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

download_verified() {
  file="$work_dir/$1"
  curl --fail --location --retry 3 --retry-all-errors --output "$file" "$2"
  test "$(sha256 "$file")" = "$3"
}

case "$target" in
  linux-x64)
    node_archive="node-v$node_version-linux-x64.tar.xz"
    node_path="node-v$node_version-linux-x64/bin/node"
    ;;
  windows-x64)
    node_archive="node-v$node_version-win-x64.zip"
    node_path="node-v$node_version-win-x64/node.exe"
    ;;
  darwin-arm64)
    node_archive="node-v$node_version-darwin-arm64.tar.xz"
    node_path="node-v$node_version-darwin-arm64/bin/node"
    ;;
  darwin-x64)
    node_archive="node-v$node_version-darwin-x64.tar.xz"
    node_path="node-v$node_version-darwin-x64/bin/node"
    ;;
  *)
    printf 'Unsupported runtime target: %s\n' "$target" >&2
    exit 64
    ;;
esac

node_checksums="$work_dir/SHASUMS256.txt"
curl --fail --location --retry 3 --retry-all-errors --output "$node_checksums" \
  "https://nodejs.org/dist/v$node_version/SHASUMS256.txt"
node_sha=$(awk -v asset="$node_archive" '$2 == asset { print $1 }' "$node_checksums")
test -n "$node_sha"
download_verified "$node_archive" \
  "https://nodejs.org/dist/v$node_version/$node_archive" "$node_sha"
case "$node_archive" in
  *.zip) unzip -q "$work_dir/$node_archive" -d "$work_dir" ;;
  *) tar -xJf "$work_dir/$node_archive" -C "$work_dir" ;;
esac

staging_dir="$work_dir/runtime"
mkdir -p "$staging_dir"
node_suffix=
if test "$target" = windows-x64; then
  node_suffix=.exe
fi
install -m 0755 "$work_dir/$node_path" "$staging_dir/node$node_suffix"

rm -rf "$output_dir"
mkdir -p "$(dirname -- "$output_dir")"
mv "$staging_dir" "$output_dir"
printf 'Prepared %s runtime (Node %s) at %s\n' \
  "$target" "$node_version" "$output_dir"

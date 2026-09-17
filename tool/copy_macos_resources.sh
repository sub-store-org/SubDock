#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
resources_dir="$project_dir/.subdock"
case "${SUBDOCK_MACOS_RUNTIME_TARGET:?missing SUBDOCK_MACOS_RUNTIME_TARGET}" in
  arm64) runtime_target=darwin-arm64 ;;
  x86_64) runtime_target=darwin-x64 ;;
  *)
    printf 'Unsupported macOS runtime architecture: %s\n' \
      "$SUBDOCK_MACOS_RUNTIME_TARGET" >&2
    exit 64
    ;;
esac
runtime_dir="$resources_dir/runtime/$runtime_target"
http_meta_dir="$resources_dir/http-meta/$runtime_target"
destination="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}/Contents/MacOS/data"

for file in \
  "$runtime_dir/node" \
  "$runtime_dir/bin/shoutrrr" \
  "$resources_dir/backend/sub-store.bundle.js" \
  "$resources_dir/backend/runtime-manifest.json" \
  "$resources_dir/backend/version" \
  "$resources_dir/frontend/index.html" \
  "$resources_dir/frontend/version" \
  "$http_meta_dir/http-meta.bundle.js" \
  "$http_meta_dir/version" \
  "$http_meta_dir/meta/tpl.yaml" \
  "$http_meta_dir/meta/mihomo" \
  "$http_meta_dir/meta/mihomo-version"; do
  test -f "$file"
done

rm -rf "$destination"
mkdir -p "$destination"
cp -R "$runtime_dir" "$destination/runtime"
cp -R "$resources_dir/backend" "$destination/backend"
cp -R "$resources_dir/frontend" "$destination/frontend"
cp -R "$http_meta_dir" "$destination/http-meta"
mkdir -p "$destination/licenses"
cp "$project_dir/LICENSE" "$destination/licenses/GPL-3.0-only.txt"
mkdir -p "$destination/icon"
cp "$project_dir/assets/icon/app_icon.png" "$destination/icon/app_icon.png"

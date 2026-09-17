#!/bin/sh
set -eu

bundle_dir=${1:?usage: tool/verify_bundle.sh <bundle-dir> [windows]}
platform=${2:-unix}
suffix=
if test "$platform" = windows; then
  suffix=.exe
  # Windows loads the tray icon directly from the packaged .ico.
  tray_icon="$bundle_dir/data/tray_icon.ico"
elif test "$platform" = macos; then
  tray_icon="$bundle_dir/../Frameworks/App.framework/Resources/flutter_assets/assets/icon/app_icon_32.png"
else
  # Linux serves the tray icon from Flutter assets.
  tray_icon="$bundle_dir/data/flutter_assets/assets/icon/app_icon_32.png"
fi

for file in \
  "$bundle_dir/data/runtime/node$suffix" \
  "$bundle_dir/data/runtime/bin/shoutrrr$suffix" \
  "$bundle_dir/data/backend/sub-store.bundle.js" \
  "$bundle_dir/data/backend/runtime-manifest.json" \
  "$bundle_dir/data/backend/version" \
  "$bundle_dir/data/frontend/index.html" \
  "$bundle_dir/data/frontend/version" \
  "$bundle_dir/data/http-meta/http-meta.bundle.js" \
  "$bundle_dir/data/http-meta/version" \
  "$bundle_dir/data/http-meta/meta/tpl.yaml" \
  "$bundle_dir/data/http-meta/meta/mihomo-version" \
  "$bundle_dir/data/licenses/GPL-3.0-only.txt" \
  "$bundle_dir/data/icon/app_icon.png" \
  "$tray_icon"; do
  test -f "$file"
done

if test "$platform" != windows; then
  test -x "$bundle_dir/data/runtime/node"
  test -x "$bundle_dir/data/runtime/bin/shoutrrr"
  test -x "$bundle_dir/data/http-meta/meta/mihomo"
else
  test -f "$bundle_dir/data/http-meta/meta/mihomo.exe"
fi

for version in \
  "$bundle_dir/data/backend/version" \
  "$bundle_dir/data/frontend/version" \
  "$bundle_dir/data/http-meta/version" \
  "$bundle_dir/data/http-meta/meta/mihomo-version"; do
  test "$(wc -l < "$version" | tr -d ' ')" = 1
  test -n "$(tr -d '\r\n' < "$version")"
done

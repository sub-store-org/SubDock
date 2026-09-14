#!/usr/bin/env bash
set -euo pipefail

APP="$1"
TARGET_ARCH="$2"

echo "Thinning macOS bundle to $TARGET_ARCH"
echo "App: $APP"

while IFS= read -r -d '' binary; do
  if ! file "$binary" | grep -q 'Mach-O'; then
    continue
  fi

  archs="$(lipo -archs "$binary" 2>/dev/null || true)"

  case " $archs " in
    *" $TARGET_ARCH "*)
      ;;
    *)
      echo "::error file=$binary::Missing required architecture $TARGET_ARCH (has: $archs)"
      exit 1
      ;;
  esac

  if [ "$archs" != "$TARGET_ARCH" ]; then
    echo "Thinning: $binary"
    echo "  $archs -> $TARGET_ARCH"

    lipo "$binary" \
      -thin "$TARGET_ARCH" \
      -output "$binary.thin"

    mv "$binary.thin" "$binary"
  fi
done < <(find "$APP" -type f -print0)

echo
echo "Final main executable:"
file "$APP/Contents/MacOS/SubDock"
lipo -archs "$APP/Contents/MacOS/SubDock"
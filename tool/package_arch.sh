#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bundle_dir="$repo_root/build/linux/x64/release/bundle"
pkgbuild="$repo_root/linux/packaging/arch/PKGBUILD"

test -x "$bundle_dir/SubDock"
test -f "$pkgbuild"
command -v makepkg >/dev/null 2>&1

version=$(sed -n 's/^version: \([0-9][0-9.]*\).*/\1/p' "$repo_root/pubspec.yaml")
test -n "$version"
work_dir=$(mktemp -d)
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT HUP INT TERM

# 从 deb make_config.yaml 派生 Arch 的 .desktop（单一真源）。
"$repo_root/tool/derive_arch_desktop.sh" >/dev/null

cp "$pkgbuild" "$work_dir/PKGBUILD"
sed -i "s/^pkgver=.*/pkgver=$version/" "$work_dir/PKGBUILD"
cp "$repo_root/linux/packaging/arch/subdock.desktop" "$work_dir/subdock.desktop"
cp -R "$bundle_dir" "$work_dir/bundle"
(cd "$work_dir" && makepkg --cleanbuild --noconfirm)
mkdir -p "$repo_root/dist"
find "$work_dir" -maxdepth 1 -type f -name '*.pkg.tar.zst' -exec cp {} "$repo_root/dist/" \;

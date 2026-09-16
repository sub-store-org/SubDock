#!/bin/sh
# Derive the Arch package's .desktop entry from the shared deb make_config.yaml.
#
# Single source of truth: linux/packaging/deb/make_config.yaml already carries
# display_name / generic_name / categories for the fastforge-produced .desktop
# (deb/rpm). Arch keeps its own PKGBUILD but must not hand-write a second set
# of desktop metadata, so this script reads that YAML and fills in the
# Arch-specific fields (Exec, Icon, StartupWMClass).
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
config="$repo_root/linux/packaging/deb/make_config.yaml"
out="$repo_root/linux/packaging/arch/subdock.desktop"
app_id="org.substore.subdock"

test -f "$config"

yaml_value() {
  sed -n "s/^$1: *\\(.*\\)\$/\\1/p" "$config" | head -n 1
}

display_name=$(yaml_value display_name)
test -n "$display_name"
generic_name=$(yaml_value generic_name)
comment=$(yaml_value comment)
categories=$(sed -n '/^categories:/,/^[a-z]/p' "$config" | sed -n 's/^  - *//p' | tr '\n' ';')

if [ -z "$categories" ]; then
  # make_config.yaml 里 categories 是列表；解析失败时退化为常见值。
  categories="Network;Utility;"
fi

startup_notify=$(yaml_value startup_notify)
if [ -z "$startup_notify" ]; then startup_notify="true"; fi

{
  printf '[Desktop Entry]\n'
  printf 'Type=Application\n'
  printf 'Name=%s\n' "$display_name"
  if [ -n "$generic_name" ]; then printf 'GenericName=%s\n' "$generic_name"; fi
  if [ -n "$comment" ]; then printf 'Comment=%s\n' "$comment"; fi
  printf 'Exec=/opt/subdock/SubDock\n'
  # Icon 复用 Sub-Store 前端图标（打包内 data/frontend）。
  printf 'Icon=/opt/subdock/SubDock/data/frontend/512x512.png\n'
  printf 'Terminal=false\n'
  printf 'Categories=%s\n' "$categories"
  printf 'StartupWMClass=%s\n' "$app_id"
  printf 'StartupNotify=%s\n' "$startup_notify"
} > "$out"

printf 'Wrote %s\n' "$out"

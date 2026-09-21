# SubDock

SubDock is a native desktop application for running a packaged
[Sub-Store](https://github.com/sub-store-org/Sub-Store) backend and opening its
local management UI. It supports Linux, Windows, and macOS packaging.

## What it provides

- A local Backend runtime with packaged Node.js, frontend, and HTTP-META resources.
- A desktop dashboard for runtime status, management, logs, component updates,
  and settings.
- Tray controls, launch-at-login, and an optional start-hidden-to-tray preference.
- Per-user configuration, logs, backups, component state, and staging data.

## Run from source

This project uses FVM. Prepare the packaged resources for the target platform
before running the desktop app.

### Linux

```sh
tool/prepare_backend.sh
tool/prepare_frontend.sh
tool/prepare_runtime.sh linux-x64
tool/prepare_http_meta.sh linux-x64

fvm flutter run -d linux
```

### Other desktop targets

Use the matching runtime target when preparing resources:

```sh
tool/prepare_runtime.sh windows-x64
tool/prepare_runtime.sh darwin-arm64
# or
tool/prepare_runtime.sh darwin-x64
```

Also prepare the backend, frontend, and HTTP-META resources for that target
before building or running it.

## Validate changes

```sh
fvm flutter analyze
fvm flutter test
```

## Packaging

The preparation scripts download the published Backend, Frontend, Node.js, and
available Shoutrrr resources into `.subdock/`. Those resources are then copied
into the platform bundle during packaging. The preparation scripts accept
`SUBDOCK_*_VERSION` environment variables to pin release inputs.

CI builds Linux DEB/RPM/AppImage and Arch packages, Windows EXE packages, and
macOS DMG packages. Bundle verification is part of each packaging workflow.

For contribution-specific architecture, safety invariants, and code-editing
rules, see [AGENTS.md](AGENTS.md).

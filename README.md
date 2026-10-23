# SubDock

SubDock is a desktop application for running a packaged
[Sub-Store](https://github.com/sub-store-org/Sub-Store) Backend and opening its
local management UI. The repository contains desktop packaging configuration
for Linux, Windows, and macOS.

## Desktop workspace

The desktop workspace has five main pages. About SubDock is a subpage within
Settings.

- **Overview** shows Backend and HTTP-META status, component versions, runtime
  details, recent activity, and service controls.
- **Manage** opens the local Sub-Store UI while the Backend is available. You
  can use the system browser if embedded browsing is unavailable.
- **Logs** shows current output and saved run history.
- **Updates** checks the Sub-Store Backend and Frontend and manages their
  updates and rollbacks.
- **Settings** contains desktop preferences, Backend Configuration, Advanced
  ENV, and the HTTP-META preference. Its **About SubDock** subpage shows the
  SubDock version and platform details, copies runtime and component diagnostics,
  and opens the application and bundled font licenses.

The pages share the current service and component state. SubDock keeps
preferences, configuration, log history, component state, and backups in
per-user runtime directories. Switching pages or hiding the window keeps the
desktop session open. Unsaved Settings changes prompt to save, discard, or stay
in Settings before leaving.

## Startup and settings

On desktop, SubDock checks for interrupted component operations and recovers
log history before starting the Backend. It skips automatic Backend startup
when configuration, component, or log recovery needs attention. The Overview
page provides the start action after the issue is resolved.

The **Settings** page separates desktop preferences from Backend runtime
configuration. General preferences such as theme, language, and window behavior
save automatically by default. Turn off automatic saving to save those
preferences manually.

Backend Configuration, Advanced ENV, and the HTTP-META setting are drafts.
Save commits the Backend environment and SubDock configuration together.
Backend Configuration values override matching Advanced ENV values. HTTP-META
is optional; if it fails to start, the Backend continues starting. Saving
configuration does not restart the Backend. If a running Backend does not use
the saved settings, SubDock marks the change as waiting to be applied. While
the Backend is running, Settings offers **Apply saved configuration**; it stops
the Backend before restarting it. If the Backend is stopped, Settings offers
**Start Backend**, which starts it with the saved settings. A failed stop or
start leaves the saved settings available for retry.

The desktop normally starts the Backend automatically. The **Start hidden to
tray** preference hides the window during startup; if tray initialization
fails, SubDock shows the window and reports the problem. **Launch at login**
uses Linux XDG autostart. Windows and macOS show that this setting is
unsupported.

The close preference controls the window close button. **Close to tray** hides
the window without stopping the Backend. **Exit** asks for confirmation and
stops the Backend before closing. Cancel keeps the application open. If
stopping or shutdown fails, SubDock keeps the window available and offers a
retry. SubDock does not hide the window when the tray is unavailable.

## Updates and rollbacks

The online component updater checks and changes only the Sub-Store Backend
and Frontend. A confirmed multi-component update processes the Frontend before
the Backend. If the Backend is running, SubDock stops it before changing
components and restarts it with the saved configuration only after every
selected change succeeds. A Backend that was already stopped stays stopped.
If a component change fails after the stop succeeds, completed changes remain
in place and the Backend stays stopped. Retry handles only remaining changes;
before retrying an update, the Updates page checks that component again. If
only Backend startup failed, retry starts it without repeating completed
changes.

On launch, SubDock restores a saved maintenance outcome for review. It does
not resume component changes or automatically start the Backend from that
record, including when the saved record says component work completed while
the Backend was stopped.

Rollback is available only when the previous component files are present. A
Backend rollback also restores the data snapshot linked to that Backend
version. This can replace subscription data changed since the snapshot. SubDock
refuses the rollback if it cannot find the linked snapshot; it does not choose
an unrelated backup.

## Logs and history

The **Current** view shows Backend and HTTP-META output. Pausing the view
freezes what you are reading but does not stop log capture. Resume to follow
new output. The current view keeps a configurable tail of 50–2,000 entries.
Saved history stores recorded run events separately from that display limit;
integrity labels distinguish complete, incomplete, unverified, and recovered
runs.

The **History** view stores runs in roughly 10 MiB log segments and keeps them
for seven days. Search and source/level filters are applied before history
pagination. **Copy filtered logs** copies every matching event in a history
run, not only the visible page. In Current view, copying uses the filtered
entries in the retained current view.

You can delete a saved run or clear history, then undo the most recent deletion
during the same application session. If deletion is interrupted, SubDock
restores the unfinished deletion batch on the next launch before cleaning up
temporary files. Undo does not carry over to a later launch.

Records without an integrity field show as unverified. A run with a recorded
incomplete status stays marked incomplete; an unfinished older record that
SubDock repairs during startup is marked recovered. If log recovery fails,
SubDock pauses automatic cleanup and Backend startup until recovery succeeds.

## WebView, mobile, and fonts

The embedded Sub-Store page uses different WebView implementations by
platform. macOS uses `webview_flutter`; Linux and Windows use `webview_all`.
Windows requires Microsoft Edge WebView2 Runtime. The Manage page can open the
local UI in the system browser when the embedded view is unavailable. The
embedded Sub-Store page follows SubDock's effective light/dark appearance when
its theme is automatic; a manual theme selected in the website takes
precedence. This synchronization applies only to the embedded view; the system
browser uses its own theme settings. Linux source builds need GTK, X11, Xi, and
WebKitGTK development libraries.

The mobile entry point is a placeholder. It does not automatically start a
runtime and does not enable the WebView.

The SubDock shell bundles Noto Sans CJK SC and DejaVu Sans Mono, with the text
font as a fallback for CJK characters in monospaced text. These bundled fonts
style the SubDock interface; the embedded Sub-Store page uses its WebView's
web fonts and platform renderer.

## Run from source

This project uses FVM. Prepare resources for the target platform before
running or packaging the desktop app. Prepare Backend first because runtime
preparation reads its runtime manifest to select the tested Node.js version.

### Linux

Install the native development libraries on Debian or Ubuntu:

```sh
sudo apt-get install -y libgtk-3-dev libx11-dev libxi-dev libwebkit2gtk-4.1-dev
```

GTK, X11, and Xi development libraries are also required for `flutter test`,
which compiles the tray's native library.

```sh
tool/prepare_backend.sh
tool/prepare_frontend.sh
tool/prepare_runtime.sh linux-x64
tool/prepare_http_meta.sh linux-x64

fvm flutter run -d linux
```

### Windows and macOS

Prepare the Backend and Frontend once, then prepare runtime and HTTP-META
resources for the target you will build. For Windows x64:

```sh
tool/prepare_backend.sh
tool/prepare_frontend.sh
tool/prepare_runtime.sh windows-x64
tool/prepare_http_meta.sh windows-x64

fvm flutter run -d windows
```

For Apple Silicon macOS, use `darwin-arm64`; for Intel macOS, use
`darwin-x64`. The macOS runtime preparation builds its bundled Shoutrrr binary
from source and requires Go.

```sh
tool/prepare_backend.sh
tool/prepare_frontend.sh
tool/prepare_runtime.sh darwin-arm64
tool/prepare_http_meta.sh darwin-arm64

fvm flutter run -d macos
```

Replace `darwin-arm64` with `darwin-x64` for an Intel macOS build.

## Validate changes

```sh
fvm flutter analyze
fvm flutter test
node --test test/embedded_webview_color_scheme_bridge.test.cjs
```

The Node behavior check uses only Node's built-in test and VM modules; no npm
package or additional install is needed. If Node is not on `PATH`, run it with
the existing prepared runtime at `.subdock/runtime/<target>/node` (or
`node.exe` on Windows).

## Packaging

Preparation scripts stage the Sub-Store Backend and Frontend, Node.js, HTTP-META
and its mihomo resource, and supporting runtime files under `.subdock/`. Desktop
packaging copies these resources into the application bundle. The online
component updater changes only the Backend and Frontend; Node.js, HTTP-META,
and mihomo are packaged resources, not independent update targets. Set
`SUBDOCK_*_VERSION` variables to pin resource release versions.

The desktop packaging workflows define Linux DEB, RPM, AppImage, and Arch
packages, Windows EXE packages, and macOS DMG packages. They run bundle
verification during packaging.

For project architecture, safety invariants, and development guidance, see
[AGENTS.md](AGENTS.md).

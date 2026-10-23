<!-- pi-agents-md:begin version=1 scope=. -->
# SubDock

## Repository boundaries

- This is one Flutter application, not the Sub-Store Backend or Frontend source tree. Those components are downloaded by `tool/prepare_backend.sh` and `tool/prepare_frontend.sh` into ignored `.subdock/` resources.
- `lib/main.dart` delegates to `lib/desktop_main.dart`, the desktop composition root. `lib/app/app_coordinator.dart` coordinates runtime, configuration, and maintenance; `lib/runtime/` owns processes and logs; `lib/update/` owns component updates, recovery, and backups.
- Keep `lib/mobile_main.dart` as the limited mobile seam: `MobilePlaceholderRuntime`, no automatic start, and no WebView.

## Runtime safety invariants

- Configure initial window visibility before expensive startup work in `lib/desktop_main.dart`. Hidden starts must hide immediately and again when the window is ready.
- `AppCoordinator` and `DesktopBackendRuntime` serialize operations. Preserve restart ordering: stop successfully before starting again. Saved configuration is not applied configuration until startup succeeds.
- Use `EffectiveRuntimeConfig.resolve` in `lib/settings/subdock_config.dart` as the merge boundary: system environment, raw Backend ENV, then SubDock config overrides. Runtime-owned data, Frontend, and HTTP-META paths override those inputs.
- Create per-user runtime directories through `RuntimeDirectories`; preserve the access restrictions in `lib/runtime/runtime_permissions.dart` (Unix directories `700`, files `600`; Windows current-user ACLs).
- Preserve loopback defaults and the randomly generated Backend API path; a missing path must not silently fall back to `/`.
- Tray initialization is optional: show the window and a warning on failure. Closing without a working tray must take the confirmed exit path rather than hide the window. Failed shutdown keeps the window available for retry.
- Startup configuration, component, and log recovery failures must block automatic Backend startup. For update ordering, retry semantics, and data-replacing Backend rollback behavior, consult README sections **Startup and settings** and **Updates and rollbacks** before changing these flows.

## Verification

Use FVM; `.fvmrc` pins Flutter. On Linux, `flutter test` compiles the tray native library and needs GTK, X11, and Xi development libraries. Desktop builds also need WebKitGTK; exact Debian/Ubuntu packages are in README **Run from source**. Runtime process tests additionally need `node` on `PATH` and Unix shell utilities; they create temporary fixture bundles rather than using downloaded Backend resources.

- Dart analysis: `fvm flutter analyze`.
- Focused ordering/configuration tests: `fvm flutter test test/app/app_coordinator_test.dart`.
- Focused process tests: `fvm flutter test test/runtime/desktop_backend_runtime_test.dart`.
- For other boundaries, pass the responsible file or directory to `fvm flutter test`, e.g. `fvm flutter test test/settings/`.
- Cross-cutting changes: `fvm flutter test`.
- WebView bridge changes also require `node --test test/embedded_webview_color_scheme_bridge.test.cjs`; Flutter tests do not run this JavaScript behavior check. It uses Node built-ins only, with no npm install. See README **Validate changes** for using the prepared Node executable.
- Bundle verifier regression: `fvm flutter test test/runtime_packaging_test.dart`. This exercises platform layouts on a Unix host, skips on Windows, and does not prove native Windows/macOS builds work.

## Generated and platform files

- Edit localization sources in `lib/l10n/app_zh.arb` (template) and `app_en.arb`; regenerate `lib/l10n/generated/` with `fvm flutter gen-l10n` using `l10n.yaml`, rather than editing generated Dart.
- `.subdock/`, `build/`, `dist/`, `.dart_tool/`, and `.fvm/` are ignored preparation/build outputs, not implementation sources.
- `analysis_options.yaml` excludes all platform directories as well as `build/`. Keep platform edits scoped to a platform requirement; a clean Dart analysis does not validate native runners, CMake, or packaging. Regenerate Flutter plugin registrants/build rules instead of hand-editing them.

## Desktop resources and packaging

- Follow README **Run from source** for the target-specific preparation sequence. Prepare Backend before runtime: `tool/prepare_runtime.sh` reads Backend's `runtime-manifest.json` for the tested Node version unless explicitly overridden.
- Preparation downloads resources and replaces staged output. Version overrides are defined in `tool/versions.sh`; defaults generally select latest releases. Use those scripts instead of patching downloaded bundles.
- Runtime preparation bundles Node only. Backend notifications use in-process `shoutrrr-ts`; no separate notification executable or Go toolchain is required. The online updater changes Backend and Frontend only, not Node, HTTP-META, or mihomo.
- `.github/workflows/desktop-build.yml` is authoritative for native packaging dependencies, targets, and verification hooks. After packaging, run `tool/verify_bundle.sh <bundle-dir>` on Linux, add `windows` for Windows, or use `tool/verify_bundle.sh <SubDock.app/Contents/MacOS> macos`. On Linux, launch the installed bundle executable, not `intermediates_do_not_run/` (see `linux/CMakeLists.txt`).

## Completion criteria

For Dart changes, analysis and responsible-boundary tests must pass; run the full suite for cross-cutting changes and the separate Node check for bridge changes. Packaging changes require the relevant bundle verification. Report unavailable native builds or checks as unverified; layout fixtures and Dart analysis are not substitutes for platform execution.
<!-- pi-agents-md:end -->

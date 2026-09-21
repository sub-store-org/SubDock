<!-- pi-agents-md:begin version=1 scope=. -->
# SubDock

## Overview

SubDock is a private Flutter desktop runtime manager for Sub-Store.

## Architecture and invariants

- Keep desktop composition in `lib/desktop_main.dart`; configure initial window visibility before expensive startup work. Hidden starts must hide immediately and again when the window is ready.
- `AppCoordinator` and `DesktopBackendRuntime` serialize operations. Preserve `restart` ordering: stop successfully before starting again.
- Use `EffectiveRuntimeConfig.resolve` as the configuration merge boundary: system environment, raw backend ENV, then SubDock config overrides.
- Create and retain per-user runtime directories through `RuntimeDirectories`; preserve their current-user permission restrictions.
- Treat tray initialization as optional: surface failure as a warning and exit rather than hide-to-tray when it is unavailable.
- Keep `lib/mobile_main.dart` as the limited mobile seam: `MobilePlaceholderRuntime`, no automatic start, and no WebView.

## Development and validation

- Use FVM: run `fvm flutter analyze` after Dart changes and targeted `fvm flutter test` tests; run the full suite for cross-cutting work.
- Follow coordinator tests for ordering and configuration behavior; test changes at the responsible boundary.
- Do not hand-edit generated or platform directories covered by analyzer exclusions unless the platform-specific change requires it.

## Packaging

- Build packaging resources through the preparation scripts before desktop packaging. CI prepares backend, frontend, runtime, and HTTP-META resources, then verifies the resulting bundle.
- See `README.md` for developer setup and platform preparation commands.
<!-- pi-agents-md:end -->

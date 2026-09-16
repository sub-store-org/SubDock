import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/app_coordinator.dart';
import 'app/mobile_placeholder_runtime.dart';
import 'runtime/runtime_directories.dart';
import 'settings/backend_env_store.dart';
import 'settings/config_error.dart';

Future<SubDockApp> createMobileApp({RuntimeDirectories? directories}) async {
  final runtimeDirectories = directories ?? await RuntimeDirectories.create();
  final coordinator = AppCoordinator(
    runtime: MobilePlaceholderRuntime(),
    environmentStore: BackendEnvStore(runtimeDirectories),
  );
  try {
    await coordinator.loadEnvironment();
  } on AppConfigError {
    // The shared Settings page provides the existing recovery surface.
  }
  return SubDockApp(
    coordinator: coordinator,
    autoStart: false,
    enableWebView: false,
    showCustomDesktopChrome: false,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(await createMobileApp());
}

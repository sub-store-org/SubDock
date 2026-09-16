import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

import 'app/app.dart';
import 'app/app_coordinator.dart';
import 'app/close_request_guard.dart';
import 'desktop_lifecycle.dart';
import 'l10n/generated/app_localizations.dart';
import 'runtime/desktop_backend_runtime.dart';
import 'runtime/runtime_directories.dart';
import 'runtime/runtime_log_store.dart';
import 'settings/autostart.dart';
import 'settings/backend_env_store.dart';
import 'settings/config_error.dart';
import 'settings/desktop_preferences_store.dart';
import 'settings/subdock_config_store.dart';
import 'update/component_metadata_store.dart';
import 'update/component_recovery.dart';
import 'update/component_resource_resolver.dart';
import 'update/component_update_service.dart';
import 'update/data_backup_store.dart';
import 'update/github_release_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  if (Platform.isWindows) {
    await WindowsSingleInstance.ensureSingleInstance(
      Platform.executableArguments,
      'subdock',
      onSecondWindow: (_) => unawaited(_showWindow()),
    );
  }
  final directories = await RuntimeDirectories.create();
  final logStore = RuntimeLogStore(directories);
  await logStore.initialize();
  Object? startupBlocker;
  try {
    await ComponentRecovery(
      bundleDirectory: File(Platform.resolvedExecutable).parent,
      dataDirectory: directories.data,
      metadataStore: ComponentMetadataStore(directories.components),
      dataBackups: DataBackupStore(
        backupsDirectory: directories.backups,
        stagingDirectory: directories.staging,
      ),
    ).recoverPending();
  } catch (error) {
    startupBlocker = AppConfigError(
      AppConfigErrorCode.componentRecoveryFailed,
      detail: '$error',
    );
  }
  final runtime = DesktopBackendRuntime(
    directories: directories,
    logStore: logStore,
  );
  final metadataStore = ComponentMetadataStore(directories.components);
  final dataBackups = DataBackupStore(
    backupsDirectory: directories.backups,
    stagingDirectory: directories.staging,
  );
  final resources = ComponentResourceResolver(
    bundleDirectory: File(Platform.resolvedExecutable).parent,
    componentsDirectory: directories.components,
    metadataStore: metadataStore,
  );
  final coordinator = AppCoordinator(
    runtime: runtime,
    environmentStore: BackendEnvStore(directories),
    configurationStore: SubDockConfigStore(directories),
    startupBlocker: startupBlocker,
    componentUpdates: ComponentUpdateService(
      runtime: runtime,
      directories: directories,
      metadataStore: metadataStore,
      resources: resources,
      releases: GithubReleaseClient(),
      backups: dataBackups,
    ),
    logStore: logStore,
  );
  try {
    await coordinator.loadEnvironment();
  } on AppConfigError {
    // The settings page provides the recovery path via `configurationError`.
  }
  final preferencesStore = DesktopPreferencesStore(directories);
  final preferences = await preferencesStore.load();
  // The tray is built before the app loads its preference, so the resolver
  // reads a mutable holder that the locale-change callback updates. Resolve
  // the persisted preference here so a saved en preference shows in the tray
  // on the very first launch, not only after a manual change.
  var currentLocale = resolveEffectiveLocale(
    preferences.locale,
    WidgetsBinding.instance.platformDispatcher.locales,
  );
  final closeRequestGuard = CloseRequestGuard();
  final retentionTimer = Timer.periodic(const Duration(hours: 6), (_) {
    unawaited(logStore.pruneExpired().catchError((_) {}));
  });
  final lifecycle = DesktopLifecycle(
    onExit: () async {
      retentionTimer.cancel();
      await coordinator.dispose();
    },
    closeRequestGuard: closeRequestGuard,
    closeBehavior: () async => (await preferencesStore.load()).closeBehavior,
    trayLabels: (item) {
      final l10n = lookupAppLocalizations(currentLocale);
      return switch (item) {
        TrayItem.show => l10n.trayShowWindow,
        TrayItem.exit => l10n.trayExit,
      };
    },
  );
  await lifecycle.initialize();
  // 启动时隐藏到托盘：窗口就绪但暂不显示，仅驻留托盘。
  if (preferences.startHiddenToTray) {
    await windowManager.waitUntilReadyToShow(desktopWindowOptions(), null);
  } else {
    await windowManager.waitUntilReadyToShow(desktopWindowOptions(), _showWindow);
  }
  final autostart = AutostartManager();
  runApp(
    SubDockApp(
      coordinator: coordinator,
      autoStart: startupBlocker == null,
      initialError: startupBlocker,
      desktopWarning: lifecycle.warning,
      onMinimize: lifecycle.minimize,
      onToggleMaximize: lifecycle.toggleMaximize,
      onClose: lifecycle.closeToTray,
      isMaximized: lifecycle.isMaximized,
      closeRequestGuard: closeRequestGuard,
      onAutostartChanged: (enabled) =>
          enabled ? autostart.enable() : autostart.disable(),
      onStartDragging: windowManager.startDragging,
      showCustomDesktopChrome: usesCustomDesktopChrome(),
      preferences: preferences,
      preferencesStore: preferencesStore,
      onLocaleChanged: (locale) async {
        currentLocale = resolveEffectiveLocale(
          locale?.languageCode,
          WidgetsBinding.instance.platformDispatcher.locales,
        );
        await lifecycle.updateTray();
      },
    ),
  );
}

Locale resolveEffectiveLocale(
  String? languageCode,
  List<Locale> systemLocales,
) {
  if (languageCode != null) return Locale(languageCode);
  return basicLocaleListResolution(
    systemLocales,
    AppLocalizations.supportedLocales,
  );
}

Future<void> _showWindow() async {
  await windowManager.show();
  await windowManager.focus();
}

WindowOptions desktopWindowOptions({bool? isMacOS}) {
  final macOS = isMacOS ?? Platform.isMacOS;
  return WindowOptions(
    title: 'SubDock',
    minimumSize: const Size(600, 480),
    titleBarStyle: macOS ? TitleBarStyle.normal : TitleBarStyle.hidden,
  );
}

bool usesCustomDesktopChrome({bool? isMacOS}) => !(isMacOS ?? Platform.isMacOS);

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/app.dart';
import 'package:subdock/app/app_coordinator.dart';
import 'package:subdock/app/close_request_guard.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/settings/backend_env_store.dart';
import 'package:subdock/settings/autostart.dart';
import 'package:subdock/settings/desktop_preferences.dart';
import 'package:subdock/settings/desktop_preferences_store.dart';
import 'package:subdock/settings/subdock_config_store.dart';

import '../support/pump_app.dart';

void main() {
  testWidgets('automatic preference saving is remembered across launches', (
    WidgetTester tester,
  ) async {
    late Directory temporaryDirectory;
    addTearDown(
      () => tester.runAsync(() => temporaryDirectory.delete(recursive: true)),
    );
    final directories = await tester.runAsync(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'settings_page_test_',
      );
      return RuntimeDirectories.fromBaseDirectory(temporaryDirectory);
    });
    final preferencesStore = DesktopPreferencesStore(directories!);
    final coordinator = AppCoordinator(
      runtime: _SettingsRuntime(),
      environmentStore: BackendEnvStore(directories),
      configurationStore: SubDockConfigStore(directories),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      final disposal = coordinator.dispose();
      await tester.pump();
      await disposal;
    });
    await tester.binding.setSurfaceSize(const Size(1024, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> showSettings(DesktopPreferences preferences) async {
      await pumpApp(
        tester,
        SubDockApp(
          coordinator: coordinator,
          autoStart: false,
          enableWebView: false,
          locale: const Locale('zh'),
          preferences: preferences,
          preferencesStore: preferencesStore,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
      await tester.pumpAndSettle();
    }

    await showSettings(DesktopPreferences.defaults);

    final automaticSaving = find.byKey(const ValueKey('settings-auto-save'));
    expect(tester.widget<Switch>(automaticSaving).value, isTrue);
    await tester.tap(automaticSaving);
    await _pumpRealIo(tester);
    final persistedPreferences = await tester.runAsync(preferencesStore.load);
    expect(persistedPreferences!.autoSavePreferences, isFalse);

    await tester.pumpWidget(const SizedBox());
    await showSettings(persistedPreferences);
    expect(tester.widget<Switch>(automaticSaving).value, isFalse);

    final themeMode = find.byKey(const ValueKey('settings-theme-mode'));
    await tester.tap(find.descendant(of: themeMode, matching: find.text('深色')));
    await tester.pumpAndSettle();
    expect(tester.widget<SegmentedButton<ThemeMode>>(themeMode).selected, {
      ThemeMode.dark,
    });
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsWidgets);
    expect(
      (await tester.runAsync(preferencesStore.load))!.locale,
      persistedPreferences.locale,
    );

    final discard = find.byKey(const ValueKey('settings-discard-preferences'));
    await tester.scrollUntilVisible(
      discard,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(discard);
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsWidgets);
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('settings-language')),
          )
          .initialValue,
      'system',
    );
    expect(tester.widget<SegmentedButton<ThemeMode>>(themeMode).selected, {
      persistedPreferences.themeMode,
    });
    final revertedPreferences = await tester.runAsync(preferencesStore.load);
    expect(revertedPreferences!.locale, persistedPreferences.locale);
    expect(revertedPreferences.themeMode, persistedPreferences.themeMode);

    final recentLogLimit = find.byKey(
      const ValueKey('settings-recent-log-limit'),
    );
    await tester.scrollUntilVisible(
      recentLogLimit,
      -240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.enterText(recentLogLimit, '49');
    await tester.pump();
    await tester.scrollUntilVisible(
      themeMode,
      -240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: themeMode, matching: find.text('Dark')),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      automaticSaving,
      -240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(automaticSaving);
    await _pumpRealIo(tester);

    final reenabledPreferences = await tester.runAsync(preferencesStore.load);
    expect(reenabledPreferences!.autoSavePreferences, isTrue);
    expect(reenabledPreferences.themeMode, ThemeMode.dark);
    expect(reenabledPreferences.recentLogLimit, 200);
    expect(tester.widget<TextField>(recentLogLimit).controller!.text, '49');
    expect(find.text('Enter a whole number from 50 to 2,000.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-save-preferences')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('automatic saving keeps failures visible until retry succeeds', (
    WidgetTester tester,
  ) async {
    late Directory temporaryDirectory;
    addTearDown(
      () => tester.runAsync(() => temporaryDirectory.delete(recursive: true)),
    );
    final directories = await tester.runAsync(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'settings_page_test_',
      );
      return RuntimeDirectories.fromBaseDirectory(temporaryDirectory);
    });
    final bootstrapStore = DesktopPreferencesStore(directories!);
    await tester.runAsync(
      () => bootstrapStore.save(DesktopPreferences.defaults),
    );
    final preferencesStore = _FailOncePreferencesStore(directories);
    final coordinator = AppCoordinator(
      runtime: _SettingsRuntime(),
      environmentStore: BackendEnvStore(directories),
      configurationStore: SubDockConfigStore(directories),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      final disposal = coordinator.dispose();
      await tester.pump();
      await disposal;
    });
    await tester.binding.setSurfaceSize(const Size(1024, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
        preferences: await tester.runAsync(bootstrapStore.load),
        preferencesStore: preferencesStore,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
    await tester.pumpAndSettle();
    final theme = find.byType(SegmentedButton<ThemeMode>);
    final light = find.descendant(of: theme, matching: find.text('Light'));
    await tester.ensureVisible(light);
    await tester.tap(light);
    await _pumpRealIo(tester);

    final error = find.byKey(const ValueKey('settings-preferences-error'));
    expect(error, findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-save-preferences')),
      findsNothing,
    );
    expect(preferencesStore.attempted, hasLength(1));

    final retry = find.descendant(
      of: error,
      matching: find.byType(OutlinedButton),
    );
    await tester.scrollUntilVisible(
      retry,
      -240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(retry);
    await _pumpRealIo(tester);

    expect(
      find.byKey(const ValueKey('settings-preferences-error')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('settings-save-preferences')),
      findsNothing,
    );
    expect(preferencesStore.attempted, hasLength(2));
    expect(
      (await tester.runAsync(bootstrapStore.load))!.themeMode,
      ThemeMode.light,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'login startup failure keeps the preference saved and can retry',
    (WidgetTester tester) async {
      late Directory temporaryDirectory;
      addTearDown(
        () => tester.runAsync(() => temporaryDirectory.delete(recursive: true)),
      );
      final directories = await tester.runAsync(() async {
        temporaryDirectory = await Directory.systemTemp.createTemp(
          'settings_page_test_',
        );
        return RuntimeDirectories.fromBaseDirectory(temporaryDirectory);
      });
      final preferencesStore = _CountingPreferencesStore(directories!);
      final preferences = await tester.runAsync(preferencesStore.load);
      preferencesStore.writes.clear();
      final coordinator = AppCoordinator(
        runtime: _SettingsRuntime(),
        environmentStore: BackendEnvStore(directories),
        configurationStore: SubDockConfigStore(directories),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        final disposal = coordinator.dispose();
        await tester.pump();
        await disposal;
      });
      await tester.binding.setSurfaceSize(const Size(1024, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var attempts = 0;
      final retryCompletion = Completer<void>();
      addTearDown(() {
        if (!retryCompletion.isCompleted) retryCompletion.complete();
      });
      final startupDirectory = Directory(
        '${temporaryDirectory.path}/autostart',
      );
      final autostart = AutostartManager(
        configHome: startupDirectory,
        executablePath: '/opt/subdock/SubDock',
      );
      await pumpApp(
        tester,
        SubDockApp(
          coordinator: coordinator,
          autoStart: false,
          enableWebView: false,
          locale: const Locale('en'),
          preferences: preferences!,
          preferencesStore: preferencesStore,
          onAutostartChanged: (enabled) async {
            attempts++;
            if (attempts == 1) throw StateError('temporary startup failure');
            if (attempts == 2) await retryCompletion.future;
            await (enabled ? autostart.enable() : autostart.disable());
          },
        ),
      );
      await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
      await tester.pumpAndSettle();
      final launchAtLogin = find.byKey(
        const ValueKey('settings-launch-at-login'),
      );
      await tester.scrollUntilVisible(
        launchAtLogin,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(launchAtLogin);
      await _pumpRealIo(tester);

      expect(attempts, 1);
      expect(
        find.byKey(const ValueKey('settings-autostart-error')),
        findsOneWidget,
      );
      expect(
        (await tester.runAsync(preferencesStore.load))!.launchAtLogin,
        isTrue,
      );
      expect(preferencesStore.writes, hasLength(1));

      final retry = find.descendant(
        of: find.byKey(const ValueKey('settings-autostart-error')),
        matching: find.byType(OutlinedButton),
      );
      await tester.scrollUntilVisible(
        retry,
        -240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(preferencesStore.writes, hasLength(1));
      await tester.scrollUntilVisible(
        launchAtLogin,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(launchAtLogin);
      await _pumpRealIo(tester);
      retryCompletion.complete();
      await _pumpRealIo(tester);
      expect(attempts, 3);
      expect(
        find.byKey(const ValueKey('settings-autostart-error')),
        findsNothing,
      );
      expect(preferencesStore.writes, hasLength(2));
      expect(
        (await tester.runAsync(preferencesStore.load))!.launchAtLogin,
        isFalse,
      );
      expect(
        await tester.runAsync(
          () =>
              File.fromUri(startupDirectory.uri.resolve('subdock.desktop'))
                  .exists(),
        ),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
    },
    skip: !Platform.isLinux,
  );

  testWidgets('recent log limit saves valid edits after a debounce', (
    WidgetTester tester,
  ) async {
    late Directory temporaryDirectory;
    addTearDown(
      () => tester.runAsync(() => temporaryDirectory.delete(recursive: true)),
    );
    final directories = await tester.runAsync(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'settings_page_test_',
      );
      return RuntimeDirectories.fromBaseDirectory(temporaryDirectory);
    });
    final preferencesStore = _CountingPreferencesStore(directories!);
    final preferences = await tester.runAsync(preferencesStore.load);
    preferencesStore.writes.clear();
    final coordinator = AppCoordinator(
      runtime: _SettingsRuntime(),
      environmentStore: BackendEnvStore(directories),
      configurationStore: SubDockConfigStore(directories),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      final disposal = coordinator.dispose();
      await tester.pump();
      await disposal;
    });
    await tester.binding.setSurfaceSize(const Size(1024, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
        preferences: preferences!,
        preferencesStore: preferencesStore,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
    await tester.pumpAndSettle();
    final recentLogLimit = find.byKey(
      const ValueKey('settings-recent-log-limit'),
    );
    await tester.scrollUntilVisible(
      recentLogLimit,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    for (final invalid in ['49', '2001', '', 'abc']) {
      await tester.enterText(recentLogLimit, invalid);
      await tester.pump(const Duration(seconds: 1));
      expect(preferencesStore.writes, isEmpty);
    }
    expect((await tester.runAsync(preferencesStore.load))!.recentLogLimit, 200);

    await tester.enterText(recentLogLimit, '50');
    await tester.pump(const Duration(milliseconds: 699));
    expect(preferencesStore.writes, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await _pumpRealIo(tester);
    expect(preferencesStore.writes, hasLength(1));
    expect(preferencesStore.writes.single.recentLogLimit, 50);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _pumpRealIo(tester);
    expect(preferencesStore.writes, hasLength(1));

    await tester.enterText(recentLogLimit, '2000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _pumpRealIo(tester);
    expect(preferencesStore.writes, hasLength(2));
    expect(preferencesStore.writes.last.recentLogLimit, 2000);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('runtime draft is protected only when leaving settings', (
    WidgetTester tester,
  ) async {
    late Directory temporaryDirectory;
    addTearDown(
      () => tester.runAsync(() => temporaryDirectory.delete(recursive: true)),
    );
    final directories = await tester.runAsync(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'settings_page_test_',
      );
      return RuntimeDirectories.fromBaseDirectory(temporaryDirectory);
    });
    final coordinator = AppCoordinator(
      runtime: _SettingsRuntime(),
      environmentStore: BackendEnvStore(directories!),
      configurationStore: SubDockConfigStore(directories),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      final disposal = coordinator.dispose();
      await tester.pump();
      await disposal;
    });
    final closeRequestGuard = CloseRequestGuard();
    await tester.runAsync(coordinator.loadEnvironment);
    await tester.binding.setSurfaceSize(const Size(1024, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
        closeRequestGuard: closeRequestGuard,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-card-backend-config')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings-card-backend-config')),
    );
    await tester.pumpAndSettle();
    final hostField = find.descendant(
      of: find.byKey(const ValueKey('settings-backend-host-row')),
      matching: find.byType(TextField),
    );
    await tester.enterText(hostField, '127.0.0.2');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('settings-back')));
    await tester.pumpAndSettle();

    expect(find.text('You have unsaved changes. Continue?'), findsNothing);
    expect(
      find.text('Runtime configuration draft has not been saved.'),
      findsOneWidget,
    );
    final closeApproval = closeRequestGuard.request();
    await tester.pumpAndSettle();
    expect(find.text('Exit SubDock?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(await closeApproval, isFalse);
    expect(
      find.text('Runtime configuration draft has not been saved.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('nav-item-overview')));
    await tester.pumpAndSettle();
    expect(find.text('You have unsaved changes. Continue?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Offstage>(find.byKey(const ValueKey('page-settings')))
          .offstage,
      isFalse,
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-card-backend-config')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings-card-backend-config')),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(hostField).controller!.text, '127.0.0.2');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('connection and ENV drafts are saved as one configuration', (
    WidgetTester tester,
  ) async {
    late Directory temporaryDirectory;
    addTearDown(
      () => tester.runAsync(() => temporaryDirectory.delete(recursive: true)),
    );
    final directories = await tester.runAsync(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'settings_page_test_',
      );
      return RuntimeDirectories.fromBaseDirectory(temporaryDirectory);
    });
    final runtime = _SettingsRuntime();
    final configurationStore = _PausedConfigurationStore(directories!);
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      configurationStore: configurationStore,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      final disposal = coordinator.dispose();
      await tester.pump();
      await disposal;
    });
    await tester.runAsync(coordinator.loadEnvironment);
    await tester.binding.setSurfaceSize(const Size(1024, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
    await tester.pumpAndSettle();
    final startingRevision = coordinator.savedRevision;

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-card-backend-config')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings-card-backend-config')),
    );
    await tester.pumpAndSettle();
    final hostField = find.descendant(
      of: find.byKey(const ValueKey('settings-backend-host-row')),
      matching: find.byType(TextField),
    );
    await tester.enterText(hostField, '127.0.0.2');
    final portField = find.descendant(
      of: find.byKey(const ValueKey('settings-backend-port-row')),
      matching: find.byType(TextField),
    );
    await tester.enterText(portField, 'invalid');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('settings-back')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-card-advanced-env')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-advanced-env')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('settings-raw-env-expansion')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-raw-env-expansion')));
    await tester.pumpAndSettle();
    const environmentText = 'SUB_STORE_BACKEND_API_PORT=3222\n';
    await tester.enterText(
      find.byKey(const ValueKey('settings-raw-env-editor')),
      environmentText,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('settings-back')));
    await tester.pumpAndSettle();

    final save = find.byKey(const ValueKey('settings-save-all'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    final connection = find.byKey(
      const ValueKey('settings-card-backend-config'),
    );
    await tester.scrollUntilVisible(
      connection,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(connection);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(portField).controller!.text, 'invalid');
    await tester.enterText(portField, '');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('settings-back')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(save);
    final releaseSave = Completer<void>();
    configurationStore.beforeWrite = releaseSave;
    addTearDown(() {
      if (!releaseSave.isCompleted) releaseSave.complete();
    });
    await tester.tap(save);
    await _pumpRealIo(tester);
    await tester.scrollUntilVisible(
      connection,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(connection);
    await tester.pumpAndSettle();
    await tester.enterText(portField, 'next-invalid');
    releaseSave.complete();
    await _pumpRealIo(tester);
    expect(
      tester.widget<TextField>(portField).controller!.text,
      'next-invalid',
    );
    await tester.enterText(portField, '');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('settings-back')));
    await tester.pumpAndSettle();

    final savedPair = await tester.runAsync(
      () => coordinator.runtimeConfigurationStore!.load(),
    );
    expect(coordinator.savedRevision, startingRevision + 1);
    expect(savedPair!.configuration.environment.rawText, environmentText);
    expect(savedPair.configuration.configuration.backend.apiHost, '127.0.0.2');
    expect(savedPair.configuration.configuration.backend.apiPort, isNull);
    expect(runtime.currentState.status, RuntimeStatus.stopped);
    expect(
      find.text(
        'Saved runtime configuration will be used when Backend starts.',
      ),
      findsOneWidget,
    );
    final applySaved = find.byKey(
      const ValueKey('settings-apply-saved-runtime'),
    );
    expect(tester.widget<OutlinedButton>(applySaved).onPressed, isNotNull);
    await tester.scrollUntilVisible(
      applySaved,
      -240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(applySaved);
    await _pumpRealIo(tester);
    expect(runtime.starts, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'risk confirmations are separate and cancellation preserves saved files',
    (WidgetTester tester) async {
      late Directory temporaryDirectory;
      addTearDown(
        () => tester.runAsync(() => temporaryDirectory.delete(recursive: true)),
      );
      final directories = await tester.runAsync(() async {
        temporaryDirectory = await Directory.systemTemp.createTemp(
          'settings_page_test_',
        );
        return RuntimeDirectories.fromBaseDirectory(temporaryDirectory);
      });
      final coordinator = AppCoordinator(
        runtime: _SettingsRuntime(),
        environmentStore: BackendEnvStore(directories!),
        configurationStore: SubDockConfigStore(directories),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        final disposal = coordinator.dispose();
        await tester.pump();
        await disposal;
      });
      await tester.runAsync(coordinator.loadEnvironment);
      final store = coordinator.runtimeConfigurationStore!;
      final savedBefore = await tester.runAsync(store.load);
      final startingRevision = coordinator.savedRevision;
      await tester.binding.setSurfaceSize(const Size(1024, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpApp(
        tester,
        SubDockApp(
          coordinator: coordinator,
          autoStart: false,
          enableWebView: false,
          locale: const Locale('en'),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-card-backend-config')),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('settings-card-backend-config')),
      );
      await tester.pumpAndSettle();
      final host = find.descendant(
        of: find.byKey(const ValueKey('settings-backend-host-row')),
        matching: find.byType(TextField),
      );
      await tester.enterText(host, '0.0.0.0');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('settings-back')));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-card-advanced-env')),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('settings-card-advanced-env')),
      );
      await tester.pumpAndSettle();
      final rawExpansion = find.byKey(
        const ValueKey('settings-raw-env-expansion'),
      );
      await tester.ensureVisible(rawExpansion);
      await tester.tap(rawExpansion);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('settings-raw-env-editor')),
        'SUB_STORE_CORS_ALLOWED_ORIGINS=https://example.com\n',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('settings-back')));
      await tester.pumpAndSettle();

      const externalCorsPrompt =
          'Allowing an external origin lets it reach the Backend API. Save anyway?';
      const nonLoopbackPrompt =
          'The Backend has no authentication; a non-loopback address lets other devices on the network reach every API. Save anyway?';
      final save = find.byKey(const ValueKey('settings-save-all'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text(externalCorsPrompt), findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();

      Future<void> expectOriginalPair() async {
        expect(coordinator.savedRevision, startingRevision);
        final after = await tester.runAsync(store.load);
        expect(after!.configuration, savedBefore!.configuration);
      }

      await expectOriginalPair();
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text(externalCorsPrompt), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text(externalCorsPrompt), findsNothing);
      expect(find.text(nonLoopbackPrompt), findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(find.text(nonLoopbackPrompt), findsNothing);
      await expectOriginalPair();
    },
  );
}

Future<void> _pumpRealIo(WidgetTester tester, {int turns = 40}) async {
  for (var turn = 0; turn < turns; turn++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

class _PausedConfigurationStore extends SubDockConfigStore {
  _PausedConfigurationStore(super.directories);

  Completer<void>? beforeWrite;

  @override
  Future<void> replaceRaw(String rawText) async {
    await beforeWrite?.future;
    await super.replaceRaw(rawText);
  }
}

class _FailOncePreferencesStore extends DesktopPreferencesStore {
  _FailOncePreferencesStore(super.directories);

  final attempted = <DesktopPreferences>[];
  var _shouldFail = true;

  @override
  Future<void> save(DesktopPreferences preferences) async {
    attempted.add(preferences);
    if (_shouldFail) {
      _shouldFail = false;
      throw const FileSystemException('simulated preferences write failure');
    }
    await super.save(preferences);
  }
}

class _CountingPreferencesStore extends DesktopPreferencesStore {
  _CountingPreferencesStore(super.directories);

  final List<DesktopPreferences> writes = [];

  @override
  Future<void> save(DesktopPreferences preferences) async {
    writes.add(preferences);
    await super.save(preferences);
  }
}

class _SettingsRuntime extends BackendRuntime {
  final _logs = StreamController<RuntimeLog>.broadcast(sync: true);
  var starts = 0;
  final _states = StreamController<RuntimeState>.broadcast(sync: true);

  @override
  RuntimeState get currentState =>
      RuntimeState(status: RuntimeStatus.stopped, changedAt: DateTime.now());

  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:3001');

  @override
  Stream<RuntimeLog> get logs => _logs.stream;

  @override
  Stream<RuntimeState> get state => _states.stream;

  @override
  Future<BackendInfo> info() async =>
      const BackendInfo(nodeVersion: '-', backendVersion: '-', port: 3001);

  @override
  Future<bool> isHealthy() async => false;

  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> restart() async {}

  @override
  Future<void> activateUserEnvironment(Map<String, String> environment) async {}

  @override
  Future<void> dispose() async {
    await _logs.close();
    await _states.close();
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:subdock/app/app.dart';
import 'package:subdock/app/app_colors.dart';
import 'package:subdock/app/app_coordinator.dart';
import 'package:subdock/app/close_request_guard.dart';
import 'package:subdock/l10n/generated/app_localizations.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/settings/backend_env_store.dart';
import 'package:subdock/settings/autostart.dart';
import 'package:subdock/settings/desktop_preferences.dart';
import 'package:subdock/settings/desktop_preferences_store.dart';
import 'package:subdock/settings/subdock_config.dart';
import 'package:subdock/settings/subdock_config_store.dart';

import '../support/pump_app.dart';

void main() {
  testWidgets(
    'saving preferences while leaving settings leaves without asking again',
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
      final preferencesStore = _PausedPreferencesStore(directories!);
      final preferences = DesktopPreferences.defaults.copyWith(
        autoSavePreferences: false,
      );
      await tester.runAsync(() => preferencesStore.save(preferences));
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
          preferences: preferences,
          preferencesStore: preferencesStore,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
      await tester.pumpAndSettle();

      final themeMode = find.byKey(const ValueKey('settings-theme-mode'));
      await tester.tap(
        find.descendant(of: themeMode, matching: find.text('Dark')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-item-overview')));
      await tester.pumpAndSettle();
      final leaveDialog = find.byType(ShadDialog);
      expect(
        find.descendant(
          of: leaveDialog,
          matching: find.text('You have unsaved changes. Continue?'),
        ),
        findsOneWidget,
      );

      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      addTearDown(() {
        if (!releaseWrite.isCompleted) releaseWrite.complete();
      });
      preferencesStore.writeStarted = writeStarted;
      preferencesStore.releaseWrite = releaseWrite;
      await tester.tap(
        find.descendant(of: leaveDialog, matching: find.text('Save')),
      );
      await tester.runAsync(() => writeStarted.future);
      await tester.pump();
      final saveCompleted = Completer<void>();
      preferencesStore.saveCompleted = saveCompleted;
      releaseWrite.complete();
      final leavePrompt = find.text('You have unsaved changes. Continue?');
      final overviewPage = find.byKey(const ValueKey('page-overview'));
      await _pumpUntilSaveLeaveOutcome(
        tester,
        saveCompleted,
        expectedPublicOutcome:
            'the leave prompt to close and Overview to activate',
        publicOutcomeReached: () =>
            leavePrompt.evaluate().isEmpty &&
            overviewPage.evaluate().isNotEmpty &&
            !tester.widget<Offstage>(overviewPage).offstage,
      );

      expect(find.text('You have unsaved changes. Continue?'), findsNothing);
      expect(
        tester
            .widget<Offstage>(find.byKey(const ValueKey('page-overview')))
            .offstage,
        isFalse,
      );
      expect(
        (await tester.runAsync(preferencesStore.load))!.themeMode,
        ThemeMode.dark,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'new preference edits stay protected while leave save is pending',
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
      final preferencesStore = _PausedPreferencesStore(directories!);
      final preferences = DesktopPreferences.defaults.copyWith(
        autoSavePreferences: false,
      );
      await tester.runAsync(() => preferencesStore.save(preferences));
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
          preferences: preferences,
          preferencesStore: preferencesStore,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
      await tester.pumpAndSettle();

      final themeMode = find.byKey(const ValueKey('settings-theme-mode'));
      await tester.tap(
        find.descendant(of: themeMode, matching: find.text('Dark')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-item-overview')));
      await tester.pumpAndSettle();
      final leaveDialog = find.byType(ShadDialog);
      expect(
        find.descendant(
          of: leaveDialog,
          matching: find.text('You have unsaved changes. Continue?'),
        ),
        findsOneWidget,
      );

      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      addTearDown(() {
        if (!releaseWrite.isCompleted) releaseWrite.complete();
      });
      preferencesStore.writeStarted = writeStarted;
      preferencesStore.releaseWrite = releaseWrite;
      await tester.tap(
        find.descendant(of: leaveDialog, matching: find.text('Save')),
      );
      await tester.runAsync(() => writeStarted.future);
      await tester.pump();

      final closeBehavior = find.byKey(
        const ValueKey('settings-close-behavior'),
      );
      await tester.scrollUntilVisible(
        closeBehavior,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(closeBehavior);
      await tester.pumpAndSettle();
      await tester.tap(closeBehavior);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close to tray'));
      await tester.pumpAndSettle();
      final saveCompleted = Completer<void>();
      preferencesStore.saveCompleted = saveCompleted;
      releaseWrite.complete();
      final expectedLeavePrompt = find.descendant(
        of: find.byType(ShadDialog),
        matching: find.text('You have unsaved changes. Continue?'),
      );
      await _pumpUntilSaveLeaveOutcome(
        tester,
        saveCompleted,
        expectedPublicOutcome:
            'a new leave prompt for the newer preference edit',
        publicOutcomeReached: () => expectedLeavePrompt.evaluate().isNotEmpty,
      );

      final newLeaveDialog = find.byType(ShadDialog);
      expect(
        find.descendant(
          of: newLeaveDialog,
          matching: find.text('You have unsaved changes. Continue?'),
        ),
        findsOneWidget,
      );
      final persisted = await tester.runAsync(preferencesStore.load);
      expect(persisted!.themeMode, ThemeMode.dark);
      expect(persisted.closeBehavior, CloseBehavior.exitApp);
      await tester.tap(
        find.descendant(of: newLeaveDialog, matching: find.text('Cancel')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Close to tray'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

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
    expect(tester.widget<ShadSwitch>(automaticSaving).value, isTrue);
    await tester.tap(automaticSaving);
    await _pumpRealIo(tester);
    final persistedPreferences = await tester.runAsync(preferencesStore.load);
    expect(persistedPreferences!.autoSavePreferences, isFalse);

    await tester.pumpWidget(const SizedBox());
    await showSettings(persistedPreferences);
    expect(tester.widget<ShadSwitch>(automaticSaving).value, isFalse);
    await _expectFloatingSettingsActions(
      tester,
      'settings-preferences-actions',
      'settings-save-preferences',
    );

    final savedBrightness = _settingsBrightness(tester);
    final themeMode = find.byKey(const ValueKey('settings-theme-mode'));
    await tester.tap(find.descendant(of: themeMode, matching: find.text('深色')));
    await tester.pumpAndSettle();
    expect(_settingsBrightness(tester), Brightness.dark);
    await tester.tap(find.byKey(const ValueKey('settings-language')));
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
          .widget<ShadSelect<String>>(
            find.byKey(const ValueKey('settings-language')),
          )
          .initialValue,
      'system',
    );
    expect(_settingsBrightness(tester), savedBrightness);
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
    expect(tester.widget<ShadInput>(recentLogLimit).controller!.text, '49');
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
    final theme = find.byKey(const ValueKey('settings-theme-mode'));
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

    final retry = find.descendant(of: error, matching: find.byType(ShadButton));
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
        matching: find.byType(ShadButton),
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
      matching: find.byType(ShadInput),
    );
    await tester.enterText(hostField, '127.0.0.2');
    await tester.pump();
    final settingsBack = find.byKey(const ValueKey('settings-back'));
    await tester.ensureVisible(settingsBack);
    await tester.pumpAndSettle();
    await tester.tap(settingsBack);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-local-service-card')),
      findsOneWidget,
    );

    expect(find.text('You have unsaved changes. Continue?'), findsNothing);
    final closeApproval = closeRequestGuard.request();
    await tester.pumpAndSettle();
    expect(find.text('Exit SubDock?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(await closeApproval, isFalse);

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
    expect(tester.widget<ShadInput>(hostField).controller!.text, '127.0.0.2');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings-runtime-application')),
        matching: find.text('Runtime configuration draft has not been saved.'),
      ),
      findsOneWidget,
    );
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
      matching: find.byType(ShadInput),
    );
    await tester.enterText(hostField, '127.0.0.2');
    final portField = find.descendant(
      of: find.byKey(const ValueKey('settings-backend-port-row')),
      matching: find.byType(ShadInput),
    );
    await tester.enterText(portField, 'invalid');
    await tester.pump();
    await _expectFloatingSettingsActions(
      tester,
      'settings-runtime-actions',
      'settings-child-save',
    );

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
    await _expectFloatingSettingsActions(
      tester,
      'settings-runtime-actions',
      'settings-child-save',
    );
    await tester.tap(find.byKey(const ValueKey('settings-back')));
    await tester.pumpAndSettle();

    final save = find.byKey(const ValueKey('settings-child-save'));
    // The invalid port keeps Save blocked; the blocked button must still be
    // readable rather than a pale accent label on a pale fill.
    _expectReadableDisabledButton(tester, save, 'Save runtime configuration');
    expect(tester.widget<ShadInput>(portField).controller!.text, 'invalid');
    await tester.enterText(portField, '');
    await tester.pump();
    await tester.ensureVisible(save);
    final releaseSave = Completer<void>();
    configurationStore.beforeWrite = releaseSave;
    addTearDown(() {
      if (!releaseSave.isCompleted) releaseSave.complete();
    });
    await tester.tap(save);
    await _pumpRealIo(tester);
    await tester.ensureVisible(portField);
    await tester.pumpAndSettle();
    await tester.enterText(portField, 'next-invalid');
    releaseSave.complete();
    await _pumpRealIo(tester);
    expect(
      tester.widget<ShadInput>(portField).controller!.text,
      'next-invalid',
    );
    await tester.enterText(portField, '');
    await tester.pump();

    final savedPair = await tester.runAsync(
      () => coordinator.runtimeConfigurationStore!.load(),
    );
    expect(coordinator.savedRevision, startingRevision + 1);
    expect(savedPair!.configuration.environment.rawText, environmentText);
    expect(savedPair.configuration.configuration.backend.apiHost, '127.0.0.2');
    expect(savedPair.configuration.configuration.backend.apiPort, isNull);
    expect(runtime.currentState.status, RuntimeStatus.stopped);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings-runtime-pending-status')),
        matching: find.text(
          'Saved runtime configuration will be used when Backend starts.',
        ),
      ),
      findsOneWidget,
    );
    final applySaved = find.byKey(
      const ValueKey('settings-apply-saved-runtime'),
    );
    expect(tester.widget<ShadButton>(applySaved).onPressed, isNotNull);
    await tester.scrollUntilVisible(
      applySaved,
      -240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    // Saving reports through the draft state in the form; no success toast can
    // cover the action group that reveals Apply afterwards.
    expect(find.text('Saved'), findsNothing);
    expect(find.byType(ShadToast), findsNothing);
    expect(save, findsNothing);
    expect(applySaved.hitTestable(), findsOneWidget);
    await tester.tap(applySaved);
    await _pumpRealIo(tester);
    expect(runtime.starts, 1);
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsNothing);

    // A failed shared save surfaces its retry in the form, and that retry keeps
    // the Save button's busy guard: never enterable while a save is in flight.
    configurationStore.failNextWrite = true;
    await tester.enterText(hostField, '127.0.0.3');
    await tester.pump();
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsNothing);
    await tester.tap(save);
    await _pumpRealIo(tester);
    final saveFailure = find.byKey(
      const ValueKey('settings-runtime-save-error'),
    );
    expect(saveFailure, findsOneWidget);
    final retrySave = find.descendant(
      of: saveFailure,
      matching: find.byType(ShadButton),
    );
    expect(tester.widget<ShadButton>(retrySave).onPressed, isNotNull);

    final pendingRetry = Completer<void>();
    configurationStore.beforeWrite = pendingRetry;
    try {
      await tester.ensureVisible(retrySave);
      await tester.pumpAndSettle();
      await tester.tap(retrySave);
      await _pumpRealIo(tester);
      expect(tester.widget<ShadButton>(retrySave).onPressed, isNull);
    } finally {
      pendingRetry.complete();
    }
    await _pumpRealIo(tester);
    expect(
      find.byKey(const ValueKey('settings-runtime-save-error')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'settings can retry a failed runtime apply without an applied snapshot',
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
      final runtime = _RetryableSettingsRuntime(failedStarts: 2);
      final coordinator = AppCoordinator(
        runtime: runtime,
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

      await tester.tap(find.text('Start').last);
      await _pumpUntilSettingsRuntime(
        tester,
        () => runtime.currentState.status == RuntimeStatus.running,
        'the initial Backend start to succeed',
      );
      expect(runtime.appliedConfiguration, isNotNull);

      await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
      await tester.pumpAndSettle();
      final backendConfiguration = find.byKey(
        const ValueKey('settings-card-backend-config'),
      );
      await tester.ensureVisible(backendConfiguration);
      await tester.pumpAndSettle();
      await tester.tap(backendConfiguration);
      await tester.pumpAndSettle();
      final hostField = find.descendant(
        of: find.byKey(const ValueKey('settings-backend-host-row')),
        matching: find.byType(ShadInput),
      );
      await tester.enterText(hostField, '127.0.0.2');
      await tester.pump();
      final saveConfiguration = find.byKey(
        const ValueKey('settings-child-save'),
      );
      await tester.ensureVisible(saveConfiguration);
      final savedRevision = coordinator.savedRevision;
      await tester.tap(saveConfiguration);
      await _pumpUntilSettingsRuntime(
        tester,
        () =>
            coordinator.savedRevision == savedRevision + 1 &&
            runtime.currentState.status == RuntimeStatus.running,
        'the edited runtime configuration to be saved',
      );
      final saved = await tester.runAsync(
        () => coordinator.runtimeConfigurationStore!.load(),
      );
      expect(saved!.configuration.configuration.backend.apiHost, '127.0.0.2');
      final currentSummary = find.byKey(
        const ValueKey('settings-current-runtime-summary'),
      );
      final proposedSummary = find.byKey(
        const ValueKey('settings-proposed-runtime-summary'),
      );
      expect(find.byKey(const ValueKey('settings-runtime')), findsOneWidget);
      expect(
        find.descendant(
          of: currentSummary,
          matching: find.textContaining(
            runtime
                .appliedConfiguration!
                .environment['SUB_STORE_BACKEND_API_HOST']!,
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: proposedSummary,
          matching: find.textContaining('127.0.0.2'),
        ),
        findsOneWidget,
      );

      final applySaved = find.byKey(
        const ValueKey('settings-apply-saved-runtime'),
      );
      await tester.ensureVisible(applySaved);
      await tester.pumpAndSettle();
      await tester.tap(applySaved);
      await _pumpUntilSettingsRuntime(
        tester,
        () =>
            runtime.currentState.status == RuntimeStatus.crashed &&
            runtime.appliedConfiguration == null &&
            find
                .byKey(const ValueKey('settings-apply-runtime-error'))
                .evaluate()
                .isNotEmpty,
        'the stop-success/start-failure recovery state',
      );
      expect(runtime.appliedConfiguration, isNull);
      expect(
        find.descendant(
          of: currentSummary,
          matching: find.text('No runtime configuration is currently applied.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: proposedSummary,
          matching: find.textContaining('127.0.0.2'),
        ),
        findsOneWidget,
      );
      final retryError = find.byKey(
        const ValueKey('settings-apply-runtime-error'),
      );
      var retry = find.descendant(
        of: retryError,
        matching: find.byType(ShadButton),
      );
      expect(tester.widget<ShadButton>(retry).onPressed, isNotNull);

      // The failed apply belongs to the shared draft, so the Advanced ENV view
      // must report the same failure with a working retry instead of dead-ending
      // without the Apply button.
      await tester.tap(find.byKey(const ValueKey('settings-back')));
      await tester.pumpAndSettle();
      final backendConfigEntry = find.byKey(
        const ValueKey('settings-card-backend-config'),
      );
      await tester.ensureVisible(backendConfigEntry);
      await tester.pumpAndSettle();
      await tester.tap(backendConfigEntry);
      await tester.pumpAndSettle();
      final advancedEnvEntry = find.byKey(
        const ValueKey('settings-card-advanced-env'),
      );
      await tester.ensureVisible(advancedEnvEntry);
      await tester.pumpAndSettle();
      await tester.tap(advancedEnvEntry);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-raw-env')), findsOneWidget);
      final envRetryError = find.byKey(
        const ValueKey('settings-apply-runtime-error'),
      );
      expect(envRetryError, findsOneWidget);
      // The failure copy keeps announcing itself; the surrounding card adds no
      // live region, so the error text must own that semantics.
      expect(
        tester.getSemantics(
          find.descendant(
            of: envRetryError,
            matching: find.text(
              'Saved runtime configuration could not be applied. It remains '
              'saved and can be retried.',
            ),
          ),
        ),
        isSemantics(isLiveRegion: true),
      );
      var envRetry = find.descendant(
        of: envRetryError,
        matching: find.byType(ShadButton),
      );
      expect(tester.widget<ShadButton>(envRetry).onPressed, isNotNull);

      final secondAttemptCompleted = runtime.observeNextStartCompletion();
      await tester.ensureVisible(envRetry);
      await tester.pumpAndSettle();
      await tester.tap(envRetry);
      await _pumpUntilSettingsRuntime(
        tester,
        () =>
            secondAttemptCompleted.isCompleted &&
            runtime.currentState.status == RuntimeStatus.crashed &&
            runtime.appliedConfiguration == null &&
            find
                .byKey(const ValueKey('settings-apply-runtime-error'))
                .evaluate()
                .isNotEmpty,
        'a second failed attempt to leave recovery available from Advanced ENV',
      );
      expect(envRetryError, findsOneWidget);
      envRetry = find.descendant(
        of: envRetryError,
        matching: find.byType(ShadButton),
      );
      expect(tester.widget<ShadButton>(envRetry).onPressed, isNotNull);

      await tester.tap(find.byKey(const ValueKey('settings-back')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-backend-config')),
        findsOneWidget,
      );
      retry = find.descendant(
        of: find.byKey(const ValueKey('settings-apply-runtime-error')),
        matching: find.byType(ShadButton),
      );
      expect(tester.widget<ShadButton>(retry).onPressed, isNotNull);

      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      await tester.tap(retry);
      await _pumpUntilSettingsRuntime(
        tester,
        () =>
            runtime.currentState.status == RuntimeStatus.running &&
            runtime.appliedConfiguration != null,
        'the saved runtime configuration to be applied on retry',
      );
      expect(
        runtime.appliedConfiguration!.environment['SUB_STORE_BACKEND_API_HOST'],
        '127.0.0.2',
      );
      expect(
        find.byKey(const ValueKey('settings-apply-runtime-error')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'save-and-apply confirmation cancels safely and applies when confirmed',
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
      final runtime = _RetryableSettingsRuntime(failedStarts: 0);
      final coordinator = AppCoordinator(
        runtime: runtime,
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
      await tester.tap(find.text('Start').last);
      await _pumpUntilSettingsRuntime(
        tester,
        () => runtime.currentState.status == RuntimeStatus.running,
        'the initial Backend start to succeed',
      );
      final appliedBeforeComment = runtime.appliedConfiguration!;
      final appliedHostBefore =
          appliedBeforeComment.environment['SUB_STORE_BACKEND_API_HOST'];

      await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
      await tester.pumpAndSettle();
      final backendCard = find.byKey(
        const ValueKey('settings-card-backend-config'),
      );
      await tester.ensureVisible(backendCard);
      await tester.pumpAndSettle();
      await tester.tap(backendCard);
      await tester.pumpAndSettle();
      final advancedEnv = find.byKey(
        const ValueKey('settings-card-advanced-env'),
      );
      await tester.ensureVisible(advancedEnv);
      await tester.pumpAndSettle();
      await tester.tap(advancedEnv);
      await tester.pumpAndSettle();
      final rawExpansion = find.byKey(
        const ValueKey('settings-raw-env-expansion'),
      );
      await tester.ensureVisible(rawExpansion);
      await tester.pumpAndSettle();
      expect(rawExpansion.hitTestable(), findsOneWidget);
      await tester.tap(rawExpansion);
      await tester.pumpAndSettle();
      final rawEnvironment = find.byKey(
        const ValueKey('settings-raw-env-editor'),
      );
      await tester.ensureVisible(rawEnvironment);
      const commentOnly = '# comment-only ENV edit\n';
      await tester.enterText(rawEnvironment, commentOnly);
      await tester.pump();
      final backToConnection = find.byKey(const ValueKey('settings-back'));
      await tester.ensureVisible(backToConnection);
      await tester.pumpAndSettle();
      expect(backToConnection.hitTestable(), findsOneWidget);
      await tester.tap(backToConnection);
      await tester.pumpAndSettle();

      final commentOnlySaveAndApply = find.byKey(
        const ValueKey('settings-child-save-and-apply'),
      );
      expect(commentOnlySaveAndApply, findsNothing);
      final saveOnly = find.byKey(const ValueKey('settings-child-save'));
      expect(tester.widget<ShadButton>(saveOnly).onPressed, isNotNull);
      await tester.ensureVisible(saveOnly);
      await tester.pumpAndSettle();
      final revisionBeforeComment = coordinator.savedRevision;
      await tester.tap(saveOnly);
      await _pumpUntilSettingsRuntime(
        tester,
        () =>
            coordinator.savedRevision == revisionBeforeComment + 1 &&
            runtime.currentState.status == RuntimeStatus.running,
        'comment-only ENV to save without applying a runtime change',
      );
      final savedComment = await tester.runAsync(
        () => coordinator.runtimeConfigurationStore!.load(),
      );
      expect(savedComment!.configuration.environment.rawText, commentOnly);
      expect(
        identical(runtime.appliedConfiguration, appliedBeforeComment),
        isTrue,
      );

      final storedBefore = await tester.runAsync(
        () => coordinator.runtimeConfigurationStore!.load(),
      );
      final revisionBefore = coordinator.savedRevision;
      final host = find.descendant(
        of: find.byKey(const ValueKey('settings-backend-host-row')),
        matching: find.byType(ShadInput),
      );
      await tester.ensureVisible(host);
      await tester.enterText(host, '127.0.0.2');
      await tester.pump();

      final saveAndApply = find.byKey(
        const ValueKey('settings-child-save-and-apply'),
      );
      await tester.ensureVisible(saveAndApply);
      await tester.pumpAndSettle();
      expect(tester.widget<ShadButton>(saveAndApply).onPressed, isNotNull);
      await tester.tap(saveAndApply);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Save the connection, HTTP-META, and ENV draft, then restart Backend with it?',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(coordinator.savedRevision, revisionBefore);
      expect(runtime.currentState.status, RuntimeStatus.running);
      expect(
        runtime.appliedConfiguration!.environment['SUB_STORE_BACKEND_API_HOST'],
        appliedHostBefore,
      );
      final storedAfterCancel = await tester.runAsync(
        () => coordinator.runtimeConfigurationStore!.load(),
      );
      expect(
        storedAfterCancel!.configuration.configuration.backend.apiHost,
        storedBefore!.configuration.configuration.backend.apiHost,
      );

      await tester.ensureVisible(saveAndApply);
      await tester.pumpAndSettle();
      await tester.tap(saveAndApply);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue').last);
      await _pumpUntilSettingsRuntime(
        tester,
        () =>
            coordinator.savedRevision == revisionBefore + 1 &&
            runtime.currentState.status == RuntimeStatus.running &&
            runtime
                    .appliedConfiguration
                    ?.environment['SUB_STORE_BACKEND_API_HOST'] ==
                '127.0.0.2',
        'the combined save-and-apply operation to persist and apply the new host',
      );
      expect(
        (await tester.runAsync(
          () => coordinator.runtimeConfigurationStore!.load(),
        ))!.configuration.configuration.backend.apiHost,
        '127.0.0.2',
      );
    },
  );

  testWidgets('reverting the connection task discards its shared ENV draft', (
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
    final backendCard = find.byKey(
      const ValueKey('settings-card-backend-config'),
    );
    await tester.ensureVisible(backendCard);
    await tester.pumpAndSettle();
    await tester.tap(backendCard);
    await tester.pumpAndSettle();

    final host = find.descendant(
      of: find.byKey(const ValueKey('settings-backend-host-row')),
      matching: find.byType(ShadInput),
    );
    await tester.ensureVisible(host);
    await tester.enterText(host, '127.0.0.2');
    await tester.pump();
    final advancedEnv = find.byKey(
      const ValueKey('settings-card-advanced-env'),
    );
    await tester.ensureVisible(advancedEnv);
    await tester.pumpAndSettle();
    await tester.tap(advancedEnv);
    await tester.pumpAndSettle();
    final rawExpansion = find.byKey(
      const ValueKey('settings-raw-env-expansion'),
    );
    await tester.ensureVisible(rawExpansion);
    await tester.pumpAndSettle();
    expect(rawExpansion.hitTestable(), findsOneWidget);
    await tester.tap(rawExpansion);
    await tester.pumpAndSettle();
    final rawEnvironment = find.byKey(
      const ValueKey('settings-raw-env-editor'),
    );
    await tester.ensureVisible(rawEnvironment);
    await tester.enterText(rawEnvironment, 'SUB_STORE_BACKEND_API_PORT=3222\n');
    await tester.pump();
    final back = find.byKey(const ValueKey('settings-back'));
    await tester.ensureVisible(back);
    await tester.pumpAndSettle();
    expect(back.hitTestable(), findsOneWidget);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(tester.widget<ShadInput>(host).controller!.text, '127.0.0.2');
    expect(coordinator.savedRevision, startingRevision);

    final revert = find.byKey(const ValueKey('settings-child-revert'));
    expect(tester.widget<ShadButton>(revert).onPressed, isNotNull);
    await tester.ensureVisible(revert);
    await tester.pumpAndSettle();
    expect(revert.hitTestable(), findsOneWidget);
    await tester.tap(revert);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Revert connection, HTTP-META, and Advanced ENV changes to the last saved configuration?',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Continue').last);
    await tester.pumpAndSettle();
    expect(tester.widget<ShadInput>(host).controller!.text, isEmpty);
    expect(coordinator.savedRevision, startingRevision);

    await tester.ensureVisible(advancedEnv);
    await tester.pumpAndSettle();
    await tester.tap(advancedEnv);
    await tester.pumpAndSettle();
    final restoredRawEnvironment = find.byKey(
      const ValueKey('settings-raw-env-editor'),
    );
    if (restoredRawEnvironment.evaluate().isEmpty) {
      await tester.ensureVisible(rawExpansion);
      await tester.pumpAndSettle();
      expect(rawExpansion.hitTestable(), findsOneWidget);
      await tester.tap(rawExpansion);
      await tester.pumpAndSettle();
    }
    expect(
      tester.widget<ShadInput>(restoredRawEnvironment).controller!.text,
      isEmpty,
    );
    final savedAfter = await tester.runAsync(store.load);
    expect(
      savedAfter!.configuration.environment.rawText,
      savedBefore!.configuration.environment.rawText,
    );
    expect(
      savedAfter.configuration.configuration.backend.apiHost,
      savedBefore.configuration.configuration.backend.apiHost,
    );
  });

  testWidgets(
    'quick preferences keep the approved one-panel layout and whole-card runtime entry',
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
      await tester.binding.setSurfaceSize(const Size(1440, 960));
      await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
      await tester.pumpAndSettle();

      final l10n = AppLocalizations.of(
        tester.element(find.byKey(const ValueKey('settings-list'))),
      )!;
      final panel = find.byKey(const ValueKey('settings-preferences-panel'));
      final appearanceGroup = find.byKey(const ValueKey('settings-appearance'));
      final desktopGroup = find.byKey(
        const ValueKey('settings-desktop-behavior'),
      );
      // One preference panel holds both groups, instead of a bordered card per
      // section heading.
      final themeRow = find.byKey(const ValueKey('settings-theme-row'));
      final closeRow = find.byKey(
        const ValueKey('settings-close-behavior-row'),
      );
      final appearanceCard = find.ancestor(
        of: themeRow,
        matching: find.byType(ShadCard),
      );
      final desktopCard = find.ancestor(
        of: closeRow,
        matching: find.byType(ShadCard),
      );
      expect(appearanceCard, findsOneWidget);
      expect(desktopCard, findsOneWidget);
      expect(tester.element(appearanceCard), same(tester.element(desktopCard)));
      expect(panel, findsOneWidget);
      for (final heading in [
        l10n.settingsQuickAppearanceHeading,
        l10n.settingsQuickDesktopHeading,
      ]) {
        expect(
          find.descendant(of: panel, matching: find.text(heading)),
          findsOneWidget,
        );
      }

      // The numeric limit keeps its 140px bound instead of filling the column.
      final recentLogLimit = find.byKey(
        const ValueKey('settings-recent-log-limit'),
      );
      expect(tester.getSize(recentLogLimit).width, closeTo(140, 0.5));

      // The home frame is the approved 1060px, top-left aligned one instead of
      // a centered column that floats away from the page title.
      final settingsList = find.byKey(const ValueKey('settings-list'));
      final listRect = tester.getRect(settingsList);
      final panelRect = tester.getRect(panel);
      expect(panelRect.width, closeTo(1060, 0.5));
      expect(panelRect.left - (listRect.left + 24), closeTo(0, 0.5));
      expect(listRect.right - panelRect.right, greaterThan(100));

      // At 900+ the groups sit side by side with the 32/28 gaps and a vertical
      // rule between them.
      final wideAppearance = tester.getRect(appearanceGroup);
      final wideDesktop = tester.getRect(desktopGroup);
      expect(wideAppearance.right, lessThan(wideDesktop.left));
      expect(wideDesktop.left - wideAppearance.right, closeTo(61, 0.5));
      expect((wideDesktop.top - wideAppearance.top).abs(), lessThan(0.5));
      final splitRule = find.byKey(
        const ValueKey('settings-preferences-divider'),
      );
      expect(splitRule, findsOneWidget);
      final splitRuleRect = tester.getRect(splitRule);
      expect(splitRuleRect.width, closeTo(1, 0.5));
      expect((splitRuleRect.top - wideAppearance.top).abs(), lessThan(0.5));
      expect(
        (splitRuleRect.left - (wideAppearance.right + 32)).abs(),
        lessThan(0.5),
      );

      // Inside a group narrower than its field breakpoint the copy comes first,
      // then a 9px gap, and the editor starts at the group's left edge.
      final languageControl = find.byKey(const ValueKey('settings-language'));
      final languageRow = find.byKey(const ValueKey('settings-language-row'));
      final stackedControlRect = tester.getRect(languageControl);
      final stackedCopyRect = tester.getRect(languageRow);
      expect(stackedControlRect.left, closeTo(wideAppearance.left, 0.5));
      expect(stackedControlRect.top - stackedCopyRect.bottom, closeTo(9, 0.5));

      // The 900 split is measured inside the panel's padding and border: a
      // panel that is wider than 900 still stacks while its content is not.
      await tester.binding.setSurfaceSize(const Size(1109, 800));
      await tester.pumpAndSettle();
      final innerBreakpointPanel = tester.getRect(panel);
      expect(innerBreakpointPanel.width, greaterThanOrEqualTo(900));
      expect(innerBreakpointPanel.width, lessThan(942));
      final innerGroupWidth = tester.getRect(appearanceGroup).width;
      expect(innerGroupWidth, closeTo(innerBreakpointPanel.width - 42, 0.5));
      expect(innerGroupWidth, lessThan(900));
      expect(
        tester.getRect(desktopGroup).top,
        greaterThanOrEqualTo(tester.getRect(appearanceGroup).bottom),
      );

      // Below 900 the same panel stacks its groups with an 18/22 right around a
      // horizontal rule instead of a vertical one.
      await tester.binding.setSurfaceSize(const Size(1024, 800));
      await tester.pumpAndSettle();
      final narrowPanel = tester.getRect(panel);
      final narrowAppearance = tester.getRect(appearanceGroup);
      final narrowDesktop = tester.getRect(desktopGroup);
      expect(panel, findsOneWidget);
      expect(narrowAppearance.width, closeTo(narrowPanel.width - 42, 0.5));
      expect(narrowDesktop.width, closeTo(narrowPanel.width - 42, 0.5));
      expect(narrowDesktop.top - narrowAppearance.bottom, closeTo(41, 0.5));
      final stackedRule = tester.getRect(
        find.byKey(const ValueKey('settings-preferences-divider')),
      );
      expect(stackedRule.height, closeTo(1, 0.5));
      expect(
        (stackedRule.top - (narrowAppearance.bottom + 18)).abs(),
        lessThan(0.5),
      );

      // A group at or above the 700px field breakpoint keeps the label on the
      // left and the control on the right, with a bounded editor and real gap.
      final narrowControlRect = tester.getRect(languageControl);
      final narrowCopyRect = tester.getRect(languageRow);
      expect(
        (narrowControlRect.right - narrowAppearance.right).abs(),
        lessThan(0.5),
      );
      expect(
        (narrowControlRect.center.dy - narrowCopyRect.center.dy).abs(),
        lessThan(0.5),
      );
      expect(narrowControlRect.left, greaterThan(narrowCopyRect.right + 20));
      expect(tester.takeException(), isNull);

      // The local service entry is the same whole-card navigation tile as the
      // About entry: applied state and address inside it, one chevron, no
      // nested call-to-action button.
      final serviceTile = find.byKey(
        const ValueKey('settings-local-service-card'),
      );
      final serviceEntryTarget = find.byKey(
        const ValueKey('settings-card-backend-config'),
      );
      final aboutTile = find.byKey(const ValueKey('settings-card-about'));
      expect(serviceTile, findsOneWidget);
      expect(
        find.descendant(of: serviceTile, matching: serviceEntryTarget),
        findsOneWidget,
      );
      expect(
        find.descendant(of: serviceTile, matching: find.byType(ShadButton)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: serviceTile,
          matching: find.text(l10n.settingsRuntimeConfigurationEntry),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: serviceTile,
          matching: find.byIcon(Icons.chevron_right),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: serviceTile,
          matching: find.text('http://127.0.0.1:3001'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: serviceTile,
          matching: find.textContaining('Backend:'),
        ),
        findsOneWidget,
      );
      final tileRect = tester.getRect(serviceTile);
      final aboutRect = tester.getRect(aboutTile);
      expect(tileRect.width, closeTo(aboutRect.width, 0.5));
      expect(tileRect.left, closeTo(aboutRect.left, 0.5));
      expect(
        tester.getRect(serviceEntryTarget).width,
        closeTo(tileRect.width, 0.5),
      );

      // The whole card navigates, including its icon column.
      await tester.ensureVisible(serviceTile);
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getTopLeft(serviceTile) + const Offset(12, 12));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-backend-config')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

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
        matching: find.byType(ShadInput),
      );
      await tester.enterText(host, '0.0.0.0');
      await tester.pump();

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
      final save = find.byKey(const ValueKey('settings-child-save'));
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

/// Proves the settings action corner is an overlay of buttons only: the list
/// viewport keeps the full content height, no footer band sits under it, the
/// group carries no permanent description/status copy, and the last control can
/// still be reached above the floating buttons.
Future<void> _expectFloatingSettingsActions(
  WidgetTester tester,
  String actionGroupKey,
  String trailingActionKey,
) async {
  final group = find.byKey(ValueKey(actionGroupKey));
  final action = find.byKey(ValueKey(trailingActionKey));
  final list = find.byKey(const ValueKey('settings-list'));

  expect(group, findsOneWidget);
  expect(tester.widget(group), isNot(isA<ShadCard>()));
  // Every piece of text in the corner belongs to a button label; the previous
  // permanent helper/status copy is gone rather than merely restyled.
  final groupTexts = find.descendant(of: group, matching: find.byType(Text));
  expect(groupTexts, findsWidgets);
  for (final element in groupTexts.evaluate()) {
    var insideButton = false;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget is ShadButton) {
        insideButton = true;
        return false;
      }
      return true;
    });
    expect(
      insideButton,
      isTrue,
      reason: 'Unexpected non-button copy in the action group.',
    );
  }

  final listRect = tester.getRect(list);
  final groupRect = tester.getRect(group);
  expect(
    groupRect.top,
    lessThan(listRect.bottom),
    reason: 'The buttons float over the viewport instead of a separate band.',
  );
  expect(tester.getRect(action).right, closeTo(groupRect.right, 0.5));

  // The scroll range ends with clearance for the floating buttons instead of a
  // shrunken viewport: at the end of the list the deepest form copy sits above
  // the button group and can still be operated.
  final scrollable = tester.state<ScrollableState>(
    find.descendant(of: list, matching: find.byType(Scrollable)).first,
  );
  final previousOffset = scrollable.position.pixels;
  scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
  await tester.pump();
  final deepestContentBottom = find
      .descendant(of: list, matching: find.byType(Text))
      .evaluate()
      .map((element) => tester.getRect(find.byWidget(element.widget)).bottom)
      .reduce((a, b) => a > b ? a : b);
  expect(
    deepestContentBottom,
    lessThanOrEqualTo(tester.getRect(group).top),
    reason: 'The last form content must clear the floating buttons.',
  );
  scrollable.position.jumpTo(previousOffset);
  await tester.pump();
}

/// Relative luminance contrast between two opaque colors, per WCAG 2.x.
double _contrastRatio(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final lighter = first > second ? first : second;
  final darker = first > second ? second : first;
  return (lighter + 0.05) / (darker + 0.05);
}

/// A disabled [ShadButton] must read as inactive yet still legible: the label
/// keeps usable contrast against the page surface when the SDK's 0.5 disabled
/// opacity is applied, and the control stays disabled in behavior and semantics.
void _expectReadableDisabledButton(
  WidgetTester tester,
  Finder button,
  String label,
) {
  final widget = tester.widget<ShadButton>(button);
  expect(widget.enabled, isFalse);
  expect(widget.onPressed, isNull);
  expect(
    find.descendant(of: button, matching: find.text(label)),
    findsOneWidget,
  );
  final colors = Theme.of(tester.element(button)).extension<AppColors>()!;
  final pageSurface = colors.surfaceLowest;
  final labelFinder = find.descendant(of: button, matching: find.text(label));
  // The button's own text style wins; otherwise the DefaultTextStyle the SDK
  // installs *inside* the button supplies the variant's effective label color.
  final labelColor =
      tester.widget<Text>(labelFinder).style?.color ??
      DefaultTextStyle.of(tester.element(labelFinder)).style.color ??
      widget.foregroundColor!;
  final decoration = tester
      .widget<ShadDecorator>(
        find.descendant(of: button, matching: find.byType(ShadDecorator)).first,
      )
      .decoration;
  final effectiveBackground = Color.alphaBlend(
    (decoration?.color ?? Colors.transparent).withValues(
      alpha: (decoration?.color?.a ?? 0) * 0.5,
    ),
    pageSurface,
  );
  final effectiveLabel = Color.alphaBlend(
    labelColor.withValues(alpha: 0.5),
    pageSurface,
  );
  expect(
    _contrastRatio(effectiveLabel, effectiveBackground),
    greaterThanOrEqualTo(2.5),
    reason: 'A disabled label must stay readable on the page surface.',
  );
}

Brightness _settingsBrightness(WidgetTester tester) =>
    Theme.of(tester.element(find.byKey(const ValueKey('settings-list'))))
        .brightness;

Future<void> _pumpUntilSaveLeaveOutcome(
  WidgetTester tester,
  Completer<void> saveCompleted, {
  required String expectedPublicOutcome,
  required bool Function() publicOutcomeReached,
}) async {
  const timeout = Duration(seconds: 5);
  final elapsed = Stopwatch()..start();
  while (true) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 16));

    final fixtureSaveCompleted = saveCompleted.isCompleted;
    final outcomeReached = publicOutcomeReached();
    if (fixtureSaveCompleted && outcomeReached) return;
    if (elapsed.elapsed >= timeout) {
      fail(
        'Timed out after ${timeout.inSeconds}s waiting for $expectedPublicOutcome '
        '(fixture save completed: $fixtureSaveCompleted; '
        'public outcome reached: $outcomeReached).',
      );
    }
  }
}

Future<void> _pumpUntilSettingsRuntime(
  WidgetTester tester,
  bool Function() outcomeReached,
  String expectedPublicOutcome,
) async {
  const timeout = Duration(seconds: 5);
  final elapsed = Stopwatch()..start();
  while (true) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 16));
    if (outcomeReached()) return;
    if (elapsed.elapsed >= timeout) {
      fail(
        'Timed out after ${timeout.inSeconds}s waiting for '
        '$expectedPublicOutcome.',
      );
    }
  }
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
  var failNextWrite = false;

  @override
  Future<void> replaceRaw(String rawText) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw const FileSystemException('simulated configuration write failure');
    }
    await beforeWrite?.future;
    await super.replaceRaw(rawText);
  }
}

class _PausedPreferencesStore extends DesktopPreferencesStore {
  _PausedPreferencesStore(super.directories);

  Completer<void>? writeStarted;
  Completer<void>? releaseWrite;
  Completer<void>? saveCompleted;

  @override
  Future<void> save(DesktopPreferences preferences) async {
    if (writeStarted case final started? when !started.isCompleted) {
      started.complete();
    }
    await releaseWrite?.future;
    try {
      await super.save(preferences);
    } finally {
      final completed = saveCompleted;
      if (completed != null && !completed.isCompleted) completed.complete();
    }
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

class _RetryableSettingsRuntime extends BackendRuntime {
  _RetryableSettingsRuntime({required int failedStarts})
    : _failedStartsRemaining = failedStarts;

  final _logs = StreamController<RuntimeLog>.broadcast(sync: true);
  final _states = StreamController<RuntimeState>.broadcast(sync: true);
  var _currentState = RuntimeState(
    status: RuntimeStatus.stopped,
    changedAt: DateTime.utc(2026),
  );
  int _failedStartsRemaining;
  var _initialStartSucceeded = false;
  EffectiveRuntimeConfig? _pendingConfiguration;
  EffectiveRuntimeConfig? _appliedConfiguration;
  Completer<void>? _nextStartCompletion;

  Completer<void> observeNextStartCompletion() {
    final completion = Completer<void>();
    _nextStartCompletion = completion;
    return completion;
  }

  void _setStatus(RuntimeStatus status) {
    _currentState = RuntimeState(status: status, changedAt: DateTime.utc(2026));
    _states.add(_currentState);
  }

  @override
  RuntimeState get currentState => _currentState;

  @override
  EffectiveRuntimeConfig? get appliedConfiguration => _appliedConfiguration;

  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:3001');

  @override
  Stream<RuntimeLog> get logs => _logs.stream;

  @override
  Stream<RuntimeState> get state => Stream<RuntimeState>.multi((controller) {
    controller.add(_currentState);
    final subscription = _states.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = subscription.cancel;
  }, isBroadcast: true);

  @override
  Future<BackendInfo> info() async =>
      const BackendInfo(nodeVersion: '-', backendVersion: '-', port: 3001);

  @override
  Future<bool> isHealthy() async =>
      _currentState.status == RuntimeStatus.running;

  @override
  Future<void> start() async {
    if (_currentState.status != RuntimeStatus.stopped) {
      throw StateError('Backend must be stopped before it can start');
    }
    final completion = _nextStartCompletion;
    _nextStartCompletion = null;
    try {
      if (_initialStartSucceeded && _failedStartsRemaining > 0) {
        _failedStartsRemaining--;
        _appliedConfiguration = null;
        _setStatus(RuntimeStatus.crashed);
        throw StateError('simulated Backend startup failure');
      }
      _appliedConfiguration = _pendingConfiguration;
      _setStatus(RuntimeStatus.running);
      _initialStartSucceeded = true;
    } finally {
      if (completion != null && !completion.isCompleted) completion.complete();
    }
  }

  @override
  Future<void> stop() async {
    _appliedConfiguration = null;
    _setStatus(RuntimeStatus.stopped);
  }

  @override
  Future<void> restart() async {
    await stop();
    await start();
  }

  @override
  Future<void> activateUserEnvironment(Map<String, String> environment) async {}

  @override
  Future<void> activateConfiguration(
    EffectiveRuntimeConfig configuration,
  ) async {
    _pendingConfiguration = configuration;
  }

  @override
  Future<void> dispose() async {
    await _logs.close();
    await _states.close();
  }
}

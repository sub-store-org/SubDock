import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:subdock/app/app.dart';
import 'package:subdock/app/app_coordinator.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/settings/backend_env_store.dart';
import 'package:subdock/settings/desktop_preferences.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_update_checker.dart';
import 'package:subdock/update/component_update_service.dart';
import 'package:subdock/update/github_release_client.dart';

void main() {
  testWidgets(
    'keyboard focus reaches window chrome, Logs controls, and Settings actions',
    (tester) async {
      late Directory temp;
      final directories = await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('subdock_focus_');
        return RuntimeDirectories.fromBaseDirectory(temp);
      });
      addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));

      final runtime = _FocusRuntime();
      addTearDown(runtime.dispose);

      final maximized = ValueNotifier<bool>(false);
      addTearDown(maximized.dispose);

      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        SubDockApp(
          coordinator: AppCoordinator(
            runtime: runtime,
            environmentStore: BackendEnvStore(directories!),
          ),
          autoStart: false,
          enableWebView: false,
          locale: const Locale('en'),
          preferences: DesktopPreferences.defaults.copyWith(
            autoSavePreferences: false,
          ),
          onMinimize: () async {},
          onToggleMaximize: () async {},
          onClose: () async {},
          isMaximized: maximized,
        ),
      );
      await tester.pumpAndSettle();

      final semantics = tester.ensureSemantics();
      try {
        final minimize = find.ancestor(
          of: find.bySemanticsLabel('Minimize'),
          matching: find.byType(ShadIconButton),
        );
        final maximize = find.ancestor(
          of: find.bySemanticsLabel('Maximize'),
          matching: find.byType(ShadIconButton),
        );
        final close = find.ancestor(
          of: find.bySemanticsLabel('Close'),
          matching: find.byType(ShadIconButton),
        );

        expect(minimize, findsOneWidget);
        expect(maximize, findsOneWidget);
        expect(close, findsOneWidget);

        await _tabUntilFocused(tester, minimize);
        await _tabUntilFocused(tester, maximize);
        await _tabUntilFocused(tester, close);
      } finally {
        semantics.dispose();
      }

      final logsNavigation = find.byKey(const ValueKey('nav-item-logs'));
      final settingsNavigation = find.byKey(
        const ValueKey('nav-item-settings'),
      );
      final overviewNavigation = find.byKey(
        const ValueKey('nav-item-overview'),
      );
      final themeMode = find.byKey(const ValueKey('settings-theme-mode'));
      final inactiveThemeMode = find.byKey(
        const ValueKey('settings-theme-mode'),
        skipOffstage: false,
      );

      await _tabUntilFocused(tester, logsNavigation);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      final currentMode = find.widgetWithText(ShadButton, 'Current');
      final sourceFilter = find.byKey(const ValueKey('logs-source-filter'));
      final newestFirst = find.byKey(const ValueKey('logs-sort-selector'));

      expect(currentMode, findsOneWidget);
      expect(sourceFilter, findsOneWidget);
      expect(newestFirst, findsOneWidget);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      await _tabUntilFocused(tester, currentMode);
      await _tabUntilFocused(tester, sourceFilter);
      await _tabUntilFocused(tester, newestFirst);

      await _tabUntilFocused(tester, logsNavigation);
      final startingFocus = FocusManager.instance.primaryFocus;
      expect(startingFocus, isNotNull);
      var completedFocusCycle = false;
      for (var index = 0; index < 80; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          _containsPrimaryFocus(tester, inactiveThemeMode),
          isFalse,
          reason: 'An inactive Settings control received keyboard focus.',
        );
        if (identical(FocusManager.instance.primaryFocus, startingFocus)) {
          completedFocusCycle = true;
          break;
        }
      }
      expect(
        completedFocusCycle,
        isTrue,
        reason: 'Keyboard traversal did not return to its starting control.',
      );

      await _tabUntilFocused(tester, settingsNavigation);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      final manualActions = find.byKey(
        const ValueKey('settings-preferences-actions'),
      );
      final savePreferences = find.byKey(
        const ValueKey('settings-save-preferences'),
      );
      // The action corner's button-only shape is owned by the settings-page
      // helper; this flow only tracks keyboard reachability and save state.
      expect(manualActions, findsOneWidget);
      expect(tester.widget<ShadButton>(savePreferences).onPressed, isNull);

      final systemBrightness = _settingsBrightness(tester);
      final lightTheme = find.ancestor(
        of: find.descendant(of: themeMode, matching: find.text('Light')),
        matching: find.byType(ShadButton),
      );
      await _tabUntilFocused(tester, lightTheme);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(_settingsBrightness(tester), Brightness.light);
      expect(tester.widget<ShadButton>(savePreferences).onPressed, isNotNull);

      final discardPreferences = find.byKey(
        const ValueKey('settings-discard-preferences'),
      );
      await _tabUntilFocused(tester, discardPreferences);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(_settingsBrightness(tester), systemBrightness);
      expect(tester.widget<ShadButton>(savePreferences).onPressed, isNull);

      await _tabUntilFocused(tester, lightTheme);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.widget<ShadButton>(savePreferences).onPressed, isNotNull);

      await _tabUntilFocused(tester, savePreferences);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(savePreferences, findsOneWidget);
      expect(tester.widget<ShadButton>(savePreferences).enabled, isFalse);
      expect(tester.widget<ShadButton>(savePreferences).onPressed, isNull);
      expect(_settingsBrightness(tester), Brightness.light);

      final darkTheme = find.ancestor(
        of: find.descendant(of: themeMode, matching: find.text('Dark')),
        matching: find.byType(ShadButton),
      );
      await _tabUntilFocused(tester, darkTheme);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await _tabUntilFocused(tester, overviewNavigation);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      final unsavedDialog = find.byType(ShadDialog);
      expect(unsavedDialog, findsOneWidget);
      expect(
        find.descendant(
          of: unsavedDialog,
          matching: find.text('You have unsaved changes. Continue?'),
        ),
        findsOneWidget,
      );

      final cancelLeave = find.ancestor(
        of: find.descendant(of: unsavedDialog, matching: find.text('Cancel')),
        matching: find.byType(ShadButton),
      );
      await _tabUntilFocused(tester, cancelLeave);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(ShadDialog), findsNothing);
      expect(
        _containsPrimaryFocus(tester, overviewNavigation),
        isTrue,
        reason: 'Cancel should return focus to the navigation control.',
      );
      expect(
        tester
            .widget<Offstage>(find.byKey(const ValueKey('page-settings')))
            .offstage,
        isFalse,
      );

      await _tabUntilFocused(tester, discardPreferences);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(_settingsBrightness(tester), Brightness.light);
      expect(tester.widget<ShadButton>(savePreferences).onPressed, isNull);

      // Commit the manual preference draft before opening the backend editor.

      final backendConfig = find.byKey(
        const ValueKey('settings-card-backend-config'),
      );
      await tester.ensureVisible(backendConfig);
      await tester.pumpAndSettle();
      await tester.tap(backendConfig);
      await tester.pumpAndSettle();

      final back = find.byKey(const ValueKey('settings-back'));
      expect(back, findsOneWidget);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await _tabUntilFocused(tester, back);

      final hostField = find.descendant(
        of: find.byKey(const ValueKey('settings-backend-host-row')),
        matching: find.byType(ShadInput),
      );
      await tester.ensureVisible(hostField);
      await tester.pumpAndSettle();
      await tester.enterText(hostField, '127.0.0.1');
      await tester.pump();

      final childSave = find.byKey(const ValueKey('settings-child-save'));
      expect(tester.widget<ShadButton>(childSave).onPressed, isNotNull);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await _tabUntilFocused(tester, childSave);

      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('keyboard focus reaches component update actions', (
    tester,
  ) async {
    late Directory temp;
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_focus_update_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));

    final runtime = _FocusRuntime();
    addTearDown(runtime.dispose);

    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      SubDockApp(
        coordinator: AppCoordinator(
          runtime: runtime,
          environmentStore: BackendEnvStore(directories!),
          componentUpdates: _FocusComponentUpdates(),
        ),
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
    await tester.pumpAndSettle();

    final releaseNotes = find.byKey(
      const ValueKey('component-release-notes-frontend'),
    );
    final recheck = find.byKey(
      const ValueKey('component-update-recheck-frontend'),
    );
    final update = find.byKey(
      const ValueKey('component-update-action-frontend'),
    );
    final rollback = find.byKey(
      const ValueKey('component-rollback-action-frontend'),
    );

    expect(releaseNotes, findsOneWidget);
    expect(recheck, findsOneWidget);
    expect(update, findsOneWidget);
    expect(rollback, findsOneWidget);

    expect(tester.widget<ShadButton>(releaseNotes).onPressed, isNotNull);
    expect(tester.widget<ShadButton>(recheck).onPressed, isNotNull);
    expect(tester.widget<ShadButton>(update).onPressed, isNotNull);
    expect(tester.widget<ShadButton>(rollback).onPressed, isNotNull);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    await _tabUntilFocused(tester, releaseNotes);
    await _tabUntilFocused(tester, recheck);
    await _tabUntilFocused(tester, update);
    await _tabUntilFocused(tester, rollback);

    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });
}

Brightness _settingsBrightness(WidgetTester tester) =>
    Theme.of(tester.element(find.byKey(const ValueKey('settings-list'))))
        .brightness;

Future<void> _tabUntilFocused(
  WidgetTester tester,
  Finder target, {
  int maxTabs = 60,
}) async {
  for (var index = 0; index < maxTabs; index++) {
    if (_containsPrimaryFocus(tester, target)) return;

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }

  expect(
    _containsPrimaryFocus(tester, target),
    isTrue,
    reason: 'Target was not reachable with Tab within $maxTabs steps.',
  );
}

bool _containsPrimaryFocus(WidgetTester tester, Finder target) {
  final targetElement = tester.element(target);
  final focusContext = FocusManager.instance.primaryFocus?.context;
  if (focusContext == null) return false;

  if (identical(focusContext, targetElement)) return true;

  var containsFocus = false;
  (focusContext as Element).visitAncestorElements((ancestor) {
    if (identical(ancestor, targetElement)) {
      containsFocus = true;
      return false;
    }
    return true;
  });
  return containsFocus;
}

class _FocusRuntime extends BackendRuntime {
  final _states = StreamController<RuntimeState>.broadcast();

  @override
  RuntimeState get currentState => RuntimeState(
    status: RuntimeStatus.stopped,
    changedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:3001');

  @override
  Stream<RuntimeLog> get logs => const Stream<RuntimeLog>.empty();

  @override
  Stream<RuntimeState> get state => _states.stream;

  @override
  Future<void> activateUserEnvironment(Map<String, String> environment) async {}

  @override
  Future<void> dispose() => _states.close();

  @override
  Future<BackendInfo> info() async => const BackendInfo(
    nodeVersion: 'v24.0.0',
    backendVersion: 'fixture',
    port: 3001,
  );

  @override
  Future<bool> isHealthy() async => false;

  @override
  Future<void> restart() async {}

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

class _FocusComponentUpdates implements ComponentUpdateOperations {
  @override
  Future<ComponentVersionStatus> status(ComponentKind kind) async =>
      const ComponentVersionStatus(current: '1.0.0', previous: '0.9.0');

  @override
  Future<ComponentUpdate> check(ComponentKind kind) async => ComponentUpdate(
    kind: kind,
    currentVersion: '1.0.0',
    availableVersion: '1.1.0',
    release: GithubRelease(
      version: '1.1.0',
      releaseUri: Uri.parse('https://example.invalid/${kind.name}'),
      assets: const [],
    ),
  );

  @override
  Future<void> update(ComponentUpdate update) async {}

  @override
  Future<ComponentRollbackResult> rollback(ComponentKind kind) async {
    return const ComponentRollbackResult.completed();
  }
}

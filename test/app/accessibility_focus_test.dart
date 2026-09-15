import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/app.dart';
import 'package:subdock/app/app_coordinator.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/settings/backend_env_store.dart';
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
          onMinimize: () async {},
          onToggleMaximize: () async {},
          onClose: () async {},
          isMaximized: maximized,
        ),
      );
      await tester.pumpAndSettle();

      final minimize = find.widgetWithIcon(IconButton, Icons.minimize);
      final maximize = find.widgetWithIcon(IconButton, Icons.maximize);
      final close = find.widgetWithIcon(IconButton, Icons.close);

      expect(minimize, findsOneWidget);
      expect(maximize, findsOneWidget);
      expect(close, findsOneWidget);

      await _tabUntilFocused(tester, minimize);
      await _tabUntilFocused(tester, maximize);
      await _tabUntilFocused(tester, close);

      await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
      await tester.pumpAndSettle();

      final currentMode = find.ancestor(
        of: find.text('Current'),
        matching: find.byType(TextButton),
      );
      final backendSource = find.byKey(const ValueKey('logs-source-Backend'));
      final warningLevel = find.byKey(const ValueKey('logs-level-warning'));
      final newestFirst = find.ancestor(
        of: find.text('Newest first'),
        matching: find.byType(TextButton),
      );

      expect(currentMode, findsOneWidget);
      expect(backendSource, findsOneWidget);
      expect(warningLevel, findsOneWidget);
      expect(newestFirst, findsOneWidget);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      await _tabUntilFocused(tester, currentMode);
      await _tabUntilFocused(tester, backendSource);
      await _tabUntilFocused(tester, warningLevel);
      await _tabUntilFocused(tester, newestFirst);

      await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
      await tester.pumpAndSettle();

      final themeMode = find.byKey(const ValueKey('settings-theme-mode'));

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await _tabUntilFocused(tester, themeMode);

      await tester.tap(
        find.descendant(of: themeMode, matching: find.text('Light')),
      );
      await tester.pumpAndSettle();

      final saveAll = find.byKey(const ValueKey('settings-save-all'));
      expect(tester.widget<FilledButton>(saveAll).onPressed, isNotNull);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await _tabUntilFocused(tester, saveAll);

      // The theme selection above intentionally dirties the General edit
      // session. Persist it before navigating to another Settings section;
      // otherwise _openSection() correctly opens the dirty-leave guard.
      await tester.tap(saveAll);
      await tester.pumpAndSettle();

      expect(tester.widget<FilledButton>(saveAll).onPressed, isNull);

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

      await tester.enterText(find.byType(TextField).first, '127.0.0.1');
      await tester.pump();

      final childSave = find.byKey(const ValueKey('settings-child-save'));
      expect(tester.widget<FilledButton>(childSave).onPressed, isNotNull);

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

    expect(tester.widget<TextButton>(releaseNotes).onPressed, isNotNull);
    expect(tester.widget<OutlinedButton>(recheck).onPressed, isNotNull);
    expect(tester.widget<FilledButton>(update).onPressed, isNotNull);
    expect(tester.widget<TextButton>(rollback).onPressed, isNotNull);

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
  Future<void> rollback(ComponentKind kind) async {}
}

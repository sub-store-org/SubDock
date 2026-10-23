import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/app.dart';
import 'package:subdock/app/app_coordinator.dart';
import 'package:subdock/app/close_request_guard.dart';
import 'package:subdock/app/maintenance_operation.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/runtime/runtime_log_store.dart';
import 'package:subdock/settings/backend_env.dart';
import 'package:subdock/settings/backend_env_store.dart';
import 'package:subdock/settings/subdock_config.dart';
import 'package:subdock/settings/subdock_config_store.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_update_checker.dart';
import 'package:subdock/update/component_update_service.dart';
import 'package:subdock/update/github_release_client.dart';
import 'package:subdock/update/maintenance_attempt_store.dart';

import '../support/pump_app.dart';

void main() {
  testWidgets(
    'saved connection stays applied across Service and Manage until activated',
    (tester) async {
      final fixture = await _createFixture(
        tester,
        initialConfiguration: const SubDockConfig(
          backend: SubDockBackendConfig(
            apiHost: '127.0.0.1',
            apiPort: 3101,
            frontendBackendPath: '/old-api',
          ),
        ),
        startRuntime: true,
      );
      await _mountApp(tester, fixture);

      await _openPage(tester, 'settings');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-card-backend-config')),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(
        find.byKey(const ValueKey('settings-card-backend-config')),
      );
      await tester.pumpAndSettle();
      final hostField = find.descendant(
        of: find.byKey(const ValueKey('settings-backend-host-row')),
        matching: find.byType(TextField),
      );
      await tester.ensureVisible(hostField);
      await tester.enterText(hostField, '127.0.0.2');
      await tester.pump();

      final saveApplied = fixture.runtime.watchNextActivation();
      await tester.tap(find.byKey(const ValueKey('settings-child-save')));
      await _pumpUntil(tester, saveApplied);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings-runtime-pending-status')),
        findsOneWidget,
      );
      expect(
        find.text('Saved runtime configuration is waiting to be applied.'),
        findsOneWidget,
      );
      expect(fixture.coordinator.hasPendingConfiguration, isTrue);
      expect(
        fixture.runtime.appliedConfiguration!.environment[BackendEnvPolicy
            .host],
        '127.0.0.1',
      );
      final saved = await tester.runAsync(
        () => fixture.coordinator.runtimeConfigurationStore!.load(),
      );
      expect(saved!.configuration.configuration.backend.apiHost, '127.0.0.2');

      await tester.tap(find.byKey(const ValueKey('settings-back')));
      await tester.pumpAndSettle();
      await _openPage(tester, 'overview');
      final serviceEndpoint = find.byKey(
        const ValueKey('runtime-endpoint-value'),
      );
      await tester.ensureVisible(serviceEndpoint);
      expect(
        tester.widget<SelectableText>(serviceEndpoint).data,
        'http://127.0.0.1:3101/old-api',
      );

      await _openPage(tester, 'manage');
      final openInBrowser = find.byKey(
        const ValueKey('manage-open-fallback-browser'),
      );
      expect(openInBrowser, findsOneWidget);
      await tester.tap(openInBrowser);
      await tester.pumpAndSettle();
      expect(fixture.openedUris, hasLength(1));
      expect(fixture.openedUris.single.host, '127.0.0.1');
      expect(fixture.openedUris.single.port, 3101);
      expect(
        fixture.openedUris.single.queryParameters['api'],
        'http://127.0.0.1:3101/old-api',
      );

      await _openPage(tester, 'settings');
      final applySaved = find.byKey(
        const ValueKey('settings-apply-saved-runtime'),
      );
      await tester.scrollUntilVisible(
        applySaved,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      final newEntryStarted = fixture.runtime.watchNextStart();
      await tester.tap(applySaved);
      await _pumpUntil(tester, newEntryStarted);
      await tester.pumpAndSettle();

      expect(fixture.coordinator.hasPendingConfiguration, isFalse);
      expect(
        fixture.runtime.appliedConfiguration!.environment[BackendEnvPolicy
            .host],
        '127.0.0.2',
      );
      expect(
        fixture.coordinator.appliedRevision,
        fixture.coordinator.savedRevision,
      );
      final applied = await tester.runAsync(
        () => fixture.coordinator.runtimeConfigurationStore!.load(),
      );
      expect(applied!.configuration.configuration.backend.apiHost, '127.0.0.2');

      await _openPage(tester, 'overview');
      await tester.ensureVisible(serviceEndpoint);
      expect(
        tester.widget<SelectableText>(serviceEndpoint).data,
        'http://127.0.0.2:3101/old-api',
      );
      await _openPage(tester, 'manage');
      fixture.openedUris.clear();
      await tester.tap(openInBrowser);
      await tester.pumpAndSettle();
      expect(fixture.openedUris, hasLength(1));
      expect(fixture.openedUris.single.host, '127.0.0.2');
      expect(fixture.openedUris.single.port, 3101);
      expect(
        fixture.openedUris.single.queryParameters['api'],
        'http://127.0.0.2:3101/old-api',
      );
    },
  );

  testWidgets(
    'maintenance failure stays visible across pages and retries only remaining work',
    (tester) async {
      final updates = _CrossPageUpdates();
      final fixture = await _createFixture(
        tester,
        componentUpdates: updates,
        startRuntime: true,
      );
      await _mountApp(tester, fixture);

      final checkedBoth = updates.watchNextChecks();
      await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
      await tester.pump();
      await _pumpUntil(tester, checkedBoth);
      await tester.pumpAndSettle();
      final updateAll = find.byKey(const ValueKey('updates-update-all'));
      await tester.ensureVisible(updateAll);
      await tester.tap(updateAll);
      await tester.pumpAndSettle();
      final failureSaved = fixture.maintenanceStore.watchBackendFailure();
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await _pumpUntil(tester, failureSaved);
      await tester.pumpAndSettle();

      final resultPanel = find.byKey(
        const ValueKey('updates-maintenance-result'),
      );
      expect(resultPanel, findsOneWidget);
      expect(
        find.descendant(
          of: resultPanel,
          matching: find.text(
            'Component maintenance stopped before all selected changes completed.',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: resultPanel, matching: find.text('Completed')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: resultPanel, matching: find.text('Failed')),
        findsOneWidget,
      );
      expect(updates.updateCalls, [
        ComponentKind.frontend,
        ComponentKind.backend,
      ]);
      expect(fixture.runtime.currentState.status, RuntimeStatus.stopped);
      final failedAttempt = await tester.runAsync(
        fixture.maintenanceStore.load,
      );
      expect(failedAttempt!.completed, [ComponentKind.frontend]);
      expect(failedAttempt.failedKind, ComponentKind.backend);
      expect(failedAttempt.failureStage, MaintenanceFailureStage.updating);

      await _openPage(tester, 'overview');
      final overview = find.byKey(const ValueKey('overview-backend-hero'));
      expect(
        find.descendant(of: overview, matching: find.text('Backend Stopped')),
        findsOneWidget,
      );
      expect(
        (await tester.runAsync(fixture.maintenanceStore.load))!.completed,
        [ComponentKind.frontend],
      );

      await _openPage(tester, 'logs');
      final activity = find.byKey(const ValueKey('logs-maintenance-activity'));
      expect(activity, findsOneWidget);
      expect(
        find.descendant(
          of: activity,
          matching: find.textContaining('Maintenance failed'),
        ),
        findsOneWidget,
      );
      expect(
        (await tester.runAsync(fixture.maintenanceStore.load))!.failedKind,
        ComponentKind.backend,
      );

      await _openPage(tester, 'settings');
      final startBackend = find.byKey(
        const ValueKey('settings-apply-saved-runtime'),
      );
      await tester.scrollUntilVisible(
        startBackend,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<OutlinedButton>(startBackend).onPressed, isNotNull);
      expect(find.text('Start Backend'), findsOneWidget);
      expect(
        (await tester.runAsync(fixture.maintenanceStore.load))!.failedKind,
        ComponentKind.backend,
      );

      final checkedAgain = updates.watchNextChecks();
      await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
      await tester.pump();
      await _pumpUntil(tester, checkedAgain);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: resultPanel, matching: find.text('Completed')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: resultPanel, matching: find.text('Failed')),
        findsOneWidget,
      );
      expect(fixture.runtime.currentState.status, RuntimeStatus.stopped);
      expect(
        (await tester.runAsync(fixture.maintenanceStore.load))!.completed,
        [ComponentKind.frontend],
      );

      final operationCleared = fixture.maintenanceStore.watchNextClear();
      final retry = find.byKey(const ValueKey('updates-maintenance-retry'));
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await _pumpUntil(tester, operationCleared);
      await tester.pumpAndSettle();

      expect(updates.updateCalls, [
        ComponentKind.frontend,
        ComponentKind.backend,
        ComponentKind.backend,
      ]);
      expect(
        fixture.updates!.statuses[ComponentKind.backend]!.current,
        '2.1.0',
      );
      expect(fixture.runtime.currentState.status, RuntimeStatus.stopped);
      expect(await tester.runAsync(fixture.maintenanceStore.load), isNull);
      expect(
        find.descendant(of: resultPanel, matching: find.text('Failed')),
        findsNothing,
      );
      expect(
        find.descendant(of: resultPanel, matching: find.text('Completed')),
        findsNWidgets(2),
      );
    },
  );

  testWidgets(
    'history reading and exit cancellation survive navigation and live logs',
    (tester) async {
      final fixture = await _createFixture(tester, startRuntime: true);
      late String runId;
      await tester.runAsync(() async {
        runId = await fixture.logStore.beginRun();
        for (var index = 0; index < 205; index++) {
          await fixture.logStore.append(
            RuntimeLog(
              timestamp: DateTime.utc(2026, 1, 2).add(Duration(seconds: index)),
              source: RuntimeLogSource.stdout,
              message: 'cross-page-note-${index.toString().padLeft(3, '0')}',
            ),
          );
        }
        await fixture.logStore.finalize();
      });
      final closeGuard = CloseRequestGuard();
      await _mountApp(tester, fixture, closeRequestGuard: closeGuard);

      await _openPage(tester, 'logs');
      final runsLoaded = fixture.logStore.watchNextListRead();
      await tester.tap(find.text('History'));
      await _pumpUntil(tester, runsLoaded);
      await tester.pumpAndSettle();
      final runTile = find.byKey(ValueKey('history-run-$runId'));
      expect(runTile, findsOneWidget);
      final firstPageLoaded = fixture.logStore.watchNextRunRead();
      await tester.tap(runTile);
      await _pumpUntil(tester, firstPageLoaded);
      await tester.pumpAndSettle();

      final search = find.byKey(const ValueKey('logs-search'));
      final matchingPageLoaded = fixture.logStore.watchNextRunRead();
      await tester.enterText(search, 'cross-page-note');
      await _pumpUntil(tester, matchingPageLoaded);
      await tester.pumpAndSettle();
      final secondPageLoaded = fixture.logStore.watchNextRunRead();
      await tester.tap(find.text('Next'));
      await _pumpUntil(tester, secondPageLoaded);
      await tester.pumpAndSettle();
      expect(find.textContaining('cross-page-note-004'), findsOneWidget);
      expect(find.textContaining('cross-page-note-000'), findsOneWidget);
      expect(find.textContaining('cross-page-note-005'), findsNothing);

      await _openPage(tester, 'overview');
      fixture.runtime.emitLog(
        RuntimeLog(
          timestamp: DateTime.utc(2026, 1, 2, 1),
          source: RuntimeLogSource.stdout,
          message: 'live notification while reading history',
        ),
      );
      await tester.pump();
      await _openPage(tester, 'logs');

      expect(
        tester.widget<TextField>(search).controller!.text,
        'cross-page-note',
      );
      expect(find.byKey(const ValueKey('history-back')), findsOneWidget);
      expect(find.textContaining('cross-page-note-004'), findsOneWidget);
      expect(find.textContaining('cross-page-note-000'), findsOneWidget);
      expect(find.textContaining('cross-page-note-005'), findsNothing);
      expect(
        find.textContaining('live notification while reading history'),
        findsNothing,
      );

      final closeApproval = closeGuard.request();
      await tester.pumpAndSettle();
      expect(find.text('Exit SubDock?'), findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(await closeApproval, isFalse);
      expect(
        tester
            .widget<Offstage>(find.byKey(const ValueKey('page-logs')))
            .offstage,
        isFalse,
      );
      expect(find.byKey(const ValueKey('history-back')), findsOneWidget);
      expect(fixture.runtime.disposeCalls, 0);
    },
  );
}

Future<_CrossPageFixture> _createFixture(
  WidgetTester tester, {
  SubDockConfig? initialConfiguration,
  _CrossPageUpdates? componentUpdates,
  bool startRuntime = false,
}) async {
  final root = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('unified_desktop_experience_'),
  ))!;
  _CrossPageRuntime? runtime;
  AppCoordinator? coordinator;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    final currentCoordinator = coordinator;
    if (currentCoordinator == null) {
      await runtime?.dispose();
    } else {
      final disposal = currentCoordinator.dispose();
      await tester.pump();
      await disposal;
    }
    await tester.runAsync(() => root.delete(recursive: true));
  });

  final directories = (await tester.runAsync(
    () => RuntimeDirectories.fromBaseDirectory(root),
  ))!;
  final activeRuntime = _CrossPageRuntime();
  runtime = activeRuntime;
  final environmentStore = BackendEnvStore(directories);
  final configurationStore = SubDockConfigStore(directories);
  final logStore = _CrossPageLogStore(directories);
  final maintenanceStore = _ObservedMaintenanceAttemptStore(directories);
  await tester.runAsync(logStore.initialize);
  final coordinatorInstance = AppCoordinator(
    runtime: activeRuntime,
    environmentStore: environmentStore,
    configurationStore: configurationStore,
    componentUpdates: componentUpdates,
    maintenanceAttemptStore: maintenanceStore,
    logStore: logStore,
  );
  coordinator = coordinatorInstance;
  await tester.runAsync(() async {
    await coordinatorInstance.loadEnvironment();
    if (initialConfiguration != null) {
      await coordinatorInstance.saveRuntimeConfiguration(
        BackendEnvDocument.parse(''),
        initialConfiguration,
      );
    }
    if (startRuntime) await coordinatorInstance.start();
  });
  return _CrossPageFixture(
    coordinator: coordinatorInstance,
    runtime: activeRuntime,
    logStore: logStore,
    maintenanceStore: maintenanceStore,
    updates: componentUpdates,
  );
}

Future<void> _mountApp(
  WidgetTester tester,
  _CrossPageFixture fixture, {
  CloseRequestGuard? closeRequestGuard,
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await pumpApp(
    tester,
    SubDockApp(
      coordinator: fixture.coordinator,
      autoStart: false,
      enableWebView: false,
      locale: const Locale('en'),
      closeRequestGuard: closeRequestGuard,
      onOpenExternalUri: (uri) async {
        fixture.openedUris.add(uri);
        return true;
      },
    ),
  );
}

Future<void> _openPage(WidgetTester tester, String page) async {
  await tester.tap(find.byKey(ValueKey('nav-item-$page')));
  await tester.pumpAndSettle();
}

Future<void> _pumpUntil(WidgetTester tester, Completer<void> completion) async {
  for (var turn = 0; turn < 40 && !completion.isCompleted; turn++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(completion.isCompleted, isTrue);
}

class _CrossPageFixture {
  _CrossPageFixture({
    required this.coordinator,
    required this.runtime,
    required this.logStore,
    required this.maintenanceStore,
    required this.updates,
  });

  final AppCoordinator coordinator;
  final _CrossPageRuntime runtime;
  final _CrossPageLogStore logStore;
  final _ObservedMaintenanceAttemptStore maintenanceStore;
  final _CrossPageUpdates? updates;
  final openedUris = <Uri>[];
}

class _CrossPageRuntime extends BackendRuntime {
  final _logs = StreamController<RuntimeLog>.broadcast(sync: true);
  final _states = StreamController<RuntimeState>.broadcast(sync: true);
  EffectiveRuntimeConfig? _pending;
  EffectiveRuntimeConfig? _applied;
  RuntimeState _currentState = RuntimeState(
    status: RuntimeStatus.stopped,
    changedAt: DateTime.now(),
  );
  Completer<void>? _nextActivation;
  Completer<void>? _nextStart;
  var disposeCalls = 0;

  @override
  RuntimeState get currentState => _currentState;

  @override
  EffectiveRuntimeConfig? get appliedConfiguration => _applied;

  @override
  Uri get endpoint {
    final environment = _applied?.environment ?? const <String, String>{};
    return Uri(
      scheme: 'http',
      host:
          environment[BackendEnvPolicy.host] ??
          InternetAddress.loopbackIPv4.address,
      port: int.tryParse(environment[BackendEnvPolicy.port] ?? '') ?? 3001,
    );
  }

  @override
  Stream<RuntimeLog> get logs => _logs.stream;

  @override
  Stream<RuntimeState> get state => _states.stream;

  @override
  Future<void> activateConfiguration(
    EffectiveRuntimeConfig configuration,
  ) async {
    _pending = configuration;
    final activation = _nextActivation;
    _nextActivation = null;
    activation?.complete();
  }

  @override
  Future<void> activateUserEnvironment(Map<String, String> environment) async {}

  @override
  Future<BackendInfo> info() async => BackendInfo(
    nodeVersion: '24.15.0',
    backendVersion: '2.38.4',
    port: endpoint.port,
  );

  @override
  Future<bool> isHealthy() async => true;

  @override
  Future<void> start() async {
    _applied = _pending;
    _publish(RuntimeStatus.running);
    final start = _nextStart;
    _nextStart = null;
    start?.complete();
  }

  @override
  Future<void> stop() async => _publish(RuntimeStatus.stopped);

  @override
  Future<void> restart() async {
    await stop();
    await start();
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _logs.close();
    await _states.close();
  }

  void emitLog(RuntimeLog log) => _logs.add(log);

  Completer<void> watchNextActivation() {
    final next = Completer<void>();
    _nextActivation = next;
    return next;
  }

  Completer<void> watchNextStart() {
    final next = Completer<void>();
    _nextStart = next;
    return next;
  }

  void _publish(RuntimeStatus status) {
    _currentState = RuntimeState(status: status, changedAt: DateTime.now());
    _states.add(_currentState);
  }
}

class _CrossPageUpdates implements ComponentUpdateOperations {
  final statuses = <ComponentKind, ComponentVersionStatus>{
    ComponentKind.frontend: const ComponentVersionStatus(current: '1.0.0'),
    ComponentKind.backend: const ComponentVersionStatus(current: '2.0.0'),
  };
  final _releases = <ComponentKind, ComponentUpdate>{
    ComponentKind.frontend: ComponentUpdate(
      kind: ComponentKind.frontend,
      currentVersion: '1.0.0',
      availableVersion: '1.1.0',
      release: GithubRelease(
        version: '1.1.0',
        releaseUri: Uri.parse('https://example.invalid/frontend'),
        assets: const [],
      ),
    ),
    ComponentKind.backend: ComponentUpdate(
      kind: ComponentKind.backend,
      currentVersion: '2.0.0',
      availableVersion: '2.1.0',
      release: GithubRelease(
        version: '2.1.0',
        releaseUri: Uri.parse('https://example.invalid/backend'),
        assets: const [],
      ),
    ),
  };
  final updateCalls = <ComponentKind>[];
  Completer<void>? _bothChecks;
  final _checkedKinds = <ComponentKind>{};
  var _failBackendOnce = true;

  @override
  Future<ComponentUpdate> check(ComponentKind kind) async {
    final checks = _bothChecks;
    if (checks != null) {
      _checkedKinds.add(kind);
      if (_checkedKinds.length == ComponentKind.values.length) {
        _bothChecks = null;
        _checkedKinds.clear();
        checks.complete();
      }
    }
    return _releases[kind]!;
  }

  @override
  Future<ComponentVersionStatus> status(ComponentKind kind) async =>
      statuses[kind]!;

  @override
  Future<void> update(ComponentUpdate update) async {
    updateCalls.add(update.kind);
    if (update.kind == ComponentKind.backend && _failBackendOnce) {
      _failBackendOnce = false;
      throw StateError('backend update failed');
    }
    statuses[update.kind] = ComponentVersionStatus(
      current: update.availableVersion,
      previous: update.currentVersion,
    );
  }

  @override
  Future<ComponentRollbackResult> rollback(ComponentKind kind) =>
      Future<ComponentRollbackResult>.error(
        UnsupportedError('Rollback is not part of this scenario'),
      );

  Completer<void> watchNextChecks() {
    final checks = Completer<void>();
    _checkedKinds.clear();
    _bothChecks = checks;
    return checks;
  }
}

class _ObservedMaintenanceAttemptStore extends MaintenanceAttemptStore {
  _ObservedMaintenanceAttemptStore(super.directories);

  Completer<void>? _backendFailureSaved;
  Completer<void>? _nextClear;

  Completer<void> watchBackendFailure() {
    final saved = Completer<void>();
    _backendFailureSaved = saved;
    return saved;
  }

  Completer<void> watchNextClear() {
    final cleared = Completer<void>();
    _nextClear = cleared;
    return cleared;
  }

  @override
  Future<void> save(MaintenanceAttempt attempt) async {
    await super.save(attempt);
    final failure = _backendFailureSaved;
    if (failure != null &&
        attempt.phase == MaintenancePhase.failed &&
        attempt.failedKind == ComponentKind.backend &&
        attempt.failureStage == MaintenanceFailureStage.updating &&
        attempt.completed.contains(ComponentKind.frontend)) {
      _backendFailureSaved = null;
      failure.complete();
    }
  }

  @override
  Future<void> clear() async {
    await super.clear();
    final cleared = _nextClear;
    _nextClear = null;
    cleared?.complete();
  }
}

class _CrossPageLogStore extends RuntimeLogStore {
  _CrossPageLogStore(super.directories);

  Completer<void>? _nextListRead;
  Completer<void>? _nextRunRead;

  Completer<void> watchNextListRead() {
    final read = Completer<void>();
    _nextListRead = read;
    return read;
  }

  Completer<void> watchNextRunRead() {
    final read = Completer<void>();
    _nextRunRead = read;
    return read;
  }

  @override
  Future<List<RuntimeLogRun>> listRuns() async {
    final read = _nextListRead;
    _nextListRead = null;
    try {
      return await super.listRuns();
    } finally {
      read?.complete();
    }
  }

  @override
  Stream<RuntimeLog> readRunStream(String id, {bool reverse = false}) async* {
    final read = _nextRunRead;
    _nextRunRead = null;
    try {
      await for (final log in super.readRunStream(id, reverse: reverse)) {
        yield log;
      }
    } finally {
      read?.complete();
    }
  }
}

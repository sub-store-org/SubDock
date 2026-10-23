import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart'
    show ShadButton, ShadIconButton, ShadInput, ShadToast;
import 'package:subdock/app/app.dart';
import 'package:subdock/app/app_coordinator.dart';
import 'package:subdock/app/close_request_guard.dart';
import 'package:subdock/app/maintenance_operation.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/runtime/runtime_log_store.dart';
import 'package:subdock/settings/backend_env.dart';
import 'package:subdock/settings/backend_env_store.dart';
import 'package:subdock/settings/config_error.dart';
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
        matching: find.byType(ShadInput),
      );
      await tester.ensureVisible(hostField);
      await tester.enterText(hostField, '127.0.0.2');
      await tester.pump();

      final saveConfiguration = find.byKey(
        const ValueKey('settings-child-save'),
      );
      await tester.ensureVisible(saveConfiguration);
      await tester.pumpAndSettle();
      final saveApplied = fixture.runtime.watchNextActivation();
      await tester.tap(saveConfiguration);
      await _pumpUntil(tester, saveApplied);
      await tester.pumpAndSettle();

      final pendingStatus = find.byKey(
        const ValueKey('settings-runtime-pending-status'),
      );
      expect(pendingStatus, findsOneWidget);
      expect(
        find.descendant(
          of: pendingStatus,
          matching: find.text(
            'Saved runtime configuration is waiting to be applied.',
          ),
        ),
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

      final settingsBack = find.byKey(const ValueKey('settings-back'));
      await tester.ensureVisible(settingsBack);
      await tester.pumpAndSettle();
      await tester.tap(settingsBack);
      await tester.pumpAndSettle();
      await _openPage(tester, 'overview');
      final serviceEndpoint = find.byKey(
        const ValueKey('runtime-endpoint-value'),
      );
      await tester.ensureVisible(serviceEndpoint);
      expect(
        find.byKey(const ValueKey('overview-pending-configuration')),
        findsOneWidget,
      );
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
      final backendConfiguration = find.byKey(
        const ValueKey('settings-card-backend-config'),
      );
      await tester.ensureVisible(backendConfiguration);
      await tester.pumpAndSettle();
      await tester.tap(backendConfiguration);
      await tester.pumpAndSettle();
      final applySaved = find.byKey(
        const ValueKey('settings-apply-saved-runtime'),
      );
      await tester.scrollUntilVisible(
        applySaved,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(applySaved);
      await tester.pumpAndSettle();
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
        find.byKey(const ValueKey('overview-pending-configuration')),
        findsNothing,
      );
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
    'retained Service page shows the committed component version after maintenance',
    (tester) async {
      final updates = _CrossPageUpdates();
      final fixture = await _createFixture(tester, componentUpdates: updates);
      await _mountApp(tester, fixture);
      final checkedBoth = updates.watchNextChecks();
      await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
      await tester.pump();
      await _pumpUntil(tester, checkedBoth);
      await tester.pumpAndSettle();

      final updateFrontend = find.byKey(
        const ValueKey('component-update-action-frontend'),
      );
      await tester.ensureVisible(updateFrontend);
      await tester.tap(updateFrontend);
      await tester.pumpAndSettle();
      final releaseUpdate = updates.holdNextUpdate();
      final updateEntered = updates.updateEntered;
      final maintenanceCompleted = Completer<void>();
      void observeCompletion() {
        final operation = fixture.coordinator.maintenanceOperation;
        if (operation?.phase == MaintenancePhase.completed &&
            !maintenanceCompleted.isCompleted) {
          maintenanceCompleted.complete();
        }
      }

      fixture.coordinator.maintenanceChanges.addListener(observeCompletion);
      try {
        await tester.tap(find.widgetWithText(ShadButton, 'Continue'));
        await tester.pump();
        await _pumpUntil(tester, updateEntered);
        await _openPage(tester, 'overview');
        final versionRow = find.byKey(
          const ValueKey('overview-component-frontend'),
        );
        expect(versionRow, findsOneWidget);
        final committedVersion = find.descendant(
          of: versionRow,
          matching: find.textContaining('1.1.0'),
        );
        expect(committedVersion, findsNothing);
        releaseUpdate.complete();
        await _pumpUntil(tester, maintenanceCompleted);
        await tester.pumpAndSettle();
        expect(committedVersion, findsOneWidget);
      } finally {
        if (!releaseUpdate.isCompleted) releaseUpdate.complete();
        try {
          if (updateEntered.isCompleted && !maintenanceCompleted.isCompleted) {
            await _pumpUntil(tester, maintenanceCompleted);
          }
        } finally {
          fixture.coordinator.maintenanceChanges.removeListener(
            observeCompletion,
          );
        }
      }
    },
  );

  testWidgets(
    'Service actions and copied runtime values report actual completion',
    (tester) async {
      final fixture = await _createFixture(tester);
      await _mountApp(tester, fixture);
      final toast = find.byType(ShadToast);
      expect(toast, findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('nav-item-overview')),
          matching: find.text('Service'),
        ),
        findsOneWidget,
      );
      Future<void> closeFeedback() async {
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(of: toast, matching: find.byType(ShadIconButton)),
        );
        await tester.pumpAndSettle();
        expect(toast, findsNothing);
      }

      final started = fixture.runtime.watchNextStart();
      await tester.tap(find.widgetWithText(ShadButton, 'Start'));
      await _pumpUntil(
        tester,
        started,
        rendered: () => toast.evaluate().isNotEmpty,
      );
      expect(fixture.runtime.currentState.status, RuntimeStatus.running);
      expect(fixture.runtime.startCalls, 1);
      expect(
        find.widgetWithText(ShadButton, 'Enter Sub-Store'),
        findsOneWidget,
      );
      await _openPage(tester, 'settings');
      expect(toast, findsNothing);
      await _openPage(tester, 'overview');
      expect(toast, findsNothing);

      final copied = Completer<void>();
      Completer<void>? copyReply;
      Completer<void>? copyEntered;
      String? clipboardText;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String;
          if (!copied.isCompleted) copied.complete();
          if (copyEntered != null && !copyEntered.isCompleted) {
            copyEntered.complete();
          }
          if (copyReply != null) await copyReply.future;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final endpoint = find.byKey(const ValueKey('runtime-endpoint-value'));
      final copy = find.byKey(const ValueKey('runtime-copy-Backend'));
      await tester.ensureVisible(copy);
      final displayedEndpoint = tester.widget<SelectableText>(endpoint).data;
      await tester.tap(copy);
      await _pumpUntil(
        tester,
        copied,
        rendered: () => toast.evaluate().isNotEmpty,
      );
      expect(clipboardText, displayedEndpoint);
      await closeFeedback();

      final releaseCopy = Completer<void>();
      final enteredCopy = Completer<void>();
      copyReply = releaseCopy;
      copyEntered = enteredCopy;
      try {
        await tester.tap(copy);
        await _pumpUntil(tester, enteredCopy);
        await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
        releaseCopy.complete();
        // Complete the platform reply before rendering the navigation frame.
        await tester.idle();
        await tester.pumpAndSettle();
        expect(toast, findsNothing);
        await _openPage(tester, 'overview');
        expect(toast, findsNothing);
      } finally {
        if (!releaseCopy.isCompleted) releaseCopy.complete();
        await tester.idle();
        copyReply = null;
        copyEntered = null;
      }

      final stop = find.widgetWithText(ShadButton, 'Stop');
      await tester.ensureVisible(stop);
      await tester.tap(stop);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ShadButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(fixture.runtime.currentState.status, RuntimeStatus.running);
      expect(toast, findsNothing);

      final stopped = Completer<void>();
      final subscription = fixture.runtime.state.listen((state) {
        if (state.status == RuntimeStatus.stopped && !stopped.isCompleted) {
          stopped.complete();
        }
      });
      try {
        await tester.tap(stop);
        await tester.pumpAndSettle();
        await tester.tap(stop.last);
        await _pumpUntil(
          tester,
          stopped,
          rendered: () => toast.evaluate().isNotEmpty,
        );
        expect(fixture.runtime.currentState.status, RuntimeStatus.stopped);
        expect(fixture.runtime.startCalls, 1);
        await closeFeedback();
      } finally {
        await tester.runAsync(() => subscription.cancel());
      }
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
      await tester.tap(find.widgetWithText(ShadButton, 'Continue'));
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
      expect(find.byType(ShadToast), findsNothing);
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
      final overview = find.byKey(const ValueKey('overview-service-card'));
      expect(
        find.descendant(
          of: overview,
          matching: find.text('Local service has not started'),
        ),
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
      final backendConfiguration = find.byKey(
        const ValueKey('settings-card-backend-config'),
      );
      await tester.ensureVisible(backendConfiguration);
      await tester.pumpAndSettle();
      await tester.tap(backendConfiguration);
      await tester.pumpAndSettle();
      final startBackend = find.byKey(
        const ValueKey('settings-apply-saved-runtime'),
      );
      await tester.ensureVisible(startBackend);
      await tester.pumpAndSettle();
      final startBackendButton = tester.widget<ShadButton>(startBackend);
      expect(startBackendButton.enabled, isTrue);
      expect(startBackendButton.onPressed, isNotNull);
      expect(
        find.descendant(of: startBackend, matching: find.text('Start Backend')),
        findsOneWidget,
      );
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

  for (final cause in [
    'desktop startup component recovery blocker',
    'temporary maintenance record read failure',
  ]) {
    testWidgets(
      'recovery revalidation handles $cause without starting or maintaining runtime',
      (tester) async {
        final recovery = Completer<void>();
        var recoveryCalls = 0;
        final updates = _CrossPageUpdates();
        final fixture = await _createFixture(
          tester,
          componentUpdates: updates,
          startupBlocker: cause.startsWith('desktop')
              ? const AppConfigError(
                  AppConfigErrorCode.componentRecoveryFailed,
                  detail: 'startup recovery failed',
                )
              : null,
          componentRecovery: () {
            recoveryCalls++;
            return recovery.future;
          },
        );
        if (cause.startsWith('temporary')) {
          fixture.maintenanceStore.failNextLoad = true;
          await tester.runAsync(fixture.coordinator.restoreMaintenanceAttempt);
        }
        final revalidated = Completer<void>();
        void observeRevalidation() {
          if (fixture.coordinator.startupBlocker == null &&
              fixture.coordinator.maintenanceRecoveryError == null &&
              !revalidated.isCompleted) {
            revalidated.complete();
          }
        }

        fixture.coordinator.configurationChanges.addListener(
          observeRevalidation,
        );
        addTearDown(
          () => fixture.coordinator.configurationChanges.removeListener(
            observeRevalidation,
          ),
        );
        await _mountApp(tester, fixture);
        final checked = fixture.updates!.watchNextChecks();
        await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
        await tester.pump();
        await _pumpUntil(tester, checked);
        await tester.pumpAndSettle();

        final revalidate = find.byKey(
          const ValueKey('updates-revalidate-recovery'),
        );
        expect(revalidate, findsOneWidget);
        final updateAll = find.byKey(const ValueKey('updates-update-all'));
        final frontendUpdate = find.byKey(
          const ValueKey('component-update-action-frontend'),
        );
        final frontendRecheck = find.byKey(
          const ValueKey('component-update-recheck-frontend'),
        );
        expect(tester.widget<ShadButton>(updateAll).enabled, isFalse);
        expect(tester.widget<ShadButton>(frontendUpdate).enabled, isFalse);
        expect(tester.widget<ShadButton>(frontendRecheck).enabled, isTrue);
        await tester.ensureVisible(revalidate);
        try {
          await tester.tap(revalidate);
          await tester.pump();
          expect(recoveryCalls, 1);
          expect(tester.widget<ShadButton>(revalidate).enabled, isFalse);
          expect(fixture.updates!.updateCalls, isEmpty);
          expect(fixture.runtime.startCalls, 0);
        } finally {
          if (!recovery.isCompleted) recovery.complete();
        }
        await _pumpUntil(tester, revalidated);
        await tester.pumpAndSettle();
        expect(fixture.coordinator.startupBlocker, isNull);
        expect(fixture.coordinator.maintenanceRecoveryError, isNull);
        expect(fixture.runtime.currentState.status, RuntimeStatus.stopped);
        expect(fixture.runtime.startCalls, 0);
        expect(fixture.updates!.updateCalls, isEmpty);
        expect(recoveryCalls, 1);
      },
    );
  }

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
      await tester.tap(find.byKey(ValueKey('history-view-$runId')));
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
        tester.widget<ShadInput>(search).controller!.text,
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
  Object? startupBlocker,
  Future<void> Function()? componentRecovery,
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
    startupBlocker: startupBlocker,
    componentRecovery: componentRecovery,
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

Future<void> _pumpUntil(
  WidgetTester tester,
  Completer<void> completion, {
  bool Function()? rendered,
}) async {
  for (
    var turn = 0;
    turn < 40 && (!completion.isCompleted || !(rendered?.call() ?? true));
    turn++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(completion.isCompleted, isTrue);
  if (rendered != null) expect(rendered(), isTrue);
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
  var startCalls = 0;

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
    startCalls++;
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
  Completer<void>? _updateGate;
  Completer<void>? _updateEntered;

  Completer<void> holdNextUpdate() {
    _updateGate = Completer<void>();
    _updateEntered = Completer<void>();
    return _updateGate!;
  }

  Completer<void> get updateEntered => _updateEntered!;

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
  Future<ComponentVersionStatus> status(ComponentKind kind) async {
    return statuses[kind]!;
  }

  @override
  Future<void> update(ComponentUpdate update) async {
    updateCalls.add(update.kind);
    final gate = _updateGate;
    if (update.kind == ComponentKind.frontend && gate != null) {
      _updateEntered?.complete();
      await gate.future;
      _updateGate = null;
    }
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
  bool failNextLoad = false;

  @override
  Future<MaintenanceAttempt?> load() async {
    if (failNextLoad) {
      failNextLoad = false;
      throw StateError('temporary recovery read failure');
    }
    return super.load();
  }

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

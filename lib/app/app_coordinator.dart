import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../runtime/backend_runtime.dart';
import '../runtime/runtime_log_store.dart';
import 'maintenance_operation.dart';
import '../settings/backend_env.dart';
import '../settings/backend_env_store.dart';
import '../settings/config_error.dart';
import '../settings/runtime_configuration_store.dart';
import '../settings/subdock_config.dart';
import '../settings/subdock_config_store.dart';
import '../update/component_metadata_store.dart';
import '../update/component_update_checker.dart';
import '../update/component_update_service.dart';
import '../update/maintenance_attempt_store.dart';

class AppCoordinator {
  AppCoordinator({
    required this.runtime,
    required this.environmentStore,
    this.configurationStore,
    this._startupBlocker,
    this._componentRecovery,
    this.componentUpdates,
    MaintenanceAttemptStore? maintenanceAttemptStore,
    this.logStore,
    Object? initialLogRecoveryError,
    RuntimeConfigurationStore? runtimeConfigurationStore,
  }) : maintenanceAttemptStore =
           maintenanceAttemptStore ??
           MaintenanceAttemptStore(environmentStore.directories),
       runtimeConfigurationStore =
           runtimeConfigurationStore ??
           (configurationStore == null
               ? null
               : RuntimeConfigurationStore(
                   directories: environmentStore.directories,
                   environmentStore: environmentStore,
                   configurationStore: configurationStore,
                 )),
       _logRecoveryError = initialLogRecoveryError;

  final BackendRuntime runtime;
  final BackendEnvStore environmentStore;
  final SubDockConfigStore? configurationStore;

  /// The paired `subdock.json`／`backend.env` boundary.
  ///
  /// Null when no structured config store is configured, in which case only
  /// the raw ENV keeps its previous single-file behavior.
  final RuntimeConfigurationStore? runtimeConfigurationStore;
  Object? _startupBlocker;
  final Future<void> Function()? _componentRecovery;
  Object? _logRecoveryError;

  Object? get startupBlocker => _startupBlocker;
  Object? get logRecoveryError => _logRecoveryError;
  Object? get maintenanceRecoveryError => _maintenanceRecoveryError;
  MaintenanceOperation? get maintenanceOperation => _maintenanceOperation;
  List<MaintenanceActivity> get maintenanceActivity =>
      List.unmodifiable(_maintenanceActivity);
  Map<ComponentKind, ComponentVersionStatus> get componentStatuses =>
      Map.unmodifiable(_componentStatuses);
  Map<ComponentKind, ComponentUpdate> get componentChecks =>
      Map.unmodifiable(_componentChecks);
  Set<ComponentKind> get componentsChecking =>
      Set.unmodifiable(_checksInProgress);
  Map<ComponentKind, Object> get componentStatusErrors =>
      Map.unmodifiable(_componentStatusErrors);
  Map<ComponentKind, Object> get componentCheckErrors =>
      Map.unmodifiable(_componentCheckErrors);
  final ComponentUpdateOperations? componentUpdates;
  final MaintenanceAttemptStore maintenanceAttemptStore;
  final RuntimeLogStore? logStore;
  BackendEnvDocument _environment = BackendEnvDocument.parse('');
  SubDockConfig _configuration = const SubDockConfig();
  AppConfigError? _configurationError;
  AppConfigError? _runtimeConfigurationError;
  EffectiveRuntimeConfig? _savedEffective;
  EffectiveRuntimeConfig? _runtimePending;
  var _savedRevision = 0;
  var _appliedRevision = 0;
  var _cleanupPending = false;
  var _shutdownRequested = false;
  var _disposed = false;
  Future<void>? _disposal;
  var _rollbackPreflightCount = 0;
  Completer<void>? _rollbackPreflightsDrained;
  var _maintenanceReserved = false;
  Object? _maintenanceRecoveryError;
  MaintenanceOperation? _maintenanceOperation;
  Future<void> _operation = Future<void>.value();
  final _componentStatuses = <ComponentKind, ComponentVersionStatus>{};
  final _componentChecks = <ComponentKind, ComponentUpdate>{};
  final _componentStatusErrors = <ComponentKind, Object>{};
  final _componentCheckErrors = <ComponentKind, Object>{};
  final _checksInProgress = <ComponentKind>{};
  final _maintenanceActivity = <MaintenanceActivity>[];

  /// Ticks whenever a shared saved／applied／error snapshot changes.
  ///
  /// Pages read the getters and listen here instead of caching a second copy
  /// of the applied entry or component state.
  final configurationChanges = ValueNotifier<int>(0);
  final maintenanceChanges = ValueNotifier<int>(0);

  void _notifyConfigurationChanged() {
    if (_disposed) return;
    configurationChanges.value = configurationChanges.value + 1;
  }

  BackendEnvDocument get environment => _environment;
  SubDockConfig get configuration => _configuration;
  AppConfigError? get configurationError => _configurationError;

  /// The effective environment of the saved pair: what a launch would use.
  Map<String, String> get effectiveEnvironment => UnmodifiableMapView(
    _savedEffective?.environment ?? const <String, String>{},
  );

  /// Advances only after the pair is committed on disk.
  int get savedRevision => _savedRevision;

  /// Advances only after a start of [savedRevision] became healthy.
  int get appliedRevision => _appliedRevision;

  /// The saved effective configuration a launch would use right now.
  EffectiveRuntimeConfig? get savedConfiguration => _savedEffective;

  /// True when a running service does not use the saved pair yet.
  ///
  /// The runtime's applied snapshot is the single source of truth, so a saved
  /// pair never reads as applied before a successful start, and a stopped
  /// service reports nothing pending.
  bool get hasPendingConfiguration {
    final applied = runtime.appliedConfiguration;
    if (applied == null) return false;
    return !_sameEffective(_savedEffective ?? applied, applied);
  }

  /// True when the pair is saved but its recovery record could not be cleared.
  bool get cleanupPending => _cleanupPending;

  /// Set when startup could not resolve the paired files safely.
  ///
  /// A corrupt recovery record or a suspected external edit blocks here, so
  /// callers suppress automatic start instead of consuming a half set.
  AppConfigError? get runtimeConfigurationError => _runtimeConfigurationError;

  /// Compares the effective environment and HTTP-META flag.
  static bool _sameEffective(
    EffectiveRuntimeConfig saved,
    EffectiveRuntimeConfig? other,
  ) =>
      other != null &&
      saved.httpMetaEnabled == other.httpMetaEnabled &&
      mapEquals(saved.environment, other.environment);

  List<BackendEnvIssue> get environmentIssues =>
      BackendEnvPolicy.validate(_environment);

  bool get canOpenWebUi =>
      environmentIssues.isEmpty &&
      (_effectiveValue(BackendEnvPolicy.frontendBackendPath) ?? '/').startsWith(
        '/',
      );

  Uri get webUiUri {
    final frontend = _frontendOrigin.replace(path: '/');
    return frontend.replace(queryParameters: {'api': webUiApiUri.toString()});
  }

  Uri get webUiApiUri => runtime.endpoint.replace(
    path: _effectiveValue(BackendEnvPolicy.frontendBackendPath) ?? '/',
  );

  /// The frontend entry bound to the configuration actually running now.
  /// Unlike [webUiUri], this never falls back to a newly saved configuration.
  /// Null until a runtime has successfully applied a launch configuration.
  Uri? get appliedWebUiUri {
    final applied = runtime.appliedConfiguration;
    if (applied == null) return null;
    final environment = applied.environment;
    final frontendOrigin = environment[BackendEnvPolicy.merge] == 'false'
        ? runtime.endpoint.replace(
            host:
                environment[BackendEnvPolicy.frontendHost] ??
                runtime.endpoint.host,
            port:
                int.tryParse(
                  environment[BackendEnvPolicy.frontendPort] ?? '',
                ) ??
                3001,
          )
        : runtime.endpoint;
    final apiUri = runtime.endpoint.replace(
      path: environment[BackendEnvPolicy.frontendBackendPath] ?? '/',
    );
    return frontendOrigin
        .replace(path: '/')
        .replace(queryParameters: {'api': apiUri.toString()});
  }

  /// The API route paired with [appliedWebUiUri] for the active process.
  Uri? get appliedWebUiApiUri {
    final applied = runtime.appliedConfiguration;
    if (applied == null) return null;
    return runtime.endpoint.replace(
      path: applied.environment[BackendEnvPolicy.frontendBackendPath] ?? '/',
    );
  }

  Uri get _frontendOrigin {
    if (_effectiveValue(BackendEnvPolicy.merge) != 'false') {
      return runtime.endpoint;
    }
    final port = int.tryParse(
      _effectiveValue(BackendEnvPolicy.frontendPort) ?? '',
    );
    return runtime.endpoint.replace(
      host:
          _effectiveValue(BackendEnvPolicy.frontendHost) ??
          runtime.endpoint.host,
      port: port != null && port >= 1 && port <= 65535 ? port : 3001,
    );
  }

  Future<void> loadEnvironment() {
    _ensureExitIsNotPending();
    return _serialize(() async {
      final pairStore = runtimeConfigurationStore;
      if (pairStore != null) {
        await _loadPaired(pairStore);
        return;
      }
      final document = await environmentStore.load();
      SubDockConfig configuration;
      try {
        configuration = await _loadConfiguration();
        _configurationError = null;
      } on AppConfigError catch (error) {
        _configuration = const SubDockConfig();
        _configurationError = error;
        rethrow;
      }
      final firstRunConfiguration = await _initializeBackendPath(configuration);
      configuration = firstRunConfiguration;
      final issues = BackendEnvPolicy.validate(document);
      if (issues.isNotEmpty) {
        _environment = document;
        throw _environmentError(issues.first);
      }
      await _adoptSaved(document, configuration);
    });
  }

  /// Loads the pair through its recovery owner, then generates the first-run
  /// backend path as part of the same committed pair.
  Future<void> _loadPaired(RuntimeConfigurationStore store) async {
    RuntimeConfigurationLoad load;
    try {
      load = await store.load();
    } on AppConfigError catch (error) {
      _runtimeConfigurationError = error;
      _configuration = const SubDockConfig();
      _configurationError = error;
      rethrow;
    }
    var document = load.configuration.environment;
    var configuration = load.configuration.configuration;
    if (configuration.backend.frontendBackendPath == null) {
      configuration = configuration.copyWith(
        backend: configuration.backend.copyWith(
          frontendBackendPath: randomBackendPath(),
        ),
      );
      await store.save(
        RuntimeConfiguration(
          environment: document,
          configuration: configuration,
        ),
      );
    }
    final issues = BackendEnvPolicy.validate(document);
    if (issues.isNotEmpty) {
      _environment = document;
      _configuration = configuration;
      throw _environmentError(issues.first);
    }
    _runtimeConfigurationError = null;
    _configurationError = null;
    _cleanupPending = await store.recoveryFile.exists();
    await _adoptSaved(document, configuration);
  }

  /// 首次配置时生成默认后端路径并持久化。
  ///
  /// UI 显示的 `frontendBackendPath` 应来自 config：当 config 尚未设置该字段
  /// 且 config store 可用时，生成随机路径（`randomBackendPath`）写入 config，
  /// 之后 `EffectiveRuntimeConfig.resolve` 从 config 取值，运行时不再用 `/` 兜底。
  Future<SubDockConfig> _initializeBackendPath(
    SubDockConfig configuration,
  ) async {
    final store = configurationStore;
    if (store == null) return configuration;
    if (configuration.backend.frontendBackendPath != null) return configuration;
    final initialized = configuration.copyWith(
      backend: configuration.backend.copyWith(
        frontendBackendPath: randomBackendPath(),
      ),
    );
    await store.save(initialized);
    return initialized;
  }

  Future<void> saveEnvironment(BackendEnvDocument document) {
    _ensureNoMaintenanceOperation();
    return _serialize(() async {
      final issues = BackendEnvPolicy.validate(document);
      if (issues.isNotEmpty) throw _environmentError(issues.first);
      await _savePair(document, _configuration);
    });
  }

  Future<void> saveConfiguration(SubDockConfig configuration) {
    _ensureNoMaintenanceOperation();
    return _serialize(() async {
      SubDockConfig.fromJson(configuration.toJson());
      if (configurationStore == null) {
        throw const AppConfigError(AppConfigErrorCode.configStoreDisabled);
      }
      await _savePair(_environment, configuration);
    });
  }

  /// Saves one connection and ENV candidate through the paired store.
  Future<void> saveRuntimeConfiguration(
    BackendEnvDocument environment,
    SubDockConfig configuration,
  ) {
    _ensureNoMaintenanceOperation();
    return _serialize(() async {
      final issues = BackendEnvPolicy.validate(environment);
      if (issues.isNotEmpty) throw _environmentError(issues.first);
      SubDockConfig.fromJson(configuration.toJson());
      if (configurationStore == null) {
        throw const AppConfigError(AppConfigErrorCode.configStoreDisabled);
      }
      await _savePair(environment, configuration);
    });
  }

  Future<void> resetConfiguration() {
    _ensureNoMaintenanceOperation();
    return _serialize(() async {
      if (runtimeConfigurationStore == null) {
        throw const AppConfigError(AppConfigErrorCode.configStoreDisabled);
      }
      await _savePair(_environment, const SubDockConfig());
    });
  }

  /// Commits both files as one pair and advances the saved revision.
  ///
  /// The saved snapshot and the runtime's next-launch snapshot move together;
  /// a running process keeps its frozen launch snapshot until the engine's
  /// successful-stop gate replaces it.
  Future<void> _savePair(
    BackendEnvDocument environment,
    SubDockConfig configuration,
  ) async {
    final store = runtimeConfigurationStore;
    if (store != null) {
      final commit = await store.save(
        RuntimeConfiguration(
          environment: environment,
          configuration: configuration,
        ),
      );
      _cleanupPending = commit.cleanupPending;
    } else {
      await environmentStore.save(environment);
    }
    await _adoptSaved(environment, configuration);
  }

  /// Adopts a committed pair as the saved snapshot and syncs the runtime's
  /// pending configuration for the next launch.
  Future<void> _adoptSaved(
    BackendEnvDocument environment,
    SubDockConfig configuration,
  ) async {
    final effective = _resolve(environment, configuration);
    _environment = environment;
    _configuration = configuration;
    _configurationError = null;
    _runtimeConfigurationError = null;
    _savedEffective = effective;
    _savedRevision++;
    await _syncRuntimePending(effective);
    _notifyConfigurationChanged();
  }

  Future<void> start() {
    _ensureNoMaintenanceOperation();
    return _serialize(() async {
      _ensureStartupAllowed();
      if (environmentIssues.isNotEmpty) {
        throw _environmentError(environmentIssues.first);
      }
      await _launchSaved();
    });
  }

  /// Applies the saved configuration to the service.
  ///
  /// A running service is stopped first and only restarted once that stop
  /// succeeds; a stopped service stays stopped so the explicit start action
  /// applies the saved configuration. A failed stop leaves the old entry in
  /// place and reports the saved pair as still pending.
  Future<void> applyConfiguration() {
    _ensureNoMaintenanceOperation();
    return _serialize(() async {
      _ensureStartupAllowed();
      await _recoverConfigurationIfNeeded();
      if (environmentIssues.isNotEmpty) {
        throw _environmentError(environmentIssues.first);
      }
      final blocked = _runtimeConfigurationError;
      if (blocked != null) throw blocked;
      final saved = _savedEffective;
      if (saved != null) await _syncRuntimePending(saved);
      if (runtime.currentState.status == RuntimeStatus.stopped) {
        _notifyConfigurationChanged();
        return;
      }
      await _launchSaved();
    });
  }

  Future<void> stop() {
    _ensureNoMaintenanceOperation();
    return _serialize(runtime.stop);
  }

  Future<void> retryLogRecovery() {
    _ensureNoMaintenanceOperation();
    return _serialize(() async {
      if (_logRecoveryError == null) return;
      if (runtime.currentState.status != RuntimeStatus.stopped) {
        throw StateError('Stop the Backend before recovering log history');
      }
      final store = logStore;
      if (store == null) throw StateError('Log history is unavailable');
      try {
        await store.initialize();
        _logRecoveryError = null;
      } catch (error) {
        _logRecoveryError = error;
        rethrow;
      }
    });
  }

  Future<void> retryLogFinalization(String runId) {
    _ensureExitIsNotPending();
    return _serialize(() => runtime.retryLogFinalization(runId));
  }

  Future<void> restart() {
    _ensureNoMaintenanceOperation();
    return _serialize(() async {
      _ensureStartupAllowed();
      if (environmentIssues.isNotEmpty) {
        throw _environmentError(environmentIssues.first);
      }
      await _launchSaved(forceRestart: true);
    });
  }

  /// The single internal launch step every real start entry point funnels to.
  ///
  /// A running service with a different saved pair is stopped first; its
  /// failure keeps the old entry and aborts the launch. The applied revision
  /// advances only after a successful start, so a failed launch never claims
  /// the saved pair is in effect and a duplicate start cannot masquerade as
  /// applying a new configuration.
  Future<void> _launchSaved({bool forceRestart = false}) async {
    await _recoverConfigurationIfNeeded();
    final blocked = _runtimeConfigurationError;
    if (blocked != null) throw blocked;
    final saved = _savedEffective;
    if (saved != null) await _syncRuntimePending(saved);
    final revision = _savedRevision;
    final running = runtime.currentState.status != RuntimeStatus.stopped;
    final applied = runtime.appliedConfiguration;
    final appliesChange =
        forceRestart ||
        (running &&
            saved != null &&
            (applied == null || !_sameEffective(saved, applied)));
    if (appliesChange && running) await runtime.stop();
    await runtime.start();
    if (saved != null &&
        revision == _savedRevision &&
        runtime.appliedConfiguration != null) {
      _appliedRevision = revision;
    }
    _notifyConfigurationChanged();
  }

  Future<void> _recoverConfigurationIfNeeded() async {
    final store = runtimeConfigurationStore;
    if (store != null &&
        (_runtimeConfigurationError != null ||
            await store.recoveryFile.exists())) {
      await _loadPaired(store);
    }
  }

  Future<MaintenanceOperation> runComponentUpdates(
    Map<ComponentKind, ComponentUpdate> confirmedUpdates,
  ) {
    _ensureMaintenanceCanBeReserved(confirmedUpdates.keys);
    final targets = <MaintenanceTarget>[];
    for (final entry in confirmedUpdates.entries) {
      final checked = _componentChecks[entry.key];
      if (!identical(checked, entry.value) ||
          entry.value.kind != entry.key ||
          !entry.value.isAvailable) {
        throw StateError(
          'The confirmed component release is no longer current',
        );
      }
      targets.add(
        MaintenanceTarget(
          kind: entry.key,
          action: MaintenanceAction.update,
          currentVersion: entry.value.currentVersion,
          targetVersion: entry.value.availableVersion,
        ),
      );
    }
    targets.sort((a, b) => a.kind == ComponentKind.frontend ? -1 : 1);
    return _reserveMaintenance(
      targets,
      updates: Map.unmodifiable(confirmedUpdates),
    );
  }

  Future<MaintenanceOperation> runComponentRollback(
    ComponentKind kind, {
    required ComponentVersionStatus confirmedStatus,
  }) => _reserveRollback(kind, confirmedStatus: confirmedStatus);

  Future<MaintenanceOperation> _reserveRollback(
    ComponentKind kind, {
    required ComponentVersionStatus confirmedStatus,
    bool allowAdmittedExit = false,
  }) {
    _ensureMaintenanceCanBeReserved([
      kind,
    ], allowAdmittedExit: allowAdmittedExit);
    final status = _componentStatuses[kind];
    final targetVersion = confirmedStatus.previous;
    if (!identical(status, confirmedStatus) ||
        targetVersion == null ||
        confirmedStatus.rollbackBlockedReason != null) {
      throw StateError(
        'The confirmed component rollback is no longer available',
      );
    }
    return _reserveMaintenance([
      MaintenanceTarget(
        kind: kind,
        action: MaintenanceAction.rollback,
        currentVersion: confirmedStatus.current,
        targetVersion: targetVersion,
      ),
    ]);
  }

  Future<MaintenanceOperation> retryMaintenance() {
    final previous = _maintenanceOperation;
    if (previous == null ||
        previous.phase == MaintenancePhase.completed ||
        previous.isActive) {
      throw StateError('There is no interrupted component operation to retry');
    }
    final pending = previous.remainingTargets;
    final updates = <ComponentKind, ComponentUpdate>{};
    if (!previous.startOnly) {
      for (final target in pending) {
        if (target.action != MaintenanceAction.update) continue;
        final update = _componentChecks[target.kind];
        if (update == null ||
            update.currentVersion != target.currentVersion ||
            update.availableVersion != target.targetVersion ||
            !update.isAvailable) {
          throw StateError(
            'Check the remaining component version before retrying',
          );
        }
        updates[target.kind] = update;
      }
    }
    _ensureMaintenanceCanBeReserved(
      previous.startOnly ? const <ComponentKind>[] : pending.map((t) => t.kind),
    );
    final cleanupOnly = _isCompletedMaintenanceCleanup(previous);
    return _reserveMaintenance(
      previous.targets,
      updates: Map.unmodifiable(updates),
      previous: previous,
      startOnly: previous.startOnly,
      cleanupOnly: cleanupOnly,
    );
  }

  Future<void> restoreMaintenanceAttempt() {
    _ensureExitIsNotPending();
    return _serialize(() async {
      if (_startupBlocker != null) return;
      await _restoreMaintenanceAttemptUnqueued();
    });
  }

  Future<void> _restoreMaintenanceAttemptUnqueued() async {
    final store = maintenanceAttemptStore;
    MaintenanceAttempt? attempt;
    try {
      attempt = await store.load();
    } on Object catch (error) {
      _setMaintenanceRecoveryBlocker(error);
      return;
    }
    if (attempt == null) {
      _clearMaintenanceRecoveryBlocker();
      return;
    }
    try {
      final results = <MaintenanceTargetResult>[];
      for (final target in attempt.targets) {
        final status = await _requireUpdates().status(target.kind);
        _componentStatuses[target.kind] = status;
        _componentStatusErrors.remove(target.kind);
        final wasCompleted = attempt.completed.contains(target.kind);
        if (status.current == target.targetVersion) {
          results.add(
            MaintenanceTargetResult(
              target: target,
              state: MaintenanceTargetState.completed,
            ),
          );
        } else if (status.current == target.currentVersion && !wasCompleted) {
          results.add(
            MaintenanceTargetResult(
              target: target,
              state: MaintenanceTargetState.pending,
            ),
          );
        } else {
          throw StateError(
            'Installed ${target.kind.name} version does not match the interrupted operation',
          );
        }
      }
      final complete = results.every(
        (result) => result.state == MaintenanceTargetState.completed,
      );
      final startOnly =
          attempt.startOnly || (complete && attempt.restoreAfterChanges);
      final phase = complete
          ? startOnly
                ? MaintenancePhase.awaitingStart
                : MaintenancePhase.completed
          : MaintenancePhase.interrupted;
      final operation = MaintenanceOperation(
        phase: phase,
        results: results,
        failedKind: attempt.failedKind,
        failureStage: attempt.failureStage,
        restoreAfterChanges: attempt.restoreAfterChanges,
        startOnly: startOnly,
      );
      _maintenanceOperation = operation;
      if (complete && !startOnly) {
        await store.clear();
      } else {
        await store.save(_attemptFor(operation));
      }
      _clearMaintenanceRecoveryBlocker();
      _recordMaintenanceActivity(phase, kind: attempt.failedKind);
    } on Object catch (error) {
      _setMaintenanceRecoveryBlocker(error);
    }
  }

  void _clearMaintenanceRecoveryBlocker() {
    if (_maintenanceRecoveryError == null) return;
    _maintenanceRecoveryError = null;
    final operation = _maintenanceOperation;
    if (operation?.phase == MaintenancePhase.blocked &&
        operation?.failureStage == MaintenanceFailureStage.recovery) {
      _maintenanceOperation = null;
    }
    _notifyMaintenanceChanged();
  }

  void _setMaintenanceRecoveryBlocker(Object error) {
    _maintenanceRecoveryError = AppConfigError(
      AppConfigErrorCode.componentRecoveryFailed,
      detail: 'Maintenance recovery requires attention',
    );
    _maintenanceOperation = MaintenanceOperation(
      phase: MaintenancePhase.blocked,
      results: _maintenanceOperation?.results ?? const [],
      error: error,
      failureStage: MaintenanceFailureStage.recovery,
    );
    _recordMaintenanceActivity(MaintenancePhase.blocked);
  }

  Future<MaintenanceOperation> _reserveMaintenance(
    List<MaintenanceTarget> targets, {
    Map<ComponentKind, ComponentUpdate> updates = const {},
    MaintenanceOperation? previous,
    bool startOnly = false,
    bool cleanupOnly = false,
  }) {
    _maintenanceReserved = true;
    final base =
        previous ??
        MaintenanceOperation(
          phase: MaintenancePhase.preparing,
          results: targets
              .map(
                (target) => MaintenanceTargetResult(
                  target: target,
                  state: MaintenanceTargetState.pending,
                ),
              )
              .toList(),
        );
    _maintenanceOperation = base.copyWith(
      phase: MaintenancePhase.preparing,
      results: targets
          .map(
            (target) => MaintenanceTargetResult(
              target: target,
              state:
                  previous?.results
                      .where((item) => item.target.kind == target.kind)
                      .firstOrNull
                      ?.state ??
                  MaintenanceTargetState.pending,
            ),
          )
          .toList(),
      clearError: true,
      clearFailedKind: true,
      clearFailureStage: !cleanupOnly,
      startOnly: startOnly,
    );
    _recordMaintenanceActivity(MaintenancePhase.preparing);
    final result = _serializeValue(
      () => _executeMaintenance(
        _maintenanceOperation!,
        updates: updates,
        startOnly: startOnly,
      ),
    );
    return result.whenComplete(() {
      _maintenanceReserved = false;
      _notifyMaintenanceChanged();
    });
  }

  Future<MaintenanceOperation> _executeMaintenance(
    MaintenanceOperation operation, {
    required Map<ComponentKind, ComponentUpdate> updates,
    required bool startOnly,
  }) async {
    final store = maintenanceAttemptStore;
    try {
      _ensureStartupAllowed();
      if (_isCompletedMaintenanceCleanup(operation)) {
        return await _retryCompletedMaintenanceCleanup(operation, store);
      }
      final status = runtime.currentState.status;
      if (status == RuntimeStatus.starting ||
          status == RuntimeStatus.stopping) {
        throw StateError('Wait for the Backend to reach a stable state');
      }
      final restoreAfterChanges = status != RuntimeStatus.stopped;
      operation = operation.copyWith(
        restoreAfterChanges: restoreAfterChanges,
        startOnly: startOnly,
      );
      if (startOnly) {
        return await _retryStartOnly(operation, store);
      }
      if (operation.targets.isEmpty) {
        return _publishMaintenance(
          operation.copyWith(phase: MaintenancePhase.completed),
          MaintenancePhase.completed,
        );
      }
      for (final target in operation.remainingTargets) {
        final status = await _requireUpdates().status(target.kind);
        _componentStatuses[target.kind] = status;
        if (status.current != target.currentVersion ||
            (target.action == MaintenanceAction.rollback &&
                (status.previous != target.targetVersion ||
                    status.rollbackBlockedReason != null))) {
          throw StateError(
            'The confirmed ${target.kind.name} version changed before maintenance began',
          );
        }
      }
      await store.save(_attemptFor(operation));
      if (restoreAfterChanges) {
        operation = operation.copyWith(phase: MaintenancePhase.stopping);
        await store.save(_attemptFor(operation));
        _publishMaintenance(operation, MaintenancePhase.stopping);
        try {
          await runtime.stop();
        } on Object catch (error) {
          return await _publishMaintenanceFailure(
            operation,
            error,
            MaintenanceFailureStage.stopping,
            failedKind: operation.targets.first.kind,
          );
        }
      }
      operation = operation.copyWith(phase: MaintenancePhase.updating);
      await store.save(_attemptFor(operation));
      _publishMaintenance(operation, MaintenancePhase.updating);
      for (final target in operation.remainingTargets) {
        try {
          if (runtime.currentState.status != RuntimeStatus.stopped) {
            throw StateError(
              'The Backend must be stopped before changing components',
            );
          }
          switch (target.action) {
            case MaintenanceAction.update:
              final update = updates[target.kind];
              if (update == null ||
                  update.currentVersion != target.currentVersion ||
                  update.availableVersion != target.targetVersion) {
                throw StateError(
                  'The confirmed component release changed before installation',
                );
              }
              await _requireUpdates().update(update);
              break;
            case MaintenanceAction.rollback:
              await _requireUpdates().rollback(target.kind);
              break;
          }
        } on Object catch (error) {
          return await _publishMaintenanceFailure(
            operation.copyWith(
              failedKind: target.kind,
              failureStage: MaintenanceFailureStage.updating,
            ),
            error,
            MaintenanceFailureStage.updating,
            failedKind: target.kind,
          );
        }
        final results = operation.results
            .map(
              (result) => result.target.kind == target.kind
                  ? MaintenanceTargetResult(
                      target: target,
                      state: MaintenanceTargetState.completed,
                    )
                  : result,
            )
            .toList();
        _componentChecks.remove(target.kind);
        _componentCheckErrors.remove(target.kind);
        operation = operation.copyWith(results: results);
        _recordMaintenanceActivity(
          MaintenancePhase.updating,
          kind: target.kind,
        );
        try {
          await store.save(_attemptFor(operation));
        } on Object catch (error) {
          return await _publishMaintenanceFailure(
            operation,
            error,
            MaintenanceFailureStage.recovery,
            failedKind: target.kind,
            phase: MaintenancePhase.blocked,
          );
        }
        try {
          final refreshed = await _requireUpdates().status(target.kind);
          _componentStatuses[target.kind] = refreshed;
          _componentStatusErrors.remove(target.kind);
        } on Object catch (error) {
          _componentStatusErrors[target.kind] = error;
          operation = operation.copyWith(
            results: operation.results
                .map(
                  (result) => result.target.kind == target.kind
                      ? MaintenanceTargetResult(
                          target: result.target,
                          state: result.state,
                          statusRefreshFailed: true,
                        )
                      : result,
                )
                .toList(),
          );
        }
        _notifyMaintenanceChanged();
      }
      if (restoreAfterChanges) {
        operation = operation.copyWith(
          phase: MaintenancePhase.starting,
          startOnly: true,
          clearFailedKind: true,
          clearFailureStage: true,
        );
        try {
          await store.save(_attemptFor(operation));
        } on Object catch (error) {
          return await _publishMaintenanceFailure(
            operation,
            error,
            MaintenanceFailureStage.recovery,
            phase: MaintenancePhase.blocked,
          );
        }
        _publishMaintenance(operation, MaintenancePhase.starting);
        try {
          await _launchSaved();
        } on Object catch (error) {
          return await _publishMaintenanceFailure(
            operation,
            error,
            MaintenanceFailureStage.starting,
            phase: MaintenancePhase.startFailed,
          );
        }
      }
      operation = operation.copyWith(
        phase: MaintenancePhase.completed,
        startOnly: false,
        clearFailedKind: true,
        clearFailureStage: true,
        clearError: true,
      );
      try {
        if (restoreAfterChanges) await store.save(_attemptFor(operation));
        await store.clear();
      } on Object catch (error) {
        return await _publishMaintenanceFailure(
          operation,
          error,
          MaintenanceFailureStage.recovery,
          phase: MaintenancePhase.blocked,
        );
      }
      return _publishMaintenance(operation, MaintenancePhase.completed);
    } on Object catch (error) {
      return _publishMaintenanceFailure(
        operation,
        error,
        MaintenanceFailureStage.recovery,
      );
    }
  }

  bool _isCompletedMaintenanceCleanup(MaintenanceOperation operation) =>
      operation.targets.isNotEmpty &&
      operation.failureStage == MaintenanceFailureStage.recovery &&
      !operation.startOnly &&
      operation.remainingTargets.isEmpty;

  Future<MaintenanceOperation> _retryCompletedMaintenanceCleanup(
    MaintenanceOperation operation,
    MaintenanceAttemptStore store,
  ) async {
    try {
      for (final result in operation.results) {
        final status = await _requireUpdates().status(result.target.kind);
        _componentStatuses[result.target.kind] = status;
        _componentStatusErrors.remove(result.target.kind);
        if (status.current != result.target.targetVersion) {
          throw StateError(
            'Installed ${result.target.kind.name} version does not match the completed operation',
          );
        }
      }
      final completed = operation.copyWith(
        phase: MaintenancePhase.completed,
        startOnly: false,
        clearError: true,
        clearFailedKind: true,
        clearFailureStage: true,
      );
      await store.save(_attemptFor(completed));
      await store.clear();
      return _publishMaintenance(completed, MaintenancePhase.completed);
    } on Object catch (error) {
      return _publishMaintenanceFailure(
        operation,
        error,
        MaintenanceFailureStage.recovery,
        phase: MaintenancePhase.blocked,
      );
    }
  }

  Future<MaintenanceOperation> _retryStartOnly(
    MaintenanceOperation operation,
    MaintenanceAttemptStore store,
  ) async {
    final status = runtime.currentState.status;
    if (status == RuntimeStatus.running) {
      operation = operation.copyWith(
        phase: MaintenancePhase.completed,
        startOnly: false,
        clearError: true,
        clearFailedKind: true,
        clearFailureStage: true,
      );
      try {
        await store.clear();
      } on Object catch (error) {
        return _publishMaintenanceFailure(
          operation,
          error,
          MaintenanceFailureStage.recovery,
          phase: MaintenancePhase.blocked,
        );
      }
      return _publishMaintenance(operation, MaintenancePhase.completed);
    }
    if (status == RuntimeStatus.starting || status == RuntimeStatus.stopping) {
      return _publishMaintenanceFailure(
        operation,
        StateError('Wait for the Backend to reach a stable state'),
        MaintenanceFailureStage.recovery,
        phase: MaintenancePhase.blocked,
      );
    }
    if (status != RuntimeStatus.stopped) {
      operation = operation.copyWith(phase: MaintenancePhase.stopping);
      try {
        await store.save(_attemptFor(operation));
      } on Object catch (error) {
        return _publishMaintenanceFailure(
          operation,
          error,
          MaintenanceFailureStage.recovery,
          phase: MaintenancePhase.blocked,
        );
      }
      _publishMaintenance(operation, MaintenancePhase.stopping);
      try {
        await runtime.stop();
        if (runtime.currentState.status != RuntimeStatus.stopped) {
          throw StateError(
            'The Backend did not stop before retrying its start',
          );
        }
      } on Object catch (error) {
        return _publishMaintenanceFailure(
          operation,
          error,
          MaintenanceFailureStage.stopping,
          phase: MaintenancePhase.blocked,
        );
      }
    }
    operation = operation.copyWith(phase: MaintenancePhase.starting);
    try {
      await store.save(_attemptFor(operation));
      _publishMaintenance(operation, MaintenancePhase.starting);
      await _launchSaved();
    } on Object catch (error) {
      return _publishMaintenanceFailure(
        operation,
        error,
        MaintenanceFailureStage.starting,
        phase: MaintenancePhase.startFailed,
      );
    }
    operation = operation.copyWith(
      phase: MaintenancePhase.completed,
      startOnly: false,
      clearError: true,
      clearFailedKind: true,
      clearFailureStage: true,
    );
    try {
      await store.clear();
    } on Object catch (error) {
      return _publishMaintenanceFailure(
        operation,
        error,
        MaintenanceFailureStage.recovery,
        phase: MaintenancePhase.blocked,
      );
    }
    return _publishMaintenance(operation, MaintenancePhase.completed);
  }

  Future<MaintenanceOperation> _publishMaintenanceFailure(
    MaintenanceOperation operation,
    Object error,
    MaintenanceFailureStage stage, {
    ComponentKind? failedKind,
    MaintenancePhase phase = MaintenancePhase.failed,
  }) async {
    operation = operation.copyWith(
      phase: phase,
      results: stage == MaintenanceFailureStage.updating && failedKind != null
          ? operation.results
                .map(
                  (result) => result.target.kind == failedKind
                      ? MaintenanceTargetResult(
                          target: result.target,
                          state: MaintenanceTargetState.failed,
                          statusRefreshFailed: result.statusRefreshFailed,
                        )
                      : result,
                )
                .toList()
          : operation.results,
      failedKind: failedKind ?? operation.failedKind,
      failureStage: stage,
      error: error,
      startOnly: stage == MaintenanceFailureStage.starting
          ? true
          : operation.startOnly,
    );
    if (operation.targets.isNotEmpty) {
      try {
        await maintenanceAttemptStore.save(_attemptFor(operation));
      } on Object {
        // The earlier durable checkpoint remains available for startup repair.
      }
    }
    return _publishMaintenance(operation, phase);
  }

  MaintenanceOperation _publishMaintenance(
    MaintenanceOperation operation,
    MaintenancePhase activity, {
    ComponentKind? kind,
  }) {
    _maintenanceOperation = operation;
    _recordMaintenanceActivity(activity, kind: kind);
    return operation;
  }

  MaintenanceAttempt _attemptFor(MaintenanceOperation operation) =>
      MaintenanceAttempt(
        targets: operation.targets,
        completed: operation.results
            .where((result) => result.state == MaintenanceTargetState.completed)
            .map((result) => result.target.kind)
            .toList(),
        phase: operation.phase,
        restoreAfterChanges: operation.restoreAfterChanges,
        startOnly: operation.startOnly,
        failedKind: operation.failedKind,
        failureStage: operation.failureStage,
      );

  Future<ComponentVersionStatus> componentStatus(ComponentKind kind) {
    _ensureNoMaintenanceOperation();
    return _serializeValue(() async {
      try {
        final status = await _requireUpdates().status(kind);
        _componentStatuses[kind] = status;
        _componentStatusErrors.remove(kind);
        return status;
      } on Object catch (error) {
        _componentStatusErrors[kind] = error;
        rethrow;
      } finally {
        _notifyMaintenanceChanged();
      }
    });
  }

  Future<ComponentUpdate> checkComponent(ComponentKind kind) {
    _ensureNoMaintenanceOperation();
    if (!_checksInProgress.add(kind)) {
      throw StateError('A component check is already in progress');
    }
    _componentChecks.remove(kind);
    _componentCheckErrors.remove(kind);
    _notifyMaintenanceChanged();
    return _serializeValue(() async {
      try {
        final update = await _requireUpdates().check(kind);
        _componentChecks[kind] = update;
        return update;
      } on Object catch (error) {
        _componentCheckErrors[kind] = error;
        rethrow;
      } finally {
        _checksInProgress.remove(kind);
        _notifyMaintenanceChanged();
      }
    });
  }

  void _ensureMaintenanceCanBeReserved(
    Iterable<ComponentKind> kinds, {
    bool allowAdmittedExit = false,
  }) {
    _ensureNoMaintenanceOperation(allowAdmittedExit: allowAdmittedExit);
    if (kinds.any(_checksInProgress.contains)) {
      throw StateError(
        'Wait for the component check to finish before maintenance',
      );
    }
  }

  void _ensureNoMaintenanceOperation({bool allowAdmittedExit = false}) {
    _ensureExitIsNotPending(allowAdmittedExit: allowAdmittedExit);
    if (_maintenanceReserved) {
      throw StateError('A component maintenance operation is in progress');
    }
  }

  void _ensureExitIsNotPending({bool allowAdmittedExit = false}) {
    if (_disposed || (_shutdownRequested && !allowAdmittedExit)) {
      throw StateError('The application is closing');
    }
  }

  void _recordMaintenanceActivity(
    MaintenancePhase phase, {
    ComponentKind? kind,
  }) {
    _maintenanceActivity.add(
      MaintenanceActivity(timestamp: DateTime.now(), phase: phase, kind: kind),
    );
    if (_maintenanceActivity.length > 500) {
      _maintenanceActivity.removeRange(0, _maintenanceActivity.length - 500);
    }
    _notifyMaintenanceChanged();
  }

  void _notifyMaintenanceChanged() {
    if (_disposed) return;
    maintenanceChanges.value = maintenanceChanges.value + 1;
  }

  Future<void> dispose() {
    if (_disposed) return Future<void>.value();
    final disposal = _disposal;
    if (disposal != null) return disposal;

    _shutdownRequested = true;
    final pending = _disposeAfterAdmittedOperations();
    _disposal = pending;
    return pending;
  }

  Future<void> _disposeAfterAdmittedOperations() async {
    try {
      final rollbackPreflights = _rollbackPreflightsDrained;
      if (rollbackPreflights != null) await rollbackPreflights.future;
      await _serialize(() async {
        if (_disposed) return;
        await runtime.dispose();
        _disposed = true;
        configurationChanges.dispose();
        maintenanceChanges.dispose();
      });
    } on Object {
      _shutdownRequested = false;
      _disposal = null;
      rethrow;
    }
  }

  /// Retries pending component recovery while the service is stopped.
  /// A successful repair clears the blocker without automatically starting.
  Future<void> retryComponentRecovery() {
    _ensureNoMaintenanceOperation();
    return _serialize(() async {
      final recover = _componentRecovery;
      if (recover == null) {
        throw StateError('Component recovery is unavailable');
      }
      _ensureRuntimeStoppedForComponentMutation();
      try {
        await recover();
        _startupBlocker = null;
        await _restoreMaintenanceAttemptUnqueued();
      } on Object catch (error, stackTrace) {
        final blocker = AppConfigError(
          AppConfigErrorCode.componentRecoveryFailed,
          detail: '$error',
        );
        _startupBlocker = blocker;
        Error.throwWithStackTrace(blocker, stackTrace);
      } finally {
        _notifyConfigurationChanged();
      }
    });
  }

  Future<void> updateComponent(ComponentUpdate update) {
    _ensureNoMaintenanceOperation();
    if (_checksInProgress.contains(update.kind)) {
      throw StateError(
        'Wait for the component check to finish before maintenance',
      );
    }
    _componentChecks[update.kind] = update;
    _notifyMaintenanceChanged();
    return runComponentUpdates({update.kind: update}).then((_) {});
  }

  Future<void> rollbackComponent(ComponentKind kind) async {
    _ensureNoMaintenanceOperation();
    if (_rollbackPreflightCount++ == 0) {
      _rollbackPreflightsDrained = Completer<void>();
    }
    try {
      await _rollbackComponentAdmitted(kind);
    } finally {
      _rollbackPreflightCount--;
      if (_rollbackPreflightCount == 0) {
        _rollbackPreflightsDrained!.complete();
        _rollbackPreflightsDrained = null;
      }
    }
  }

  Future<void> _rollbackComponentAdmitted(ComponentKind kind) async {
    final status = await componentStatus(kind);
    await _reserveRollback(
      kind,
      confirmedStatus: status,
      allowAdmittedExit: true,
    );
  }

  Future<void> _serialize(Future<void> Function() action) {
    final next = _operation.then((_) => action());
    _operation = next.catchError((Object _) {});
    return next;
  }

  Future<T> _serializeValue<T>(Future<T> Function() action) {
    final next = _operation.then((_) => action());
    _operation = next.then<void>((_) {}).catchError((Object _) {});
    return next;
  }

  ComponentUpdateOperations _requireUpdates() {
    final updates = componentUpdates;
    if (updates == null) {
      throw const AppConfigError(AppConfigErrorCode.updaterDisabled);
    }
    return updates;
  }

  void _ensureStartupAllowed() {
    if (startupBlocker != null) throw startupBlocker!;
    if (_logRecoveryError != null) {
      throw StateError('Log history recovery must succeed before starting');
    }
    final maintenanceBlocker = _maintenanceRecoveryError;
    if (maintenanceBlocker != null) throw maintenanceBlocker;
  }

  void _ensureRuntimeStoppedForComponentMutation() {
    if (runtime.currentState.status != RuntimeStatus.stopped) {
      throw StateError('Component mutation requires a stopped Backend');
    }
  }

  static AppConfigError _environmentError(BackendEnvIssue issue) =>
      AppConfigError(AppConfigErrorCode.environmentInvalid, issue: issue);

  Future<SubDockConfig> _loadConfiguration() async {
    final store = configurationStore;
    return store == null ? const SubDockConfig() : store.load();
  }

  EffectiveRuntimeConfig _resolve(
    BackendEnvDocument environment,
    SubDockConfig configuration,
  ) => EffectiveRuntimeConfig.resolve(
    systemEnvironment: Platform.environment,
    backendEnvironment: environment,
    config: configuration,
  );

  /// Pushes the saved configuration to the runtime as its next-launch input.
  ///
  /// The runtime freezes it at start, so this never changes the endpoint or
  /// health checks of a process that is already running.
  Future<void> _syncRuntimePending(EffectiveRuntimeConfig effective) async {
    final pending = _runtimePending;
    if (pending != null && _sameEffective(effective, pending)) return;
    await runtime.activateConfiguration(effective);
    _runtimePending = effective;
  }

  /// The configuration a currently running process uses, or the saved pair.
  EffectiveRuntimeConfig? get _activeEffective =>
      runtime.currentState.status == RuntimeStatus.stopped
      ? _savedEffective
      : (runtime.appliedConfiguration ?? _savedEffective);

  String? _effectiveValue(String key) =>
      _activeEffective?.environment[key] ??
      _savedEffective?.environment[key] ??
      _environment.values[key];
}

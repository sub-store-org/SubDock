import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../runtime/backend_runtime.dart';
import '../runtime/runtime_log_store.dart';
import '../settings/backend_env.dart';
import '../settings/backend_env_store.dart';
import '../settings/config_error.dart';
import '../settings/runtime_configuration_store.dart';
import '../settings/subdock_config.dart';
import '../settings/subdock_config_store.dart';
import '../update/component_metadata_store.dart';
import '../update/component_update_checker.dart';
import '../update/component_update_service.dart';

class AppCoordinator {
  AppCoordinator({
    required this.runtime,
    required this.environmentStore,
    this.configurationStore,
    this._startupBlocker,
    this._componentRecovery,
    this.componentUpdates,
    this.logStore,
    RuntimeConfigurationStore? runtimeConfigurationStore,
  }) : runtimeConfigurationStore =
           runtimeConfigurationStore ??
           (configurationStore == null
               ? null
               : RuntimeConfigurationStore(
                   directories: environmentStore.directories,
                   environmentStore: environmentStore,
                   configurationStore: configurationStore,
                 ));

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

  Object? get startupBlocker => _startupBlocker;
  final ComponentUpdateOperations? componentUpdates;
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
  var _disposed = false;
  Future<void> _operation = Future<void>.value();

  /// Ticks whenever a shared saved／applied／error snapshot changes.
  ///
  /// Pages read the getters and listen here instead of caching a second copy
  /// of the applied entry or component state.
  final configurationChanges = ValueNotifier<int>(0);

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

  Future<void> loadEnvironment() => _serialize(() async {
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

  Future<void> saveEnvironment(BackendEnvDocument document) =>
      _serialize(() async {
        final issues = BackendEnvPolicy.validate(document);
        if (issues.isNotEmpty) throw _environmentError(issues.first);
        await _savePair(document, _configuration);
      });

  Future<void> saveConfiguration(SubDockConfig configuration) =>
      _serialize(() async {
        SubDockConfig.fromJson(configuration.toJson());
        if (configurationStore == null) {
          throw const AppConfigError(AppConfigErrorCode.configStoreDisabled);
        }
        await _savePair(_environment, configuration);
      });

  Future<void> resetConfiguration() => _serialize(() async {
    if (runtimeConfigurationStore == null) {
      throw const AppConfigError(AppConfigErrorCode.configStoreDisabled);
    }
    await _savePair(_environment, const SubDockConfig());
  });

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

  Future<void> start() => _serialize(() async {
    _ensureStartupAllowed();
    if (environmentIssues.isNotEmpty) {
      throw _environmentError(environmentIssues.first);
    }
    await _launchSaved();
  });

  /// Applies the saved configuration to the service.
  ///
  /// A running service is stopped first and only restarted once that stop
  /// succeeds; a stopped service stays stopped so the explicit start action
  /// applies the saved configuration. A failed stop leaves the old entry in
  /// place and reports the saved pair as still pending.
  Future<void> applyConfiguration() => _serialize(() async {
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

  Future<void> stop() => _serialize(runtime.stop);

  Future<void> restart() => _serialize(() async {
    _ensureStartupAllowed();
    if (environmentIssues.isNotEmpty) {
      throw _environmentError(environmentIssues.first);
    }
    await _launchSaved(forceRestart: true);
  });

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

  Future<void> dispose() => _serialize(() async {
    if (_disposed) return;
    _disposed = true;
    configurationChanges.dispose();
    await runtime.dispose();
  });

  Future<ComponentUpdate> checkComponent(ComponentKind kind) =>
      _serializeValue(() => _requireUpdates().check(kind));

  Future<ComponentVersionStatus> componentStatus(ComponentKind kind) =>
      _serializeValue(() => _requireUpdates().status(kind));

  /// Retries pending component recovery while the service is stopped.
  /// A successful repair clears the blocker without automatically starting.
  Future<void> retryComponentRecovery() => _serialize(() async {
    final recover = _componentRecovery;
    if (recover == null) throw StateError('Component recovery is unavailable');
    _ensureRuntimeStoppedForComponentMutation();
    try {
      await recover();
      _startupBlocker = null;
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

  Future<void> updateComponent(ComponentUpdate update) => _serialize(() async {
    _ensureStartupAllowed();
    _ensureRuntimeStoppedForComponentMutation();
    await _requireUpdates().update(update);
  });

  Future<void> rollbackComponent(ComponentKind kind) => _serialize(() async {
    _ensureStartupAllowed();
    _ensureRuntimeStoppedForComponentMutation();
    await _requireUpdates().rollback(kind);
  });

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

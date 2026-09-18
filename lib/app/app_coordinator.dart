import 'dart:collection';
import 'dart:io';

import '../runtime/backend_runtime.dart';
import '../runtime/runtime_log_store.dart';
import '../settings/backend_env.dart';
import '../settings/backend_env_store.dart';
import '../settings/config_error.dart';
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
    this.startupBlocker,
    this.componentUpdates,
    this.logStore,
  });

  final BackendRuntime runtime;
  final BackendEnvStore environmentStore;
  final SubDockConfigStore? configurationStore;
  final Object? startupBlocker;
  final ComponentUpdateOperations? componentUpdates;
  final RuntimeLogStore? logStore;
  BackendEnvDocument _environment = BackendEnvDocument.parse('');
  SubDockConfig _configuration = const SubDockConfig();
  AppConfigError? _configurationError;
  Map<String, String> _effectiveEnvironment = const <String, String>{};
  Future<void> _operation = Future<void>.value();

  BackendEnvDocument get environment => _environment;
  SubDockConfig get configuration => _configuration;
  AppConfigError? get configurationError => _configurationError;
  Map<String, String> get effectiveEnvironment =>
      UnmodifiableMapView(_effectiveEnvironment);

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
    await _activate(document, configuration);
    _environment = document;
    _configuration = configuration;
  });

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
        await environmentStore.save(document);
        await _activate(document, _configuration);
        _environment = document;
      });

  Future<void> saveConfiguration(SubDockConfig configuration) =>
      _serialize(() async {
        SubDockConfig.fromJson(configuration.toJson());
        final store = configurationStore;
        if (store == null) {
          throw const AppConfigError(AppConfigErrorCode.configStoreDisabled);
        }
        await store.save(configuration);
        await _activate(_environment, configuration);
        _configuration = configuration;
        _configurationError = null;
      });

  Future<void> resetConfiguration() => _serialize(() async {
    final store = configurationStore;
    if (store == null) {
      throw const AppConfigError(AppConfigErrorCode.configStoreDisabled);
    }
    await store.reset();
    const configuration = SubDockConfig();
    await _activate(_environment, configuration);
    _configuration = configuration;
    _configurationError = null;
  });

  Future<void> start() => _serialize(() async {
    _ensureStartupAllowed();
    if (environmentIssues.isNotEmpty) {
      throw _environmentError(environmentIssues.first);
    }
    await runtime.start();
  });

  Future<void> stop() => _serialize(runtime.stop);

  Future<void> restart() => _serialize(() async {
    _ensureStartupAllowed();
    if (environmentIssues.isNotEmpty) {
      throw _environmentError(environmentIssues.first);
    }
    await runtime.restart();
  });

  Future<void> dispose() => _serialize(runtime.dispose);

  Future<ComponentUpdate> checkComponent(ComponentKind kind) =>
      _serializeValue(() => _requireUpdates().check(kind));

  Future<ComponentVersionStatus> componentStatus(ComponentKind kind) =>
      _serializeValue(() => _requireUpdates().status(kind));

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

  Future<void> _activate(
    BackendEnvDocument environment,
    SubDockConfig configuration,
  ) async {
    final effective = EffectiveRuntimeConfig.resolve(
      systemEnvironment: Platform.environment,
      backendEnvironment: environment,
      config: configuration,
    );
    await runtime.activateConfiguration(effective);
    _effectiveEnvironment = effective.environment;
  }

  String? _effectiveValue(String key) =>
      _effectiveEnvironment[key] ?? _environment.values[key];
}

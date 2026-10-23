import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/app_coordinator.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/settings/backend_env.dart';
import 'package:subdock/settings/backend_env_store.dart';
import 'package:subdock/settings/config_error.dart';
import 'package:subdock/settings/runtime_configuration_store.dart';
import 'package:subdock/settings/subdock_config.dart';
import 'package:subdock/settings/subdock_config_store.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_update_checker.dart';
import 'package:subdock/update/component_update_service.dart';
import 'package:subdock/update/github_release_client.dart';

void main() {
  test('serializes environment activation before a backend start', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final runtime = _FakeRuntime();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(
        await RuntimeDirectories.fromBaseDirectory(temp),
      ),
      configurationStore: SubDockConfigStore(
        await RuntimeDirectories.fromBaseDirectory(temp),
      ),
    );
    final document = BackendEnvDocument.parse(
      'SUB_STORE_BACKEND_API_PORT=3002\n',
    );

    await Future.wait([
      coordinator.saveEnvironment(document),
      coordinator.start(),
    ]);

    expect(runtime.operations, ['configuration:3002', 'start']);
    expect(coordinator.webUiUri.path, '/');
    expect(
      coordinator.webUiUri.queryParameters['api'],
      'http://127.0.0.1:3002/',
    );
  });

  test(
    'activates saved SubDock overrides without changing backend ENV',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'subdock_coordinator_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final directories = await RuntimeDirectories.fromBaseDirectory(temp);
      final runtime = _FakeRuntime();
      final coordinator = AppCoordinator(
        runtime: runtime,
        environmentStore: BackendEnvStore(directories),
        configurationStore: SubDockConfigStore(directories),
      );

      await coordinator.saveEnvironment(
        BackendEnvDocument.parse('SUB_STORE_BACKEND_API_PORT=3002\n'),
      );
      await coordinator.saveConfiguration(
        const SubDockConfig(backend: SubDockBackendConfig(apiPort: 4000)),
      );

      expect(runtime.operations, ['configuration:3002', 'configuration:4000']);
      expect(
        (await coordinator.environmentStore.load()).rawText,
        'SUB_STORE_BACKEND_API_PORT=3002\n',
      );
      expect(coordinator.webUiUri.port, 4000);
    },
  );

  test('saving while the backend runs keeps the active entry', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final runtime = _FakeRuntime();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      configurationStore: SubDockConfigStore(directories),
    );
    await coordinator.saveEnvironment(
      BackendEnvDocument.parse('SUB_STORE_BACKEND_API_PORT=3002\n'),
    );
    await coordinator.start();
    expect(coordinator.webUiApiUri.port, 3002);
    final applied = coordinator.appliedRevision;

    await coordinator.saveConfiguration(
      const SubDockConfig(backend: SubDockBackendConfig(apiPort: 4000)),
    );

    expect(coordinator.webUiApiUri.port, 3002);
    expect(coordinator.hasPendingConfiguration, isTrue);
    expect(coordinator.appliedRevision, applied);
    expect(coordinator.savedRevision, greaterThan(applied));
  });

  test('applying the saved pair stops before it starts', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final runtime = _FakeRuntime();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      configurationStore: SubDockConfigStore(directories),
    );
    await coordinator.saveEnvironment(
      BackendEnvDocument.parse('SUB_STORE_BACKEND_API_PORT=3002\n'),
    );
    await coordinator.start();
    await coordinator.saveConfiguration(
      const SubDockConfig(backend: SubDockBackendConfig(apiPort: 4000)),
    );

    await coordinator.applyConfiguration();

    final stopIndex = runtime.operations.indexOf('stop');
    final lastStart = runtime.operations.lastIndexOf('start');
    expect(stopIndex, greaterThan(0));
    expect(stopIndex, lessThan(lastStart));
    expect(coordinator.webUiApiUri.port, 4000);
    expect(coordinator.hasPendingConfiguration, isFalse);
  });

  test('a failed stop leaves the saved pair pending and unstarted', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final runtime = _FakeRuntime();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      configurationStore: SubDockConfigStore(directories),
    );
    await coordinator.saveEnvironment(
      BackendEnvDocument.parse('SUB_STORE_BACKEND_API_PORT=3002\n'),
    );
    await coordinator.start();
    await coordinator.saveConfiguration(
      const SubDockConfig(backend: SubDockBackendConfig(apiPort: 4000)),
    );
    runtime.stopError = StateError('stop fixture failure');

    await expectLater(
      coordinator.applyConfiguration(),
      throwsA(isA<StateError>()),
    );

    expect(coordinator.webUiApiUri.port, 3002);
    expect(coordinator.hasPendingConfiguration, isTrue);
    expect(runtime.operations.where((op) => op == 'start'), hasLength(1));
  });

  test('a failed start does not advance the applied revision', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final runtime = _FakeRuntime();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      configurationStore: SubDockConfigStore(directories),
    );
    await coordinator.saveEnvironment(
      BackendEnvDocument.parse('SUB_STORE_BACKEND_API_PORT=3002\n'),
    );
    runtime.startError = StateError('start fixture failure');

    await expectLater(coordinator.start(), throwsA(isA<StateError>()));

    expect(coordinator.appliedRevision, 0);
    expect(coordinator.hasPendingConfiguration, isFalse);
  });

  test('restart consumes the latest saved pair including HTTP-META', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final runtime = _FakeRuntime();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      configurationStore: SubDockConfigStore(directories),
    );
    await coordinator.saveEnvironment(
      BackendEnvDocument.parse('SUB_STORE_BACKEND_API_PORT=3002\n'),
    );
    await coordinator.start();
    await coordinator.saveConfiguration(
      const SubDockConfig(
        backend: SubDockBackendConfig(apiPort: 4000),
        httpMeta: SubDockHttpMetaConfig(enabled: false),
      ),
    );

    await coordinator.restart();

    expect(coordinator.webUiApiUri.port, 4000);
    expect(coordinator.hasPendingConfiguration, isFalse);
    expect(runtime.appliedHttpMetaEnabled, isFalse);
  });

  test('a saved HTTP-META change alone reads as pending', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final runtime = _FakeRuntime();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      configurationStore: SubDockConfigStore(directories),
    );
    await coordinator.loadEnvironment();
    await coordinator.start();
    final applied = coordinator.appliedRevision;

    await coordinator.saveConfiguration(
      const SubDockConfig(httpMeta: SubDockHttpMetaConfig(enabled: false)),
    );

    expect(coordinator.hasPendingConfiguration, isTrue);
    expect(coordinator.appliedRevision, applied);
  });

  for (final alreadyLoaded in [false, true]) {
    test(
      'blocks unresolved configuration recovery ${alreadyLoaded ? 'after loading' : 'at startup'} and allows repair',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'subdock_coordinator_',
        );
        addTearDown(() => temp.delete(recursive: true));
        final directories = await RuntimeDirectories.fromBaseDirectory(temp);
        final runtime = _FakeRuntime();
        final store = RuntimeConfigurationStore(
          directories: directories,
          environmentStore: BackendEnvStore(directories),
          configurationStore: SubDockConfigStore(directories),
        );
        final coordinator = AppCoordinator(
          runtime: runtime,
          environmentStore: BackendEnvStore(directories),
          configurationStore: SubDockConfigStore(directories),
          runtimeConfigurationStore: store,
        );
        if (alreadyLoaded) await coordinator.loadEnvironment();
        final before = List<String>.of(runtime.operations);
        await store.recoveryFile.writeAsString('{not json');
        if (!alreadyLoaded) {
          await expectLater(
            coordinator.loadEnvironment(),
            throwsA(isA<AppConfigError>()),
          );
        }

        await expectLater(coordinator.start(), throwsA(isA<AppConfigError>()));

        expect(runtime.operations, before);
        expect(coordinator.runtimeConfigurationError, isNotNull);
        // Repair the deliberately corrupt record; retry the same start entry.
        await store.recoveryFile.delete();
        await coordinator.start();
        expect(runtime.currentState.status, RuntimeStatus.running);
        expect(coordinator.runtimeConfigurationError, isNull);
      },
    );
  }

  test('loads the pair through its recovery owner on startup', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final runtime = _FakeRuntime();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      configurationStore: SubDockConfigStore(directories),
    );

    await coordinator.loadEnvironment();

    expect(coordinator.configuration.backend.frontendBackendPath, isNotNull);
    final persisted = await SubDockConfigStore(directories).load();
    expect(
      persisted.backend.frontendBackendPath,
      coordinator.configuration.backend.frontendBackendPath,
    );
    expect(coordinator.savedRevision, 1);
    final pairStore = RuntimeConfigurationStore(
      directories: directories,
      environmentStore: BackendEnvStore(directories),
      configurationStore: SubDockConfigStore(directories),
    );
    expect(await pairStore.recoveryFile.exists(), isFalse);
  });

  test('opens a standalone frontend with its proxied API URL', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final coordinator = AppCoordinator(
      runtime: _FakeRuntime(),
      environmentStore: BackendEnvStore(
        await RuntimeDirectories.fromBaseDirectory(temp),
      ),
    );

    await coordinator.saveEnvironment(
      BackendEnvDocument.parse(
        'SUB_STORE_BACKEND_MERGE=false\n'
        'SUB_STORE_FRONTEND_PORT=3100\n'
        'SUB_STORE_FRONTEND_BACKEND_PATH=/subdock\n',
      ),
    );

    expect(coordinator.webUiApiUri, Uri.parse('http://127.0.0.1:3001/subdock'));
    expect(coordinator.webUiUri.origin, 'http://127.0.0.1:3100');
    expect(coordinator.webUiUri.path, '/');
    expect(coordinator.webUiUri.queryParameters, {
      'api': coordinator.webUiApiUri.toString(),
    });
  });

  test('passes an absolute root API URL to a standalone frontend', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final coordinator = AppCoordinator(
      runtime: _FakeRuntime(),
      environmentStore: BackendEnvStore(
        await RuntimeDirectories.fromBaseDirectory(temp),
      ),
    );

    await coordinator.saveEnvironment(
      BackendEnvDocument.parse(
        'SUB_STORE_BACKEND_MERGE=false\n'
        'SUB_STORE_FRONTEND_PORT=3100\n',
      ),
    );

    expect(coordinator.webUiApiUri, Uri.parse('http://127.0.0.1:3001/'));
    expect(
      coordinator.webUiUri.queryParameters['api'],
      coordinator.webUiApiUri.toString(),
    );
  });

  test('includes the API query parameter for the merged frontend', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final coordinator = AppCoordinator(
      runtime: _FakeRuntime(),
      environmentStore: BackendEnvStore(
        await RuntimeDirectories.fromBaseDirectory(temp),
      ),
    );

    await coordinator.saveEnvironment(BackendEnvDocument.parse(''));

    expect(
      coordinator.webUiUri,
      Uri.parse('http://127.0.0.1:3001/?api=http%3A%2F%2F127.0.0.1%3A3001%2F'),
    );
    expect(
      coordinator.webUiUri.queryParameters['api'],
      'http://127.0.0.1:3001/',
    );
  });

  test('first load generates a random persisted backend path', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = SubDockConfigStore(directories);
    final coordinator = AppCoordinator(
      runtime: _FakeRuntime(),
      environmentStore: BackendEnvStore(directories),
      configurationStore: store,
    );

    await coordinator.loadEnvironment();

    expect(coordinator.configuration.backend.frontendBackendPath, isNotNull);
    final persisted = await store.load();
    expect(
      persisted.backend.frontendBackendPath,
      coordinator.configuration.backend.frontendBackendPath,
    );
    final path = coordinator.configuration.backend.frontendBackendPath!;
    expect(path.startsWith('/'), isTrue);
    expect(path.length, inInclusiveRange(21, 25));
    expect(RegExp(r'^/[A-Za-z0-9]+$').hasMatch(path), isTrue);
  });

  test('a generated config path overrides an env-provided path', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = SubDockConfigStore(directories);
    final coordinator = AppCoordinator(
      runtime: _FakeRuntime(),
      environmentStore: BackendEnvStore(directories),
      configurationStore: store,
    );
    // backend.env 携带一个旧路径；config 首次加载生成随机路径并应覆盖它。
    await coordinator.saveEnvironment(
      BackendEnvDocument.parse('SUB_STORE_FRONTEND_BACKEND_PATH=/legacy\n'),
    );
    await coordinator.loadEnvironment();

    final path = coordinator.configuration.backend.frontendBackendPath!;
    expect(path, isNot('/legacy'));
    expect(
      coordinator.effectiveEnvironment['SUB_STORE_FRONTEND_BACKEND_PATH'],
      path,
    );
  });

  test('a generated backend path is stable across loads', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = SubDockConfigStore(directories);
    final first = AppCoordinator(
      runtime: _FakeRuntime(),
      environmentStore: BackendEnvStore(directories),
      configurationStore: store,
    );
    await first.loadEnvironment();
    final path = first.configuration.backend.frontendBackendPath!;

    final second = AppCoordinator(
      runtime: _FakeRuntime(),
      environmentStore: BackendEnvStore(directories),
      configurationStore: store,
    );
    await second.loadEnvironment();

    expect(second.configuration.backend.frontendBackendPath, path);
  });

  test('an explicit backend path is left untouched', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = SubDockConfigStore(directories);
    final coordinator = AppCoordinator(
      runtime: _FakeRuntime(),
      environmentStore: BackendEnvStore(directories),
      configurationStore: store,
    );
    await coordinator.loadEnvironment();
    await coordinator.saveConfiguration(
      const SubDockConfig(
        backend: SubDockBackendConfig(frontendBackendPath: '/manual'),
      ),
    );

    final reload = AppCoordinator(
      runtime: _FakeRuntime(),
      environmentStore: BackendEnvStore(directories),
      configurationStore: store,
    );
    await reload.loadEnvironment();

    expect(reload.configuration.backend.frontendBackendPath, '/manual');
  });

  test(
    'blocks failed component recovery and serializes a successful retry',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'subdock_coordinator_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final runtime = _FakeRuntime();
      var canRecover = false;
      final entered = Completer<void>();
      final release = Completer<void>();
      final coordinator = AppCoordinator(
        runtime: runtime,
        environmentStore: BackendEnvStore(
          await RuntimeDirectories.fromBaseDirectory(temp),
        ),
        startupBlocker: const AppConfigError(
          AppConfigErrorCode.componentRecoveryFailed,
          detail: 'test',
        ),
        componentRecovery: () async {
          if (!canRecover) throw StateError('component recovery failed');
          entered.complete();
          await release.future;
        },
      );
      addTearDown(coordinator.dispose);
      final observedBlockers = <Object?>[];
      coordinator.configurationChanges.addListener(
        () => observedBlockers.add(coordinator.startupBlocker),
      );

      await expectLater(coordinator.start(), throwsA(isA<AppConfigError>()));
      await expectLater(
        coordinator.retryComponentRecovery(),
        throwsA(isA<AppConfigError>()),
      );
      await expectLater(coordinator.start(), throwsA(isA<AppConfigError>()));
      expect(runtime.operations, isEmpty);
      expect(observedBlockers, contains(isA<AppConfigError>()));
      expect(coordinator.startupBlocker, isNotNull);

      canRecover = true;
      final retry = coordinator.retryComponentRecovery();
      await entered.future;
      final start = coordinator.start();
      try {
        expect(runtime.operations, isEmpty);
        expect(coordinator.startupBlocker, isNotNull);
      } finally {
        release.complete();
      }
      await Future.wait([retry, start]);

      expect(runtime.operations, ['start']);
      expect(coordinator.startupBlocker, isNull);
      expect(observedBlockers.last, isNull);
    },
  );

  test('serializes a component update with runtime actions', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final runtime = _FakeRuntime();
    final updates = _FakeUpdates(runtime.operations);
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(
        await RuntimeDirectories.fromBaseDirectory(temp),
      ),
      componentUpdates: updates,
    );

    final update = coordinator.updateComponent(updates.availableUpdate);
    await updates.updateEntered.future;
    final stop = coordinator.stop();
    try {
      await Future<void>.value();
      expect(runtime.operations, ['update']);
    } finally {
      updates.releaseUpdate.complete();
    }
    await Future.wait([update, stop]);

    expect(runtime.operations, ['update', 'stop']);
  });

  test(
    'rejects every component mutation while runtime is not stopped',
    () async {
      for (final status in RuntimeStatus.values.where(
        (status) => status != RuntimeStatus.stopped,
      )) {
        final temp = await Directory.systemTemp.createTemp(
          'subdock_coordinator_',
        );
        addTearDown(() => temp.delete(recursive: true));
        final runtime = _FakeRuntime(status: status);
        final updates = _FakeUpdates(runtime.operations);
        final coordinator = AppCoordinator(
          runtime: runtime,
          environmentStore: BackendEnvStore(
            await RuntimeDirectories.fromBaseDirectory(temp),
          ),
          componentUpdates: updates,
          componentRecovery: () async => runtime.operations.add('recover'),
        );

        for (final action in <Future<void> Function()>[
          () => coordinator.updateComponent(updates.frontendUpdate),
          () => coordinator.updateComponent(updates.backendUpdate),
          () => coordinator.rollbackComponent(ComponentKind.frontend),
          () => coordinator.rollbackComponent(ComponentKind.backend),
          coordinator.retryComponentRecovery,
        ]) {
          await expectLater(action(), throwsStateError);
        }
        expect(updates.operations, isEmpty);
        expect(runtime.operations, isEmpty);
      }
    },
  );
}

class _FakeUpdates implements ComponentUpdateOperations {
  _FakeUpdates(this.operations);

  final List<String> operations;
  final updateEntered = Completer<void>();
  final releaseUpdate = Completer<void>();
  final frontendUpdate = ComponentUpdate(
    kind: ComponentKind.frontend,
    currentVersion: '2.31.3',
    availableVersion: '2.32.0',
    release: GithubRelease(
      version: '2.32.0',
      releaseUri: Uri.parse('https://example.invalid/release'),
      assets: [],
    ),
  );
  final backendUpdate = ComponentUpdate(
    kind: ComponentKind.backend,
    currentVersion: '2.38.4',
    availableVersion: '2.39.0',
    release: GithubRelease(
      version: '2.39.0',
      releaseUri: Uri.parse('https://example.invalid/release'),
      assets: [],
    ),
  );
  ComponentUpdate get availableUpdate => frontendUpdate;

  @override
  Future<ComponentVersionStatus> status(ComponentKind kind) async =>
      const ComponentVersionStatus(current: '2.31.3');

  @override
  Future<ComponentUpdate> check(ComponentKind kind) async => availableUpdate;

  @override
  Future<void> rollback(ComponentKind kind) async => operations.add('rollback');

  @override
  Future<void> update(ComponentUpdate update) async {
    operations.add('update');
    updateEntered.complete();
    await releaseUpdate.future;
  }
}

class _FakeRuntime extends BackendRuntime {
  _FakeRuntime({this._status = RuntimeStatus.stopped});

  final operations = <String>[];
  final _states = StreamController<RuntimeState>.broadcast();
  RuntimeStatus _status;
  Map<String, String> _pending = const <String, String>{};
  EffectiveRuntimeConfig? _pendingConfiguration;
  EffectiveRuntimeConfig? _applied;
  Object? stopError;
  Object? startError;

  @override
  RuntimeState get currentState =>
      RuntimeState(status: _status, changedAt: DateTime.now());

  Map<String, String> get _active => _status == RuntimeStatus.stopped
      ? _pending
      : (_applied?.environment ?? _pending);

  int get _activePort =>
      int.tryParse(_active['SUB_STORE_BACKEND_API_PORT'] ?? '') ?? 3001;

  /// Models the frozen launch snapshot: a running process keeps its applied
  /// configuration until it is stopped and started again.
  @override
  EffectiveRuntimeConfig? get appliedConfiguration =>
      _status == RuntimeStatus.stopped ? null : _applied;

  bool? get appliedHttpMetaEnabled =>
      _status == RuntimeStatus.stopped ? null : _applied?.httpMetaEnabled;

  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:$_activePort');

  @override
  Stream<RuntimeLog> get logs => const Stream<RuntimeLog>.empty();

  @override
  Stream<RuntimeState> get state => _states.stream;

  @override
  Future<void> activateUserEnvironment(Map<String, String> environment) async {
    _pending = Map<String, String>.of(environment);
    operations.add('environment:$_activePort');
  }

  @override
  Future<void> activateConfiguration(
    EffectiveRuntimeConfig configuration,
  ) async {
    _pending = Map<String, String>.of(configuration.environment);
    _pendingConfiguration = configuration;
    final pendingPort =
        int.tryParse(_pending['SUB_STORE_BACKEND_API_PORT'] ?? '') ?? 3001;
    operations.add('configuration:$pendingPort');
  }

  @override
  Future<void> dispose() => _states.close();

  @override
  Future<BackendInfo> info() => throw UnimplementedError();

  @override
  Future<bool> isHealthy() async => false;

  @override
  Future<void> restart() async {
    await stop();
    await start();
  }

  @override
  Future<void> start() async {
    if (startError != null) throw startError!;
    _applied = _pendingConfiguration;
    _status = RuntimeStatus.running;
    operations.add('start');
  }

  @override
  Future<void> stop() async {
    if (stopError != null) throw stopError!;
    _status = RuntimeStatus.stopped;
    operations.add('stop');
  }
}

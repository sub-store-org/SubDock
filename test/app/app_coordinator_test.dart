import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/app_coordinator.dart';
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
    expect(coordinator.webUiUri.queryParameters, isEmpty);
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

    expect(coordinator.webUiApiUri, Uri.parse('http://127.0.0.1:3100/subdock'));
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

    expect(coordinator.webUiApiUri, Uri.parse('http://127.0.0.1:3100/'));
    expect(
      coordinator.webUiUri.queryParameters['api'],
      coordinator.webUiApiUri.toString(),
    );
  });

  test('keeps the merged frontend URL free of API query parameters', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final coordinator = AppCoordinator(
      runtime: _FakeRuntime(),
      environmentStore: BackendEnvStore(
        await RuntimeDirectories.fromBaseDirectory(temp),
      ),
    );

    await coordinator.saveEnvironment(BackendEnvDocument.parse(''));

    expect(coordinator.webUiUri, Uri.parse('http://127.0.0.1:3001/'));
    expect(coordinator.webUiUri.queryParameters, isEmpty);
  });

  test(
    'refuses backend start when update recovery could not complete',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'subdock_coordinator_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final runtime = _FakeRuntime();
      final coordinator = AppCoordinator(
        runtime: runtime,
        environmentStore: BackendEnvStore(
          await RuntimeDirectories.fromBaseDirectory(temp),
        ),
        startupBlocker: const AppConfigError(
          AppConfigErrorCode.componentRecoveryFailed,
          detail: 'test',
        ),
      );

      await expectLater(coordinator.start(), throwsA(isA<AppConfigError>()));

      expect(runtime.operations, isEmpty);
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

    await Future.wait([
      coordinator.updateComponent(updates.availableUpdate),
      coordinator.stop(),
    ]);

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
        );

        for (final action in <Future<void> Function()>[
          () => coordinator.updateComponent(updates.frontendUpdate),
          () => coordinator.updateComponent(updates.backendUpdate),
          () => coordinator.rollbackComponent(ComponentKind.frontend),
          () => coordinator.rollbackComponent(ComponentKind.backend),
        ]) {
          await expectLater(action(), throwsStateError);
        }
        expect(updates.operations, isEmpty);
        expect(runtime.operations, isEmpty);
      }
    },
  );

  test('exposes the injected log store instance', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = RuntimeLogStore(directories);
    final coordinator = AppCoordinator(
      runtime: _FakeRuntime(),
      environmentStore: BackendEnvStore(directories),
      logStore: store,
    );

    expect(identical(coordinator.logStore, store), isTrue);
  });
}

class _FakeUpdates implements ComponentUpdateOperations {
  _FakeUpdates(this.operations);

  final List<String> operations;
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
  Future<void> update(ComponentUpdate update) async => operations.add('update');
}

class _FakeRuntime extends BackendRuntime {
  _FakeRuntime({this.status = RuntimeStatus.stopped});

  final RuntimeStatus status;
  final operations = <String>[];
  final _states = StreamController<RuntimeState>.broadcast();
  var port = 3001;

  @override
  RuntimeState get currentState =>
      RuntimeState(status: status, changedAt: DateTime.now());

  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:$port');

  @override
  Stream<RuntimeLog> get logs => const Stream<RuntimeLog>.empty();

  @override
  Stream<RuntimeState> get state => _states.stream;

  @override
  Future<void> activateUserEnvironment(Map<String, String> environment) async {
    port =
        int.tryParse(environment['SUB_STORE_BACKEND_API_PORT'] ?? '') ?? port;
    operations.add('environment:$port');
  }

  @override
  Future<void> activateConfiguration(
    EffectiveRuntimeConfig configuration,
  ) async {
    port =
        int.tryParse(
          configuration.environment['SUB_STORE_BACKEND_API_PORT'] ?? '',
        ) ??
        port;
    operations.add('configuration:$port');
  }

  @override
  Future<void> dispose() => _states.close();

  @override
  Future<BackendInfo> info() => throw UnimplementedError();

  @override
  Future<bool> isHealthy() async => false;

  @override
  Future<void> restart() async => operations.add('restart');

  @override
  Future<void> start() async => operations.add('start');

  @override
  Future<void> stop() async => operations.add('stop');
}

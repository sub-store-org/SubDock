import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/app_coordinator.dart';
import 'package:subdock/app/maintenance_operation.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/runtime/runtime_log_store.dart';
import 'package:subdock/settings/backend_env.dart';
import 'package:subdock/settings/backend_env_store.dart';
import 'package:subdock/settings/config_error.dart';
import 'package:subdock/settings/runtime_configuration_store.dart';
import 'package:subdock/settings/subdock_config.dart';
import 'package:subdock/settings/subdock_config_store.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_recovery.dart';
import 'package:subdock/update/component_resource_resolver.dart';
import 'package:subdock/update/component_update_checker.dart';
import 'package:subdock/update/component_update_service.dart';
import 'package:subdock/update/data_backup_store.dart';
import 'package:subdock/update/github_release_client.dart';
import 'package:subdock/update/maintenance_attempt_store.dart';

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

  test(
    'preserves invalid first-run ENV and blocks startup until saved repair',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'subdock_coordinator_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final directories = await RuntimeDirectories.fromBaseDirectory(temp);
      final environmentStore = BackendEnvStore(directories);
      final configurationStore = SubDockConfigStore(directories);
      final runtime = _FakeRuntime();
      const originalEnvironment = 'SUB_STORE_BACKEND_API_PORT=invalid\n';
      await environmentStore.file.writeAsString(
        originalEnvironment,
        flush: true,
      );
      final pairStore = RuntimeConfigurationStore(
        directories: directories,
        environmentStore: environmentStore,
        configurationStore: configurationStore,
      );
      final coordinator = AppCoordinator(
        runtime: runtime,
        environmentStore: environmentStore,
        configurationStore: configurationStore,
        runtimeConfigurationStore: pairStore,
      );

      await expectLater(
        coordinator.loadEnvironment(),
        throwsA(
          isA<AppConfigError>().having(
            (error) => error.code,
            'code',
            AppConfigErrorCode.environmentInvalid,
          ),
        ),
      );
      await expectLater(
        coordinator.start(),
        throwsA(
          isA<AppConfigError>().having(
            (error) => error.code,
            'code',
            AppConfigErrorCode.environmentInvalid,
          ),
        ),
      );

      expect(coordinator.environment.rawText, originalEnvironment);
      expect(
        coordinator.configurationError?.code,
        AppConfigErrorCode.environmentInvalid,
      );
      expect(await environmentStore.readRaw(), originalEnvironment);
      expect(await configurationStore.file.exists(), isFalse);
      expect(await pairStore.recoveryFile.exists(), isFalse);
      expect(runtime.operations, isEmpty);
      expect(runtime.currentState.status, RuntimeStatus.stopped);

      await coordinator.saveRuntimeConfiguration(
        BackendEnvDocument.parse('SUB_STORE_BACKEND_API_PORT=3200\n'),
        const SubDockConfig(
          backend: SubDockBackendConfig(frontendBackendPath: '/repaired'),
        ),
      );

      expect(coordinator.configurationError, isNull);
      expect(coordinator.savedRevision, 1);
      expect(
        (await environmentStore.load()).rawText,
        'SUB_STORE_BACKEND_API_PORT=3200\n',
      );
      expect(
        (await configurationStore.load()).backend.frontendBackendPath,
        '/repaired',
      );
      await coordinator.start();

      expect(runtime.operations, ['configuration:3200', 'start']);
      expect(
        runtime.appliedConfiguration?.environment['SUB_STORE_BACKEND_API_PORT'],
        '3200',
      );
      expect(
        runtime
            .appliedConfiguration
            ?.environment['SUB_STORE_FRONTEND_BACKEND_PATH'],
        '/repaired',
      );
    },
  );

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

  test(
    'WebView origins remain bound to the applied launch configuration',
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

      expect(coordinator.appliedWebUiUri, isNull);
      await coordinator.saveEnvironment(
        BackendEnvDocument.parse(
          'SUB_STORE_BACKEND_MERGE=false\n'
          'SUB_STORE_FRONTEND_PORT=3100\n'
          'SUB_STORE_FRONTEND_BACKEND_PATH=/subdock\n',
        ),
      );
      await coordinator.start();

      final appliedUri = coordinator.appliedWebUiUri!;
      expect(appliedUri.origin, 'http://127.0.0.1:3100');
      expect(appliedUri.path, '/');
      expect(
        appliedUri.queryParameters['api'],
        'http://127.0.0.1:3001/subdock',
      );

      await coordinator.saveEnvironment(
        BackendEnvDocument.parse(
          'SUB_STORE_BACKEND_API_PORT=4000\n'
          'SUB_STORE_BACKEND_MERGE=false\n'
          'SUB_STORE_FRONTEND_PORT=3200\n'
          'SUB_STORE_FRONTEND_BACKEND_PATH=/new-api\n',
        ),
      );
      expect(coordinator.appliedWebUiUri, appliedUri);
      expect(
        coordinator.appliedWebUiApiUri,
        Uri.parse('http://127.0.0.1:3001/subdock'),
      );

      await coordinator.restart();

      expect(coordinator.appliedWebUiUri?.origin, 'http://127.0.0.1:3200');
      expect(
        coordinator.appliedWebUiApiUri,
        Uri.parse('http://127.0.0.1:4000/new-api'),
      );
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

  test('log recovery alone blocks startup until recovery succeeds', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final writer = RuntimeLogStore(directories);
    await writer.initialize();
    final runId = await writer.beginRun();
    await writer.append(
      RuntimeLog(
        timestamp: DateTime.utc(2026, 10, 16),
        source: RuntimeLogSource.stdout,
        message: 'recoverable log prefix',
      ),
    );
    final metadata = File.fromUri(
      directories.logs.uri.resolve('runs/$runId/meta.json'),
    );
    final savedMetadata = await metadata.readAsBytes();
    await metadata.writeAsString('{', flush: true);

    final logStore = RuntimeLogStore(directories);
    Object? recoveryError;
    try {
      await logStore.initialize();
    } catch (error) {
      recoveryError = error;
    }
    expect(recoveryError, isA<FormatException>());

    final runtime = _FakeRuntime();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      logStore: logStore,
      initialLogRecoveryError: recoveryError,
    );
    addTearDown(coordinator.dispose);

    await expectLater(coordinator.start(), throwsA(isA<StateError>()));
    expect(runtime.operations, isEmpty);
    expect(coordinator.logRecoveryError, same(recoveryError));

    await metadata.writeAsBytes(savedMetadata, flush: true);
    await coordinator.retryLogRecovery();
    expect(coordinator.logRecoveryError, isNull);
    await coordinator.start();
    expect(runtime.operations.last, 'start');
    expect(runtime.operations.where((operation) => operation == 'start'), [
      'start',
    ]);
  });

  test(
    'waits for admitted maintenance and rejects new intents during exit',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'subdock_coordinator_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final directories = await RuntimeDirectories.fromBaseDirectory(temp);
      final runtime = _FakeRuntime()..blockDispose = true;
      final updates = _FakeUpdates(runtime.operations, blockUpdates: true);
      final coordinator = AppCoordinator(
        runtime: runtime,
        environmentStore: BackendEnvStore(directories),
        componentUpdates: updates,
        maintenanceAttemptStore: MaintenanceAttemptStore(directories),
      );
      final confirmed = await coordinator.checkComponent(
        ComponentKind.frontend,
      );
      final maintenance = coordinator.runComponentUpdates({
        ComponentKind.frontend: confirmed,
      });
      await updates.updateEntered.future;

      final disposal = coordinator.dispose();
      expect(runtime.disposeEntered.isCompleted, isFalse);
      updates.releaseUpdate.complete();
      await maintenance;
      await runtime.disposeEntered.future;
      Future<void>? acceptedSave;
      Future<void>? acceptedStart;
      Object? saveAdmissionError;
      Object? startAdmissionError;
      try {
        expect(runtime.operations, ['update:frontend:2.32.0']);
        try {
          acceptedSave = coordinator.saveEnvironment(
            BackendEnvDocument.parse('SUB_STORE_BACKEND_API_PORT=4000\n'),
          );
        } on StateError catch (error) {
          saveAdmissionError = error;
        }
        try {
          acceptedStart = coordinator.start();
        } on StateError catch (error) {
          startAdmissionError = error;
        }
      } finally {
        runtime.releaseDispose.complete();
      }
      await disposal;
      if (acceptedSave != null) await acceptedSave;
      if (acceptedStart != null) await acceptedStart;

      expect(saveAdmissionError, isA<StateError>());
      expect(startAdmissionError, isA<StateError>());
      expect(runtime.operations, ['update:frontend:2.32.0']);
      expect(runtime.disposeCalls, 1);
    },
  );

  test(
    'runtime disposal failure leaves the coordinator available to retry',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'subdock_coordinator_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final directories = await RuntimeDirectories.fromBaseDirectory(temp);
      final disposalError = StateError('runtime disposal failed');
      final runtime = _FakeRuntime()..disposeError = disposalError;
      final coordinator = AppCoordinator(
        runtime: runtime,
        environmentStore: BackendEnvStore(directories),
        componentUpdates: _FakeUpdates(runtime.operations),
      );
      addTearDown(() async {
        runtime.disposeError = null;
        if (!runtime._states.isClosed) await runtime._states.close();
      });
      var configurationNotifications = 0;
      var maintenanceNotifications = 0;
      coordinator.configurationChanges.addListener(
        () => configurationNotifications++,
      );
      coordinator.maintenanceChanges.addListener(
        () => maintenanceNotifications++,
      );

      final firstDisposal = coordinator.dispose();
      final concurrentDisposal = coordinator.dispose();
      await expectLater(firstDisposal, throwsA(same(disposalError)));
      await expectLater(concurrentDisposal, throwsA(same(disposalError)));
      expect(runtime.disposeCalls, 1);

      runtime.disposeError = null;
      await coordinator.saveEnvironment(
        BackendEnvDocument.parse('SUB_STORE_BACKEND_API_PORT=4000\n'),
      );
      await coordinator.componentStatus(ComponentKind.frontend);
      expect(configurationNotifications, greaterThan(0));
      expect(maintenanceNotifications, greaterThan(0));

      await coordinator.dispose();
      expect(runtime.disposeCalls, 2);
      await coordinator.dispose();
      expect(runtime.disposeCalls, 2);
    },
  );

  test(
    'finishes rollback admitted before exit before runtime disposal',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'subdock_coordinator_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final directories = await RuntimeDirectories.fromBaseDirectory(temp);
      final runtime = _FakeRuntime()..blockDispose = true;
      final updates = _FakeUpdates(
        runtime.operations,
        blockStatus: true,
        blockRollbacks: true,
      );
      final coordinator = AppCoordinator(
        runtime: runtime,
        environmentStore: BackendEnvStore(directories),
        componentUpdates: updates,
        maintenanceAttemptStore: MaintenanceAttemptStore(directories),
      );

      final rollback = coordinator.rollbackComponent(ComponentKind.frontend);
      await updates.statusEntered.future;
      final disposal = coordinator.dispose();
      Future<void>? acceptedSave;
      Future<void>? acceptedStart;
      var saveRejectedBeforeStatusRelease = false;
      var startRejectedBeforeStatusRelease = false;
      try {
        try {
          acceptedSave = coordinator
              .saveEnvironment(
                BackendEnvDocument.parse('SUB_STORE_BACKEND_API_PORT=4000\n'),
              )
              .catchError((Object _) {});
        } on Object catch (error) {
          saveRejectedBeforeStatusRelease = error is StateError;
        }
        try {
          acceptedStart = coordinator.start().catchError((Object _) {});
        } on Object catch (error) {
          startRejectedBeforeStatusRelease = error is StateError;
        }
      } finally {
        updates.releaseStatus.complete();
      }
      await Future.any([
        updates.rollbackEntered.future,
        runtime.disposeEntered.future,
      ]);
      final rollbackStartedBeforeDisposal =
          updates.rollbackEntered.isCompleted &&
          !runtime.disposeEntered.isCompleted;

      updates.releaseRollback.complete();
      runtime.releaseDispose.complete();
      Object? rollbackError;
      try {
        await rollback;
      } on Object catch (error) {
        rollbackError = error;
      }
      await disposal;
      if (acceptedSave != null) await acceptedSave;
      if (acceptedStart != null) await acceptedStart;

      expect(saveRejectedBeforeStatusRelease, isTrue);
      expect(startRejectedBeforeStatusRelease, isTrue);
      expect(rollbackStartedBeforeDisposal, isTrue);
      expect(rollbackError, isNull);
      expect(updates.rollbackCalls, [ComponentKind.frontend]);
      expect(runtime.operations, ['rollback:frontend']);
      expect(runtime.disposeCalls, 1);
    },
  );

  test(
    'reserves maintenance and rejects conflicting runtime and save intents',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'subdock_coordinator_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final directories = await RuntimeDirectories.fromBaseDirectory(temp);
      final runtime = _FakeRuntime();
      final updates = _FakeUpdates(runtime.operations, blockUpdates: true);
      final coordinator = AppCoordinator(
        runtime: runtime,
        environmentStore: BackendEnvStore(directories),
        componentUpdates: updates,
        maintenanceAttemptStore: MaintenanceAttemptStore(directories),
      );

      final confirmed = await coordinator.checkComponent(
        ComponentKind.frontend,
      );
      final maintenance = coordinator.runComponentUpdates({
        ComponentKind.frontend: confirmed,
      });
      await updates.updateEntered.future;
      expect(coordinator.maintenanceOperation?.isActive, isTrue);
      await expectLater(() => coordinator.start(), throwsStateError);
      await expectLater(
        () => coordinator.applyConfiguration(),
        throwsStateError,
      );
      await expectLater(() => coordinator.stop(), throwsStateError);
      await expectLater(
        () => coordinator.saveRuntimeConfiguration(
          BackendEnvDocument.parse('SUB_STORE_BACKEND_API_PORT=4000\\n'),
          const SubDockConfig(),
        ),
        throwsStateError,
      );
      await expectLater(
        () => coordinator.updateComponent(updates.backendUpdate),
        throwsStateError,
      );
      expect(runtime.operations, ['update:frontend:2.32.0']);

      updates.releaseUpdate.complete();
      final result = await maintenance;

      expect(result.phase, MaintenancePhase.completed);
      expect(result.remainingTargets, isEmpty);
      expect(runtime.operations, ['update:frontend:2.32.0']);
      expect(await MaintenanceAttemptStore(directories).load(), isNull);
    },
  );

  test(
    'updates confirmed Frontend before Backend and resumes once when running',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'subdock_coordinator_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final directories = await RuntimeDirectories.fromBaseDirectory(temp);
      final runtime = _FakeRuntime();
      final updates = _FakeUpdates(runtime.operations);
      final coordinator = AppCoordinator(
        runtime: runtime,
        environmentStore: BackendEnvStore(directories),
        componentUpdates: updates,
        maintenanceAttemptStore: MaintenanceAttemptStore(directories),
      );
      await coordinator.saveEnvironment(
        BackendEnvDocument.parse('SUB_STORE_BACKEND_API_PORT=3002\n'),
      );
      await coordinator.start();
      final frontend = await coordinator.checkComponent(ComponentKind.frontend);
      final backend = await coordinator.checkComponent(ComponentKind.backend);

      final result = await coordinator.runComponentUpdates({
        ComponentKind.backend: backend,
        ComponentKind.frontend: frontend,
      });

      expect(result.phase, MaintenancePhase.completed);
      expect(result.results.map((item) => item.target.kind), [
        ComponentKind.frontend,
        ComponentKind.backend,
      ]);
      expect(runtime.operations, [
        'configuration:3002',
        'start',
        'stop',
        'update:frontend:2.32.0',
        'update:backend:2.39.0',
        'start',
      ]);
      expect(updates.currentVersions, {
        ComponentKind.frontend: '2.32.0',
        ComponentKind.backend: '2.39.0',
      });
      expect(await MaintenanceAttemptStore(directories).load(), isNull);
    },
  );

  test('retry preserves a committed component and does not restart a stopped Backend', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final runtime = _FakeRuntime();
    final updates = _FakeUpdates(runtime.operations)
      ..updateErrors[ComponentKind.backend] = StateError('snapshot failed');
    final store = MaintenanceAttemptStore(directories);
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      componentUpdates: updates,
      maintenanceAttemptStore: store,
    );
    await coordinator.start();
    final frontend = await coordinator.checkComponent(ComponentKind.frontend);
    final backend = await coordinator.checkComponent(ComponentKind.backend);

    final first = await coordinator.runComponentUpdates({
      ComponentKind.frontend: frontend,
      ComponentKind.backend: backend,
    });

    expect(first.phase, MaintenancePhase.failed);
    expect(first.failureStage, MaintenanceFailureStage.updating);
    expect(first.results.map((result) => result.state), [
      MaintenanceTargetState.completed,
      MaintenanceTargetState.failed,
    ]);
    expect(runtime.currentState.status, RuntimeStatus.stopped);
    expect(updates.currentVersions[ComponentKind.frontend], '2.32.0');
    expect(updates.currentVersions[ComponentKind.backend], '2.38.4');
    expect((await store.load())?.completed, [ComponentKind.frontend]);

    updates.updateErrors.remove(ComponentKind.backend);
    await coordinator.checkComponent(ComponentKind.backend);
    final retried = await coordinator.retryMaintenance();

    expect(retried.phase, MaintenancePhase.completed);
    expect(updates.updateCalls, [
      'frontend:2.32.0',
      'backend:2.39.0',
      'backend:2.39.0',
    ]);
    expect(runtime.currentState.status, RuntimeStatus.stopped);
    expect(runtime.operations, [
      'start',
      'stop',
      'update:frontend:2.32.0',
      'update:backend:2.39.0',
      'update:backend:2.39.0',
    ]);
    expect(await store.load(), isNull);
  });

  test('crashed Backend retry uses the latest saved configuration without reinstalling', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final runtime = _FakeRuntime();
    final updates = _FakeUpdates(runtime.operations);
    final store = MaintenanceAttemptStore(directories);
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      componentUpdates: updates,
      maintenanceAttemptStore: store,
    );
    await coordinator.saveEnvironment(
      BackendEnvDocument.parse('SUB_STORE_BACKEND_API_PORT=3002\n'),
    );
    await coordinator.start();
    runtime.startError = StateError('start failed');
    final confirmed = await coordinator.checkComponent(ComponentKind.frontend);

    final failed = await coordinator.runComponentUpdates({
      ComponentKind.frontend: confirmed,
    });

    expect(failed.phase, MaintenancePhase.startFailed);
    expect(failed.startOnly, isTrue);
    expect(runtime.currentState.status, RuntimeStatus.crashed);
    expect((await store.load())?.startOnly, isTrue);
    updates.updateErrors.clear();
    runtime.startError = null;
    await coordinator.saveEnvironment(
      BackendEnvDocument.parse('SUB_STORE_BACKEND_API_PORT=4310\n'),
    );

    final retried = await coordinator.retryMaintenance();

    expect(retried.phase, MaintenancePhase.completed);
    expect(updates.updateCalls, ['frontend:2.32.0']);
    expect(
      runtime.appliedConfiguration?.environment['SUB_STORE_BACKEND_API_PORT'],
      '4310',
    );
    expect(runtime.operations, [
      'configuration:3002',
      'start',
      'stop',
      'update:frontend:2.32.0',
      'configuration:4310',
      'stop',
      'start',
    ]);
    expect(await store.load(), isNull);
  });

  test(
    'start-only retry stops an unhealthy Backend before launching',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'subdock_coordinator_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final directories = await RuntimeDirectories.fromBaseDirectory(temp);
      final store = MaintenanceAttemptStore(directories);
      await store.save(
        MaintenanceAttempt(
          targets: const [
            MaintenanceTarget(
              kind: ComponentKind.frontend,
              action: MaintenanceAction.update,
              currentVersion: '2.31.3',
              targetVersion: '2.32.0',
            ),
          ],
          completed: const [ComponentKind.frontend],
          phase: MaintenancePhase.starting,
          restoreAfterChanges: true,
          startOnly: true,
        ),
      );
      final runtime = _FakeRuntime().._status = RuntimeStatus.unhealthy;
      final updates = _FakeUpdates(runtime.operations)
        ..currentVersions[ComponentKind.frontend] = '2.32.0';
      final coordinator = AppCoordinator(
        runtime: runtime,
        environmentStore: BackendEnvStore(directories),
        componentUpdates: updates,
        maintenanceAttemptStore: store,
      );
      await coordinator.restoreMaintenanceAttempt();

      final result = await coordinator.retryMaintenance();

      expect(result.phase, MaintenancePhase.completed);
      expect(runtime.operations, ['stop', 'start']);
      expect(runtime.currentState.status, RuntimeStatus.running);
      expect(updates.updateCalls, isEmpty);
      expect(await store.load(), isNull);
    },
  );

  test('marker cleanup retry does not restart a recovered Backend', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = _FailOnceClearMaintenanceAttemptStore(directories);
    await store.save(
      MaintenanceAttempt(
        targets: const [
          MaintenanceTarget(
            kind: ComponentKind.frontend,
            action: MaintenanceAction.update,
            currentVersion: '2.31.3',
            targetVersion: '2.32.0',
          ),
        ],
        completed: const [ComponentKind.frontend],
        phase: MaintenancePhase.starting,
        restoreAfterChanges: true,
        startOnly: true,
      ),
    );
    final runtime = _FakeRuntime();
    final updates = _FakeUpdates(runtime.operations)
      ..currentVersions[ComponentKind.frontend] = '2.32.0';
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      componentUpdates: updates,
      maintenanceAttemptStore: store,
    );
    await coordinator.restoreMaintenanceAttempt();

    final failed = await coordinator.retryMaintenance();

    expect(failed.phase, MaintenancePhase.blocked);
    expect(failed.failureStage, MaintenanceFailureStage.recovery);
    expect(failed.results.single.state, MaintenanceTargetState.completed);
    expect(runtime.currentState.status, RuntimeStatus.running);
    expect(runtime.operations, ['start']);
    expect(updates.updateCalls, isEmpty);
    expect((await store.load())?.completed, [ComponentKind.frontend]);
    final operationsBeforeCleanupRetry = List<String>.of(runtime.operations);

    final retried = await coordinator.retryMaintenance();

    expect(retried.phase, MaintenancePhase.completed);
    expect(runtime.operations, operationsBeforeCleanupRetry);
    expect(updates.updateCalls, isEmpty);
    expect(await store.load(), isNull);
  });

  test('stopped-origin cleanup retry leaves the Backend stopped', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = _FailOnceClearMaintenanceAttemptStore(directories);
    final runtime = _FakeRuntime();
    final updates = _FakeUpdates(runtime.operations);
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      componentUpdates: updates,
      maintenanceAttemptStore: store,
    );
    final confirmed = await coordinator.checkComponent(ComponentKind.frontend);

    final failed = await coordinator.runComponentUpdates({
      ComponentKind.frontend: confirmed,
    });

    expect(failed.phase, MaintenancePhase.blocked);
    expect(failed.failureStage, MaintenanceFailureStage.recovery);
    expect(failed.results.single.state, MaintenanceTargetState.completed);
    expect(runtime.currentState.status, RuntimeStatus.stopped);
    expect(runtime.operations, ['update:frontend:2.32.0']);
    expect(updates.updateCalls, ['frontend:2.32.0']);
    expect((await store.load())?.completed, [ComponentKind.frontend]);

    final retried = await coordinator.retryMaintenance();

    expect(retried.phase, MaintenancePhase.completed);
    expect(runtime.currentState.status, RuntimeStatus.stopped);
    expect(runtime.operations, ['update:frontend:2.32.0']);
    expect(updates.updateCalls, ['frontend:2.32.0']);
    expect(await store.load(), isNull);
  });

  test(
    'committed rollback cleanup retries without repeating the rollback',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'subdock_coordinator_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final directories = await RuntimeDirectories.fromBaseDirectory(temp);
      final runtime = _FakeRuntime();
      final updates = _FakeUpdates(runtime.operations)
        ..rollbackResults[ComponentKind.backend] =
            ComponentRollbackResult.cleanupPending(
              StateError('snapshot delete failed'),
            );
      final store = MaintenanceAttemptStore(directories);
      var recoveries = 0;
      final coordinator = AppCoordinator(
        runtime: runtime,
        environmentStore: BackendEnvStore(directories),
        componentUpdates: updates,
        maintenanceAttemptStore: store,
        componentRecovery: () async => recoveries++,
      );
      final confirmed = await coordinator.componentStatus(
        ComponentKind.backend,
      );

      final blocked = await coordinator.runComponentRollback(
        ComponentKind.backend,
        confirmedStatus: confirmed,
      );

      expect(blocked.phase, MaintenancePhase.blocked);
      expect(blocked.failureStage, MaintenanceFailureStage.recovery);
      expect(blocked.remainingTargets, isEmpty);
      expect(blocked.error, isA<ComponentRollbackCleanupFailure>());
      expect(blocked.error.toString(), contains('rollback committed'));
      expect(blocked.error.toString(), contains('snapshot delete failed'));
      expect(updates.rollbackCalls, [ComponentKind.backend]);
      expect(runtime.currentState.status, RuntimeStatus.stopped);
      expect(runtime.operations, ['rollback:backend']);
      expect((await store.load())?.completed, [ComponentKind.backend]);
      expect(
        (await store.load())?.failureStage,
        MaintenanceFailureStage.recovery,
      );

      final retried = await coordinator.retryMaintenance();

      expect(retried.phase, MaintenancePhase.completed);
      expect(recoveries, 1);
      expect(updates.rollbackCalls, [ComponentKind.backend]);
      expect(runtime.currentState.status, RuntimeStatus.stopped);
      expect(runtime.operations, ['rollback:backend']);
      expect(await store.load(), isNull);
    },
  );

  test(
    'keeps committed rollback cleanup pending after recovery itself fails',
    () async {
      final fixture = await _createRollbackCoordinatorFixture(
        runtimeStatus: RuntimeStatus.stopped,
        discardFailures: 2,
      );
      final store = MaintenanceAttemptStore(fixture.directories);
      var recoveryAttempts = 0;
      final coordinator = AppCoordinator(
        runtime: fixture.runtime,
        environmentStore: BackendEnvStore(fixture.directories),
        componentUpdates: fixture.updates,
        maintenanceAttemptStore: store,
        componentRecovery: () async {
          recoveryAttempts++;
          await fixture.recoverPending();
        },
      );
      final confirmed = await coordinator.componentStatus(
        ComponentKind.backend,
      );

      final committed = await coordinator.runComponentRollback(
        ComponentKind.backend,
        confirmedStatus: confirmed,
      );
      expect(committed.phase, MaintenancePhase.blocked);
      expect(committed.results.single.state, MaintenanceTargetState.completed);
      expect(fixture.runtime.currentState.status, RuntimeStatus.stopped);
      expect(
        await fixture.backendMetadata(),
        predicate<ComponentMetadata>(
          (metadata) => metadata.cleanupBackupId == fixture.targetBackupId,
        ),
      );
      expect(await fixture.backendVersion(), '2.38.4');
      expect(await fixture.dataContents(), 'restored-data');

      final recoveryFailed = await coordinator.retryMaintenance();
      expect(recoveryFailed.phase, MaintenancePhase.blocked);
      expect(recoveryFailed.failureStage, MaintenanceFailureStage.recovery);
      expect(
        recoveryFailed.error.toString(),
        contains('injected snapshot cleanup failure'),
      );
      expect(
        recoveryFailed.committedRollbackCleanupFailure?.error.toString(),
        contains('injected snapshot cleanup failure'),
      );
      expect((await store.load())?.completed, [ComponentKind.backend]);
      expect(
        (await fixture.backendMetadata()).cleanupBackupId,
        fixture.targetBackupId,
      );
      expect(fixture.runtime.currentState.status, RuntimeStatus.stopped);
      expect(await fixture.backendVersion(), '2.38.4');
      expect(await fixture.dataContents(), 'restored-data');

      final retried = await coordinator.retryMaintenance();

      expect(retried.phase, MaintenancePhase.completed);
      expect(recoveryAttempts, 2);
      expect((await fixture.backendMetadata()).cleanupBackupId, isNull);
      expect(await fixture.backups.list(), [
        (await fixture.backendMetadata()).previousBackupId,
      ]);
      expect(await fixture.backendVersion(), '2.38.4');
      expect(await fixture.dataContents(), 'restored-data');
      expect(fixture.runtime.currentState.status, RuntimeStatus.stopped);
      expect(fixture.runtime.operations, isEmpty);
    },
  );

  test(
    'recovers committed rollback cleanup after its completed checkpoint fails',
    () async {
      final fixture = await _createRollbackCoordinatorFixture(
        runtimeStatus: RuntimeStatus.stopped,
        discardFailures: 1,
      );
      final store = _FailOnceCompletedMaintenanceAttemptStore(
        fixture.directories,
      );
      final coordinator = AppCoordinator(
        runtime: fixture.runtime,
        environmentStore: BackendEnvStore(fixture.directories),
        componentUpdates: fixture.updates,
        maintenanceAttemptStore: store,
        componentRecovery: fixture.recoverPending,
      );
      await coordinator.start();
      final confirmed = await coordinator.componentStatus(
        ComponentKind.backend,
      );

      final checkpointFailed = await coordinator.runComponentRollback(
        ComponentKind.backend,
        confirmedStatus: confirmed,
      );

      expect(checkpointFailed.phase, MaintenancePhase.blocked);
      expect(checkpointFailed.failureStage, MaintenanceFailureStage.recovery);
      expect(
        checkpointFailed.error.toString(),
        contains('completed target checkpoint failed'),
      );
      expect(
        checkpointFailed.committedRollbackCleanupFailure?.error.toString(),
        contains('injected snapshot cleanup failure'),
      );
      expect((await store.load())?.completed, [ComponentKind.backend]);
      expect(
        (await fixture.backendMetadata()).cleanupBackupId,
        fixture.targetBackupId,
      );
      expect(fixture.runtime.currentState.status, RuntimeStatus.stopped);
      expect(await fixture.backendVersion(), '2.38.4');
      expect(await fixture.dataContents(), 'restored-data');

      final retried = await coordinator.retryMaintenance();

      expect(retried.phase, MaintenancePhase.completed);
      expect((await fixture.backendMetadata()).cleanupBackupId, isNull);
      expect(await fixture.backups.list(), [
        (await fixture.backendMetadata()).previousBackupId,
      ]);
      expect(await fixture.backendVersion(), '2.38.4');
      expect(await fixture.dataContents(), 'restored-data');
      expect(fixture.runtime.currentState.status, RuntimeStatus.running);
      expect(fixture.runtime.operations, ['start', 'stop', 'start']);
      expect(await store.load(), isNull);
    },
  );

  test(
    'retains prior-running restoration after cleanup succeeds but status fails',
    () async {
      final fixture = await _createRollbackCoordinatorFixture(
        runtimeStatus: RuntimeStatus.stopped,
        discardFailures: 1,
      );
      final store = MaintenanceAttemptStore(fixture.directories);
      var failNextStatus = true;
      final coordinator = AppCoordinator(
        runtime: fixture.runtime,
        environmentStore: BackendEnvStore(fixture.directories),
        componentUpdates: fixture.updates,
        maintenanceAttemptStore: store,
        componentRecovery: () async {
          await fixture.recoverPending();
          if (failNextStatus) {
            failNextStatus = false;
            await _writeRollbackFile(
              fixture.bundle,
              'data/backend/version',
              'invalid version\n',
            );
          }
        },
      );
      await coordinator.start();
      final confirmed = await coordinator.componentStatus(
        ComponentKind.backend,
      );
      await coordinator.runComponentRollback(
        ComponentKind.backend,
        confirmedStatus: confirmed,
      );

      final statusFailed = await coordinator.retryMaintenance();

      expect(statusFailed.phase, MaintenancePhase.blocked);
      expect(statusFailed.failureStage, MaintenanceFailureStage.recovery);
      expect(
        statusFailed.committedRollbackCleanupFailure?.error.toString(),
        contains('injected snapshot cleanup failure'),
      );
      expect((await fixture.backendMetadata()).cleanupBackupId, isNull);
      expect((await store.load())?.completed, [ComponentKind.backend]);
      expect(fixture.runtime.currentState.status, RuntimeStatus.stopped);
      await _writeRollbackFile(
        fixture.bundle,
        'data/backend/version',
        '2.38.4\n',
      );

      final retried = await coordinator.retryMaintenance();

      expect(retried.phase, MaintenancePhase.completed);
      expect(fixture.runtime.currentState.status, RuntimeStatus.running);
      expect(fixture.runtime.operations, ['start', 'stop', 'start']);
      expect(await store.load(), isNull);
      expect(await fixture.backendVersion(), '2.38.4');
      expect(await fixture.dataContents(), 'restored-data');
    },
  );

  test('stop failure leaves all component files untouched', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final runtime = _FakeRuntime()..startError = null;
    final updates = _FakeUpdates(runtime.operations);
    final store = MaintenanceAttemptStore(directories);
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      componentUpdates: updates,
      maintenanceAttemptStore: store,
    );
    await coordinator.start();
    runtime.stopError = StateError('stop failed');
    final confirmed = await coordinator.checkComponent(ComponentKind.frontend);

    final result = await coordinator.runComponentUpdates({
      ComponentKind.frontend: confirmed,
    });

    expect(result.failureStage, MaintenanceFailureStage.stopping);
    expect(updates.updateCalls, isEmpty);
    expect(runtime.currentState.status, RuntimeStatus.running);
    expect(runtime.operations, ['start']);
    expect((await store.load())?.phase, MaintenancePhase.failed);
  });

  test('interprets interrupted results after component recovery without resuming work', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = MaintenanceAttemptStore(directories);
    await store.save(
      MaintenanceAttempt(
        targets: const [
          MaintenanceTarget(
            kind: ComponentKind.frontend,
            action: MaintenanceAction.update,
            currentVersion: '2.31.3',
            targetVersion: '2.32.0',
          ),
          MaintenanceTarget(
            kind: ComponentKind.backend,
            action: MaintenanceAction.update,
            currentVersion: '2.38.4',
            targetVersion: '2.39.0',
          ),
        ],
        completed: const [ComponentKind.frontend],
        phase: MaintenancePhase.updating,
        restoreAfterChanges: true,
        startOnly: false,
      ),
    );
    final runtime = _FakeRuntime();
    final updates = _FakeUpdates(runtime.operations)
      ..currentVersions[ComponentKind.frontend] = '2.32.0';
    var recovered = false;
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      componentUpdates: updates,
      maintenanceAttemptStore: store,
      componentRecovery: () async => recovered = true,
    );

    await coordinator.retryComponentRecovery();

    expect(recovered, isTrue);
    expect(
      coordinator.maintenanceOperation?.phase,
      MaintenancePhase.interrupted,
    );
    expect(
      coordinator.maintenanceOperation?.results.map((result) => result.state),
      [MaintenanceTargetState.completed, MaintenanceTargetState.pending],
    );
    expect(runtime.operations, isEmpty);
    expect(updates.updateCalls, isEmpty);
    expect((await store.load())?.completed, [ComponentKind.frontend]);
  });

  test(
    'transient maintenance recovery failure clears after revalidation',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'subdock_coordinator_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final directories = await RuntimeDirectories.fromBaseDirectory(temp);
      final store = MaintenanceAttemptStore(directories);
      await store.save(
        MaintenanceAttempt(
          targets: const [
            MaintenanceTarget(
              kind: ComponentKind.frontend,
              action: MaintenanceAction.update,
              currentVersion: '2.31.3',
              targetVersion: '2.32.0',
            ),
          ],
          completed: const [],
          phase: MaintenancePhase.updating,
          restoreAfterChanges: false,
          startOnly: false,
        ),
      );
      final runtime = _FakeRuntime();
      final updates = _FakeUpdates(runtime.operations)
        ..failStatusOnCall[ComponentKind.frontend] = 1
        ..statusErrors[ComponentKind.frontend] = StateError(
          'temporary failure',
        );
      final coordinator = AppCoordinator(
        runtime: runtime,
        environmentStore: BackendEnvStore(directories),
        componentUpdates: updates,
        maintenanceAttemptStore: store,
      );

      await coordinator.restoreMaintenanceAttempt();

      expect(coordinator.maintenanceRecoveryError, isNotNull);
      expect(await store.file.exists(), isTrue);
      expect(runtime.operations, isEmpty);
      updates.statusErrors.remove(ComponentKind.frontend);

      await coordinator.restoreMaintenanceAttempt();

      expect(coordinator.maintenanceRecoveryError, isNull);
      expect(
        coordinator.maintenanceOperation?.phase,
        MaintenancePhase.interrupted,
      );
      expect((await store.load())?.completed, isEmpty);
      await coordinator.start();
      expect(runtime.currentState.status, RuntimeStatus.running);

      await coordinator.stop();
      updates.statusErrors[ComponentKind.frontend] = StateError(
        'temporary failure',
      );
      updates.failStatusOnCall[ComponentKind.frontend] = 3;
      await coordinator.restoreMaintenanceAttempt();
      expect(coordinator.maintenanceRecoveryError, isNotNull);
      await store.clear();

      await coordinator.restoreMaintenanceAttempt();

      expect(coordinator.maintenanceRecoveryError, isNull);
      expect(coordinator.maintenanceOperation, isNull);
      await coordinator.start();
      expect(runtime.currentState.status, RuntimeStatus.running);
    },
  );

  test('corrupt maintenance marker blocks start and remains available for diagnosis', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_coordinator_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = MaintenanceAttemptStore(directories);
    await store.file.writeAsString('{not json');
    final runtime = _FakeRuntime();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      componentUpdates: _FakeUpdates(runtime.operations),
      maintenanceAttemptStore: store,
    );

    await coordinator.restoreMaintenanceAttempt();
    await expectLater(coordinator.start(), throwsA(isA<AppConfigError>()));

    expect(coordinator.maintenanceRecoveryError, isNotNull);
    expect(await store.file.readAsString(), '{not json');
    expect(runtime.operations, isEmpty);
  });

  test(
    'does not change components while the Backend is transitioning',
    () async {
      for (final status in [RuntimeStatus.starting, RuntimeStatus.stopping]) {
        final temp = await Directory.systemTemp.createTemp(
          'subdock_coordinator_',
        );
        addTearDown(() => temp.delete(recursive: true));
        final directories = await RuntimeDirectories.fromBaseDirectory(temp);
        final runtime = _FakeRuntime(status: status);
        final updates = _FakeUpdates(runtime.operations);
        final coordinator = AppCoordinator(
          runtime: runtime,
          environmentStore: BackendEnvStore(directories),
          componentUpdates: updates,
          maintenanceAttemptStore: MaintenanceAttemptStore(directories),
        );
        final confirmed = await coordinator.checkComponent(
          ComponentKind.frontend,
        );

        final result = await coordinator.runComponentUpdates({
          ComponentKind.frontend: confirmed,
        });

        expect(result.phase, MaintenancePhase.failed);
        expect(result.failureStage, MaintenanceFailureStage.recovery);
        expect(updates.updateCalls, isEmpty);
        expect(runtime.operations, isEmpty);
      }
    },
  );
}

class _FakeUpdates implements ComponentUpdateOperations {
  _FakeUpdates(
    this.operations, {
    this.blockUpdates = false,
    this.blockStatus = false,
    this.blockRollbacks = false,
  });

  final List<String> operations;
  final rollbackResults = <ComponentKind, ComponentRollbackResult>{};
  final bool blockUpdates;
  final bool blockStatus;
  final bool blockRollbacks;
  final updateEntered = Completer<void>();
  final releaseUpdate = Completer<void>();
  final statusEntered = Completer<void>();
  final releaseStatus = Completer<void>();
  final rollbackEntered = Completer<void>();
  final releaseRollback = Completer<void>();
  final currentVersions = <ComponentKind, String>{
    ComponentKind.frontend: '2.31.3',
    ComponentKind.backend: '2.38.4',
  };
  final previousVersions = <ComponentKind, String?>{
    ComponentKind.frontend: '2.30.0',
    ComponentKind.backend: '2.38.3',
  };
  final statusCalls = <ComponentKind, int>{};
  final checkCalls = <ComponentKind, int>{};
  final failStatusOnCall = <ComponentKind, int>{};
  final statusErrors = <ComponentKind, Object>{};
  final checkErrors = <ComponentKind, Object>{};
  final updateErrors = <ComponentKind, Object>{};
  final updateCalls = <String>[];
  final rollbackCalls = <ComponentKind>[];
  final frontendUpdate = ComponentUpdate(
    kind: ComponentKind.frontend,
    currentVersion: '2.31.3',
    availableVersion: '2.32.0',
    release: GithubRelease(
      version: '2.32.0',
      releaseUri: Uri.parse('https://example.invalid/frontend'),
      assets: [],
    ),
  );
  final backendUpdate = ComponentUpdate(
    kind: ComponentKind.backend,
    currentVersion: '2.38.4',
    availableVersion: '2.39.0',
    release: GithubRelease(
      version: '2.39.0',
      releaseUri: Uri.parse('https://example.invalid/backend'),
      assets: [],
    ),
  );
  ComponentUpdate get availableUpdate => frontendUpdate;

  @override
  Future<ComponentVersionStatus> status(ComponentKind kind) async {
    final count = (statusCalls[kind] ?? 0) + 1;
    statusCalls[kind] = count;
    final error = statusErrors[kind];
    if (failStatusOnCall[kind] == count && error != null) throw error;
    if (blockStatus) {
      if (!statusEntered.isCompleted) statusEntered.complete();
      await releaseStatus.future;
    }
    return ComponentVersionStatus(
      current: currentVersions[kind]!,
      previous: previousVersions[kind],
    );
  }

  @override
  Future<ComponentUpdate> check(ComponentKind kind) async {
    checkCalls[kind] = (checkCalls[kind] ?? 0) + 1;
    final error = checkErrors[kind];
    if (error != null) throw error;
    return kind == ComponentKind.frontend ? frontendUpdate : backendUpdate;
  }

  @override
  Future<ComponentRollbackResult> rollback(ComponentKind kind) async {
    rollbackCalls.add(kind);
    operations.add('rollback:${kind.name}');
    if (blockRollbacks) {
      if (!rollbackEntered.isCompleted) rollbackEntered.complete();
      await releaseRollback.future;
    }
    final previous = previousVersions[kind];
    if (previous == null) throw StateError('No previous component');
    previousVersions[kind] = currentVersions[kind];
    currentVersions[kind] = previous;
    return rollbackResults[kind] ?? const ComponentRollbackResult.completed();
  }

  @override
  Future<void> update(ComponentUpdate update) async {
    updateCalls.add('${update.kind.name}:${update.availableVersion}');
    operations.add('update:${update.kind.name}:${update.availableVersion}');
    if (blockUpdates) {
      if (!updateEntered.isCompleted) updateEntered.complete();
      await releaseUpdate.future;
    }
    final error = updateErrors[update.kind];
    if (error != null) throw error;
    currentVersions[update.kind] = update.availableVersion;
  }
}

class _RollbackCoordinatorFixture {
  const _RollbackCoordinatorFixture({
    required this.bundle,
    required this.directories,
    required this.runtime,
    required this.metadataStore,
    required this.backups,
    required this.updates,
    required this.targetBackupId,
  });

  final Directory bundle;
  final RuntimeDirectories directories;
  final _FakeRuntime runtime;
  final ComponentMetadataStore metadataStore;
  final _FailingDiscardBackups backups;
  final ComponentUpdateService updates;
  final String targetBackupId;

  Future<ComponentMetadata> backendMetadata() =>
      metadataStore.load(ComponentKind.backend, baseline: '2.38.4');

  Future<String> backendVersion() async => (await ComponentResourceResolver(
    bundleDirectory: bundle,
    componentsDirectory: directories.components,
    metadataStore: metadataStore,
  ).resolve()).backendVersion;

  Future<String> dataContents() =>
      File('${directories.data.path}/settings.json').readAsString();

  Future<void> recoverPending() async {
    await ComponentRecovery(
      bundleDirectory: bundle,
      dataDirectory: directories.data,
      metadataStore: metadataStore,
      dataBackups: backups,
    ).recoverPending();
  }
}

Future<_RollbackCoordinatorFixture> _createRollbackCoordinatorFixture({
  required RuntimeStatus runtimeStatus,
  required int discardFailures,
}) async {
  final root = await Directory.systemTemp.createTemp(
    'subdock_rollback_coordinator_',
  );
  addTearDown(() => root.delete(recursive: true));
  final bundle = Directory.fromUri(root.uri.resolve('bundle/'));
  await _writeRollbackFile(bundle, 'data/backend/version', '2.38.4\n');
  await _writeRollbackFile(
    bundle,
    'data/backend/sub-store.bundle.js',
    'packaged backend',
  );
  await _writeRollbackFile(
    bundle,
    'data/backend/runtime-manifest.json',
    '{"testedNode":"24.15.0","externalBinary":[]}',
  );
  await _writeRollbackFile(bundle, 'data/frontend/version', '2.31.3\n');
  await _writeRollbackFile(
    bundle,
    'data/frontend/index.html',
    'packaged frontend',
  );
  final directories = await RuntimeDirectories.fromBaseDirectory(
    Directory.fromUri(root.uri.resolve('support/')),
  );
  await _writeRollbackFile(directories.data, 'settings.json', 'restored-data');
  final metadataStore = ComponentMetadataStore(directories.components);
  final backups = _FailingDiscardBackups(
    backupsDirectory: directories.backups,
    stagingDirectory: directories.staging,
    failuresRemaining: discardFailures,
  );
  final targetBackupId = await backups.create(directories.data);
  await _writeRollbackFile(directories.data, 'settings.json', 'active-data');
  await _writeRollbackFile(
    directories.components,
    'backend/2.39.0/sub-store.bundle.js',
    'active backend',
  );
  await _writeRollbackFile(
    directories.components,
    'backend/2.39.0/runtime-manifest.json',
    '{"testedNode":"24.15.0","externalBinary":[]}',
  );
  await metadataStore.save(
    ComponentKind.backend,
    ComponentMetadata(
      baseline: '2.38.4',
      active: '2.39.0',
      previous: '2.38.4',
      previousBackupId: targetBackupId,
    ),
  );
  final runtime = _FakeRuntime(status: runtimeStatus);
  final resources = ComponentResourceResolver(
    bundleDirectory: bundle,
    componentsDirectory: directories.components,
    metadataStore: metadataStore,
  );
  final updates = ComponentUpdateService(
    runtime: runtime,
    directories: directories,
    metadataStore: metadataStore,
    resources: resources,
    releases: GithubReleaseClient(),
    backups: backups,
  );
  return _RollbackCoordinatorFixture(
    bundle: bundle,
    directories: directories,
    runtime: runtime,
    metadataStore: metadataStore,
    backups: backups,
    updates: updates,
    targetBackupId: targetBackupId,
  );
}

Future<void> _writeRollbackFile(
  Directory root,
  String path,
  String contents,
) async {
  final file = File.fromUri(root.uri.resolve(path));
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
}

class _FailingDiscardBackups extends DataBackupStore {
  _FailingDiscardBackups({
    required super.backupsDirectory,
    required super.stagingDirectory,
    required this.failuresRemaining,
  });

  int failuresRemaining;

  @override
  Future<void> discard(String backupId) async {
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('injected snapshot cleanup failure');
    }
    await super.discard(backupId);
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
  Object? disposeError;
  var blockDispose = false;
  final disposeEntered = Completer<void>();
  final releaseDispose = Completer<void>();
  var disposeCalls = 0;

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
  Future<void> dispose() async {
    disposeCalls++;
    if (!disposeEntered.isCompleted) disposeEntered.complete();
    if (blockDispose) await releaseDispose.future;
    if (disposeError != null) throw disposeError!;
    await _states.close();
  }

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
    if (startError != null) {
      // Match DesktopBackendRuntime's state after a failed launch.
      _status = RuntimeStatus.crashed;
      _states.add(RuntimeState(status: _status, changedAt: DateTime.now()));
      throw startError!;
    }
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

class _FailOnceCompletedMaintenanceAttemptStore
    extends MaintenanceAttemptStore {
  _FailOnceCompletedMaintenanceAttemptStore(super.directories);

  var failNextCompletedSave = true;

  @override
  Future<void> save(MaintenanceAttempt attempt) async {
    if (failNextCompletedSave &&
        attempt.completed.contains(ComponentKind.backend)) {
      failNextCompletedSave = false;
      throw StateError('completed target checkpoint failed');
    }
    await super.save(attempt);
  }
}

class _FailOnceClearMaintenanceAttemptStore extends MaintenanceAttemptStore {
  _FailOnceClearMaintenanceAttemptStore(super.directories);

  var failNextClear = true;

  @override
  Future<void> clear() async {
    if (failNextClear) {
      failNextClear = false;
      throw StateError('maintenance marker cleanup failed');
    }
    await super.clear();
  }
}

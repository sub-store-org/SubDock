import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/desktop_backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/runtime/runtime_log_store.dart';
import 'package:subdock/settings/backend_env.dart';
import 'package:subdock/settings/subdock_config.dart';
import 'package:subdock/update/component_metadata_store.dart';

void main() {
  group('DesktopBackendRuntime', () {
    late Directory temp;
    late DesktopBackendRuntime runtime;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('subdock_runtime_');
      runtime = await _createRuntime(temp, bundledNodeVersion: '24.15.0');
    });

    tearDown(() async {
      try {
        await runtime.dispose();
      } on Object {
        // A persistence-failure fixture may reject finalization once.
      }
      await temp.delete(recursive: true);
    });

    test('starts once, streams logs, reports info, and stops', () async {
      final logs = <RuntimeLog>[];
      final states = <RuntimeState>[];
      final logSubscription = runtime.logs.listen(logs.add);
      final stateSubscription = runtime.state.listen(states.add);
      addTearDown(logSubscription.cancel);
      addTearDown(stateSubscription.cancel);

      await runtime.start();
      await runtime.start();

      expect(await runtime.isHealthy(), isTrue);
      expect((await runtime.info()).backendVersion, 'fixture-backend');
      expect(
        states.where((state) => state.status == RuntimeStatus.starting),
        hasLength(1),
      );
      await _waitFor(() => logs.length >= 2);
      expect(
        logs.map((log) => log.source),
        containsAll(<RuntimeLogSource>[
          RuntimeLogSource.stdout,
          RuntimeLogSource.stderr,
        ]),
      );
      final legacyLog = File.fromUri(
        temp.uri.resolve('application-support/logs/backend.log'),
      );
      await runtime.stop();

      final runs = await runtime.logStore.listRuns();
      expect(runs, hasLength(1));
      expect(
        (await runtime.logStore.readRun(runs.single.id))
            .map((log) => log.message),
        containsAll(<String>['fixture stdout', 'fixture stderr']),
      );
      expect(await legacyLog.exists(), isFalse);

      expect(states.last.status, RuntimeStatus.stopped);
      expect(runtime.currentState.status, RuntimeStatus.stopped);
      expect(runtime.endpoint, Uri.parse('http://127.0.0.1:${runtime.port}'));
    });

    test('reports an unexpected child exit as crashed', () async {
      runtime = await _createRuntime(temp, mode: 'crash');
      final states = <RuntimeState>[];
      final subscription = runtime.state.listen(states.add);
      addTearDown(subscription.cancel);

      await expectLater(runtime.start(), throwsStateError);
      await _waitFor(
        () => states.any((state) => state.status == RuntimeStatus.crashed),
      );

      expect(runtime.currentState.status, RuntimeStatus.crashed);
      final runs = await runtime.logStore.listRuns();
      expect(runs, hasLength(1));
      expect((await runtime.logStore.readRun(runs.single.id)), isNotEmpty);
    });

    test('publishes startup failure only after history is finalized', () async {
      final blockedPort = await _unusedPort();
      final blocker = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        blockedPort,
      );
      addTearDown(blocker.close);
      runtime = await _createRuntime(temp, port: blockedPort);
      final runsAtCrash = <int>[];
      final subscription = runtime.state.listen((state) async {
        if (state.status == RuntimeStatus.crashed) {
          runsAtCrash.add(
            await runtime.logStore.listRuns().then((runs) => runs.length),
          );
        }
      });
      addTearDown(subscription.cancel);

      await expectLater(
        runtime.start(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('occupied by an unknown process'),
          ),
        ),
      );
      await _waitFor(() => runsAtCrash.isNotEmpty);
      expect(runsAtCrash.single, 1);
      expect(runtime.currentState.status, RuntimeStatus.crashed);
      expect(await runtime.logStore.listRuns(), hasLength(1));
    });

    test('finalizes a run when a running backend exits unexpectedly', () async {
      runtime = await _createRuntime(temp, mode: 'unexpected-exit');
      final states = <RuntimeState>[];
      final subscription = runtime.state.listen(states.add);
      addTearDown(subscription.cancel);

      await runtime.start();
      await _waitFor(
        () => states.any((state) => state.status == RuntimeStatus.crashed),
      );

      expect(await runtime.logStore.listRuns(), hasLength(1));
      expect(runtime.currentState.status, RuntimeStatus.crashed);
    });

    test(
      'keeps an append failure incomplete through normal shutdown',
      () async {
        runtime = await _createRuntime(temp, failingAppend: true);
        final updates = <RuntimeLogRunUpdate>[];
        final subscription = runtime.logRunUpdates.listen(updates.add);
        addTearDown(subscription.cancel);

        await runtime.start();
        await _waitFor(() => updates.any((update) => !update.finalized));
        final captureFailure = updates.singleWhere(
          (update) => !update.finalized,
        );
        expect(captureFailure.integrity, RuntimeLogIntegrity.incomplete);
        expect(captureFailure.persistenceConfirmed, isFalse);
        expect(captureFailure.retryAvailable, isFalse);

        await runtime.stop();
        final run = (await runtime.logStore.listRuns()).single;
        expect(run.id, captureFailure.runId);
        expect(run.integrity, RuntimeLogIntegrity.incomplete);
        expect(runtime.currentState.status, RuntimeStatus.stopped);
        expect(updates.last.integrity, RuntimeLogIntegrity.incomplete);
        expect(updates.last.persistenceConfirmed, isTrue);
      },
    );

    test(
      'publishes incomplete finalization and retries before a new run',
      () async {
        runtime = await _createRuntime(
          temp,
          mode: 'unexpected-exit',
          failingFinalize: true,
        );
        final states = <RuntimeState>[];
        final updates = <RuntimeLogRunUpdate>[];
        final stateSubscription = runtime.state.listen(states.add);
        final updateSubscription = runtime.logRunUpdates.listen(updates.add);
        addTearDown(stateSubscription.cancel);
        addTearDown(updateSubscription.cancel);

        await runtime.start();
        await _waitFor(
          () => updates.any(
            (update) => update.finalized && !update.persistenceConfirmed,
          ),
        );
        final failure = updates.singleWhere(
          (update) => update.finalized && !update.persistenceConfirmed,
        );
        expect(failure.integrity, RuntimeLogIntegrity.incomplete);
        expect(failure.retryAvailable, isTrue);
        expect(runtime.currentState.status, RuntimeStatus.crashed);
        expect(runtime.currentState.message, contains('finalization'));
        expect(
          runtime.currentState.message,
          isNot(contains('fixture failure')),
        );
        expect(await runtime.logStore.listRuns(), isEmpty);

        await runtime.retryLogFinalization(failure.runId);
        final incomplete = (await runtime.logStore.listRuns()).single;
        expect(incomplete.id, failure.runId);
        expect(incomplete.integrity, RuntimeLogIntegrity.incomplete);
        expect((await runtime.logStore.readRun(incomplete.id)), isNotEmpty);
        final retried = updates.lastWhere(
          (update) => update.runId == failure.runId,
        );
        expect(retried.integrity, RuntimeLogIntegrity.incomplete);
        expect(retried.finalized, isTrue);
        expect(retried.persistenceConfirmed, isTrue);
        expect(retried.retryAvailable, isFalse);

        await runtime.start();
        await _waitFor(
          () => updates.any(
            (update) => update.runId != failure.runId && update.finalized,
          ),
        );
        final runs = await runtime.logStore.listRuns();
        expect(runs, hasLength(2));
        expect(
          runs.singleWhere((run) => run.id == failure.runId).integrity,
          RuntimeLogIntegrity.incomplete,
        );
        final second = runs.singleWhere((run) => run.id != failure.runId);
        expect(second.integrity, RuntimeLogIntegrity.complete);
        await runtime.stop();
      },
    );

    test(
      'keeps one actual run identity across HTTP-META state changes',
      () async {
        final httpMetaPort = await _unusedPort();
        runtime = await _createRuntime(
          temp,
          httpMetaPort: httpMetaPort,
          httpMetaExitOnRequest: true,
        );
        final runIds = <String>[];
        final states = <RuntimeState>[];
        final runSubscription = runtime.logRunStarted.listen(
          (event) => runIds.add(event.runId),
        );
        final stateSubscription = runtime.state.listen(states.add);
        addTearDown(runSubscription.cancel);
        addTearDown(stateSubscription.cancel);

        await runtime.start();
        final client = HttpClient();
        try {
          final request = await client.postUrl(
            Uri(
              scheme: 'http',
              host: InternetAddress.loopbackIPv4.address,
              port: httpMetaPort,
              path: '/exit',
            ),
          );
          final response = await request.close();
          await response.drain<void>();
        } finally {
          client.close(force: true);
        }
        await _waitFor(
          () => runtime.currentState.httpMetaStatus == HttpMetaStatus.degraded,
        );
        expect(runtime.currentState.httpMetaMihomoVersion, 'fixture-mihomo');
        expect(runIds, hasLength(1));
        expect([
          for (var index = 1; index < states.length; index++)
            if (states[index - 1].status == states[index].status &&
                states[index].httpMetaStatus == HttpMetaStatus.degraded)
              states[index],
        ], isNotEmpty);
        await runtime.stop();

        final runs = await runtime.logStore.listRuns();
        expect(runs, hasLength(1));
        expect(runIds, [runs.single.id]);
        final logs = await runtime.logStore.readRun(runs.single.id);
        expect(
          logs.map((log) => log.source),
          containsAll(<RuntimeLogSource>[
            RuntimeLogSource.httpMetaStdout,
            RuntimeLogSource.httpMetaStderr,
          ]),
        );
      },
    );

    test(
      'marks a running process unhealthy when its HTTP endpoint closes',
      () async {
        runtime = await _createRuntime(temp, mode: 'unhealthy');
        final states = <RuntimeState>[];
        final subscription = runtime.state.listen(states.add);
        addTearDown(subscription.cancel);

        await runtime.start();
        await _waitFor(
          () => states.any((state) => state.status == RuntimeStatus.unhealthy),
        );

        expect(await runtime.isHealthy(), isFalse);
      },
    );

    test('uses the packaged Node runtime', () async {
      runtime = await _createRuntime(
        temp,
        manifestVersion: '25.0.0',
        bundledNodeVersion: '25.0.0',
      );

      await runtime.start();

      expect(await runtime.isHealthy(), isTrue);
      expect(
        await File.fromUri(temp.uri.resolve('bundle/data/runtime/selected'))
            .exists(),
        isTrue,
      );
    });

    test(
      'starts the active Backend component instead of the packaged bundle',
      () async {
        runtime = await _createRuntime(
          temp,
          activeBackendVersion: 'candidate-backend',
        );

        await runtime.start();

        expect((await runtime.info()).backendVersion, 'candidate-backend');
      },
    );

    for (final kind in ComponentKind.values) {
      test(
        'blocks every child while ${kind.name} recovery is pending',
        () async {
          runtime = await _createRuntime(
            temp,
            httpMetaPort: await _unusedPort(),
          );
          final directories = await RuntimeDirectories.fromBaseDirectory(
            Directory.fromUri(temp.uri.resolve('application-support/')),
          );
          final metadata = ComponentMetadataStore(directories.components);
          final baseline = kind == ComponentKind.backend ? '2.38.4' : '2.31.3';
          await metadata.save(
            kind,
            ComponentMetadata(
              baseline: baseline,
              previous: baseline,
              pending: const ComponentPending(version: 'interrupted'),
            ),
          );
          final selected = File.fromUri(
            temp.uri.resolve('bundle/data/runtime/selected'),
          );
          expect(await selected.exists(), isFalse);

          await expectLater(
            runtime.start(),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                contains('unresolved operation'),
              ),
            ),
          );
          expect(await selected.exists(), isFalse);

          await metadata.save(kind, ComponentMetadata(baseline: baseline));
          await runtime.start();
          expect(await runtime.isHealthy(), isTrue);
          expect(await selected.exists(), isTrue);
        },
      );
    }

    test('activates user environment on the next backend start', () async {
      final configuredPort = await _unusedPort();
      final logs = <RuntimeLog>[];
      final subscription = runtime.logs.listen(logs.add);
      addTearDown(subscription.cancel);

      await runtime.activateUserEnvironment({
        'SUB_STORE_BACKEND_API_PORT': '$configuredPort',
        'SUB_STORE_DATA_BASE_PATH': '/not-user-controlled',
      });
      await runtime.start();

      expect(runtime.port, configuredPort);
      expect(runtime.endpoint.port, configuredPort);
      expect(await runtime.isHealthy(), isTrue);
      expect(
        logs.map((log) => log.message),
        contains('data path:${runtime.directories.data.path}'),
      );
    });

    test('keeps the running entry and health checks when a newer configuration is activated', () async {
      final runningPort = runtime.port;
      await runtime.activateUserEnvironment({
        'SUB_STORE_BACKEND_API_PORT': '$runningPort',
      });
      await runtime.start();
      expect(await runtime.isHealthy(), isTrue);

      final nextPort = await _unusedPort();
      await runtime.activateConfiguration(
        EffectiveRuntimeConfig.resolve(
          systemEnvironment: const <String, String>{},
          backendEnvironment: BackendEnvDocument.parse(
            'SUB_STORE_BACKEND_API_PORT=$nextPort\n',
          ),
          config: const SubDockConfig(),
        ),
      );

      expect(runtime.endpoint.port, runningPort);
      expect(runtime.port, runningPort);
      expect(await runtime.isHealthy(), isTrue);
    });

    test('health checks honor the configured frontend backend path', () async {
      await runtime.activateUserEnvironment({
        BackendEnvPolicy.frontendBackendPath: '/subdock',
      });

      await runtime.start();

      expect(await runtime.isHealthy(), isTrue);
      expect((await runtime.info()).backendVersion, 'fixture-backend');
    });

    test('health checks Backend root for a standalone Frontend', () async {
      await runtime.activateUserEnvironment({
        BackendEnvPolicy.merge: 'false',
        BackendEnvPolicy.frontendBackendPath: '/subdock',
      });

      await runtime.start();

      expect(await runtime.isHealthy(), isTrue);
    });

    test(
      'keeps a legacy backend log untouched while using run history',
      () async {
        final log = File.fromUri(
          temp.uri.resolve('application-support/logs/backend.log'),
        );
        await log.parent.create(recursive: true);
        await log.writeAsString('legacy');

        await runtime.start();
        await runtime.stop();

        expect(await log.readAsString(), 'legacy');
        expect(await File('${log.path}.1').exists(), isFalse);
        expect(await runtime.logStore.listRuns(), hasLength(1));
      },
    );

    test('rejects a missing manifest external binary', () async {
      runtime = await _createRuntime(
        temp,
        externalBinaries: const <String>['shoutrrr'],
        bundledNodeVersion: '24.15.0',
      );

      await expectLater(runtime.start(), throwsStateError);

      expect(runtime.currentState.status, RuntimeStatus.crashed);
    });

    test('disposes lifecycle resources', () async {
      var stateDone = false;
      final subscription = runtime.state.listen(
        null,
        onDone: () => stateDone = true,
      );
      addTearDown(subscription.cancel);

      await runtime.dispose();
      await _waitFor(() => stateDone);

      expect(stateDone, isTrue);
    });

    test('keeps finalization retryable when disposal fails', () async {
      runtime = await _createRuntime(temp, failingFinalize: true);
      final states = <RuntimeState>[];
      final logs = <RuntimeLog>[];
      final runIds = <String>[];
      final stateSubscription = runtime.state.listen(states.add);
      final logSubscription = runtime.logs.listen(logs.add);
      final runSubscription = runtime.logRunStarted.listen(
        (event) => runIds.add(event.runId),
      );
      addTearDown(stateSubscription.cancel);
      addTearDown(logSubscription.cancel);
      addTearDown(runSubscription.cancel);

      await runtime.start();
      await expectLater(runtime.dispose(), throwsA(isA<Exception>()));

      final runId = runIds.single;
      final failure = runtime.currentState;
      expect(failure.status, RuntimeStatus.crashed);
      expect(failure.message, contains('Unable to stop backend'));
      expect(await runtime.logStore.listRuns(), isEmpty);

      await runtime.retryLogFinalization(runId);
      final recoveredRun = (await runtime.logStore.listRuns()).single;
      expect(recoveredRun.id, runId);
      expect(recoveredRun.integrity, RuntimeLogIntegrity.incomplete);
      expect(runtime.currentState.status, RuntimeStatus.stopped);

      await runtime.start();
      await runtime.stop();
      await _waitFor(
        () =>
            states
                .where((state) => state.status == RuntimeStatus.running)
                .length ==
            2,
      );

      expect(
        states.where((state) => state.status == RuntimeStatus.running),
        hasLength(2),
      );
      expect(
        logs.where((log) => log.message == 'fixture stdout'),
        hasLength(2),
      );
      expect(await runtime.logStore.listRuns(), hasLength(2));
      await runtime.dispose();
    });

    test('finalizes a run before disposing a running runtime', () async {
      await runtime.start();
      await runtime.dispose();

      expect(await runtime.logStore.listRuns(), hasLength(1));
    });

    test('restarts a healthy backend with a new log run identity', () async {
      final states = <RuntimeState>[];
      final runIds = <String>[];
      final subscription = runtime.state.listen(states.add);
      final runSubscription = runtime.logRunStarted.listen(
        (event) => runIds.add(event.runId),
      );
      addTearDown(subscription.cancel);
      addTearDown(runSubscription.cancel);

      await runtime.start();
      await runtime.restart();
      await runtime.stop();

      final runs = await runtime.logStore.listRuns();
      expect(runs, hasLength(2));
      expect(runIds, hasLength(2));
      expect(runIds.toSet(), {for (final run in runs) run.id});
      for (final run in runs) {
        final messages = (await runtime.logStore.readRun(run.id))
            .map((log) => log.message)
            .toList();
        expect(
          messages.where((message) => message == 'fixture stdout'),
          hasLength(1),
        );
        expect(
          messages.where((message) => message == 'fixture stderr'),
          hasLength(1),
        );
      }
      expect(
        states.where((state) => state.status == RuntimeStatus.starting),
        hasLength(2),
      );
    });

    test(
      'reports failed startup without reusing the previous applied identity',
      () async {
        await runtime.activateConfiguration(
          EffectiveRuntimeConfig.resolve(
            systemEnvironment: const <String, String>{},
            backendEnvironment: BackendEnvDocument.parse(
              'SUB_STORE_BACKEND_API_PORT=${runtime.port}\n',
            ),
            config: const SubDockConfig(),
          ),
        );
        await runtime.start();
        expect(runtime.appliedConfiguration, isNotNull);
        await runtime.stop();
        // Reuse the existing real-process stall fixture for the next launch.
        final bundle = File.fromUri(
          temp.uri.resolve('bundle/data/backend/sub-store.bundle.js'),
        );
        await bundle.writeAsString(
          (await bundle.readAsString()).replaceFirst(
            "const mode = 'healthy';",
            "const mode = 'stall';",
          ),
        );
        final started = runtime.logs.firstWhere(
          (log) => log.message == 'fixture stdout',
        );
        final states = <RuntimeState>[];
        final subscription = runtime.state.listen(states.add);
        addTearDown(subscription.cancel);

        final starting = runtime.start().timeout(const Duration(seconds: 30));
        unawaited(starting.then<void>((_) {}, onError: (Object _) {}));
        await started.timeout(const Duration(seconds: 5));
        expect(runtime.appliedConfiguration, isNull);
        await expectLater(
          starting,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('Backend did not become healthy'),
            ),
          ),
        );
        await _waitFor(
          () => states.any((state) => state.status == RuntimeStatus.crashed),
        );
        expect(states.last.status, RuntimeStatus.crashed);
      },
    );

    test('persists the final shutdown output before finalizing', () async {
      runtime = await _createRuntime(temp, shutdownTail: true);

      await runtime.start();
      await runtime.stop();

      final runs = await runtime.logStore.listRuns();
      final messages = await runtime.logStore.readRun(runs.single.id);
      expect(
        messages.map((log) => log.message),
        contains('fixture shutdown tail'),
      );
    });
  });
}

Future<DesktopBackendRuntime> _createRuntime(
  Directory temp, {
  String mode = 'healthy',
  String manifestVersion = '24.15.0',
  String? bundledNodeVersion = '24.15.0',
  List<String> externalBinaries = const <String>[],
  int? port,
  String? activeBackendVersion,
  int? httpMetaPort,
  bool failingFinalize = false,
  bool failingAppend = false,
  bool shutdownTail = false,
  bool httpMetaExitOnRequest = false,
}) async {
  final bundle = Directory.fromUri(temp.uri.resolve('bundle/'));
  final backend = Directory.fromUri(bundle.uri.resolve('data/backend/'));
  await backend.create(recursive: true);
  final fixture = File('test/fixtures/backend_fixture.js');
  var source = await fixture.readAsString();
  source = source.replaceFirst(
    "const mode = process.env.TEST_BACKEND_MODE || 'healthy';",
    "const mode = '$mode';",
  );
  if (mode == 'unexpected-exit') {
    source = source.replaceFirst(
      "server.listen(process.env.SUB_STORE_BACKEND_API_PORT, '127.0.0.1');",
      "server.listen(process.env.SUB_STORE_BACKEND_API_PORT, '127.0.0.1');\n  setTimeout(() => server.close(() => process.exit(1)), 150);",
    );
  }
  if (shutdownTail) {
    source = source.replaceFirst(
      "process.on('SIGTERM', () => {",
      "process.on('SIGTERM', () => {\n    process.stdout.write('fixture shutdown tail\\n');",
    );
  }
  await File.fromUri(backend.uri.resolve('sub-store.bundle.js'))
      .writeAsString(source);
  await File.fromUri(
    backend.uri.resolve('runtime-manifest.json'),
  ).writeAsString(
    '{"testedNode":"$manifestVersion","externalBinary":${jsonEncode(externalBinaries)}}',
  );
  await File.fromUri(backend.uri.resolve('version')).writeAsString('2.38.4\n');
  final frontend = Directory.fromUri(bundle.uri.resolve('data/frontend/'));
  await frontend.create(recursive: true);
  await File.fromUri(frontend.uri.resolve('index.html'))
      .writeAsString('frontend');
  await File.fromUri(frontend.uri.resolve('version')).writeAsString('2.31.3\n');
  if (bundledNodeVersion != null) {
    final node = File.fromUri(bundle.uri.resolve('data/runtime/node'));
    await node.parent.create(recursive: true);
    await node.writeAsString(
      '#!/bin/sh\nif [ "\$1" = "--version" ]; then echo v$bundledNodeVersion; exit 0; fi\ntouch "${node.parent.path}/selected"\nexec node "\$@"\n',
    );
    await Process.run('chmod', <String>['755', node.path]);
  }
  final directories = await RuntimeDirectories.fromBaseDirectory(
    Directory.fromUri(temp.uri.resolve('application-support/')),
  );
  if (httpMetaPort != null) {
    final httpMeta = Directory.fromUri(
      bundle.uri.resolve('data/http-meta/meta/'),
    );
    await httpMeta.create(recursive: true);
    await File.fromUri(bundle.uri.resolve('data/http-meta/version'))
        .writeAsString('fixture-http-meta\n');
    await File.fromUri(httpMeta.uri.resolve('tpl.yaml')).writeAsString('tpl');
    await File.fromUri(httpMeta.uri.resolve('mihomo-version'))
        .writeAsString('fixture-mihomo\n');
    final mihomo = File.fromUri(
      httpMeta.uri.resolve(Platform.isWindows ? 'mihomo.exe' : 'mihomo'),
    );
    await mihomo.writeAsString('fixture');
    if (!Platform.isWindows) {
      await Process.run('chmod', <String>['755', mihomo.path]);
    }
    await File.fromUri(bundle.uri.resolve('data/http-meta/http-meta.bundle.js'))
        .writeAsString('''
const http = require('node:http');
console.log('http-meta stdout');
console.error('http-meta stderr');
const server = http.createServer((request, response) => {
  response.statusCode = 200;
  if ($httpMetaExitOnRequest && request.url === '/exit') {
    response.end('{}', () =>
      setImmediate(() => server.close(() => process.exit(1))),
    );
    return;
  }
  response.end('{}');
});
server.listen(process.env.PORT, '127.0.0.1');
process.on('SIGTERM', () => server.close(() => process.exit(0)));
''');
  }
  final store = failingFinalize
      ? _FailingFinalizeStore(directories)
      : failingAppend
      ? _FailingAppendStore(directories)
      : RuntimeLogStore(directories);
  await store.initialize();
  if (activeBackendVersion != null) {
    final candidate = Directory.fromUri(
      directories.components.uri.resolve('backend/$activeBackendVersion/'),
    );
    await candidate.create(recursive: true);
    await File.fromUri(
      candidate.uri.resolve('sub-store.bundle.js'),
    ).writeAsString(source.replaceAll('fixture-backend', activeBackendVersion));
    await File.fromUri(
      candidate.uri.resolve('runtime-manifest.json'),
    ).writeAsString(
      '{"testedNode":"$manifestVersion","externalBinary":${jsonEncode(externalBinaries)}}',
    );
    await ComponentMetadataStore(directories.components).save(
      ComponentKind.backend,
      ComponentMetadata(baseline: '2.38.4', active: activeBackendVersion),
    );
  }
  final result = DesktopBackendRuntime(
    directories: directories,
    logStore: store,
    bundleDirectory: bundle,
    port: port ?? await _unusedPort(),
  );
  if (httpMetaPort != null) {
    await result.activateUserEnvironment({'PORT': '$httpMetaPort'});
  }
  return result;
}

class _FailingAppendStore extends RuntimeLogStore {
  _FailingAppendStore(super.directories);

  var _failNextAppend = true;

  @override
  Future<void> append(RuntimeLog log) {
    if (_failNextAppend) {
      _failNextAppend = false;
      return Future<void>.error(StateError('append fixture failure'));
    }
    return super.append(log);
  }
}

class _FailingFinalizeStore extends RuntimeLogStore {
  _FailingFinalizeStore(super.directories);

  var _failNextFinalize = true;

  @override
  Future<void> finalize({
    DateTime? end,
    RuntimeLogIntegrity integrity = RuntimeLogIntegrity.complete,
  }) {
    if (_failNextFinalize) {
      _failNextFinalize = false;
      return Future<void>.error(StateError('finalize fixture failure'));
    }
    return super.finalize(end: end, integrity: integrity);
  }
}

Future<int> _unusedPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

Future<void> _waitFor(bool Function() condition) async {
  final timeout = Stopwatch()..start();
  while (!condition()) {
    if (timeout.elapsed > const Duration(seconds: 5)) {
      throw TimeoutException('Condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

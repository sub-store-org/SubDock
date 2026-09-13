import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/desktop_backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/runtime/runtime_log_store.dart';
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
      await runtime.dispose();
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
      expect(await runtime.logStore.listRuns(), hasLength(1));
    });

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

    test('rejects a port held by an unknown process', () async {
      final blockedPort = await _unusedPort();
      final blocker = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        blockedPort,
      );
      addTearDown(blocker.close);
      runtime = await _createRuntime(temp, port: blockedPort);

      await expectLater(runtime.start(), throwsStateError);

      expect(runtime.currentState.status, RuntimeStatus.crashed);
      expect(await runtime.logStore.listRuns(), hasLength(1));
    });

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

    test('finalizes a run before disposing a running runtime', () async {
      await runtime.start();
      await runtime.dispose();

      expect(await runtime.logStore.listRuns(), hasLength(1));
    });

    test('restarts a healthy backend', () async {
      final states = <RuntimeState>[];
      final subscription = runtime.state.listen(states.add);
      addTearDown(subscription.cancel);

      await runtime.start();
      await runtime.restart();
      await runtime.stop();

      expect(await runtime.logStore.listRuns(), hasLength(2));
      expect(
        states.where((state) => state.status == RuntimeStatus.starting),
        hasLength(2),
      );
    });

    test('times out when an HTTP response never completes', () async {
      runtime = await _createRuntime(temp, mode: 'stall');
      final states = <RuntimeState>[];
      final subscription = runtime.state.listen(states.add);
      addTearDown(subscription.cancel);

      await expectLater(
        runtime.start().timeout(const Duration(seconds: 15)),
        throwsStateError,
      );

      expect(states.last.status, RuntimeStatus.crashed);
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
  final logStore = RuntimeLogStore(directories);
  await logStore.initialize();
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
  return DesktopBackendRuntime(
    directories: directories,
    logStore: logStore,
    bundleDirectory: bundle,
    port: port ?? await _unusedPort(),
  );
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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/settings/backend_env.dart';
import 'package:subdock/settings/backend_env_store.dart';
import 'package:subdock/settings/config_error.dart';
import 'package:subdock/settings/runtime_configuration_store.dart';
import 'package:subdock/settings/subdock_config.dart';
import 'package:subdock/settings/subdock_config_store.dart';

void main() {
  test('saves and reloads both files as one pair', () async {
    final fixture = await _pairFixture();
    addTearDown(fixture.dispose);

    await fixture.store.save(
      _candidate(
        environment: 'SUB_STORE_BACKEND_API_PORT=3002\n',
        apiPort: 4000,
      ),
    );

    final load = await fixture.store.load();
    expect(load.recovered, isFalse);
    expect(
      load.configuration.environment.rawText,
      'SUB_STORE_BACKEND_API_PORT=3002\n',
    );
    expect(load.configuration.configuration.backend.apiPort, 4000);
    expect(await fixture.store.recoveryFile.exists(), isFalse);
  });

  test(
    'recovers the previous pair when the second replacement fails',
    () async {
      final fixture = await _pairFixture();
      addTearDown(fixture.dispose);
      await _writePair(fixture, port: 3001, apiPort: null);
      final before = await _rawPair(fixture);

      final faulty = _FaultyConfigStore(fixture.directories);
      final store = RuntimeConfigurationStore(
        directories: fixture.directories,
        environmentStore: BackendEnvStore(fixture.directories),
        configurationStore: faulty,
      );
      await expectLater(
        store.save(
          _candidate(
            environment: 'SUB_STORE_BACKEND_API_PORT=3002\n',
            apiPort: 4000,
          ),
        ),
        throwsA(isA<StateError>()),
      );

      final reload = RuntimeConfigurationStore(
        directories: fixture.directories,
        environmentStore: BackendEnvStore(fixture.directories),
        configurationStore: SubDockConfigStore(fixture.directories),
      );
      final load = await reload.load();

      expect(load.recovered, isTrue);
      expect(await _rawPair(fixture), before);
      expect(load.configuration.environment.rawText, before.environment);
      expect(load.configuration.configuration.backend.apiPort, isNull);
    },
  );

  test('recovers the previous absence of a file', () async {
    final fixture = await _pairFixture();
    addTearDown(fixture.dispose);
    expect(await fixture.store.configurationFile.exists(), isFalse);

    final faulty = _FaultyConfigStore(fixture.directories);
    final store = RuntimeConfigurationStore(
      directories: fixture.directories,
      environmentStore: BackendEnvStore(fixture.directories),
      configurationStore: faulty,
    );
    await expectLater(
      store.save(
        _candidate(
          environment: 'SUB_STORE_BACKEND_API_PORT=3002\n',
          apiPort: 4000,
        ),
      ),
      throwsA(isA<StateError>()),
    );

    final reload = RuntimeConfigurationStore(
      directories: fixture.directories,
      environmentStore: BackendEnvStore(fixture.directories),
      configurationStore: SubDockConfigStore(fixture.directories),
    );
    await reload.load();

    expect(await reload.configurationFile.exists(), isFalse);
    expect(await reload.environmentFile.exists(), isFalse);
  });

  test(
    'recovers the previous pair when a step after replacement fails',
    () async {
      final fixture = await _pairFixture();
      addTearDown(fixture.dispose);
      await _writePair(fixture, port: 3001, apiPort: null);
      final before = await _rawPair(fixture);

      final faulty = _FaultyConfigStore(
        fixture.directories,
        failAfterWrite: true,
      );
      final store = RuntimeConfigurationStore(
        directories: fixture.directories,
        environmentStore: BackendEnvStore(fixture.directories),
        configurationStore: faulty,
      );
      await expectLater(
        store.save(
          _candidate(
            environment: 'SUB_STORE_BACKEND_API_PORT=3002\n',
            apiPort: 4000,
          ),
        ),
        throwsA(isA<StateError>()),
      );

      final reload = RuntimeConfigurationStore(
        directories: fixture.directories,
        environmentStore: BackendEnvStore(fixture.directories),
        configurationStore: SubDockConfigStore(fixture.directories),
      );
      await reload.load();

      expect(await _rawPair(fixture), before);
    },
  );

  test(
    'keeps the committed pair when clearing the recovery record fails',
    () async {
      final fixture = await _pairFixture();
      addTearDown(fixture.dispose);
      await _writePair(fixture, port: 3001, apiPort: null);
      final store = _UnclearableStore(
        directories: fixture.directories,
        environmentStore: BackendEnvStore(fixture.directories),
        configurationStore: SubDockConfigStore(fixture.directories),
      );

      final commit = await store.save(
        _candidate(
          environment: 'SUB_STORE_BACKEND_API_PORT=3002\n',
          apiPort: 4000,
        ),
      );

      expect(commit.cleanupPending, isTrue);
      expect(await store.recoveryFile.exists(), isTrue);

      final reload = RuntimeConfigurationStore(
        directories: fixture.directories,
        environmentStore: BackendEnvStore(fixture.directories),
        configurationStore: SubDockConfigStore(fixture.directories),
      );
      final load = await reload.load();

      expect(load.recovered, isTrue);
      expect(
        load.configuration.environment.rawText,
        'SUB_STORE_BACKEND_API_PORT=3002\n',
      );
      expect(load.configuration.configuration.backend.apiPort, 4000);
      expect(await reload.recoveryFile.exists(), isFalse);
    },
  );

  test('rejects an invalid merged pair without writing either file', () async {
    final fixture = await _pairFixture();
    addTearDown(fixture.dispose);
    await _writePair(fixture, port: 3001, apiPort: 4000);
    final before = await _rawPair(fixture);

    await expectLater(
      fixture.store.save(
        _candidate(
          environment: 'SUB_STORE_BACKEND_API_PORT=70000\n',
          apiPort: 4000,
        ),
      ),
      throwsA(isA<AppConfigError>()),
    );

    expect(await _rawPair(fixture), before);
    expect(await fixture.store.recoveryFile.exists(), isFalse);
  });

  for (final corruption in ['invalid JSON', 'altered previous bytes']) {
    test('preserves files and blocks recovery with $corruption', () async {
      final fixture = await _pairFixture();
      addTearDown(fixture.dispose);
      await _writePair(fixture, port: 3001, apiPort: null);
      final before = await _rawPair(fixture);
      var damagedRecord = '{not json';
      if (corruption == 'altered previous bytes') {
        final interrupted = RuntimeConfigurationStore(
          directories: fixture.directories,
          environmentStore: BackendEnvStore(fixture.directories),
          configurationStore: _FaultyConfigStore(fixture.directories),
        );
        await expectLater(
          interrupted.save(
            _candidate(
              environment: 'SUB_STORE_BACKEND_API_PORT=3002\n',
              apiPort: 4000,
            ),
          ),
          throwsA(isA<StateError>()),
        );
        expect(await _rawPair(fixture), before);
        final record = jsonDecode(
          await fixture.store.recoveryFile.readAsString(),
        ) as Map<String, dynamic>;
        (record['environment'] as Map<String, dynamic>)['raw'] =
            'SUB_STORE_BACKEND_API_PORT=4444\n';
        damagedRecord = jsonEncode(record);
      }
      await fixture.store.recoveryFile.writeAsString(damagedRecord);

      await expectLater(fixture.store.load(), throwsA(isA<AppConfigError>()));
      await expectLater(
        fixture.store.save(
          _candidate(
            environment: 'SUB_STORE_BACKEND_API_PORT=4001\n',
            apiPort: 4001,
          ),
        ),
        throwsA(isA<AppConfigError>()),
      );

      expect(await _rawPair(fixture), before);
      expect(await fixture.store.recoveryFile.readAsString(), damagedRecord);
      expect(await fixture.store.recoveryFile.exists(), isTrue);
    });
  }

  test('blocks when an uncommitted pair was edited outside SubDock', () async {
    final fixture = await _pairFixture();
    addTearDown(fixture.dispose);
    await _writePair(fixture, port: 3001, apiPort: null);
    final before = await _rawPair(fixture);

    // Models a process that wrote the recovery record and the new ENV, then
    // died before committing: the pending replacement never finishes.
    final gated = _GatedConfigStore(fixture.directories);
    final store = RuntimeConfigurationStore(
      directories: fixture.directories,
      environmentStore: BackendEnvStore(fixture.directories),
      configurationStore: gated,
    );
    final pending = store.save(
      _candidate(
        environment: 'SUB_STORE_BACKEND_API_PORT=3002\n',
        apiPort: 4000,
      ),
    );
    unawaited(pending.then<void>((_) {}, onError: (Object _) {}));
    await _waitFor(
      () => fixture.store.environmentFile.readAsStringSync().contains('3002'),
    );
    await fixture.store.environmentFile.writeAsString(
      'SUB_STORE_BACKEND_API_PORT=9999\n',
    );

    await expectLater(fixture.store.load(), throwsA(isA<AppConfigError>()));
    final recoveryRecord = await fixture.store.recoveryFile.readAsString();
    await expectLater(
      fixture.store.save(
        _candidate(
          environment: 'SUB_STORE_BACKEND_API_PORT=4001\n',
          apiPort: 4001,
        ),
      ),
      throwsA(isA<AppConfigError>()),
    );
    expect(await fixture.store.recoveryFile.readAsString(), recoveryRecord);

    expect(
      await fixture.store.environmentFile.readAsString(),
      'SUB_STORE_BACKEND_API_PORT=9999\n',
    );
    expect(
      await fixture.store.configurationFile.readAsString(),
      before.configuration,
    );
    expect(await fixture.store.recoveryFile.exists(), isTrue);
  });
}

RuntimeConfiguration _candidate({
  required String environment,
  required int? apiPort,
}) => RuntimeConfiguration(
  environment: BackendEnvDocument.parse(environment),
  configuration: SubDockConfig(backend: SubDockBackendConfig(apiPort: apiPort)),
);

Future<void> _writePair(
  _PairFixture fixture, {
  required int port,
  required int? apiPort,
}) => fixture.store.save(
  _candidate(
    environment: 'SUB_STORE_BACKEND_API_PORT=$port\n',
    apiPort: apiPort,
  ),
);

Future<({String environment, String configuration})> _rawPair(
  _PairFixture fixture,
) async => (
  environment: await fixture.store.environmentFile.readAsString(),
  configuration: await fixture.store.configurationFile.readAsString(),
);

Future<void> _waitFor(bool Function() condition) async {
  final timeout = Stopwatch()..start();
  while (!condition()) {
    if (timeout.elapsed > const Duration(seconds: 5)) {
      throw TimeoutException('Condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _PairFixture {
  _PairFixture(this.root, this.directories, this.store);

  final Directory root;
  final RuntimeDirectories directories;
  final RuntimeConfigurationStore store;

  Future<void> dispose() => root.delete(recursive: true);
}

Future<_PairFixture> _pairFixture() async {
  final root = await Directory.systemTemp.createTemp('subdock_pair_');
  final directories = await RuntimeDirectories.fromBaseDirectory(root);
  return _PairFixture(
    root,
    directories,
    RuntimeConfigurationStore(
      directories: directories,
      environmentStore: BackendEnvStore(directories),
      configurationStore: SubDockConfigStore(directories),
    ),
  );
}

/// Fails the structured-file replacement so the pair cannot commit.
class _FaultyConfigStore extends SubDockConfigStore {
  _FaultyConfigStore(super.directories, {this.failAfterWrite = false});

  final bool failAfterWrite;

  @override
  Future<void> replaceRaw(String rawText) async {
    if (failAfterWrite) {
      await super.replaceRaw(rawText);
    }
    throw StateError('injected replacement failure');
  }
}

/// Fails only when the recovery record is cleared after a commit.
class _UnclearableStore extends RuntimeConfigurationStore {
  _UnclearableStore({
    required super.directories,
    required super.environmentStore,
    required super.configurationStore,
  });

  @override
  Future<void> clearRecoveryRecord() async {
    if (await recoveryFile.exists()) {
      throw StateError('injected cleanup failure');
    }
  }
}

/// Holds the structured-file replacement open to model a mid-commit death.
class _GatedConfigStore extends SubDockConfigStore {
  _GatedConfigStore(super.directories);

  final gate = Completer<void>();

  @override
  Future<void> replaceRaw(String rawText) async {
    await gate.future;
    await super.replaceRaw(rawText);
  }
}

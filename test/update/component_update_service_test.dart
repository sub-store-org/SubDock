import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_recovery.dart';
import 'package:subdock/update/component_resource_resolver.dart';
import 'package:subdock/update/component_update_checker.dart';
import 'package:subdock/update/component_update_service.dart';
import 'package:subdock/update/data_backup_store.dart';
import 'package:subdock/update/github_release_client.dart';

void main() {
  test('rolls Frontend back to its previous component', () async {
    final fixture = await _fixture();
    addTearDown(fixture.dispose);
    await fixture.metadata.save(
      ComponentKind.frontend,
      const ComponentMetadata(
        baseline: '2.31.3',
        active: '2.32.0',
        previous: '2.31.3',
      ),
    );

    await fixture.service.rollback(ComponentKind.frontend);

    expect(fixture.runtime.restarts, 0);
    expect(
      await fixture.metadata.load(ComponentKind.frontend, baseline: 'ignored'),
      const ComponentMetadata(baseline: '2.31.3', previous: '2.32.0'),
    );

    await fixture.service.rollback(ComponentKind.frontend);
    expect(
      await fixture.metadata.load(ComponentKind.frontend, baseline: 'ignored'),
      const ComponentMetadata(
        baseline: '2.31.3',
        active: '2.32.0',
        previous: '2.31.3',
      ),
    );
  });

  test('rolls Backend back with the latest pre-update data backup', () async {
    final fixture = await _fixture();
    addTearDown(fixture.dispose);
    await _write(fixture.directories.data, 'settings.json', 'old');
    await fixture.backups.create(fixture.directories.data);
    await _write(fixture.directories.data, 'settings.json', 'new');
    await fixture.metadata.save(
      ComponentKind.backend,
      const ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.38.4',
      ),
    );

    await fixture.service.rollback(ComponentKind.backend);

    expect(fixture.runtime.stops, 0);
    expect(fixture.runtime.restarts, 0);
    expect(
      await File('${fixture.directories.data.path}/settings.json')
          .readAsString(),
      'old',
    );
    expect(
      await fixture.metadata.load(ComponentKind.backend, baseline: 'ignored'),
      const ComponentMetadata(baseline: '2.38.4', previous: '2.39.0'),
    );

    await _write(fixture.directories.data, 'settings.json', 'new-again');
    await fixture.metadata.save(
      ComponentKind.backend,
      const ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.38.4',
      ),
    );
    await fixture.service.rollback(ComponentKind.backend);
    expect(
      await File('${fixture.directories.data.path}/settings.json')
          .readAsString(),
      'new',
    );
  });

  test(
    'rejects every non-stopped component mutation before reading state',
    () async {
      for (final status in const [
        RuntimeStatus.starting,
        RuntimeStatus.running,
        RuntimeStatus.stopping,
        RuntimeStatus.unhealthy,
        RuntimeStatus.crashed,
      ]) {
        final fixture = await _fixture(status: status);
        addTearDown(fixture.dispose);
        const frontendMetadata = ComponentMetadata(
          baseline: '2.31.3',
          active: '2.32.0',
          previous: '2.31.3',
        );
        const backendMetadata = ComponentMetadata(
          baseline: '2.38.4',
          active: '2.39.0',
          previous: '2.38.4',
        );
        await fixture.metadata.save(ComponentKind.frontend, frontendMetadata);
        await fixture.metadata.save(ComponentKind.backend, backendMetadata);
        await _write(
          fixture.directories.components,
          'frontend/2.32.0/index.html',
          'frontend',
        );
        await _write(
          fixture.directories.components,
          'frontend/2.31.3/index.html',
          'previous frontend',
        );
        await _write(
          fixture.directories.components,
          'backend/2.39.0/sub-store.bundle.js',
          'backend',
        );
        await _write(
          fixture.directories.components,
          'backend/2.38.4/sub-store.bundle.js',
          'previous backend',
        );
        await _write(fixture.directories.data, 'settings.json', 'current');
        await fixture.backups.create(fixture.directories.data);
        await _write(fixture.directories.data, 'settings.json', 'current');
        final backupsBefore = await fixture.backups.list();
        final update = ComponentUpdate(
          kind: ComponentKind.frontend,
          currentVersion: '2.31.3',
          availableVersion: '2.33.0',
          release: _frontendRelease('2.33.0'),
        );
        final backendUpdate = ComponentUpdate(
          kind: ComponentKind.backend,
          currentVersion: '2.38.4',
          availableVersion: '2.40.0',
          release: _backendRelease('2.40.0'),
        );

        for (final action in <({Future<void> Function() run, String message})>[
          (
            run: () => fixture.service.update(update),
            message: 'Component mutation requires a stopped Backend',
          ),
          (
            run: () => fixture.service.update(backendUpdate),
            message: 'Component mutation requires a stopped Backend',
          ),
          (
            run: () => fixture.service.rollback(ComponentKind.frontend),
            message: 'Component mutation requires a stopped Backend',
          ),
          (
            run: () => fixture.service.rollback(ComponentKind.backend),
            message: 'Component mutation requires a stopped Backend',
          ),
        ]) {
          await expectLater(
            action.run(),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                action.message,
              ),
            ),
          );
        }
        expect(
          await fixture.metadata.load(
            ComponentKind.frontend,
            baseline: 'ignored',
          ),
          frontendMetadata,
        );
        expect(
          await fixture.metadata.load(
            ComponentKind.backend,
            baseline: 'ignored',
          ),
          backendMetadata,
        );
        expect(
          await File('${fixture.directories.data.path}/settings.json')
              .readAsString(),
          'current',
        );
        expect(await fixture.backups.list(), backupsBefore);
        for (final path in ['frontend/2.33.0', 'backend/2.40.0']) {
          expect(
            await Directory.fromUri(
              fixture.directories.components.uri.resolve(path),
            ).exists(),
            isFalse,
          );
        }
        expect(fixture.downloads.calls, 0);
        expect(fixture.runtime.starts, 0);
        expect(fixture.runtime.stops, 0);
        expect(fixture.runtime.restarts, 0);
      }
    },
  );

  test(
    'restores and retries Frontend rollback after retention failure',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      const prior = ComponentMetadata(
        baseline: '2.31.3',
        active: '2.32.0',
        previous: '2.31.3',
      );
      await fixture.metadata.save(ComponentKind.frontend, prior);
      final blocker = File(
        '${fixture.directories.components.path}/frontend/9.9.9',
      );
      await blocker.parent.create(recursive: true);
      await blocker.writeAsString('blocker');

      await expectLater(
        fixture.service.rollback(ComponentKind.frontend),
        throwsStateError,
      );
      expect(
        await fixture.metadata.load(
          ComponentKind.frontend,
          baseline: 'ignored',
        ),
        prior,
      );
      await blocker.delete();
      await fixture.service.rollback(ComponentKind.frontend);
      expect(
        await fixture.metadata.load(
          ComponentKind.frontend,
          baseline: 'ignored',
        ),
        const ComponentMetadata(baseline: '2.31.3', previous: '2.32.0'),
      );
    },
  );

  test(
    'restores and retries Backend rollback after retention failure',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      await _write(fixture.directories.data, 'settings.json', 'old');
      await fixture.backups.create(fixture.directories.data);
      await _write(fixture.directories.data, 'settings.json', 'current');
      const prior = ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.38.4',
      );
      await fixture.metadata.save(ComponentKind.backend, prior);
      final blocker = File(
        '${fixture.directories.components.path}/backend/9.9.9',
      );
      await blocker.parent.create(recursive: true);
      await blocker.writeAsString('blocker');

      await expectLater(
        fixture.service.rollback(ComponentKind.backend),
        throwsStateError,
      );
      expect(
        await fixture.metadata.load(ComponentKind.backend, baseline: 'ignored'),
        prior,
      );
      expect(
        await File('${fixture.directories.data.path}/settings.json')
            .readAsString(),
        'current',
      );
      await blocker.delete();
      await fixture.service.rollback(ComponentKind.backend);
      expect(
        await File('${fixture.directories.data.path}/settings.json')
            .readAsString(),
        'old',
      );
    },
  );

  test(
    'restores Backend rollback after final metadata save failure and retries',
    () async {
      final fixture = await _fixture(failOn: {2});
      addTearDown(fixture.dispose);
      await _write(fixture.directories.data, 'settings.json', 'old');
      final targetBackup = await fixture.backups.create(
        fixture.directories.data,
      );
      await _write(fixture.directories.data, 'settings.json', 'current');
      const prior = ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.38.4',
      );
      await fixture.metadata.save(ComponentKind.backend, prior);
      final store = fixture.metadata as _FailOnSaveMetadataStore;
      store.reset();

      await expectLater(
        fixture.service.rollback(ComponentKind.backend),
        throwsStateError,
      );
      expect(
        await fixture.metadata.load(ComponentKind.backend, baseline: 'ignored'),
        prior,
      );
      expect(await fixture.backups.list(), [targetBackup]);
      expect(
        await File('${fixture.directories.data.path}/settings.json')
            .readAsString(),
        'current',
      );
      expect(fixture.runtime.starts, 0);
      expect(fixture.runtime.stops, 0);
      expect(fixture.runtime.restarts, 0);

      store.failOn = {};
      store.reset();
      await fixture.service.rollback(ComponentKind.backend);
      expect(
        await fixture.metadata.load(ComponentKind.backend, baseline: 'ignored'),
        const ComponentMetadata(baseline: '2.38.4', previous: '2.39.0'),
      );
      expect(
        await File('${fixture.directories.data.path}/settings.json')
            .readAsString(),
        'old',
      );
      final afterRetry = await fixture.backups.list();
      expect(afterRetry, hasLength(1));
      expect(afterRetry.single, isNot(targetBackup));
      expect(fixture.runtime.starts, 0);
      expect(fixture.runtime.stops, 0);
      expect(fixture.runtime.restarts, 0);
    },
  );

  test('startup recovery repairs Backend rollback when immediate recovery save fails', () async {
    final fixture = await _fixture(failOn: {2, 3});
    addTearDown(fixture.dispose);
    await _write(fixture.directories.data, 'settings.json', 'old');
    final targetBackup = await fixture.backups.create(fixture.directories.data);
    await _write(fixture.directories.data, 'settings.json', 'current');
    const prior = ComponentMetadata(
      baseline: '2.38.4',
      active: '2.39.0',
      previous: '2.38.4',
    );
    await fixture.metadata.save(ComponentKind.backend, prior);
    final store = fixture.metadata as _FailOnSaveMetadataStore;
    store.reset();
    await expectLater(
      fixture.service.rollback(ComponentKind.backend),
      throwsStateError,
    );
    final pending = await ComponentMetadataStore(fixture.directories.components)
        .load(ComponentKind.backend, baseline: 'ignored');
    expect(pending.active, isNull);
    expect(pending.previous, '2.39.0');
    expect(pending.pending?.version, '2.38.4');
    expect(pending.pending?.operation, ComponentPendingOperation.rollback);
    final safetyBackup = pending.pending!.backupId!;
    expect(
      await fixture.backups.list(),
      containsAll([targetBackup, safetyBackup]),
    );
    expect(await fixture.backups.list(), hasLength(2));
    expect(
      await File('${fixture.directories.data.path}/settings.json')
          .readAsString(),
      'current',
    );

    await ComponentRecovery(
      bundleDirectory: Directory.fromUri(fixture.root.uri.resolve('bundle/')),
      dataDirectory: fixture.directories.data,
      metadataStore: ComponentMetadataStore(fixture.directories.components),
      dataBackups: fixture.backups,
    ).recoverPending();
    final recovered = await ComponentMetadataStore(
      fixture.directories.components,
    ).load(ComponentKind.backend, baseline: 'ignored');
    expect(recovered, prior);
    expect(await fixture.backups.list(), [targetBackup]);
    store.failOn = {};
    store.reset();
    await fixture.service.rollback(ComponentKind.backend);
    expect(
      await fixture.metadata.load(ComponentKind.backend, baseline: 'ignored'),
      const ComponentMetadata(baseline: '2.38.4', previous: '2.39.0'),
    );
    expect(
      await File('${fixture.directories.data.path}/settings.json')
          .readAsString(),
      'old',
    );
    final afterRetry = await fixture.backups.list();
    expect(afterRetry, hasLength(1));
    expect(afterRetry.single, isNot(targetBackup));
    expect(fixture.runtime.starts, 0);
    expect(fixture.runtime.stops, 0);
    expect(fixture.runtime.restarts, 0);
  });

  test(
    'restores Frontend rollback after final metadata save failure and retries',
    () async {
      final fixture = await _fixture(failOn: {2});
      addTearDown(fixture.dispose);
      const prior = ComponentMetadata(
        baseline: '2.31.3',
        active: '2.32.0',
        previous: '2.31.3',
      );
      await fixture.metadata.save(ComponentKind.frontend, prior);
      final store = fixture.metadata as _FailOnSaveMetadataStore;
      store.reset();

      await expectLater(
        fixture.service.rollback(ComponentKind.frontend),
        throwsStateError,
      );
      expect(
        await fixture.metadata.load(
          ComponentKind.frontend,
          baseline: 'ignored',
        ),
        prior,
      );
      expect(fixture.runtime.starts, 0);
      expect(fixture.runtime.stops, 0);
      expect(fixture.runtime.restarts, 0);
      store.failOn = {};
      store.reset();
      await fixture.service.rollback(ComponentKind.frontend);
      expect(
        await fixture.metadata.load(
          ComponentKind.frontend,
          baseline: 'ignored',
        ),
        const ComponentMetadata(baseline: '2.31.3', previous: '2.32.0'),
      );
    },
  );

  test('startup recovery repairs Frontend rollback when immediate recovery save fails', () async {
    final fixture = await _fixture(failOn: {2, 3});
    addTearDown(fixture.dispose);
    const prior = ComponentMetadata(
      baseline: '2.31.3',
      active: '2.32.0',
      previous: '2.31.3',
    );
    await fixture.metadata.save(ComponentKind.frontend, prior);
    final store = fixture.metadata as _FailOnSaveMetadataStore;
    store.reset();
    await expectLater(
      fixture.service.rollback(ComponentKind.frontend),
      throwsStateError,
    );
    final pending = await ComponentMetadataStore(fixture.directories.components)
        .load(ComponentKind.frontend, baseline: 'ignored');
    expect(pending.active, isNull);
    expect(pending.previous, '2.32.0');
    expect(pending.pending?.version, '2.31.3');
    expect(pending.pending?.operation, ComponentPendingOperation.rollback);
    await ComponentRecovery(
      bundleDirectory: Directory.fromUri(fixture.root.uri.resolve('bundle/')),
      dataDirectory: fixture.directories.data,
      metadataStore: ComponentMetadataStore(fixture.directories.components),
      dataBackups: fixture.backups,
    ).recoverPending();
    expect(
      await ComponentMetadataStore(fixture.directories.components)
          .load(ComponentKind.frontend, baseline: 'ignored'),
      prior,
    );
    store.failOn = {};
    store.reset();
    await fixture.service.rollback(ComponentKind.frontend);
    expect(
      await fixture.metadata.load(ComponentKind.frontend, baseline: 'ignored'),
      const ComponentMetadata(baseline: '2.31.3', previous: '2.32.0'),
    );
    expect(fixture.runtime.starts, 0);
    expect(fixture.runtime.stops, 0);
    expect(fixture.runtime.restarts, 0);
  });
}

Future<_Fixture> _fixture({
  RuntimeStatus status = RuntimeStatus.stopped,
  Set<int>? failOn,
}) async {
  final root = await Directory.systemTemp.createTemp('subdock_update_service_');
  final bundle = Directory.fromUri(root.uri.resolve('bundle/'));
  await _write(bundle, 'data/backend/version', '2.38.4\n');
  await _write(bundle, 'data/backend/sub-store.bundle.js', 'baseline');
  await _write(
    bundle,
    'data/backend/runtime-manifest.json',
    '{"testedNode":"24.15.0","externalBinary":[]}',
  );
  await _write(bundle, 'data/frontend/version', '2.31.3\n');
  await _write(bundle, 'data/frontend/index.html', 'baseline');
  final directories = await RuntimeDirectories.fromBaseDirectory(
    Directory.fromUri(root.uri.resolve('application-support/')),
  );
  final metadata = failOn == null
      ? ComponentMetadataStore(directories.components)
      : _FailOnSaveMetadataStore(directories.components, failOn: failOn);
  final backups = DataBackupStore(
    backupsDirectory: directories.backups,
    stagingDirectory: directories.staging,
  );
  final runtime = _FakeRuntime(status: status);
  final downloads = _FakeDownloads();
  final service = ComponentUpdateService(
    runtime: runtime,
    directories: directories,
    metadataStore: metadata,
    resources: ComponentResourceResolver(
      bundleDirectory: bundle,
      componentsDirectory: directories.components,
      metadataStore: metadata,
    ),
    releases: downloads,
    backups: backups,
  );
  return _Fixture(
    root,
    bundle,
    directories,
    metadata,
    backups,
    runtime,
    downloads,
    service,
  );
}

GithubRelease _frontendRelease(String version) => GithubRelease(
  version: version,
  releaseUri: Uri.parse('https://example.invalid/frontend-release'),
  assets: [
    GithubReleaseAsset(name: 'dist.zip', downloadUri: Uri(), sha256: '0' * 64),
  ],
);

GithubRelease _backendRelease(String version) => GithubRelease(
  version: version,
  releaseUri: Uri.parse('https://example.invalid/backend-release'),
  assets: [
    GithubReleaseAsset(
      name: 'sub-store.bundle.js',
      downloadUri: Uri(),
      sha256: '0' * 64,
    ),
    GithubReleaseAsset(
      name: 'runtime-manifest.json',
      downloadUri: Uri(),
      sha256: '1' * 64,
    ),
  ],
);

class _FakeDownloads implements GithubReleaseDownloader {
  var calls = 0;

  @override
  Future<void> downloadVerified(GithubReleaseAsset asset, File target) async {
    calls++;
    await target.parent.create(recursive: true);
    if (asset.name == 'dist.zip') {
      final archive = Archive()
        ..add(ArchiveFile.string('index.html', 'updated frontend'));
      await target.writeAsBytes(ZipEncoder().encode(archive));
    } else {
      await target.writeAsString(
        asset.name == 'runtime-manifest.json'
            ? '{"testedNode":"24.15.0","externalBinary":[]}'
            : 'updated backend',
      );
    }
  }

  @override
  Future<GithubRelease> latest(String repository) => throw UnimplementedError();
}

class _FakeRuntime extends BackendRuntime {
  _FakeRuntime({this.status = RuntimeStatus.stopped});

  final RuntimeStatus status;
  var restarts = 0;
  var stops = 0;
  var starts = 0;

  @override
  RuntimeState get currentState =>
      RuntimeState(status: status, changedAt: DateTime.now());
  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:3001');
  @override
  Stream<RuntimeLog> get logs => const Stream.empty();
  @override
  Stream<RuntimeState> get state => const Stream.empty();
  @override
  Future<void> activateUserEnvironment(Map<String, String> environment) async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<BackendInfo> info() => throw UnimplementedError();
  @override
  Future<bool> isHealthy() async => true;
  @override
  Future<void> restart() async => restarts++;
  @override
  Future<void> start() async => starts++;
  @override
  Future<void> stop() async => stops++;
}

class _Fixture {
  const _Fixture(
    this.root,
    this.bundle,
    this.directories,
    this.metadata,
    this.backups,
    this.runtime,
    this.downloads,
    this.service,
  );

  final Directory root;
  final Directory bundle;
  final RuntimeDirectories directories;
  final ComponentMetadataStore metadata;
  final DataBackupStore backups;
  final _FakeRuntime runtime;
  final _FakeDownloads downloads;
  final ComponentUpdateService service;

  Future<void> dispose() => root.delete(recursive: true);
}

class _FailOnSaveMetadataStore extends ComponentMetadataStore {
  _FailOnSaveMetadataStore(super.directory, {required Set<int> failOn})
    : failOn = {...failOn};

  Set<int> failOn;
  var _saveCount = 0;

  void reset() => _saveCount = 0;

  @override
  Future<void> save(ComponentKind kind, ComponentMetadata metadata) {
    if (failOn.contains(++_saveCount)) {
      throw StateError('injected metadata save failure');
    }
    return super.save(kind, metadata);
  }
}

Future<void> _write(Directory root, String path, String value) async {
  final file = File.fromUri(root.uri.resolve(path));
  await file.parent.create(recursive: true);
  await file.writeAsString(value);
}

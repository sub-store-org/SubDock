import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/update/backend_component_updater.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_recovery.dart';
import 'package:subdock/update/component_resource_resolver.dart';
import 'package:subdock/update/data_backup_store.dart';
import 'package:subdock/update/github_release_client.dart';

void main() {
  test(
    'activates a verified Backend candidate after backing up data',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'subdock_backend_update_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final bundle = Directory.fromUri(temp.uri.resolve('bundle/'));
      await _write(bundle, 'data/backend/version', '2.38.4\n');
      await _write(bundle, 'data/backend/sub-store.bundle.js', 'baseline');
      await _write(
        bundle,
        'data/backend/runtime-manifest.json',
        '{"testedNode":"24.15.0","externalBinary":[]}',
      );
      await _write(bundle, 'data/frontend/version', '2.31.3\n');
      await _write(bundle, 'data/frontend/index.html', 'frontend');
      final directories = await RuntimeDirectories.fromBaseDirectory(
        Directory.fromUri(temp.uri.resolve('application-support/')),
      );
      await _write(directories.data, 'settings.json', '{"generation":1}');
      final metadata = ComponentMetadataStore(directories.components);
      await _write(
        directories.components,
        'backend/2.37.0/sub-store.bundle.js',
        'stale',
      );
      final runtime = _FakeRuntime();
      final updater = BackendComponentUpdater(
        runtime: runtime,
        directories: directories,
        metadataStore: metadata,
        resources: ComponentResourceResolver(
          bundleDirectory: bundle,
          componentsDirectory: directories.components,
          metadataStore: metadata,
        ),
        downloads: _FakeDownloads(),
        backups: DataBackupStore(
          backupsDirectory: directories.backups,
          stagingDirectory: directories.staging,
        ),
      );

      await updater.update(_release('2.39.0'));

      expect(runtime.stops, 0);
      expect(runtime.restarts, 0);
      expect(
        await metadata.load(ComponentKind.backend, baseline: 'ignored'),
        const ComponentMetadata(
          baseline: '2.38.4',
          active: '2.39.0',
          previous: '2.38.4',
        ),
      );
      expect(
        await File(
          '${directories.components.path}/backend/2.39.0/sub-store.bundle.js',
        ).exists(),
        isTrue,
      );
      expect(
        await Directory('${directories.components.path}/backend/2.37.0')
            .exists(),
        isFalse,
      );
    },
  );

  test('does not restart or health-check a stopped update', () async {
    final temp = await Directory.systemTemp.createTemp(
      'subdock_backend_update_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final bundle = Directory.fromUri(temp.uri.resolve('bundle/'));
    await _write(bundle, 'data/backend/version', '2.38.4\n');
    await _write(bundle, 'data/backend/sub-store.bundle.js', 'baseline');
    await _write(
      bundle,
      'data/backend/runtime-manifest.json',
      '{"testedNode":"24.15.0","externalBinary":[]}',
    );
    await _write(bundle, 'data/frontend/version', '2.31.3\n');
    await _write(bundle, 'data/frontend/index.html', 'frontend');
    final directories = await RuntimeDirectories.fromBaseDirectory(
      Directory.fromUri(temp.uri.resolve('application-support/')),
    );
    await _write(directories.data, 'settings.json', 'before');
    final metadata = ComponentMetadataStore(directories.components);
    final runtime = _FakeRuntime(healthy: false);
    final updater = BackendComponentUpdater(
      runtime: runtime,
      directories: directories,
      metadataStore: metadata,
      resources: ComponentResourceResolver(
        bundleDirectory: bundle,
        componentsDirectory: directories.components,
        metadataStore: metadata,
      ),
      downloads: _FakeDownloads(),
      backups: DataBackupStore(
        backupsDirectory: directories.backups,
        stagingDirectory: directories.staging,
      ),
    );

    await updater.update(_release('2.39.0'));

    expect(runtime.stops, 0);
    expect(runtime.restarts, 0);
    expect(
      await metadata.load(ComponentKind.backend, baseline: '2.38.4'),
      const ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.38.4',
      ),
    );
  });

  test('rejects every non-stopped update before any download', () async {
    for (final status in RuntimeStatus.values.where(
      (status) => status != RuntimeStatus.stopped,
    )) {
      final fixture = await _backendFixture(status: status);
      addTearDown(() => fixture.root.delete(recursive: true));
      await expectLater(
        fixture.updater.update(_release('2.39.0')),
        throwsStateError,
      );
      expect(fixture.downloads.calls, 0);
      expect(
        await fixture.updater.metadataStore.load(
          ComponentKind.backend,
          baseline: '2.38.4',
        ),
        const ComponentMetadata(baseline: '2.38.4'),
      );
      expect(
        await File('${fixture.updater.directories.data.path}/settings.json')
            .readAsString(),
        'guard-data',
      );
      expect(await fixture.updater.backups.list(), isEmpty);
      expect(
        await Directory(
          '${fixture.updater.directories.components.path}/backend/2.39.0',
        ).exists(),
        isFalse,
      );
      expect(fixture.runtime.starts, 0);
      expect(fixture.runtime.stops, 0);
      expect(fixture.runtime.restarts, 0);
    }
  });

  test('restores and retries after post-pending retention failure', () async {
    final fixture = await _backendFixture(status: RuntimeStatus.stopped);
    addTearDown(() => fixture.root.delete(recursive: true));
    final blocker = File(
      '${fixture.updater.directories.components.path}/backend/9.9.9',
    );
    await blocker.parent.create(recursive: true);
    await blocker.writeAsString('blocker');

    await expectLater(
      fixture.updater.update(_release('2.39.0')),
      throwsStateError,
    );
    expect(
      await fixture.updater.metadataStore.load(
        ComponentKind.backend,
        baseline: '2.38.4',
      ),
      const ComponentMetadata(baseline: '2.38.4'),
    );
    await blocker.delete();
    await fixture.updater.update(_release('2.39.0'));
    expect(
      (await fixture.updater.metadataStore.load(
        ComponentKind.backend,
        baseline: 'ignored',
      )).active,
      '2.39.0',
    );
  });

  test('recovers after final metadata save failure and can retry', () async {
    final fixture = await _backendFixture(
      status: RuntimeStatus.stopped,
      failOn: {2},
    );
    addTearDown(() => fixture.root.delete(recursive: true));
    final store = fixture.updater.metadataStore as _FailOnSaveMetadataStore;
    await _write(fixture.updater.directories.data, 'settings.json', 'before');
    await expectLater(
      fixture.updater.update(_release('2.39.0')),
      throwsStateError,
    );
    final disk = ComponentMetadataStore(fixture.updater.directories.components);
    expect(
      await disk.load(ComponentKind.backend, baseline: 'ignored'),
      const ComponentMetadata(baseline: '2.38.4'),
    );
    expect(
      await File('${fixture.updater.directories.data.path}/settings.json')
          .readAsString(),
      'before',
    );
    expect(
      await Directory(
        '${fixture.updater.directories.components.path}/backend/2.39.0',
      ).exists(),
      isFalse,
    );
    expect(await fixture.updater.backups.list(), isEmpty);
    expect(fixture.runtime.starts, 0);
    expect(fixture.runtime.stops, 0);
    expect(fixture.runtime.restarts, 0);
    store.failOn = {};
    store.reset();
    await fixture.updater.update(_release('2.39.0'));
    expect(
      await disk.load(ComponentKind.backend, baseline: 'ignored'),
      const ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.38.4',
      ),
    );
    final committedBackups = await fixture.updater.backups.list();
    store.failOn = {2, 3};
    store.reset();
    await expectLater(
      fixture.updater.update(_release('2.39.1')),
      throwsStateError,
    );
    final pending = await disk.load(ComponentKind.backend, baseline: 'ignored');
    expect(pending.active, '2.39.1');
    expect(pending.previous, '2.39.0');
    expect(pending.pending?.version, '2.39.1');
    expect(pending.pending?.operation, ComponentPendingOperation.update);
    final pendingBackup = pending.pending!.backupId!;
    expect(
      await fixture.updater.backups.list(),
      containsAll([...committedBackups, pendingBackup]),
    );
    expect(
      await fixture.updater.backups.list(),
      hasLength(committedBackups.length + 1),
    );
    expect(
      await Directory(
        '${fixture.updater.directories.components.path}/backend/2.39.1',
      ).exists(),
      isTrue,
    );
    final recovery = ComponentRecovery(
      bundleDirectory: fixture.bundle,
      dataDirectory: fixture.updater.directories.data,
      metadataStore: disk,
      dataBackups: fixture.updater.backups,
    );
    await recovery.recoverPending();
    final recovered = await disk.load(
      ComponentKind.backend,
      baseline: 'ignored',
    );
    expect(
      recovered,
      const ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.39.1',
      ),
    );
    expect(
      await File('${fixture.updater.directories.data.path}/settings.json')
          .readAsString(),
      'before',
    );
    expect(
      await Directory(
        '${fixture.updater.directories.components.path}/backend/2.39.1',
      ).exists(),
      isTrue,
    );
    expect(
      await fixture.updater.backups.list(),
      containsAll([...committedBackups, pendingBackup]),
    );
    expect(
      await fixture.updater.backups.list(),
      hasLength(committedBackups.length + 1),
    );
    expect(fixture.runtime.starts, 0);
    expect(fixture.runtime.stops, 0);
    expect(fixture.runtime.restarts, 0);
  });
}

Future<_BackendFixture> _backendFixture({
  RuntimeStatus status = RuntimeStatus.stopped,
  Set<int>? failOn,
}) async {
  final root = await Directory.systemTemp.createTemp('subdock_backend_guard_');
  final bundle = Directory.fromUri(root.uri.resolve('bundle/'));
  await _write(bundle, 'data/backend/version', '2.38.4\n');
  await _write(bundle, 'data/backend/sub-store.bundle.js', 'baseline');
  await _write(
    bundle,
    'data/backend/runtime-manifest.json',
    '{"testedNode":"24.15.0","externalBinary":[]}',
  );
  await _write(bundle, 'data/frontend/version', '2.31.3\n');
  await _write(bundle, 'data/frontend/index.html', 'frontend');
  final directories = await RuntimeDirectories.fromBaseDirectory(
    Directory.fromUri(root.uri.resolve('application-support/')),
  );
  await _write(directories.data, 'settings.json', 'guard-data');
  final metadata = failOn == null
      ? ComponentMetadataStore(directories.components)
      : _FailOnSaveMetadataStore(directories.components, failOn: failOn);
  final downloads = _CountingDownloads();
  final runtime = _FakeRuntime(status: status);
  final updater = BackendComponentUpdater(
    runtime: runtime,
    directories: directories,
    metadataStore: metadata,
    resources: ComponentResourceResolver(
      bundleDirectory: bundle,
      componentsDirectory: directories.components,
      metadataStore: metadata,
    ),
    downloads: downloads,
    backups: DataBackupStore(
      backupsDirectory: directories.backups,
      stagingDirectory: directories.staging,
    ),
  );
  return _BackendFixture(root, bundle, updater, downloads, runtime);
}

GithubRelease _release(String version) => GithubRelease(
  version: version,
  releaseUri: Uri.parse('https://example.invalid/release'),
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
  @override
  Future<void> downloadVerified(GithubReleaseAsset asset, File target) async {
    await target.parent.create(recursive: true);
    await target.writeAsString(
      asset.name == 'runtime-manifest.json'
          ? '{"testedNode":"24.15.0","externalBinary":[]}'
          : 'candidate',
    );
  }

  @override
  Future<GithubRelease> latest(String repository) => throw UnimplementedError();
}

class _CountingDownloads extends _FakeDownloads {
  var calls = 0;

  @override
  Future<void> downloadVerified(GithubReleaseAsset asset, File target) async {
    calls++;
    await target.parent.create(recursive: true);
    await target.writeAsString(
      asset.name == 'runtime-manifest.json'
          ? '{"testedNode":"24.15.0","externalBinary":[]}'
          : 'candidate',
    );
  }
}

class _FakeRuntime extends BackendRuntime {
  _FakeRuntime({this.healthy = true, this.status = RuntimeStatus.stopped});

  final bool healthy;
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
  Future<bool> isHealthy() async => healthy;
  @override
  Future<void> restart() async => restarts++;
  @override
  Future<void> start() async => starts++;
  @override
  Future<void> stop() async => stops++;
}

class _BackendFixture {
  const _BackendFixture(
    this.root,
    this.bundle,
    this.updater,
    this.downloads,
    this.runtime,
  );
  final Directory root;
  final Directory bundle;
  final BackendComponentUpdater updater;
  final _CountingDownloads downloads;
  final _FakeRuntime runtime;
}

class _FailOnSaveMetadataStore extends ComponentMetadataStore {
  _FailOnSaveMetadataStore(super.directory, {required Set<int> failOn})
    : failOn = {...failOn};

  Set<int> failOn;
  var _saveCount = 0;

  void reset() => _saveCount = 0;

  @override
  Future<void> save(ComponentKind kind, ComponentMetadata metadata) {
    final ordinal = ++_saveCount;
    if (failOn.contains(ordinal)) {
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

import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_recovery.dart';
import 'package:subdock/update/component_resource_resolver.dart';
import 'package:subdock/update/data_backup_store.dart';
import 'package:subdock/update/frontend_component_updater.dart';
import 'package:subdock/update/github_release_client.dart';

void main() {
  test('extracts a verified Frontend candidate and activates it', () async {
    final fixture = await _fixture();
    addTearDown(fixture.dispose);

    await fixture.updater.update(_release('2.32.0'));

    expect(fixture.runtime.restarts, 0);
    expect(
      await File(
        '${fixture.directories.components.path}/frontend/2.32.0/index.html',
      ).readAsString(),
      'updated frontend',
    );
    expect(
      await fixture.metadata.load(ComponentKind.frontend, baseline: 'ignored'),
      const ComponentMetadata(
        baseline: '2.31.3',
        active: '2.32.0',
        previous: '2.31.3',
      ),
    );
    expect(
      await Directory('${fixture.directories.components.path}/frontend/2.30.0')
          .exists(),
      isFalse,
    );
  });

  test('rejects a ZIP path that escapes the candidate directory', () async {
    final fixture = await _fixture(malicious: true);
    addTearDown(fixture.dispose);

    await expectLater(
      fixture.updater.update(_release('2.32.0')),
      throwsFormatException,
    );

    expect(fixture.runtime.restarts, 0);
    expect(
      await fixture.metadata.load(ComponentKind.frontend, baseline: '2.31.3'),
      const ComponentMetadata(baseline: '2.31.3'),
    );
  });

  test('accepts the dist root used by Frontend release archives', () async {
    final fixture = await _fixture(distRoot: true);
    addTearDown(fixture.dispose);

    await fixture.updater.update(_release('2.32.0'));

    expect(
      await File(
        '${fixture.directories.components.path}/frontend/2.32.0/index.html',
      ).readAsString(),
      'updated frontend',
    );
  });

  test(
    'keeps the stopped transaction successful without health verification',
    () async {
      final fixture = await _fixture(healthy: false);
      addTearDown(fixture.dispose);

      await fixture.updater.update(_release('2.32.0'));

      expect(fixture.runtime.restarts, 0);
      expect(
        await fixture.metadata.load(ComponentKind.frontend, baseline: '2.31.3'),
        const ComponentMetadata(
          baseline: '2.31.3',
          active: '2.32.0',
          previous: '2.31.3',
        ),
      );
    },
  );

  test('rejects every non-stopped update before any download', () async {
    for (final status in RuntimeStatus.values.where(
      (status) => status != RuntimeStatus.stopped,
    )) {
      final fixture = await _fixture(status: status);
      addTearDown(fixture.dispose);
      await expectLater(
        fixture.updater.update(_release('2.32.0')),
        throwsStateError,
      );
      expect(fixture.downloads.calls, 0);
      expect(
        await fixture.metadata.load(ComponentKind.frontend, baseline: '2.31.3'),
        const ComponentMetadata(baseline: '2.31.3'),
      );
      expect(
        await File('${fixture.directories.data.path}/settings.json')
            .readAsString(),
        'guard-data',
      );
      expect(await fixture.directories.backups.list().toList(), isEmpty);
      expect(
        await Directory(
          '${fixture.directories.components.path}/frontend/2.32.0',
        ).exists(),
        isFalse,
      );
      expect(fixture.runtime.starts, 0);
      expect(fixture.runtime.stops, 0);
      expect(fixture.runtime.restarts, 0);
    }
  });

  test('restores and retries after post-pending retention failure', () async {
    final fixture = await _fixture();
    addTearDown(fixture.dispose);
    final blocker = File(
      '${fixture.directories.components.path}/frontend/9.9.9',
    );
    await blocker.parent.create(recursive: true);
    await blocker.writeAsString('blocker');

    await expectLater(
      fixture.updater.update(_release('2.32.0')),
      throwsStateError,
    );
    expect(
      await fixture.metadata.load(ComponentKind.frontend, baseline: 'ignored'),
      const ComponentMetadata(baseline: '2.31.3'),
    );
    expect(
      await Directory('${fixture.directories.components.path}/frontend/2.32.0')
          .exists(),
      isFalse,
    );
    await blocker.delete();
    await fixture.updater.update(_release('2.32.0'));
    expect(
      (await fixture.metadata.load(
        ComponentKind.frontend,
        baseline: 'ignored',
      )).active,
      '2.32.0',
    );
  });

  test(
    'leaves pending recoverable when final and recovery saves fail',
    () async {
      final fixture = await _fixture(failOn: {2, 3});
      addTearDown(fixture.dispose);

      await expectLater(
        fixture.updater.update(_release('2.32.0')),
        throwsStateError,
      );
      final pending = await ComponentMetadataStore(
        fixture.directories.components,
      ).load(ComponentKind.frontend, baseline: 'ignored');
      expect(pending.baseline, '2.31.3');
      expect(pending.active, '2.32.0');
      expect(pending.previous, '2.31.3');
      expect(pending.pending?.version, '2.32.0');
      expect(pending.pending?.operation, ComponentPendingOperation.update);
      expect(
        await Directory(
          '${fixture.directories.components.path}/frontend/2.32.0',
        ).exists(),
        isTrue,
      );
      expect(
        await File('${fixture.directories.data.path}/settings.json')
            .readAsString(),
        'guard-data',
      );
      expect(await fixture.directories.backups.list().toList(), isEmpty);
      expect(fixture.runtime.starts, 0);
      expect(fixture.runtime.stops, 0);

      await ComponentRecovery(
        bundleDirectory: fixture.bundle,
        dataDirectory: fixture.directories.data,
        metadataStore: ComponentMetadataStore(fixture.directories.components),
        dataBackups: DataBackupStore(
          backupsDirectory: fixture.directories.backups,
          stagingDirectory: fixture.directories.staging,
        ),
      ).recoverPending();
      final recovered = await ComponentMetadataStore(
        fixture.directories.components,
      ).load(ComponentKind.frontend, baseline: 'ignored');
      expect(
        recovered,
        const ComponentMetadata(baseline: '2.31.3', previous: '2.32.0'),
      );
      expect(
        await Directory(
          '${fixture.directories.components.path}/frontend/2.32.0',
        ).exists(),
        isTrue,
      );
      expect(fixture.runtime.starts, 0);
      expect(fixture.runtime.stops, 0);
      expect(fixture.runtime.restarts, 0);
    },
  );

  test('recovers after final metadata save failure and can retry', () async {
    final fixture = await _fixture(failOn: {2});
    addTearDown(fixture.dispose);
    final store = fixture.metadata as _FailOnSaveMetadataStore;

    await expectLater(
      fixture.updater.update(_release('2.32.0')),
      throwsStateError,
    );
    final disk = ComponentMetadataStore(fixture.directories.components);
    expect(
      await disk.load(ComponentKind.frontend, baseline: 'ignored'),
      const ComponentMetadata(baseline: '2.31.3'),
    );
    expect(
      await Directory('${fixture.directories.components.path}/frontend/2.32.0')
          .exists(),
      isFalse,
    );
    expect(
      await File('${fixture.directories.data.path}/settings.json')
          .readAsString(),
      'guard-data',
    );
    expect(await fixture.directories.backups.list().toList(), isEmpty);
    expect(fixture.runtime.starts, 0);
    expect(fixture.runtime.stops, 0);
    expect(fixture.runtime.restarts, 0);
    store.failOn.clear();
    store.reset();
    await fixture.updater.update(_release('2.32.0'));
    expect(
      await disk.load(ComponentKind.frontend, baseline: 'ignored'),
      const ComponentMetadata(
        baseline: '2.31.3',
        active: '2.32.0',
        previous: '2.31.3',
      ),
    );
  });
}

Future<_Fixture> _fixture({
  bool malicious = false,
  bool distRoot = false,
  bool healthy = true,
  RuntimeStatus status = RuntimeStatus.stopped,
  Set<int>? failOn,
}) async {
  final root = await Directory.systemTemp.createTemp(
    'subdock_frontend_update_',
  );
  final bundle = Directory.fromUri(root.uri.resolve('bundle/'));
  await _write(bundle, 'data/backend/version', '2.38.4\n');
  await _write(bundle, 'data/backend/sub-store.bundle.js', 'baseline');
  await _write(
    bundle,
    'data/backend/runtime-manifest.json',
    '{"testedNode":"24.15.0","externalBinary":[]}',
  );
  await _write(bundle, 'data/frontend/version', '2.31.3\n');
  await _write(bundle, 'data/frontend/index.html', 'baseline frontend');
  final directories = await RuntimeDirectories.fromBaseDirectory(
    Directory.fromUri(root.uri.resolve('application-support/')),
  );
  await _write(directories.data, 'settings.json', 'guard-data');
  final metadata = failOn == null
      ? ComponentMetadataStore(directories.components)
      : _FailOnSaveMetadataStore(directories.components, failOn: failOn);
  await _write(
    directories.components,
    'frontend/2.30.0/index.html',
    'stale frontend',
  );
  final downloads = _ZipDownloads(malicious: malicious, distRoot: distRoot);
  final runtime = _FakeRuntime(healthy: healthy, status: status);
  final updater = FrontendComponentUpdater(
    runtime: runtime,
    directories: directories,
    metadataStore: metadata,
    resources: ComponentResourceResolver(
      bundleDirectory: bundle,
      componentsDirectory: directories.components,
      metadataStore: metadata,
    ),
    downloads: downloads,
  );
  return _Fixture(
    root,
    bundle,
    directories,
    metadata,
    runtime,
    updater,
    downloads,
  );
}

GithubRelease _release(String version) => GithubRelease(
  version: version,
  releaseUri: Uri.parse('https://example.invalid/release'),
  assets: [
    GithubReleaseAsset(name: 'dist.zip', downloadUri: Uri(), sha256: '0' * 64),
  ],
);

class _ZipDownloads implements GithubReleaseDownloader {
  _ZipDownloads({required this.malicious, required this.distRoot});

  final bool malicious;
  final bool distRoot;
  var calls = 0;

  @override
  Future<void> downloadVerified(GithubReleaseAsset asset, File target) async {
    calls++;
    final archive = Archive();
    if (distRoot) archive.add(ArchiveFile.directory('dist/'));
    archive.add(
      ArchiveFile.string(
        malicious
            ? '../outside.txt'
            : distRoot
            ? 'dist/index.html'
            : 'index.html',
        'updated frontend',
      ),
    );
    await target.parent.create(recursive: true);
    await target.writeAsBytes(ZipEncoder().encode(archive));
  }

  @override
  Future<GithubRelease> latest(String repository) => throw UnimplementedError();
}

class _FakeRuntime extends BackendRuntime {
  _FakeRuntime({required this.healthy, this.status = RuntimeStatus.stopped});

  final bool healthy;
  final RuntimeStatus status;
  var restarts = 0;
  var starts = 0;
  var stops = 0;

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

class _Fixture {
  const _Fixture(
    this.root,
    this.bundle,
    this.directories,
    this.metadata,
    this.runtime,
    this.updater,
    this.downloads,
  );

  final Directory root;
  final Directory bundle;
  final RuntimeDirectories directories;
  final ComponentMetadataStore metadata;
  final _FakeRuntime runtime;
  final FrontendComponentUpdater updater;
  final _ZipDownloads downloads;

  Future<void> dispose() => root.delete(recursive: true);
}

class _FailOnSaveMetadataStore extends ComponentMetadataStore {
  _FailOnSaveMetadataStore(super.directory, {required Set<int> failOn})
    : failOn = {...failOn};

  final Set<int> failOn;
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

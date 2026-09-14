import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/update/backend_component_updater.dart';
import 'package:subdock/update/component_metadata_store.dart';
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

class _FakeRuntime extends BackendRuntime {
  _FakeRuntime({this.healthy = true});

  final bool healthy;
  var restarts = 0;
  var stops = 0;
  @override
  RuntimeState get currentState =>
      RuntimeState(status: RuntimeStatus.stopped, changedAt: DateTime.now());
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
  Future<void> start() async {}
  @override
  Future<void> stop() async => stops++;
}

Future<void> _write(Directory root, String path, String value) async {
  final file = File.fromUri(root.uri.resolve(path));
  await file.parent.create(recursive: true);
  await file.writeAsString(value);
}

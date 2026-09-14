import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_resource_resolver.dart';
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
}

Future<_Fixture> _fixture() async {
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
  final metadata = ComponentMetadataStore(directories.components);
  final backups = DataBackupStore(
    backupsDirectory: directories.backups,
    stagingDirectory: directories.staging,
  );
  final runtime = _FakeRuntime();
  final service = ComponentUpdateService(
    runtime: runtime,
    directories: directories,
    metadataStore: metadata,
    resources: ComponentResourceResolver(
      bundleDirectory: bundle,
      componentsDirectory: directories.components,
      metadataStore: metadata,
    ),
    releases: _FakeDownloads(),
    backups: backups,
  );
  return _Fixture(root, directories, metadata, backups, runtime, service);
}

class _FakeDownloads implements GithubReleaseDownloader {
  @override
  Future<void> downloadVerified(GithubReleaseAsset asset, File target) =>
      throw UnimplementedError();

  @override
  Future<GithubRelease> latest(String repository) => throw UnimplementedError();
}

class _FakeRuntime extends BackendRuntime {
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
  Future<bool> isHealthy() async => true;
  @override
  Future<void> restart() async => restarts++;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async => stops++;
}

class _Fixture {
  const _Fixture(
    this.root,
    this.directories,
    this.metadata,
    this.backups,
    this.runtime,
    this.service,
  );

  final Directory root;
  final RuntimeDirectories directories;
  final ComponentMetadataStore metadata;
  final DataBackupStore backups;
  final _FakeRuntime runtime;
  final ComponentUpdateService service;

  Future<void> dispose() => root.delete(recursive: true);
}

Future<void> _write(Directory root, String path, String value) async {
  final file = File.fromUri(root.uri.resolve(path));
  await file.parent.create(recursive: true);
  await file.writeAsString(value);
}

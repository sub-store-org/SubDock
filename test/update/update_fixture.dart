import 'dart:io';

import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_recovery.dart';
import 'package:subdock/update/data_backup_store.dart';
import 'package:subdock/update/github_release_client.dart';

Future<UpdateFixture> createUpdateFixture({
  RuntimeStatus status = RuntimeStatus.stopped,
  bool healthy = true,
}) async {
  final root = await Directory.systemTemp.createTemp('subdock_update_');
  final bundle = Directory.fromUri(root.uri.resolve('bundle/'));
  await writeUpdateFile(bundle, 'data/backend/version', '2.38.4\n');
  await writeUpdateFile(
    bundle,
    'data/backend/sub-store.bundle.js',
    'packaged backend',
  );
  await writeUpdateFile(
    bundle,
    'data/backend/runtime-manifest.json',
    '{"testedNode":"24.15.0","externalBinary":[]}',
  );
  await writeUpdateFile(bundle, 'data/frontend/version', '2.31.3\n');
  await writeUpdateFile(
    bundle,
    'data/frontend/index.html',
    'packaged frontend',
  );
  final directories = await RuntimeDirectories.fromBaseDirectory(
    Directory.fromUri(root.uri.resolve('application-support/')),
  );
  await writeUpdateFile(directories.data, 'settings.json', 'guard-data');
  final metadata = SaveOrdinalMetadataStore(directories.components);
  final backups = DataBackupStore(
    backupsDirectory: directories.backups,
    stagingDirectory: directories.staging,
  );
  return UpdateFixture(
    root: root,
    bundle: bundle,
    directories: directories,
    metadata: metadata,
    backups: backups,
    runtime: UpdateTestRuntime(status: status, healthy: healthy),
  );
}

class UpdateFixture {
  const UpdateFixture({
    required this.root,
    required this.bundle,
    required this.directories,
    required this.metadata,
    required this.backups,
    required this.runtime,
  });

  final Directory root;
  final Directory bundle;
  final RuntimeDirectories directories;
  final SaveOrdinalMetadataStore metadata;
  final DataBackupStore backups;
  final UpdateTestRuntime runtime;

  Future<void> dispose() => root.delete(recursive: true);

  Future<ComponentMetadata> readMetadata(
    ComponentKind kind, {
    required String baseline,
  }) =>
      ComponentMetadataStore(directories.components)
          .load(kind, baseline: baseline);

  Future<bool> recoverPending() => ComponentRecovery(
    bundleDirectory: bundle,
    dataDirectory: directories.data,
    metadataStore: ComponentMetadataStore(directories.components),
    dataBackups: DataBackupStore(
      backupsDirectory: directories.backups,
      stagingDirectory: directories.staging,
    ),
  ).recoverPending();
}

class SaveOrdinalMetadataStore extends ComponentMetadataStore {
  SaveOrdinalMetadataStore(super.directory);

  Set<int> failOn = {};
  var _saveCount = 0;

  void resetSaveCount() => _saveCount = 0;

  @override
  Future<void> save(ComponentKind kind, ComponentMetadata metadata) {
    if (failOn.contains(++_saveCount)) {
      throw StateError('injected metadata save failure');
    }
    return super.save(kind, metadata);
  }
}

class UpdateTestRuntime extends BackendRuntime {
  UpdateTestRuntime({required this.status, required this.healthy});

  final RuntimeStatus status;
  final bool healthy;
  var starts = 0;
  var stops = 0;
  var restarts = 0;

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

GithubRelease backendRelease(String version) => GithubRelease(
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

GithubRelease frontendRelease(String version) => GithubRelease(
  version: version,
  releaseUri: Uri.parse('https://example.invalid/frontend-release'),
  assets: [
    GithubReleaseAsset(name: 'dist.zip', downloadUri: Uri(), sha256: '0' * 64),
  ],
);

Future<void> writeUpdateFile(Directory root, String path, String value) async {
  final file = File.fromUri(root.uri.resolve(path));
  await file.parent.create(recursive: true);
  await file.writeAsString(value);
}

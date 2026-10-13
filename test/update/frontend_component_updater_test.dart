import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_resource_resolver.dart';
import 'package:subdock/update/frontend_component_updater.dart';
import 'package:subdock/update/github_release_client.dart';

import 'update_fixture.dart';

void main() {
  test('extracts and activates a stopped Frontend update', () async {
    final fixture = await createUpdateFixture(healthy: false);
    addTearDown(fixture.dispose);
    final downloads = _ZipDownloads();
    final updater = _updater(fixture, downloads);
    await writeUpdateFile(
      fixture.directories.components,
      'frontend/2.30.0/index.html',
      'stale frontend',
    );

    await updater.update(frontendRelease('2.32.0'));

    expect(
      await File(
        '${fixture.directories.components.path}/frontend/2.32.0/index.html',
      ).readAsString(),
      'updated frontend',
    );
    expect(
      await fixture.readMetadata(ComponentKind.frontend, baseline: 'ignored'),
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
    expect(downloads.calls, 1);
    _expectRuntimeIdle(fixture.runtime);
  });

  test('rejects a traversal entry despite a valid archive index', () async {
    final fixture = await createUpdateFixture();
    addTearDown(fixture.dispose);
    final updater = _updater(fixture, _ZipDownloads(malicious: true));

    await expectLater(
      updater.update(frontendRelease('2.32.0')),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('path escapes destination'),
        ),
      ),
    );
    expect(
      await fixture.readMetadata(ComponentKind.frontend, baseline: '2.31.3'),
      const ComponentMetadata(baseline: '2.31.3'),
    );
    expect(
      await Directory('${fixture.directories.components.path}/frontend/2.32.0')
          .exists(),
      isFalse,
    );
    expect(await fixture.directories.staging.list().toList(), isEmpty);
    _expectRuntimeIdle(fixture.runtime);
  });

  test('accepts a dist root in the Frontend release archive', () async {
    final fixture = await createUpdateFixture();
    addTearDown(fixture.dispose);
    final updater = _updater(fixture, _ZipDownloads(distRoot: true));

    await updater.update(frontendRelease('2.32.0'));

    expect(
      await File(
        '${fixture.directories.components.path}/frontend/2.32.0/index.html',
      ).readAsString(),
      'updated frontend',
    );
  });

  test(
    'rejects every non-stopped update before download or transaction work',
    () async {
      for (final status in RuntimeStatus.values.where(
        (status) => status != RuntimeStatus.stopped,
      )) {
        final fixture = await createUpdateFixture(status: status);
        addTearDown(fixture.dispose);
        final downloads = _ZipDownloads();
        await expectLater(
          _updater(fixture, downloads).update(frontendRelease('2.32.0')),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Frontend component mutation requires a stopped Backend',
            ),
          ),
        );
        expect(downloads.calls, 0);
        expect(
          await fixture.readMetadata(
            ComponentKind.frontend,
            baseline: '2.31.3',
          ),
          const ComponentMetadata(baseline: '2.31.3'),
        );
        expect(
          await File('${fixture.directories.data.path}/settings.json')
              .readAsString(),
          'guard-data',
        );
        expect(await fixture.backups.list(), isEmpty);
        expect(
          await Directory(
            '${fixture.directories.components.path}/frontend/2.32.0',
          ).exists(),
          isFalse,
        );
        _expectRuntimeIdle(fixture.runtime);
      }
    },
  );

  for (final row in <({String failure, bool retention, Set<int> failOn})>[
    (failure: 'retention failure', retention: true, failOn: {}),
    (failure: 'final metadata save failure', retention: false, failOn: {2}),
  ]) {
    test('repairs and retries after Frontend ${row.failure}', () async {
      final fixture = await createUpdateFixture();
      addTearDown(fixture.dispose);
      const prior = ComponentMetadata(baseline: '2.31.3');
      await fixture.metadata.save(ComponentKind.frontend, prior);
      fixture.metadata.failOn = {...row.failOn};
      fixture.metadata.resetSaveCount();
      File? blocker;
      if (row.retention) {
        blocker = File('${fixture.directories.components.path}/frontend/9.9.9');
        await blocker.parent.create(recursive: true);
        await blocker.writeAsString('retention blocker');
      }
      final downloads = _ZipDownloads();
      final updater = _updater(fixture, downloads);

      await expectLater(
        updater.update(frontendRelease('2.32.0')),
        throwsA(isA<StateError>()),
      );
      expect(
        await fixture.readMetadata(ComponentKind.frontend, baseline: 'ignored'),
        prior,
      );
      expect(
        await File('${fixture.directories.data.path}/settings.json')
            .readAsString(),
        'guard-data',
      );
      expect(await fixture.backups.list(), isEmpty);
      expect(
        await Directory(
          '${fixture.directories.components.path}/frontend/2.32.0',
        ).exists(),
        isFalse,
      );
      expect(await fixture.directories.staging.list().toList(), isEmpty);
      _expectRuntimeIdle(fixture.runtime);

      if (blocker != null) await blocker.delete();
      fixture.metadata.failOn = {};
      fixture.metadata.resetSaveCount();
      await updater.update(frontendRelease('2.32.0'));
      expect(
        await fixture.readMetadata(ComponentKind.frontend, baseline: 'ignored'),
        const ComponentMetadata(
          baseline: '2.31.3',
          active: '2.32.0',
          previous: '2.31.3',
        ),
      );
      expect(
        await File(
          '${fixture.directories.components.path}/frontend/2.32.0/index.html',
        ).readAsString(),
        'updated frontend',
      );
      expect(downloads.calls, 2);
      _expectRuntimeIdle(fixture.runtime);
    });
  }

  test(
    'startup recovery retains a deferred Frontend candidate as previous',
    () async {
      final fixture = await createUpdateFixture();
      addTearDown(fixture.dispose);
      const prior = ComponentMetadata(baseline: '2.31.3');
      await fixture.metadata.save(ComponentKind.frontend, prior);
      fixture.metadata.failOn = {2, 3};
      fixture.metadata.resetSaveCount();
      final downloads = _ZipDownloads();
      final updater = _updater(fixture, downloads);

      await expectLater(
        updater.update(frontendRelease('2.32.0')),
        throwsA(isA<StateError>()),
      );
      final disk = ComponentMetadataStore(fixture.directories.components);
      expect(
        await disk.load(ComponentKind.frontend, baseline: 'ignored'),
        const ComponentMetadata(
          baseline: '2.31.3',
          active: '2.32.0',
          previous: '2.31.3',
          pending: ComponentPending(
            version: '2.32.0',
            operation: ComponentPendingOperation.update,
          ),
        ),
      );
      expect(
        await File('${fixture.directories.data.path}/settings.json')
            .readAsString(),
        'guard-data',
      );
      expect(await fixture.backups.list(), isEmpty);
      expect(
        await File(
          '${fixture.directories.components.path}/frontend/2.32.0/index.html',
        ).readAsString(),
        'updated frontend',
      );
      expect(await fixture.directories.staging.list().toList(), isEmpty);
      _expectRuntimeIdle(fixture.runtime);

      expect(await fixture.recoverPending(), isTrue);
      expect(
        await disk.load(ComponentKind.frontend, baseline: 'ignored'),
        const ComponentMetadata(baseline: '2.31.3', previous: '2.32.0'),
      );
      expect(
        await File('${fixture.directories.data.path}/settings.json')
            .readAsString(),
        'guard-data',
      );
      expect(
        await File(
          '${fixture.directories.components.path}/frontend/2.32.0/index.html',
        ).readAsString(),
        'updated frontend',
      );
      expect(await fixture.backups.list(), isEmpty);
      expect(downloads.calls, 1);
      _expectRuntimeIdle(fixture.runtime);
    },
  );
}

FrontendComponentUpdater _updater(
  UpdateFixture fixture,
  GithubReleaseDownloader downloads,
) => FrontendComponentUpdater(
  runtime: fixture.runtime,
  directories: fixture.directories,
  metadataStore: fixture.metadata,
  resources: ComponentResourceResolver(
    bundleDirectory: fixture.bundle,
    componentsDirectory: fixture.directories.components,
    metadataStore: fixture.metadata,
  ),
  downloads: downloads,
);

void _expectRuntimeIdle(UpdateTestRuntime runtime) {
  expect([runtime.starts, runtime.stops, runtime.restarts], [0, 0, 0]);
}

class _ZipDownloads implements GithubReleaseDownloader {
  _ZipDownloads({this.malicious = false, this.distRoot = false});

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
        distRoot ? 'dist/index.html' : 'index.html',
        'updated frontend',
      ),
    );
    if (malicious) {
      archive.add(ArchiveFile.string('../outside.txt', 'escaped'));
    }
    await target.parent.create(recursive: true);
    await target.writeAsBytes(ZipEncoder().encode(archive));
  }

  @override
  Future<GithubRelease> latest(String repository) => throw UnimplementedError();
}

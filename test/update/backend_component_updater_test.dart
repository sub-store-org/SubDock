import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/update/backend_component_updater.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_resource_resolver.dart';
import 'package:subdock/update/github_release_client.dart';

import 'update_fixture.dart';

void main() {
  test('backs up data and activates a stopped Backend update', () async {
    final fixture = await createUpdateFixture(healthy: false);
    addTearDown(fixture.dispose);
    final downloads = _CountingDownloads();
    final updater = _updater(fixture, downloads);
    await writeUpdateFile(
      fixture.directories.components,
      'backend/2.37.0/sub-store.bundle.js',
      'stale',
    );

    await updater.update(backendRelease('2.39.0'));

    final committedBackup = (await fixture.backups.list()).single;
    expect(
      await fixture.readMetadata(ComponentKind.backend, baseline: 'ignored'),
      ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.38.4',
        previousBackupId: committedBackup,
      ),
    );
    expect(
      await File(
        '${fixture.directories.components.path}/backend/2.39.0/sub-store.bundle.js',
      ).readAsString(),
      'candidate',
    );
    expect(
      await File(
        '${fixture.directories.components.path}/backend/2.39.0/runtime-manifest.json',
      ).readAsString(),
      '{"testedNode":"24.15.0","externalBinary":[]}',
    );
    expect(
      await Directory('${fixture.directories.components.path}/backend/2.37.0')
          .exists(),
      isFalse,
    );
    final backupId = (await fixture.backups.list()).single;
    expect(
      await File('${fixture.directories.backups.path}/$backupId/settings.json')
          .readAsString(),
      'guard-data',
    );
    expect(downloads.calls, 2);
    _expectRuntimeIdle(fixture.runtime);
  });

  test(
    'rejects every non-stopped update before download or transaction work',
    () async {
      for (final status in RuntimeStatus.values.where(
        (status) => status != RuntimeStatus.stopped,
      )) {
        final fixture = await createUpdateFixture(status: status);
        addTearDown(fixture.dispose);
        final downloads = _CountingDownloads();
        await expectLater(
          _updater(fixture, downloads).update(backendRelease('2.39.0')),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Backend component mutation requires a stopped Backend',
            ),
          ),
        );
        expect(downloads.calls, 0);
        expect(
          await fixture.readMetadata(ComponentKind.backend, baseline: '2.38.4'),
          const ComponentMetadata(baseline: '2.38.4'),
        );
        expect(
          await File('${fixture.directories.data.path}/settings.json')
              .readAsString(),
          'guard-data',
        );
        expect(await fixture.backups.list(), isEmpty);
        expect(
          await Directory(
            '${fixture.directories.components.path}/backend/2.39.0',
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
    test('repairs and retries after Backend ${row.failure}', () async {
      final fixture = await createUpdateFixture();
      addTearDown(fixture.dispose);
      const prior = ComponentMetadata(baseline: '2.38.4');
      await writeUpdateFile(
        fixture.directories.data,
        'settings.json',
        'original',
      );
      await fixture.metadata.save(ComponentKind.backend, prior);
      fixture.metadata.failOn = {...row.failOn};
      fixture.metadata.resetSaveCount();
      File? blocker;
      if (row.retention) {
        blocker = File('${fixture.directories.components.path}/backend/9.9.9');
        await blocker.parent.create(recursive: true);
        await blocker.writeAsString('retention blocker');
      }
      final downloads = _CountingDownloads();
      final updater = _updater(fixture, downloads);

      await expectLater(
        updater.update(backendRelease('2.39.0')),
        throwsA(isA<StateError>()),
      );
      expect(
        await fixture.readMetadata(ComponentKind.backend, baseline: 'ignored'),
        prior,
      );
      expect(
        await File('${fixture.directories.data.path}/settings.json')
            .readAsString(),
        'original',
      );
      expect(await fixture.backups.list(), isEmpty);
      expect(
        await Directory('${fixture.directories.components.path}/backend/2.39.0')
            .exists(),
        isFalse,
      );
      expect(await fixture.directories.staging.list().toList(), isEmpty);
      _expectRuntimeIdle(fixture.runtime);

      if (blocker != null) await blocker.delete();
      fixture.metadata.failOn = {};
      fixture.metadata.resetSaveCount();
      await updater.update(backendRelease('2.39.0'));
      final retryBackup = (await fixture.backups.list()).single;
      expect(
        await fixture.readMetadata(ComponentKind.backend, baseline: 'ignored'),
        ComponentMetadata(
          baseline: '2.38.4',
          active: '2.39.0',
          previous: '2.38.4',
          previousBackupId: retryBackup,
        ),
      );
      final backupId = (await fixture.backups.list()).single;
      expect(
        await File(
          '${fixture.directories.backups.path}/$backupId/settings.json',
        ).readAsString(),
        'original',
      );
      expect(
        await File(
          '${fixture.directories.components.path}/backend/2.39.0/sub-store.bundle.js',
        ).readAsString(),
        'candidate',
      );
      expect(downloads.calls, 4);
      _expectRuntimeIdle(fixture.runtime);
    });
  }

  test('retries an update cleanly after its pending save failed', () async {
    final fixture = await createUpdateFixture();
    addTearDown(fixture.dispose);
    await writeComponentVersion(fixture, ComponentKind.backend, '2.38.4');
    await writeUpdateFile(
      fixture.directories.data,
      'settings.json',
      'prior-data',
    );
    const prior = ComponentMetadata(baseline: '2.38.4');
    await fixture.metadata.save(ComponentKind.backend, prior);
    fixture.metadata.failOn = {1};
    fixture.metadata.resetSaveCount();
    final downloads = _CountingDownloads();

    await expectLater(
      _updater(fixture, downloads).update(backendRelease('2.39.0')),
      throwsA(isA<StateError>()),
    );

    expect(
      await fixture.readMetadata(ComponentKind.backend, baseline: 'ignored'),
      prior,
    );
    expect(
      await File('${fixture.directories.data.path}/settings.json')
          .readAsString(),
      'prior-data',
    );
    expect(await fixture.backups.list(), isEmpty);
    _expectRuntimeIdle(fixture.runtime);

    // The failed attempt left nothing that could later be mistaken for the
    // previous version's snapshot.
    fixture.metadata.failOn = {};
    fixture.metadata.resetSaveCount();
    await _updater(fixture, downloads).update(backendRelease('2.39.0'));

    final committed = (await fixture.backups.list()).single;
    expect(
      await fixture.readMetadata(ComponentKind.backend, baseline: 'ignored'),
      ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.38.4',
        previousBackupId: committed,
      ),
    );
    expect(
      await File('${fixture.directories.backups.path}/$committed/settings.json')
          .readAsString(),
      'prior-data',
    );
    _expectRuntimeIdle(fixture.runtime);
  });

  test(
    'discards the snapshot of an update whose pending save failed',
    () async {
      final fixture = await createUpdateFixture();
      addTearDown(fixture.dispose);
      const prior = ComponentMetadata(baseline: '2.38.4');
      await writeUpdateFile(
        fixture.directories.data,
        'settings.json',
        'original',
      );
      await fixture.metadata.save(ComponentKind.backend, prior);
      fixture.metadata.failOn = {1};
      fixture.metadata.resetSaveCount();
      final downloads = _CountingDownloads();

      await expectLater(
        _updater(fixture, downloads).update(backendRelease('2.39.0')),
        throwsA(isA<StateError>()),
      );

      expect(
        await fixture.readMetadata(ComponentKind.backend, baseline: 'ignored'),
        prior,
      );
      expect(
        await File('${fixture.directories.data.path}/settings.json')
            .readAsString(),
        'original',
      );
      expect(await fixture.backups.list(), isEmpty);
      expect(
        await Directory('${fixture.directories.components.path}/backend/2.39.0')
            .exists(),
        isFalse,
      );
      _expectRuntimeIdle(fixture.runtime);
    },
  );

  test(
    'keeps the committed rollback snapshot through a failed update',
    () async {
      final fixture = await createUpdateFixture();
      addTearDown(fixture.dispose);
      await writeComponentVersion(fixture, ComponentKind.backend, '2.39.0');
      // Three snapshots already exist; the committed association is the oldest.
      await writeUpdateFile(
        fixture.directories.data,
        'settings.json',
        'linked',
      );
      final linked = await fixture.backups.create(fixture.directories.data);
      for (var index = 0; index < 2; index++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        await writeUpdateFile(
          fixture.directories.data,
          'settings.json',
          'stale-$index',
        );
        await fixture.backups.create(
          fixture.directories.data,
          protected: {linked},
        );
      }
      final prior = ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.38.4',
        previousBackupId: linked,
      );
      await fixture.metadata.save(ComponentKind.backend, prior);
      fixture.metadata.failOn = {2};
      fixture.metadata.resetSaveCount();

      await expectLater(
        _updater(
          fixture,
          _CountingDownloads(),
        ).update(backendRelease('2.40.0')),
        throwsA(isA<StateError>()),
      );

      // The transaction was rolled back, so the committed association and its
      // snapshot must both still be in place.
      expect(
        await fixture.readMetadata(ComponentKind.backend, baseline: 'ignored'),
        prior,
      );
      expect(await fixture.backups.list(), contains(linked));
      _expectRuntimeIdle(fixture.runtime);
    },
  );

  test('startup recovery preserves a downloaded prior Backend update', () async {
    final fixture = await createUpdateFixture();
    addTearDown(fixture.dispose);
    await writeUpdateFile(
      fixture.directories.data,
      'settings.json',
      'original',
    );
    await fixture.metadata.save(
      ComponentKind.backend,
      const ComponentMetadata(baseline: '2.38.4'),
    );
    final downloads = _CountingDownloads();
    final updater = _updater(fixture, downloads);
    await updater.update(backendRelease('2.39.0'));
    final committedBackups = await fixture.backups.list();
    expect(committedBackups, hasLength(1));
    await writeUpdateFile(
      fixture.directories.data,
      'settings.json',
      'current data',
    );
    fixture.metadata.failOn = {2, 3};
    fixture.metadata.resetSaveCount();

    await expectLater(
      updater.update(backendRelease('2.39.1')),
      throwsA(isA<StateError>()),
    );

    final disk = ComponentMetadataStore(fixture.directories.components);
    final pending = await disk.load(ComponentKind.backend, baseline: 'ignored');
    final pendingBackups = await fixture.backups.list();
    final newBackupIds = pendingBackups
        .where((id) => !committedBackups.contains(id))
        .toList();
    expect(newBackupIds, hasLength(1));
    final pendingBackup = newBackupIds.single;
    expect(
      pending,
      ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.1',
        previous: '2.39.0',
        previousBackupId: pendingBackup,
        pending: ComponentPending(
          version: '2.39.1',
          backupId: pendingBackup,
          operation: ComponentPendingOperation.update,
        ),
      ),
    );
    expect(pendingBackups, containsAll([...committedBackups, pendingBackup]));
    expect(pendingBackups, hasLength(committedBackups.length + 1));
    expect(
      await File(
        '${fixture.directories.backups.path}/$pendingBackup/settings.json',
      ).readAsString(),
      'current data',
    );
    expect(
      await File('${fixture.directories.data.path}/settings.json')
          .readAsString(),
      'current data',
    );
    expect(
      await File(
        '${fixture.directories.components.path}/backend/2.39.1/sub-store.bundle.js',
      ).readAsString(),
      'candidate',
    );
    _expectRuntimeIdle(fixture.runtime);

    expect(await fixture.recoverPending(), isTrue);
    expect(
      await disk.load(ComponentKind.backend, baseline: 'ignored'),
      // 2.39.1 is the interrupted candidate; no data snapshot belongs to it.
      const ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.39.1',
      ),
    );
    expect(
      await File('${fixture.directories.data.path}/settings.json')
          .readAsString(),
      'current data',
    );
    expect(
      await Directory('${fixture.directories.components.path}/backend/2.39.1')
          .exists(),
      isTrue,
    );
    expect(
      await fixture.backups.list(),
      containsAll([...committedBackups, pendingBackup]),
    );
    expect(
      await fixture.backups.list(),
      hasLength(committedBackups.length + 1),
    );
    _expectRuntimeIdle(fixture.runtime);
  });
}

BackendComponentUpdater _updater(
  UpdateFixture fixture,
  GithubReleaseDownloader downloads,
) => BackendComponentUpdater(
  runtime: fixture.runtime,
  directories: fixture.directories,
  metadataStore: fixture.metadata,
  resources: ComponentResourceResolver(
    bundleDirectory: fixture.bundle,
    componentsDirectory: fixture.directories.components,
    metadataStore: fixture.metadata,
  ),
  downloads: downloads,
  backups: fixture.backups,
);

void _expectRuntimeIdle(UpdateTestRuntime runtime) {
  expect([runtime.starts, runtime.stops, runtime.restarts], [0, 0, 0]);
}

class _CountingDownloads implements GithubReleaseDownloader {
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

  @override
  Future<GithubRelease> latest(String repository) => throw UnimplementedError();
}

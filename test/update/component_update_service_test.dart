import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_resource_resolver.dart';
import 'package:subdock/update/component_update_checker.dart';
import 'package:subdock/update/component_update_service.dart';
import 'package:subdock/update/github_release_client.dart';

import 'update_fixture.dart';

void main() {
  for (final row in <({String owner, ComponentKind kind, String active})>[
    (owner: 'Frontend', kind: ComponentKind.frontend, active: '2.32.0'),
    (owner: 'Backend', kind: ComponentKind.backend, active: '2.39.0'),
  ]) {
    test(
      'toggles ${row.owner} rollback pointers and preserves runtime state',
      () async {
        final fixture = await createUpdateFixture();
        addTearDown(fixture.dispose);
        const baselineByOwner = {
          ComponentKind.frontend: '2.31.3',
          ComponentKind.backend: '2.38.4',
        };
        final baseline = baselineByOwner[row.kind]!;
        await writeComponentVersion(fixture, row.kind, row.active);
        String? targetBackup;
        if (row.kind == ComponentKind.backend) {
          await writeUpdateFile(
            fixture.directories.data,
            'settings.json',
            'old',
          );
          targetBackup = await fixture.backups.create(fixture.directories.data);
          await writeUpdateFile(
            fixture.directories.data,
            'settings.json',
            'new',
          );
        }
        await fixture.metadata.save(
          row.kind,
          ComponentMetadata(
            baseline: baseline,
            active: row.active,
            previous: baseline,
            previousBackupId: targetBackup,
          ),
        );
        final service = _service(fixture, _UnexpectedDownloads());

        await service.rollback(row.kind);

        _expectRuntimeIdle(fixture.runtime);
        if (row.kind == ComponentKind.backend) {
          expect(
            await File('${fixture.directories.data.path}/settings.json')
                .readAsString(),
            'old',
          );
          final safetyBackup = (await fixture.backups.list()).single;
          expect(safetyBackup, isNot(targetBackup));
          expect(
            await fixture.readMetadata(row.kind, baseline: 'ignored'),
            ComponentMetadata(
              baseline: baseline,
              previous: row.active,
              previousBackupId: safetyBackup,
            ),
          );
          expect(
            await File(
              '${fixture.directories.backups.path}/$safetyBackup/settings.json',
            ).readAsString(),
            'new',
          );

          await writeUpdateFile(
            fixture.directories.data,
            'settings.json',
            'new-again',
          );
          await service.rollback(row.kind);
          expect(
            await File('${fixture.directories.data.path}/settings.json')
                .readAsString(),
            'new',
          );
          final nextSafety = (await fixture.backups.list()).single;
          expect(nextSafety, isNot(safetyBackup));
          expect(
            await fixture.readMetadata(row.kind, baseline: 'ignored'),
            ComponentMetadata(
              baseline: baseline,
              active: row.active,
              previous: baseline,
              previousBackupId: nextSafety,
            ),
          );
          expect(
            await File(
              '${fixture.directories.backups.path}/$nextSafety/settings.json',
            ).readAsString(),
            'new-again',
          );
        } else {
          await writeUpdateFile(
            fixture.directories.data,
            'settings.json',
            'subscription-data',
          );
          expect(
            await fixture.readMetadata(row.kind, baseline: 'ignored'),
            ComponentMetadata(baseline: baseline, previous: row.active),
          );
          await service.rollback(row.kind);
          expect(
            await fixture.readMetadata(row.kind, baseline: 'ignored'),
            ComponentMetadata(
              baseline: baseline,
              active: row.active,
              previous: baseline,
            ),
          );
          // A Frontend rollback never restores or snapshots Backend data.
          expect(await fixture.backups.list(), isEmpty);
          expect(
            await File('${fixture.directories.data.path}/settings.json')
                .readAsString(),
            'subscription-data',
          );
        }
        _expectRuntimeIdle(fixture.runtime);
      },
    );
  }

  test('uses the snapshot linked to the target version, not the newest one', () async {
    final fixture = await createUpdateFixture();
    addTearDown(fixture.dispose);
    await writeComponentVersion(fixture, ComponentKind.backend, '2.39.0');
    await writeUpdateFile(
      fixture.directories.data,
      'settings.json',
      'baseline-data',
    );
    final targetBackup = await fixture.backups.create(fixture.directories.data);
    // An unrelated newer snapshot, e.g. from updating a different version.
    await writeUpdateFile(
      fixture.directories.data,
      'settings.json',
      'unrelated-data',
    );
    final unrelatedBackup = await fixture.backups.create(
      fixture.directories.data,
    );
    await writeUpdateFile(
      fixture.directories.data,
      'settings.json',
      'active-data',
    );
    await fixture.metadata.save(
      ComponentKind.backend,
      ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.38.4',
        previousBackupId: targetBackup,
      ),
    );

    await _service(
      fixture,
      _UnexpectedDownloads(),
    ).rollback(ComponentKind.backend);

    // The linked snapshot wins over the newest one, which held unrelated data.
    expect(
      await File('${fixture.directories.data.path}/settings.json')
          .readAsString(),
      'baseline-data',
    );
    final remaining = await fixture.backups.list();
    expect(remaining, isNot(contains(targetBackup)));
    final safety = remaining.singleWhere((id) => id != unrelatedBackup);
    expect(
      await File('${fixture.directories.backups.path}/$safety/settings.json')
          .readAsString(),
      'active-data',
    );
    expect(
      await fixture.readMetadata(ComponentKind.backend, baseline: 'ignored'),
      ComponentMetadata(
        baseline: '2.38.4',
        previous: '2.39.0',
        previousBackupId: safety,
      ),
    );
    _expectRuntimeIdle(fixture.runtime);
  });

  test('reports why a rollback is unsafe instead of offering it', () async {
    final fixture = await createUpdateFixture();
    addTearDown(fixture.dispose);
    await writeComponentVersion(fixture, ComponentKind.backend, '2.39.0');
    final service = _service(fixture, _UnexpectedDownloads());

    // A previous version with no recorded snapshot association.
    await fixture.metadata.save(
      ComponentKind.backend,
      const ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.38.4',
      ),
    );
    expect(
      (await service.status(ComponentKind.backend)).rollbackBlockedReason,
      ComponentRollbackBlocker.dataSnapshotMissing,
    );

    // The association exists, so the same version becomes safely rollbackable.
    final snapshot = await fixture.backups.create(fixture.directories.data);
    await fixture.metadata.save(
      ComponentKind.backend,
      ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.38.4',
        previousBackupId: snapshot,
      ),
    );
    expect(
      (await service.status(ComponentKind.backend)).rollbackBlockedReason,
      isNull,
    );

    // Losing the snapshot again disables the rollback rather than guessing.
    await fixture.backups.discard(snapshot);
    expect(
      (await service.status(ComponentKind.backend)).rollbackBlockedReason,
      ComponentRollbackBlocker.dataSnapshotMissing,
    );

    // A complete active Frontend cannot hide a missing previous version.
    await writeComponentVersion(fixture, ComponentKind.frontend, '2.33.0');
    await fixture.metadata.save(
      ComponentKind.frontend,
      const ComponentMetadata(
        baseline: '2.31.3',
        active: '2.33.0',
        previous: '2.32.0',
      ),
    );
    expect(
      (await service.status(ComponentKind.frontend)).rollbackBlockedReason,
      ComponentRollbackBlocker.componentFilesMissing,
    );
    _expectRuntimeIdle(fixture.runtime);
  });

  test(
    'blocks Backend rollback without a snapshot linked to the previous version',
    () async {
      final fixture = await createUpdateFixture();
      addTearDown(fixture.dispose);
      await writeUpdateFile(
        fixture.directories.data,
        'settings.json',
        'previous-data',
      );
      final unrelated = await fixture.backups.create(fixture.directories.data);
      await writeUpdateFile(
        fixture.directories.data,
        'settings.json',
        'active-data',
      );
      final another = await fixture.backups.create(fixture.directories.data);
      await fixture.metadata.save(
        ComponentKind.backend,
        const ComponentMetadata(
          baseline: '2.38.4',
          active: '2.39.0',
          previous: '2.38.4',
        ),
      );
      final service = _service(fixture, _UnexpectedDownloads());

      await expectLater(
        service.rollback(ComponentKind.backend),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('snapshot'),
          ),
        ),
      );

      expect(
        await File('${fixture.directories.data.path}/settings.json')
            .readAsString(),
        'active-data',
      );
      expect(await fixture.backups.list(), [unrelated, another]);
      _expectRuntimeIdle(fixture.runtime);
    },
  );

  test('keeps the target snapshot when three backups already exist', () async {
    final fixture = await createUpdateFixture();
    addTearDown(fixture.dispose);
    await writeComponentVersion(fixture, ComponentKind.backend, '2.39.0');
    // The target snapshot is the oldest of three, so plain retention would
    // drop exactly the snapshot this rollback needs.
    await writeUpdateFile(fixture.directories.data, 'settings.json', 'target');
    final targetBackup = await fixture.backups.create(fixture.directories.data);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    await writeUpdateFile(fixture.directories.data, 'settings.json', 'second');
    await fixture.backups.create(fixture.directories.data);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    await writeUpdateFile(fixture.directories.data, 'settings.json', 'third');
    await fixture.backups.create(fixture.directories.data);
    expect(await fixture.backups.list(), hasLength(3));
    await writeUpdateFile(
      fixture.directories.data,
      'settings.json',
      'active-data',
    );
    await fixture.metadata.save(
      ComponentKind.backend,
      ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.38.4',
        previousBackupId: targetBackup,
      ),
    );

    await _service(
      fixture,
      _UnexpectedDownloads(),
    ).rollback(ComponentKind.backend);

    // The rollback ran, the linked snapshot was consumed, and retention
    // returned to its limit.
    expect(
      await File('${fixture.directories.data.path}/settings.json')
          .readAsString(),
      'target',
    );
    final retained = await fixture.backups.list();
    expect(retained.length, lessThanOrEqualTo(3));
    expect(retained, isNot(contains(targetBackup)));
    final metadata = await fixture.readMetadata(
      ComponentKind.backend,
      baseline: 'ignored',
    );
    expect(metadata.previous, '2.39.0');
    expect(retained, contains(metadata.previousBackupId));
    _expectRuntimeIdle(fixture.runtime);
  });

  test(
    'blocks a rollback whose linked snapshot was removed by retention',
    () async {
      final fixture = await createUpdateFixture();
      addTearDown(fixture.dispose);
      await writeComponentVersion(fixture, ComponentKind.backend, '2.39.0');
      await writeUpdateFile(
        fixture.directories.data,
        'settings.json',
        'linked',
      );
      final linked = await fixture.backups.create(fixture.directories.data);
      await fixture.metadata.save(
        ComponentKind.backend,
        ComponentMetadata(
          baseline: '2.38.4',
          active: '2.39.0',
          previous: '2.38.4',
          previousBackupId: linked,
        ),
      );
      // Ordinary cleanup that does not know about the association evicts it.
      for (var index = 0; index < 3; index++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        await writeUpdateFile(
          fixture.directories.data,
          'settings.json',
          'later-$index',
        );
        await fixture.backups.create(fixture.directories.data);
      }
      expect(await fixture.backups.list(), isNot(contains(linked)));
      final service = _service(fixture, _UnexpectedDownloads());

      expect(
        (await service.status(ComponentKind.backend)).rollbackBlockedReason,
        ComponentRollbackBlocker.dataSnapshotMissing,
      );
      await expectLater(
        service.rollback(ComponentKind.backend),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('snapshot'),
          ),
        ),
      );
      expect(
        await File('${fixture.directories.data.path}/settings.json')
            .readAsString(),
        'later-2',
      );
      _expectRuntimeIdle(fixture.runtime);
    },
  );

  test(
    'rejects any component mutation while either component has pending work',
    () async {
      for (final pendingKind in <ComponentKind>[
        ComponentKind.backend,
        ComponentKind.frontend,
      ]) {
        final fixture = await createUpdateFixture();
        addTearDown(fixture.dispose);
        final backendPending = pendingKind == ComponentKind.backend;
        final otherKind = backendPending
            ? ComponentKind.frontend
            : ComponentKind.backend;
        final baseline = backendPending ? '2.38.4' : '2.31.3';
        final active = backendPending ? '2.39.0' : '2.32.0';
        await writeComponentVersion(fixture, pendingKind, active);
        await writeComponentVersion(
          fixture,
          otherKind,
          backendPending ? '2.32.0' : '2.39.0',
        );
        String? pendingBackup;
        if (backendPending) {
          pendingBackup = await fixture.backups.create(
            fixture.directories.data,
          );
        }
        await fixture.metadata.save(
          pendingKind,
          ComponentMetadata(
            baseline: baseline,
            active: active,
            previous: baseline,
            previousBackupId: pendingBackup,
            pending: ComponentPending(
              version: active,
              backupId: pendingBackup,
              operation: ComponentPendingOperation.rollback,
            ),
          ),
        );
        await fixture.metadata.save(
          otherKind,
          ComponentMetadata(
            baseline: backendPending ? '2.31.3' : '2.38.4',
            active: backendPending ? '2.32.0' : '2.39.0',
            previous: backendPending ? '2.31.3' : '2.38.4',
          ),
        );
        final downloads = _UnexpectedDownloads();
        final service = _service(fixture, downloads);

        await expectLater(
          service.update(
            ComponentUpdate(
              kind: ComponentKind.backend,
              currentVersion: '2.38.4',
              availableVersion: '2.40.0',
              release: backendRelease('2.40.0'),
            ),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('pending'),
            ),
          ),
          reason: 'Backend update with $pendingKind pending',
        );
        await expectLater(
          service.update(
            ComponentUpdate(
              kind: ComponentKind.frontend,
              currentVersion: '2.31.3',
              availableVersion: '2.33.0',
              release: frontendRelease('2.33.0'),
            ),
          ),
          throwsA(isA<StateError>()),
          reason: 'Frontend update with $pendingKind pending',
        );
        await expectLater(
          service.rollback(otherKind),
          throwsA(isA<StateError>()),
          reason: 'Rollback with $pendingKind pending',
        );
        expect(downloads.calls, 0);
        _expectRuntimeIdle(fixture.runtime);

        // The real recovery path still clears the block and lets work resume.
        expect(await fixture.recoverPending(), isTrue);
        expect(
          (await fixture.readMetadata(
            pendingKind,
            baseline: 'ignored',
          )).pending,
          isNull,
        );
      }
    },
  );

  test(
    'rejects all stopped-state violations before any component mutation',
    () async {
      const statuses = [
        RuntimeStatus.starting,
        RuntimeStatus.running,
        RuntimeStatus.stopping,
        RuntimeStatus.unhealthy,
        RuntimeStatus.crashed,
      ];
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
      final frontendUpdate = ComponentUpdate(
        kind: ComponentKind.frontend,
        currentVersion: '2.31.3',
        availableVersion: '2.33.0',
        release: frontendRelease('2.33.0'),
      );
      final backendUpdate = ComponentUpdate(
        kind: ComponentKind.backend,
        currentVersion: '2.38.4',
        availableVersion: '2.40.0',
        release: backendRelease('2.40.0'),
      );

      for (final status in statuses) {
        final fixture = await createUpdateFixture(status: status);
        addTearDown(fixture.dispose);
        await fixture.metadata.save(ComponentKind.frontend, frontendMetadata);
        await fixture.metadata.save(ComponentKind.backend, backendMetadata);
        await writeUpdateFile(
          fixture.directories.data,
          'settings.json',
          'backup',
        );
        await fixture.backups.create(fixture.directories.data);
        await writeUpdateFile(
          fixture.directories.data,
          'settings.json',
          'current',
        );
        final backupsBefore = await fixture.backups.list();
        final serviceDownloads = _UnexpectedDownloads();
        final service = _service(fixture, serviceDownloads);
        final actions = <({String name, Future<void> Function() run})>[
          (name: 'Frontend update', run: () => service.update(frontendUpdate)),
          (name: 'Backend update', run: () => service.update(backendUpdate)),
          (
            name: 'Frontend rollback',
            run: () => service.rollback(ComponentKind.frontend),
          ),
          (
            name: 'Backend rollback',
            run: () => service.rollback(ComponentKind.backend),
          ),
        ];

        for (final action in actions) {
          final row = '$status / ${action.name}';
          await expectLater(
            action.run(),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                'Component mutation requires a stopped Backend',
              ),
            ),
            reason: row,
          );
          expect(
            await fixture.readMetadata(
              ComponentKind.frontend,
              baseline: 'ignored',
            ),
            frontendMetadata,
            reason: row,
          );
          expect(
            await fixture.readMetadata(
              ComponentKind.backend,
              baseline: 'ignored',
            ),
            backendMetadata,
            reason: row,
          );
          expect(
            await File('${fixture.directories.data.path}/settings.json')
                .readAsString(),
            'current',
            reason: row,
          );
          expect(await fixture.backups.list(), backupsBefore, reason: row);
          for (final candidate in ['frontend/2.33.0', 'backend/2.40.0']) {
            expect(
              await Directory.fromUri(
                fixture.directories.components.uri.resolve(candidate),
              ).exists(),
              isFalse,
              reason: row,
            );
          }
          expect(serviceDownloads.calls, 0, reason: row);
          _expectRuntimeIdle(fixture.runtime, reason: row);
        }
      }
    },
  );

  for (final row
      in <
        ({
          String owner,
          ComponentKind kind,
          Set<int> failures,
          bool retentionFailure,
          bool deferred,
        })
      >[
        (
          owner: 'Backend',
          kind: ComponentKind.backend,
          failures: {},
          retentionFailure: true,
          deferred: false,
        ),
        (
          owner: 'Frontend',
          kind: ComponentKind.frontend,
          failures: {},
          retentionFailure: true,
          deferred: false,
        ),
        (
          owner: 'Backend',
          kind: ComponentKind.backend,
          failures: {2},
          retentionFailure: false,
          deferred: false,
        ),
        (
          owner: 'Frontend',
          kind: ComponentKind.frontend,
          failures: {2},
          retentionFailure: false,
          deferred: false,
        ),
        (
          owner: 'Backend',
          kind: ComponentKind.backend,
          failures: {1},
          retentionFailure: false,
          deferred: false,
        ),
        (
          owner: 'Frontend',
          kind: ComponentKind.frontend,
          failures: {1},
          retentionFailure: false,
          deferred: false,
        ),
        (
          owner: 'Backend',
          kind: ComponentKind.backend,
          failures: {2, 3},
          retentionFailure: false,
          deferred: true,
        ),
        (
          owner: 'Frontend',
          kind: ComponentKind.frontend,
          failures: {2, 3},
          retentionFailure: false,
          deferred: true,
        ),
      ]) {
    final failure = row.retentionFailure
        ? 'retention failure'
        : row.deferred
        ? 'deferred metadata repair'
        : row.failures.length == 1 && row.failures.single == 1
        ? 'pending metadata save failure'
        : 'final metadata save failure';
    test('repairs ${row.owner} rollback after $failure and retries', () async {
      final fixture = await createUpdateFixture();
      addTearDown(fixture.dispose);
      final backend = row.kind == ComponentKind.backend;
      final baseline = backend ? '2.38.4' : '2.31.3';
      final active = backend ? '2.39.0' : '2.32.0';
      const currentData = 'current';
      await writeComponentVersion(fixture, row.kind, active);
      String? targetBackup;
      if (backend) {
        await writeUpdateFile(fixture.directories.data, 'settings.json', 'old');
        targetBackup = await fixture.backups.create(fixture.directories.data);
      }
      final prior = {
        ComponentKind.backend: ComponentMetadata(
          baseline: '2.38.4',
          active: '2.39.0',
          previous: '2.38.4',
          previousBackupId: targetBackup,
        ),
        ComponentKind.frontend: const ComponentMetadata(
          baseline: '2.31.3',
          active: '2.32.0',
          previous: '2.31.3',
        ),
      };
      await writeUpdateFile(
        fixture.directories.data,
        'settings.json',
        currentData,
      );
      await fixture.metadata.save(row.kind, prior[row.kind]!);
      fixture.metadata.failOn = {...row.failures};
      fixture.metadata.resetSaveCount();

      File? blocker;
      if (row.retentionFailure) {
        blocker = File(
          '${fixture.directories.components.path}/${row.kind.name}/9.9.9',
        );
        await blocker.parent.create(recursive: true);
        await blocker.writeAsString('retention blocker');
      }
      final service = _service(fixture, _UnexpectedDownloads());
      await expectLater(service.rollback(row.kind), throwsA(isA<StateError>()));
      _expectRuntimeIdle(fixture.runtime);
      final diskMetadata = ComponentMetadataStore(
        fixture.directories.components,
      );

      if (!row.deferred) {
        expect(
          await diskMetadata.load(row.kind, baseline: 'ignored'),
          prior[row.kind],
        );
        expect(
          await File('${fixture.directories.data.path}/settings.json')
              .readAsString(),
          currentData,
        );
        expect(
          await fixture.backups.list(),
          backend ? [targetBackup] : isEmpty,
        );
      } else {
        final pending = await diskMetadata.load(row.kind, baseline: 'ignored');
        final pendingBackups = await fixture.backups.list();
        if (backend) {
          final safetyIds = pendingBackups
              .where((id) => id != targetBackup)
              .toList();
          expect(safetyIds, hasLength(1));
          final safetyBackup = safetyIds.single;
          expect(
            pending,
            ComponentMetadata(
              baseline: '2.38.4',
              previous: active,
              previousBackupId: safetyBackup,
              pending: ComponentPending(
                version: baseline,
                backupId: safetyBackup,
                previousBackupId: targetBackup,
                operation: ComponentPendingOperation.rollback,
              ),
            ),
          );
          expect(pendingBackups, containsAll([targetBackup, safetyBackup]));
          expect(pendingBackups, hasLength(2));
          expect(
            await File(
              '${fixture.directories.backups.path}/$targetBackup/settings.json',
            ).readAsString(),
            'old',
          );
          expect(
            await File(
              '${fixture.directories.backups.path}/$safetyBackup/settings.json',
            ).readAsString(),
            currentData,
          );
        } else {
          expect(
            pending,
            const ComponentMetadata(
              baseline: '2.31.3',
              previous: '2.32.0',
              pending: ComponentPending(
                version: '2.31.3',
                operation: ComponentPendingOperation.rollback,
              ),
            ),
          );
          expect(pendingBackups, isEmpty);
        }
        expect(
          await File('${fixture.directories.data.path}/settings.json')
              .readAsString(),
          currentData,
        );
        expect(await fixture.recoverPending(), isTrue);
        expect(
          await diskMetadata.load(row.kind, baseline: 'ignored'),
          prior[row.kind],
        );
        expect(
          await File('${fixture.directories.data.path}/settings.json')
              .readAsString(),
          currentData,
        );
        expect(
          await fixture.backups.list(),
          backend ? [targetBackup] : isEmpty,
        );
      }
      _expectRuntimeIdle(fixture.runtime);

      if (blocker != null) await blocker.delete();
      fixture.metadata.failOn = {};
      fixture.metadata.resetSaveCount();
      await service.rollback(row.kind);
      if (backend) {
        final retrySafety = (await fixture.backups.list()).single;
        expect(retrySafety, isNot(targetBackup));
        expect(
          await File(
            '${fixture.directories.backups.path}/$retrySafety/settings.json',
          ).readAsString(),
          currentData,
        );
        expect(
          await diskMetadata.load(row.kind, baseline: 'ignored'),
          ComponentMetadata(
            baseline: baseline,
            previous: active,
            previousBackupId: retrySafety,
          ),
        );
      } else {
        expect(await fixture.backups.list(), isEmpty);
        expect(
          await diskMetadata.load(row.kind, baseline: 'ignored'),
          ComponentMetadata(baseline: baseline, previous: active),
        );
      }
      _expectRuntimeIdle(fixture.runtime);
    });
  }
}

ComponentUpdateService _service(
  UpdateFixture fixture,
  GithubReleaseDownloader downloads,
) => ComponentUpdateService(
  runtime: fixture.runtime,
  directories: fixture.directories,
  metadataStore: fixture.metadata,
  resources: ComponentResourceResolver(
    bundleDirectory: fixture.bundle,
    componentsDirectory: fixture.directories.components,
    metadataStore: fixture.metadata,
  ),
  releases: downloads,
  backups: fixture.backups,
);

void _expectRuntimeIdle(UpdateTestRuntime runtime, {String? reason}) {
  expect(
    [runtime.starts, runtime.stops, runtime.restarts],
    [0, 0, 0],
    reason: reason,
  );
}

class _UnexpectedDownloads implements GithubReleaseDownloader {
  var calls = 0;

  @override
  Future<void> downloadVerified(GithubReleaseAsset asset, File target) async {
    calls++;
    throw StateError('A valid service operation must not download assets');
  }

  @override
  Future<GithubRelease> latest(String repository) =>
      throw StateError('A valid service operation must not load releases');
}

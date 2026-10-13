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
          ),
        );
        final service = _service(fixture, _UnexpectedDownloads());

        await service.rollback(row.kind);

        expect(
          await fixture.readMetadata(row.kind, baseline: 'ignored'),
          ComponentMetadata(baseline: baseline, previous: row.active),
        );
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
            await fixture.readMetadata(row.kind, baseline: 'ignored'),
            ComponentMetadata(
              baseline: baseline,
              active: row.active,
              previous: baseline,
            ),
          );
          expect(
            await File('${fixture.directories.data.path}/settings.json')
                .readAsString(),
            'new',
          );
          final nextSafety = (await fixture.backups.list()).single;
          expect(nextSafety, isNot(safetyBackup));
          expect(
            await File(
              '${fixture.directories.backups.path}/$nextSafety/settings.json',
            ).readAsString(),
            'new-again',
          );
        } else {
          await service.rollback(row.kind);
          expect(
            await fixture.readMetadata(row.kind, baseline: 'ignored'),
            ComponentMetadata(
              baseline: baseline,
              active: row.active,
              previous: baseline,
            ),
          );
          expect(await fixture.backups.list(), isEmpty);
        }
        _expectRuntimeIdle(fixture.runtime);
      },
    );
  }

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
        : 'final metadata save failure';
    test('repairs ${row.owner} rollback after $failure and retries', () async {
      final fixture = await createUpdateFixture();
      addTearDown(fixture.dispose);
      final backend = row.kind == ComponentKind.backend;
      final baseline = backend ? '2.38.4' : '2.31.3';
      final active = backend ? '2.39.0' : '2.32.0';
      const currentData = 'current';
      const prior = {
        ComponentKind.backend: ComponentMetadata(
          baseline: '2.38.4',
          active: '2.39.0',
          previous: '2.38.4',
        ),
        ComponentKind.frontend: ComponentMetadata(
          baseline: '2.31.3',
          active: '2.32.0',
          previous: '2.31.3',
        ),
      };
      String? targetBackup;
      if (backend) {
        await writeUpdateFile(fixture.directories.data, 'settings.json', 'old');
        targetBackup = await fixture.backups.create(fixture.directories.data);
      }
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
              pending: ComponentPending(
                version: baseline,
                backupId: safetyBackup,
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
      expect(
        await diskMetadata.load(row.kind, baseline: 'ignored'),
        ComponentMetadata(baseline: baseline, previous: active),
      );
      expect(
        await File('${fixture.directories.data.path}/settings.json')
            .readAsString(),
        backend ? 'old' : currentData,
      );
      if (backend) {
        final retrySafety = (await fixture.backups.list()).single;
        expect(retrySafety, isNot(targetBackup));
        expect(
          await File(
            '${fixture.directories.backups.path}/$retrySafety/settings.json',
          ).readAsString(),
          currentData,
        );
      } else {
        expect(await fixture.backups.list(), isEmpty);
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

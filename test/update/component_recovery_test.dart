import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_recovery.dart';
import 'package:subdock/update/data_backup_store.dart';

void main() {
  late Directory temp;
  late Directory bundle;
  late Directory data;
  late ComponentMetadataStore metadata;
  late DataBackupStore backups;
  late ComponentRecovery recovery;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('subdock_recovery_');
    bundle = Directory.fromUri(temp.uri.resolve('bundle/'));
    data = Directory.fromUri(temp.uri.resolve('application-support/data/'));
    metadata = ComponentMetadataStore(
      Directory.fromUri(temp.uri.resolve('application-support/components/')),
    );
    backups = DataBackupStore(
      backupsDirectory: Directory.fromUri(
        temp.uri.resolve('application-support/backups/'),
      ),
      stagingDirectory: Directory.fromUri(
        temp.uri.resolve('application-support/staging/'),
      ),
    );
    recovery = ComponentRecovery(
      bundleDirectory: bundle,
      dataDirectory: data,
      metadataStore: metadata,
      dataBackups: backups,
    );
    await _write(bundle, 'data/backend/version', '2.38.4\n');
    await _write(bundle, 'data/frontend/version', '2.31.3\n');
  });

  tearDown(() => temp.delete(recursive: true));

  test(
    'recovers Backend data and component pointers from a pending update',
    () async {
      await _write(data, 'settings.json', '{"generation":1}');
      final backup = await backups.create(data);
      await _write(data, 'settings.json', '{"generation":2}');
      await metadata.save(
        ComponentKind.backend,
        ComponentMetadata(
          baseline: '2.38.4',
          active: '2.39.0',
          previous: '2.38.4',
          pending: ComponentPending(version: '2.39.0', backupId: backup),
        ),
      );

      expect(await recovery.recoverPending(), isTrue);

      expect(
        await File('${data.path}/settings.json').readAsString(),
        '{"generation":1}',
      );
      // The restored 2.39.0 becomes `previous` but its data snapshot was
      // overwritten, so no association is claimed for it.
      expect(
        await metadata.load(ComponentKind.backend, baseline: 'ignored'),
        const ComponentMetadata(baseline: '2.38.4', previous: '2.39.0'),
      );
    },
  );

  test(
    'recovers only Frontend pointers when its pending update is interrupted',
    () async {
      await metadata.save(
        ComponentKind.frontend,
        const ComponentMetadata(
          baseline: '2.31.3',
          active: '2.32.0',
          previous: '2.31.3',
          pending: ComponentPending(version: '2.32.0'),
        ),
      );

      expect(await recovery.recoverPending(), isTrue);

      expect(
        await metadata.load(ComponentKind.frontend, baseline: 'ignored'),
        const ComponentMetadata(baseline: '2.31.3', previous: '2.32.0'),
      );
    },
  );

  test(
    'recovers an interrupted Backend rollback to the packaged baseline',
    () async {
      await _write(data, 'settings.json', 'baseline');
      final target = await backups.create(data);
      await _write(data, 'settings.json', 'downloaded');
      final safety = await backups.create(data);
      await _write(data, 'settings.json', 'partially-restored');
      await metadata.save(
        ComponentKind.backend,
        ComponentMetadata(
          baseline: '2.38.4',
          previous: '2.39.0',
          pending: ComponentPending(
            version: '2.38.4',
            backupId: safety,
            operation: ComponentPendingOperation.rollback,
          ),
        ),
      );

      expect(await recovery.recoverPending(), isTrue);

      expect(
        await File('${data.path}/settings.json').readAsString(),
        'downloaded',
      );
      expect(
        await metadata.load(ComponentKind.backend, baseline: 'ignored'),
        const ComponentMetadata(
          baseline: '2.38.4',
          active: '2.39.0',
          previous: '2.38.4',
        ),
      );
      expect(await backups.list(), contains(target));
      expect(await backups.list(), isNot(contains(safety)));
    },
  );

  test(
    'recovers an interrupted Frontend rollback to the packaged baseline',
    () async {
      await metadata.save(
        ComponentKind.frontend,
        const ComponentMetadata(
          baseline: '2.31.3',
          previous: '2.32.0',
          pending: ComponentPending(
            version: '2.31.3',
            operation: ComponentPendingOperation.rollback,
          ),
        ),
      );

      expect(await recovery.recoverPending(), isTrue);
      expect(
        await metadata.load(ComponentKind.frontend, baseline: 'ignored'),
        const ComponentMetadata(
          baseline: '2.31.3',
          active: '2.32.0',
          previous: '2.31.3',
        ),
      );
    },
  );

  test('conservatively recovers legacy Backend pending metadata', () async {
    await _write(data, 'settings.json', 'before');
    final backup = await backups.create(data);
    await _write(data, 'settings.json', 'after');
    await _writeMetadata(
      temp,
      '{"baseline":"2.38.4","active":"2.39.0",'
      '"previous":"2.38.4","pending":{"version":"2.39.0",'
      '"backupId":"$backup"}}',
    );

    await recovery.recoverPending();

    expect(await backups.list(), isEmpty);
    expect(await File('${data.path}/settings.json').readAsString(), 'before');
  });

  test(
    'repairs only the pending Backend and keeps a committed Frontend',
    () async {
      await _write(data, 'settings.json', 'before-update');
      final backup = await backups.create(data);
      await _write(data, 'settings.json', 'after-update');
      const committedFrontend = ComponentMetadata(
        baseline: '2.31.3',
        active: '2.32.0',
        previous: '2.31.3',
      );
      await metadata.save(ComponentKind.frontend, committedFrontend);
      await metadata.save(
        ComponentKind.backend,
        ComponentMetadata(
          baseline: '2.38.4',
          active: '2.39.0',
          previous: '2.38.4',
          previousBackupId: backup,
          pending: ComponentPending(version: '2.39.0', backupId: backup),
        ),
      );

      expect(await recovery.recoverPending(), isTrue);

      expect(
        await metadata.load(ComponentKind.backend, baseline: 'ignored'),
        // The failed 2.39.0 resumes as previous, but its data snapshot was
        // overwritten, so no association is claimed for it.
        const ComponentMetadata(baseline: '2.38.4', previous: '2.39.0'),
      );
      expect(
        await metadata.load(ComponentKind.frontend, baseline: 'ignored'),
        committedFrontend,
      );
    },
  );

  test(
    'keeps pending metadata when recovery cannot find its snapshot',
    () async {
      await _write(data, 'settings.json', 'current');
      await metadata.save(
        ComponentKind.backend,
        const ComponentMetadata(
          baseline: '2.38.4',
          active: '2.39.0',
          previous: '2.38.4',
          pending: ComponentPending(version: '2.39.0', backupId: 'data-1-1'),
        ),
      );

      await expectLater(recovery.recoverPending(), throwsA(isA<StateError>()));

      // The unresolved operation survives, so startup still has to block rather
      // than run against an unknown component/data pairing.
      final pending = await metadata.load(
        ComponentKind.backend,
        baseline: 'ignored',
      );
      expect(pending.pending, isNotNull);
      expect(
        await File('${data.path}/settings.json').readAsString(),
        'current',
      );
    },
  );

  test('does not retain a legacy rollback safety snapshot', () async {
    await _write(data, 'settings.json', 'baseline');
    final target = await backups.create(data);
    await _write(data, 'settings.json', 'downloaded');
    final safety = await backups.create(data);
    await _write(data, 'settings.json', 'partially-restored');
    await _writeMetadata(
      temp,
      '{"baseline":"2.38.4","active":null,"previous":"2.39.0",'
      '"pending":{"version":"2.38.4","backupId":"$safety"}}',
    );

    await recovery.recoverPending();

    expect(await backups.list(), contains(target));
    expect(await backups.list(), isNot(contains(safety)));
  });

  test('re-links the restored previous version to its own snapshot', () async {
    await _write(data, 'settings.json', 'data-of-2-38-4');
    final target = await backups.create(data);
    await _write(data, 'settings.json', 'data-of-2-39-0');
    final safety = await backups.create(data);
    await _write(data, 'settings.json', 'partially-restored');
    await _writeMetadata(
      temp,
      '{"baseline":"2.38.4","previous":"2.39.0",'
      '"previousBackupId":"$safety",'
      '"pending":{"version":"2.38.4","backupId":"$safety",'
      '"previousBackupId":"$target",'
      '"operation":"rollback"}}',
    );

    expect(await recovery.recoverPending(), isTrue);

    // The interrupted rollback resumed 2.39.0 as active, so 2.38.4 returns
    // to `previous` paired with the data snapshot that version ran with.
    expect(
      await metadata.load(ComponentKind.backend, baseline: 'ignored'),
      ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.38.4',
        previousBackupId: target,
      ),
    );
    expect(
      await File('${data.path}/settings.json').readAsString(),
      'data-of-2-39-0',
    );
    expect(await backups.list(), contains(target));
    expect(await backups.list(), isNot(contains(safety)));
  });

  test('keeps the linked snapshot when recovery prunes backups', () async {
    await _write(data, 'settings.json', 'data-of-2-38-4');
    final target = await backups.create(data);
    // Updates that ran while 2.38.4 was the rollback target protected its
    // snapshot, so it can be the oldest entry of an over-limit set.
    for (var index = 0; index < 3; index++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      await _write(data, 'settings.json', 'stale-$index');
      await backups.create(data, protected: {target});
    }
    expect(await backups.list(), contains(target));
    await Future<void>.delayed(const Duration(milliseconds: 1));
    await _write(data, 'settings.json', 'data-of-2-39-0');
    final safety = await backups.create(data, protected: {target});
    await _write(data, 'settings.json', 'interrupted');
    await _writeMetadata(
      temp,
      '{"baseline":"2.38.4","previous":"2.39.0",'
      '"previousBackupId":"$safety",'
      '"pending":{"version":"2.38.4","backupId":"$safety",'
      '"previousBackupId":"$target",'
      '"operation":"rollback"}}',
    );

    expect(await recovery.recoverPending(), isTrue);

    // Recovery discards the snapshot it consumed and prunes to the retained
    // limit without evicting the snapshot the restored metadata depends on.
    final retained = await backups.list();
    expect(retained.length, lessThanOrEqualTo(3));
    expect(retained, contains(target));
    expect(retained, isNot(contains(safety)));
    expect(
      await metadata.load(ComponentKind.backend, baseline: 'ignored'),
      ComponentMetadata(
        baseline: '2.38.4',
        active: '2.39.0',
        previous: '2.38.4',
        previousBackupId: target,
      ),
    );
  });
}

Future<void> _write(Directory root, String path, String value) async {
  final file = File.fromUri(root.uri.resolve(path));
  await file.parent.create(recursive: true);
  await file.writeAsString(value);
}

Future<void> _writeMetadata(Directory root, String value) async {
  final file = File('${root.path}/application-support/components/backend.json');
  await file.parent.create(recursive: true);
  await file.writeAsString(value);
}

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
}

Future<void> _write(Directory root, String path, String value) async {
  final file = File.fromUri(root.uri.resolve(path));
  await file.parent.create(recursive: true);
  await file.writeAsString(value);
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/update/data_backup_store.dart';

void main() {
  late Directory temp;
  late Directory data;
  late DataBackupStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('subdock_backup_');
    data = Directory.fromUri(temp.uri.resolve('data/'));
    store = DataBackupStore(
      backupsDirectory: Directory.fromUri(temp.uri.resolve('backups/')),
      stagingDirectory: Directory.fromUri(temp.uri.resolve('staging/')),
    );
  });

  tearDown(() => temp.delete(recursive: true));

  test(
    'copies data atomically and retains only three successful backups',
    () async {
      await _write(data, 'nested/settings.json', '{"first":true}');
      final backups = <String>[];
      for (var index = 0; index < 4; index++) {
        await _write(data, 'nested/settings.json', '{"generation":$index}');
        backups.add(await store.create(data));
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      final retained = await store.list();

      expect(retained, orderedEquals(backups.skip(1)));
      expect(
        await File('${temp.path}/backups/${backups.last}/nested/settings.json')
            .readAsString(),
        '{"generation":3}',
      );
      expect(await Directory('${temp.path}/staging').list().isEmpty, isTrue);
    },
  );

  test(
    'rejects data trees that contain symlinks',
    () async {
      await data.create(recursive: true);
      final target = File('${temp.path}/outside');
      await target.writeAsString('outside');
      await Link('${data.path}/linked').create(target.path);

      await expectLater(store.create(data), throwsStateError);

      expect(await store.list(), isEmpty);
    },
    skip: Platform.isWindows
        ? 'Windows symlink creation needs elevation'
        : false,
  );

  test('restores a completed backup without retaining staged data', () async {
    await _write(data, 'settings.json', '{"generation":1}');
    final backup = await store.create(data);
    await _write(data, 'settings.json', '{"generation":2}');

    await store.restore(backup, data);

    expect(
      await File('${data.path}/settings.json').readAsString(),
      '{"generation":1}',
    );
    expect(await Directory('${temp.path}/staging').list().isEmpty, isTrue);
  });

  test('uses distinct ids for back-to-back backups', () async {
    await _write(data, 'settings.json', 'first');
    final first = await store.create(data);
    await _write(data, 'settings.json', 'second');
    final second = await store.create(data);

    expect(second, isNot(first));
    expect(await store.list(), containsAll(<String>[first, second]));
  });
}

Future<void> _write(Directory root, String path, String value) async {
  final file = File.fromUri(root.uri.resolve(path));
  await file.parent.create(recursive: true);
  await file.writeAsString(value);
}

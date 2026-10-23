import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/settings/config_error.dart';
import 'package:subdock/update/component_metadata_store.dart';

void main() {
  test('returns the packaged baseline before a component is updated', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_component_');
    addTearDown(() => temp.delete(recursive: true));
    final store = ComponentMetadataStore(temp);

    final metadata = await store.load(
      ComponentKind.backend,
      baseline: '2.38.4',
    );

    expect(metadata.baseline, '2.38.4');
    expect(metadata.active, isNull);
    expect(metadata.previous, isNull);
    expect(metadata.pending, isNull);
  });

  test('atomically persists rollback and pending recovery metadata', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_component_');
    addTearDown(() => temp.delete(recursive: true));
    final store = ComponentMetadataStore(temp);
    const metadata = ComponentMetadata(
      baseline: '2.38.4',
      active: '2.39.0',
      previous: '2.38.4',
      pending: ComponentPending(
        version: '2.39.0',
        backupId: 'before-2390',
        operation: ComponentPendingOperation.rollback,
      ),
    );

    await store.save(ComponentKind.backend, metadata);
    final restored = await store.load(
      ComponentKind.backend,
      baseline: 'ignored-when-persisted',
    );

    expect(restored, metadata);
    expect(await File('${temp.path}/backend.json').exists(), isTrue);
    expect(
      await temp.list().where((entity) => entity.path.endsWith('.tmp')).isEmpty,
      isTrue,
    );
    if (!Platform.isWindows) {
      expect(
        (await File('${temp.path}/backend.json').stat()).mode & 0x1ff,
        0x180,
      );
    }
  });

  test('loads pre-operation pending metadata as legacy', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_component_');
    addTearDown(() => temp.delete(recursive: true));
    final store = ComponentMetadataStore(temp);
    await File('${temp.path}/backend.json').writeAsString(
      '{"baseline":"2.38.4","active":"2.39.0",'
      '"previous":"2.38.4","pending":{"version":"2.39.0",'
      '"backupId":"data-1-1"}}',
    );

    final metadata = await store.load(
      ComponentKind.backend,
      baseline: 'ignored',
    );

    expect(metadata.pending?.operation, ComponentPendingOperation.legacy);
  });

  test('reads metadata written before snapshot association existed', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_component_');
    addTearDown(() => temp.delete(recursive: true));
    final store = ComponentMetadataStore(temp);
    await File('${temp.path}/backend.json').writeAsString(
      '{"baseline":"2.38.4","active":"2.39.0","previous":"2.38.4"}',
    );

    final metadata = await store.load(
      ComponentKind.backend,
      baseline: 'ignored',
    );

    // Readable, but with no association it must not claim to be rollbackable.
    expect(metadata.previous, '2.38.4');
    expect(metadata.previousBackupId, isNull);
  });

  test(
    'rejects a wrong-typed snapshot association instead of ignoring it',
    () async {
      final temp = await Directory.systemTemp.createTemp('subdock_component_');
      addTearDown(() => temp.delete(recursive: true));
      final store = ComponentMetadataStore(temp);
      await File('${temp.path}/backend.json').writeAsString(
        '{"baseline":"2.38.4","previous":"2.38.4","previousBackupId":7}',
      );

      await expectLater(
        store.load(ComponentKind.backend, baseline: 'ignored'),
        throwsA(
          isA<AppConfigError>().having(
            (error) => error.code,
            'code',
            AppConfigErrorCode.metadataInvalid,
          ),
        ),
      );
    },
  );

  test('rejects a wrong-typed pending snapshot association', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_component_');
    addTearDown(() => temp.delete(recursive: true));
    final store = ComponentMetadataStore(temp);
    await File('${temp.path}/backend.json').writeAsString(
      '{"baseline":"2.38.4","pending":{"version":"2.39.0",'
      '"previousBackupId":false}}',
    );

    await expectLater(
      store.load(ComponentKind.backend, baseline: 'ignored'),
      throwsA(
        isA<AppConfigError>().having(
          (error) => error.code,
          'code',
          AppConfigErrorCode.pendingMetadataInvalid,
        ),
      ),
    );
  });
}

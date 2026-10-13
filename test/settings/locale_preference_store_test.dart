import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/settings/locale_preference_store.dart';

void main() {
  test('load returns null when no file exists', () async {
    final temp = await Directory.systemTemp.createTemp(
      'locale_preference_store_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);

    expect(await LocalePreferenceStore(directories).load(), isNull);
  });

  test('round-trips the language with private file permissions', () async {
    final temp = await Directory.systemTemp.createTemp(
      'locale_preference_store_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = LocalePreferenceStore(directories);

    await store.save('en');
    expect(await store.load(), 'en');

    await store.save('zh');
    expect(await store.load(), 'zh');
    if (!Platform.isWindows) {
      expect((await store.file.stat()).mode & 0x1ff, 0x180);
    }
  });

  test('corrupt JSON and unsupported languages degrade to null', () async {
    final temp = await Directory.systemTemp.createTemp(
      'locale_preference_store_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = LocalePreferenceStore(directories);
    for (final value in ['{not json', '"fr"']) {
      await store.file.writeAsString(value);
      expect(await store.load(), isNull, reason: value);
    }
  });

  test('save rejects a language outside zh/en', () async {
    final temp = await Directory.systemTemp.createTemp(
      'locale_preference_store_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = LocalePreferenceStore(directories);

    expect(() => store.save('fr'), throwsArgumentError);
  });

  test('clear removes the preference file', () async {
    final temp = await Directory.systemTemp.createTemp(
      'locale_preference_store_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = LocalePreferenceStore(directories);

    await store.save('en');
    expect(await store.load(), 'en');

    await store.clear();
    expect(await store.load(), isNull);
    expect(await store.file.exists(), isFalse);
  });
}

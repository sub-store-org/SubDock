import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/settings/desktop_preferences.dart';
import 'package:subdock/settings/desktop_preferences_store.dart';

void main() {
  test('defaults are stable and round-trip through the snapshot', () async {
    final preferences = DesktopPreferences.defaults;

    expect(preferences.themeMode, ThemeMode.system);
    expect(preferences.locale, isNull);
    expect(preferences.closeBehavior, CloseBehavior.exitApp);
    expect(preferences.recentLogLimit, 200);
    expect(preferences.logSort, LogSort.newestFirst);
    expect(preferences.launchAtLogin, isFalse);
    expect(preferences.startHiddenToTray, isFalse);
    expect(DesktopPreferences.fromJson(preferences.toJson()), preferences);
  });

  test('new booleans round-trip and legacy JSON defaults to false', () {
    final saved = DesktopPreferences.defaults.copyWith(
      launchAtLogin: true,
      startHiddenToTray: true,
    );

    expect(DesktopPreferences.fromJson(saved.toJson()), saved);

    final legacy = Map<String, Object?>.of(DesktopPreferences.defaults.toJson())
      ..remove('launchAtLogin')
      ..remove('startHiddenToTray');
    final migrated = DesktopPreferences.fromJson(legacy);
    expect(migrated.launchAtLogin, isFalse);
    expect(migrated.startHiddenToTray, isFalse);
  });

  test('rejects invalid schema, enum, locale, and log limits', () {
    final base = DesktopPreferences.defaults.toJson();

    for (final invalid in <Map<String, Object?>>[
      {...base, 'schemaVersion': 2},
      {...base, 'themeMode': 'blue'},
      {...base, 'locale': 'fr'},
      {...base, 'recentLogLimit': 49},
      {...base, 'recentLogLimit': 2001},
      {...base, 'logSort': 'random'},
    ]) {
      expect(() => DesktopPreferences.fromJson(invalid), throwsFormatException);
    }
  });

  test(
    'migrates legacy theme and locale without changing legacy files',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'desktop_preferences_store_test_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final directories = await RuntimeDirectories.fromBaseDirectory(temp);
      final theme = File.fromUri(
        directories.config.uri.resolve('theme_mode.json'),
      );
      final locale = File.fromUri(
        directories.config.uri.resolve('locale_preference.json'),
      );
      await theme.writeAsString('"dark"');
      await locale.writeAsString('"en"');
      final legacyTheme = await theme.readAsString();
      final legacyLocale = await locale.readAsString();

      final store = DesktopPreferencesStore(directories);
      final preferences = await store.load();

      expect(preferences.themeMode, ThemeMode.dark);
      expect(preferences.locale, 'en');
      expect(preferences.closeBehavior, CloseBehavior.exitApp);
      expect(await theme.readAsString(), legacyTheme);
      expect(await locale.readAsString(), legacyLocale);
      expect(await store.file.exists(), isTrue);
    },
  );

  test('corrupt new preferences fall back without throwing', () async {
    final temp = await Directory.systemTemp.createTemp(
      'desktop_preferences_store_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = DesktopPreferencesStore(directories);
    await store.file.writeAsString('{not json');

    expect(await store.load(), DesktopPreferences.defaults);
  });

  test('saves atomically with private permissions', () async {
    final temp = await Directory.systemTemp.createTemp(
      'desktop_preferences_store_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = DesktopPreferencesStore(directories);

    await store.save(
      DesktopPreferences.defaults.copyWith(
        themeMode: ThemeMode.dark,
        locale: 'zh',
        recentLogLimit: 500,
      ),
    );

    expect(await store.load(), isNot(DesktopPreferences.defaults));
    expect((await store.load()).themeMode, ThemeMode.dark);
    expect((await store.load()).locale, 'zh');
    expect((await store.load()).recentLogLimit, 500);
    if (!Platform.isWindows) {
      expect((await store.file.stat()).mode & 0x1ff, 0x180);
    }
  });
}

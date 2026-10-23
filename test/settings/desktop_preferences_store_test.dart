import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/settings/desktop_preferences.dart';
import 'package:subdock/settings/desktop_preferences_store.dart';

void main() {
  test('defaults are stable and round-trip through the snapshot', () {
    final preferences = DesktopPreferences.defaults;

    expect(preferences.themeMode, ThemeMode.system);
    expect(preferences.locale, isNull);
    expect(preferences.closeBehavior, CloseBehavior.exitApp);
    expect(preferences.recentLogLimit, 200);
    expect(preferences.logSort, LogSort.newestFirst);
    expect(preferences.launchAtLogin, isFalse);
    expect(preferences.startHiddenToTray, isFalse);
    expect(preferences.autoSavePreferences, isTrue);
    expect(DesktopPreferences.fromJson(preferences.toJson()), preferences);
  });

  test('preference choices round-trip and older files use safe defaults', () {
    final saved = DesktopPreferences.defaults.copyWith(
      launchAtLogin: true,
      startHiddenToTray: true,
      autoSavePreferences: false,
    );

    expect(DesktopPreferences.fromJson(saved.toJson()), saved);

    final legacy = Map<String, Object?>.of(DesktopPreferences.defaults.toJson())
      ..remove('launchAtLogin')
      ..remove('startHiddenToTray')
      ..remove('autoSavePreferences');
    final migrated = DesktopPreferences.fromJson(legacy);
    expect(migrated.launchAtLogin, isFalse);
    expect(migrated.startHiddenToTray, isFalse);
    expect(migrated.autoSavePreferences, isTrue);
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
      {...base, 'autoSavePreferences': null},
      {...base, 'autoSavePreferences': 'yes'},
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

  test('persists preferences with private permissions', () async {
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

    final saved = await store.load();
    expect(saved.themeMode, ThemeMode.dark);
    expect(saved.locale, 'zh');
    expect(saved.recentLogLimit, 500);
    if (!Platform.isWindows) {
      expect((await store.file.stat()).mode & 0x1ff, 0x180);
    }
  });
}

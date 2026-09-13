import 'dart:convert';
import 'dart:io';

import '../runtime/runtime_directories.dart';
import '../runtime/runtime_permissions.dart';
import 'desktop_preferences.dart';
import 'locale_preference_store.dart';
import 'theme_mode_store.dart';

class DesktopPreferencesStore {
  const DesktopPreferencesStore(this.directories);

  final RuntimeDirectories directories;

  File get file =>
      File.fromUri(directories.config.uri.resolve('desktop_preferences.json'));

  Future<DesktopPreferences> load() async {
    if (await file.exists()) {
      try {
        return DesktopPreferences.fromJson(
          jsonDecode(await file.readAsString()),
        );
      } on Object {
        return _loadLegacy();
      }
    }

    final migrated = await _loadLegacy();
    await save(migrated);
    return migrated;
  }

  Future<void> save(DesktopPreferences preferences) async {
    final validated = DesktopPreferences.fromJson(preferences.toJson());
    final temporary = File(
      '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(validated.toJson())}\n',
        encoding: utf8,
        flush: true,
      );
      await restrictFileToCurrentUser(temporary);
      await temporary.rename(file.path);
      await restrictFileToCurrentUser(file);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<DesktopPreferences> _loadLegacy() async {
    final theme = await ThemeModeStore(directories).load();
    final locale = await LocalePreferenceStore(directories).load();
    return DesktopPreferences.defaults.copyWith(
      themeMode: theme,
      locale: locale,
    );
  }
}

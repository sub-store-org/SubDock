import 'dart:convert';
import 'dart:io';

import '../runtime/runtime_directories.dart';
import '../runtime/runtime_permissions.dart';
import 'config_error.dart';
import 'subdock_config.dart';

class SubDockConfigStore {
  const SubDockConfigStore(this.directories);

  final RuntimeDirectories directories;

  File get file => File.fromUri(directories.config.uri.resolve('subdock.json'));

  /// The exact bytes [save] writes for [config].
  static String encode(SubDockConfig config) =>
      '${const JsonEncoder.withIndent('  ').convert(config.toJson())}\n';

  Future<String?> readRaw() async =>
      await file.exists() ? file.readAsString(encoding: utf8) : null;

  Future<SubDockConfig> load() async {
    if (!await file.exists()) return const SubDockConfig();
    try {
      return SubDockConfig.fromJson(jsonDecode(await file.readAsString()));
    } on AppConfigError {
      rethrow;
    } on Object catch (error) {
      throw AppConfigError(AppConfigErrorCode.readFailed, detail: '$error');
    }
  }

  Future<void> save(SubDockConfig config) async {
    SubDockConfig.fromJson(config.toJson());
    await replaceRaw(encode(config));
  }

  /// Replaces the file with bytes already validated by the caller.
  ///
  /// [RuntimeConfigurationStore] uses this to persist a candidate it validated
  /// and restored as one pair; it skips re-parsing so the previous bytes are
  /// re-written verbatim.
  Future<void> replaceRaw(String rawText) async {
    final temporary = File(
      '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsString(rawText, encoding: utf8, flush: true);
      await restrictFileToCurrentUser(temporary);
      await temporary.rename(file.path);
      await restrictFileToCurrentUser(file);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<void> reset() async {
    if (await file.exists()) await file.delete();
  }
}

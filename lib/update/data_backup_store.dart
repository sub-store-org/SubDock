import 'dart:io';

import '../runtime/runtime_permissions.dart';

class DataBackupStore {
  DataBackupStore({
    required this.backupsDirectory,
    required this.stagingDirectory,
  });

  static const _prefix = 'data-';
  static const _retainedBackups = 3;
  static final _idPattern = RegExp(r'^data-[0-9]+-[0-9]+$');

  final Directory backupsDirectory;
  final Directory stagingDirectory;

  /// Copies [dataDirectory] into a new retained snapshot. Every id in
  /// [protected] survives the retention limit, so a rollback must not lose the
  /// snapshot it is about to consume or to hand to a retry.
  Future<String> create(
    Directory dataDirectory, {
    Set<String> protected = const <String>{},
  }) async {
    if (!await dataDirectory.exists()) {
      throw StateError(
        'Backend data directory is missing: ${dataDirectory.path}',
      );
    }
    _requireBackupIds(protected, 'protected');
    await Future.wait([
      backupsDirectory.create(recursive: true),
      stagingDirectory.create(recursive: true),
    ]);
    await Future.wait([
      restrictDirectoryToCurrentUser(backupsDirectory),
      restrictDirectoryToCurrentUser(stagingDirectory),
    ]);
    var timestamp = DateTime.now().microsecondsSinceEpoch;
    String id;
    Directory target;
    do {
      id = '$_prefix$timestamp-$pid';
      target = Directory.fromUri(backupsDirectory.uri.resolve('$id/'));
      timestamp++;
    } while (await target.exists());
    final staging = Directory.fromUri(stagingDirectory.uri.resolve('$id/'));
    try {
      await _copyDirectory(dataDirectory, staging);
      await staging.rename(target.path);
      await restrictDirectoryToCurrentUser(target);
      await _prune(protected: protected);
      return id;
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<List<String>> list() async {
    if (!await backupsDirectory.exists()) return const <String>[];
    final ids = <String>[];
    await for (final entity in backupsDirectory.list(followLinks: false)) {
      if (entity is Directory) {
        final name = _nameOf(entity.uri);
        if (name.startsWith(_prefix)) ids.add(name);
      }
    }
    ids.sort();
    return ids;
  }

  Future<void> restore(String backupId, Directory dataDirectory) async {
    if (!_idPattern.hasMatch(backupId)) {
      throw ArgumentError.value(backupId, 'backupId');
    }
    final backup = Directory.fromUri(
      backupsDirectory.uri.resolve('$backupId/'),
    );
    if (!await backup.exists()) {
      throw StateError('Backend data backup is missing: $backupId');
    }
    await stagingDirectory.create(recursive: true);
    await restrictDirectoryToCurrentUser(stagingDirectory);
    final nonce = '${DateTime.now().microsecondsSinceEpoch}-$pid';
    final staged = Directory.fromUri(
      stagingDirectory.uri.resolve('restore-$nonce/'),
    );
    final previous = Directory.fromUri(
      dataDirectory.parent.uri.resolve('.subdock-restore-$nonce/'),
    );
    var movedPrevious = false;
    var restored = false;
    try {
      await _copyDirectory(backup, staged);
      if (await dataDirectory.exists()) {
        await dataDirectory.rename(previous.path);
        movedPrevious = true;
      }
      await staged.rename(dataDirectory.path);
      restored = true;
      await restrictDirectoryToCurrentUser(dataDirectory);
    } catch (_) {
      if (movedPrevious &&
          !await dataDirectory.exists() &&
          await previous.exists()) {
        await previous.rename(dataDirectory.path);
      }
      rethrow;
    } finally {
      if (await staged.exists()) await staged.delete(recursive: true);
      if (restored && await previous.exists()) {
        await previous.delete(recursive: true);
      }
    }
  }

  Future<void> discard(String backupId) async {
    if (!_idPattern.hasMatch(backupId)) {
      throw ArgumentError.value(backupId, 'backupId');
    }
    final backup = Directory.fromUri(
      backupsDirectory.uri.resolve('$backupId/'),
    );
    if (await backup.exists()) await backup.delete(recursive: true);
  }

  /// Re-applies the retained-backup limit at a safe boundary, keeping every
  /// snapshot named in [protected].
  Future<void> prune({Set<String> protected = const <String>{}}) async {
    _requireBackupIds(protected, 'protected');
    await _prune(protected: protected);
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await restrictDirectoryToCurrentUser(destination);
    await for (final entity in source.list(followLinks: false)) {
      final target =
          '${destination.path}${Platform.pathSeparator}${_nameOf(entity.uri)}';
      if (entity is Link) {
        throw StateError(
          'Data backup does not follow symlinks: ${entity.path}',
        );
      }
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(target));
      } else if (entity is File) {
        final copied = await entity.copy(target);
        await restrictFileToCurrentUser(copied);
      } else {
        throw StateError(
          'Data backup found an unsupported entry: ${entity.path}',
        );
      }
    }
  }

  Future<void> _prune({Set<String> protected = const <String>{}}) async {
    final ids = await list();
    var excess = ids.length - _retainedBackups;
    if (excess <= 0) return;
    for (final id in ids) {
      if (excess == 0) break;
      if (protected.contains(id)) continue;
      await Directory.fromUri(backupsDirectory.uri.resolve('$id/'))
          .delete(recursive: true);
      excess--;
    }
  }

  void _requireBackupIds(Set<String> ids, String name) {
    for (final id in ids) {
      if (!_idPattern.hasMatch(id)) throw ArgumentError.value(id, name);
    }
  }

  String _nameOf(Uri uri) =>
      uri.pathSegments.lastWhere((segment) => segment.isNotEmpty);
}

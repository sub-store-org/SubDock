import 'dart:convert';
import 'dart:io';

import '../runtime/runtime_permissions.dart';
import '../settings/config_error.dart';

enum ComponentKind { backend, frontend }

enum ComponentPendingOperation { update, rollback, legacy }

class ComponentPending {
  const ComponentPending({
    required this.version,
    this.backupId,
    this.previousBackupId,
    this.operation = ComponentPendingOperation.update,
  });

  final String version;

  /// Backend data snapshot taken before the operation, which recovery restores
  /// to undo it.
  final String? backupId;

  /// Backend data snapshot that belongs to the version recovery restores as
  /// the `previous` version. Recovery writes it back to
  /// [ComponentMetadata.previousBackupId], so the restored version stays
  /// rollbackable instead of losing its association.
  final String? previousBackupId;

  final ComponentPendingOperation operation;

  Map<String, String> toJson() => {
    'version': version,
    'backupId': ?backupId,
    'previousBackupId': ?previousBackupId,
    'operation': operation.name,
  };

  factory ComponentPending.fromJson(Object? value) {
    final operation = value is Map ? value['operation'] : null;
    if (value is! Map ||
        value['version'] is! String ||
        (value['backupId'] != null && value['backupId'] is! String) ||
        (value['previousBackupId'] != null &&
            value['previousBackupId'] is! String) ||
        (operation != null &&
            (operation is! String ||
                !ComponentPendingOperation.values.any(
                  (item) => item.name == operation,
                )))) {
      throw const AppConfigError(AppConfigErrorCode.pendingMetadataInvalid);
    }
    return ComponentPending(
      version: value['version'] as String,
      backupId: value['backupId'] as String?,
      previousBackupId: value['previousBackupId'] as String?,
      operation: ComponentPendingOperation.values.firstWhere(
        (item) => item.name == operation,
        orElse: () => ComponentPendingOperation.legacy,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ComponentPending &&
      other.version == version &&
      other.backupId == backupId &&
      other.previousBackupId == previousBackupId &&
      other.operation == operation;

  @override
  int get hashCode =>
      Object.hash(version, backupId, previousBackupId, operation);
}

class ComponentMetadata {
  const ComponentMetadata({
    required this.baseline,
    this.active,
    this.previous,
    this.previousBackupId,
    this.cleanupBackupId,
    this.pending,
  });

  final String baseline;
  final String? active;
  final String? previous;

  /// Backend data snapshot holding the data as it was while [previous] was
  /// active, so a rollback restores the data belonging to that version instead
  /// of trusting the newest snapshot. Null for Frontend components and for
  /// metadata written before this pairing existed, which keeps such records
  /// readable but not safely rollbackable.
  final String? previousBackupId;

  /// Data snapshot left to delete after a committed Backend rollback.
  ///
  /// Unlike [pending], this never means the active component or data should be
  /// restored; it only records cleanup that can safely be retried.
  final String? cleanupBackupId;

  final ComponentPending? pending;

  Map<String, Object> toJson() => {
    'baseline': baseline,
    'active': ?active,
    'previous': ?previous,
    'previousBackupId': ?previousBackupId,
    'cleanupBackupId': ?cleanupBackupId,
    'pending': ?pending?.toJson(),
  };

  factory ComponentMetadata.fromJson(Object? value) {
    if (value is! Map ||
        value['baseline'] is! String ||
        (value['active'] != null && value['active'] is! String) ||
        (value['previous'] != null && value['previous'] is! String) ||
        (value['previousBackupId'] != null &&
            value['previousBackupId'] is! String) ||
        (value['cleanupBackupId'] != null &&
            value['cleanupBackupId'] is! String)) {
      throw const AppConfigError(AppConfigErrorCode.metadataInvalid);
    }
    final previousBackupId = value['previousBackupId'] as String?;
    return ComponentMetadata(
      baseline: value['baseline'] as String,
      active: value['active'] as String?,
      previous: value['previous'] as String?,
      previousBackupId: previousBackupId,
      cleanupBackupId: value['cleanupBackupId'] as String?,
      pending: value['pending'] == null
          ? null
          : ComponentPending.fromJson(value['pending']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ComponentMetadata &&
      other.baseline == baseline &&
      other.active == active &&
      other.previous == previous &&
      other.previousBackupId == previousBackupId &&
      other.cleanupBackupId == cleanupBackupId &&
      other.pending == pending;

  @override
  int get hashCode => Object.hash(
    baseline,
    active,
    previous,
    previousBackupId,
    cleanupBackupId,
    pending,
  );
}

class ComponentMetadataStore {
  ComponentMetadataStore(this._directory);

  final Directory _directory;

  Future<ComponentMetadata> load(
    ComponentKind kind, {
    required String baseline,
  }) async {
    final file = _fileFor(kind);
    if (!await file.exists()) return ComponentMetadata(baseline: baseline);
    return ComponentMetadata.fromJson(jsonDecode(await file.readAsString()));
  }

  /// Writes [metadata] so a returned future means the record was published.
  ///
  /// The temporary file receives the current-user restriction before the rename,
  /// and the rename is the last fallible step: once it succeeds the published
  /// record is private and complete, and nothing else runs that could make a
  /// published save look uncommitted. A failed write still cleans up its own
  /// temporary file and leaves the previously published record untouched.
  Future<void> save(ComponentKind kind, ComponentMetadata metadata) async {
    await _directory.create(recursive: true);
    await restrictDirectoryToCurrentUser(_directory);
    final target = _fileFor(kind);
    final temporary = File(
      '${target.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    var published = false;
    try {
      await temporary.writeAsString(jsonEncode(metadata.toJson()), flush: true);
      await restrictFileToCurrentUser(temporary);
      await temporary.rename(target.path);
      published = true;
    } finally {
      if (!published && await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  File _fileFor(ComponentKind kind) =>
      File('${_directory.path}/${kind.name}.json');
}

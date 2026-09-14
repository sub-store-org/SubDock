import 'dart:convert';
import 'dart:io';

import '../runtime/runtime_permissions.dart';
import '../settings/config_error.dart';

enum ComponentKind { backend, frontend }

enum ComponentPendingOperation { update, rollback }

class ComponentPending {
  const ComponentPending({
    required this.version,
    this.backupId,
    this.operation = ComponentPendingOperation.update,
  });

  final String version;
  final String? backupId;
  final ComponentPendingOperation operation;

  Map<String, String> toJson() => {
    'version': version,
    'backupId': ?backupId,
    'operation': operation.name,
  };

  factory ComponentPending.fromJson(Object? value) {
    final operation = value is Map ? value['operation'] : null;
    if (value is! Map ||
        value['version'] is! String ||
        (value['backupId'] != null && value['backupId'] is! String) ||
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
      operation: ComponentPendingOperation.values.firstWhere(
        (item) => item.name == operation,
        orElse: () => ComponentPendingOperation.update,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ComponentPending &&
      other.version == version &&
      other.backupId == backupId &&
      other.operation == operation;

  @override
  int get hashCode => Object.hash(version, backupId, operation);
}

class ComponentMetadata {
  const ComponentMetadata({
    required this.baseline,
    this.active,
    this.previous,
    this.pending,
  });

  final String baseline;
  final String? active;
  final String? previous;
  final ComponentPending? pending;

  Map<String, Object> toJson() => {
    'baseline': baseline,
    'active': ?active,
    'previous': ?previous,
    'pending': ?pending?.toJson(),
  };

  factory ComponentMetadata.fromJson(Object? value) {
    if (value is! Map ||
        value['baseline'] is! String ||
        (value['active'] != null && value['active'] is! String) ||
        (value['previous'] != null && value['previous'] is! String)) {
      throw const AppConfigError(AppConfigErrorCode.metadataInvalid);
    }
    return ComponentMetadata(
      baseline: value['baseline'] as String,
      active: value['active'] as String?,
      previous: value['previous'] as String?,
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
      other.pending == pending;

  @override
  int get hashCode => Object.hash(baseline, active, previous, pending);
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

  Future<void> save(ComponentKind kind, ComponentMetadata metadata) async {
    await _directory.create(recursive: true);
    await restrictDirectoryToCurrentUser(_directory);
    final target = _fileFor(kind);
    final temporary = File(
      '${target.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsString(jsonEncode(metadata.toJson()), flush: true);
      await restrictFileToCurrentUser(temporary);
      await temporary.rename(target.path);
      await restrictFileToCurrentUser(target);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  File _fileFor(ComponentKind kind) =>
      File('${_directory.path}/${kind.name}.json');
}

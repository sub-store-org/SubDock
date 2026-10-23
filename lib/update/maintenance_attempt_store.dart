import 'dart:convert';
import 'dart:io';

import '../app/maintenance_operation.dart';
import '../runtime/runtime_directories.dart';
import '../runtime/runtime_permissions.dart';
import 'component_metadata_store.dart';

/// The durable checkpoint used to explain interrupted component maintenance.
/// It never instructs startup to install a component or start the Backend.
class MaintenanceAttempt {
  MaintenanceAttempt({
    required List<MaintenanceTarget> targets,
    required List<ComponentKind> completed,
    required this.phase,
    required this.restoreAfterChanges,
    required this.startOnly,
    this.failedKind,
    this.failureStage,
  }) : targets = List.unmodifiable(targets),
       completed = List.unmodifiable(completed) {
    if (this.targets.isEmpty ||
        this.targets.length > ComponentKind.values.length ||
        this.targets.map((target) => target.kind).toSet().length !=
            this.targets.length ||
        this.completed.toSet().length != this.completed.length ||
        !this.targets
            .map((target) => target.kind)
            .toSet()
            .containsAll(this.completed) ||
        (startOnly && this.completed.length != this.targets.length)) {
      throw const FormatException('Invalid maintenance attempt');
    }
  }

  final List<MaintenanceTarget> targets;
  final List<ComponentKind> completed;
  final MaintenancePhase phase;
  final bool restoreAfterChanges;
  final bool startOnly;
  final ComponentKind? failedKind;
  final MaintenanceFailureStage? failureStage;

  Map<String, Object?> toJson() => {
    'version': 1,
    'targets': targets.map((target) => target.toJson()).toList(),
    'completed': completed.map((kind) => kind.name).toList(),
    'phase': phase.name,
    'restoreAfterChanges': restoreAfterChanges,
    'startOnly': startOnly,
    'failedKind': failedKind?.name,
    'failureStage': failureStage?.name,
  };

  factory MaintenanceAttempt.fromJson(Object? value) {
    if (value is! Map ||
        value['version'] != 1 ||
        value['targets'] is! List ||
        value['completed'] is! List ||
        value['phase'] is! String ||
        value['restoreAfterChanges'] is! bool ||
        value['startOnly'] is! bool ||
        (value['failedKind'] != null && value['failedKind'] is! String) ||
        (value['failureStage'] != null && value['failureStage'] is! String)) {
      throw const FormatException('Invalid maintenance attempt');
    }
    final targets = (value['targets'] as List)
        .map(MaintenanceTarget.fromJson)
        .toList(growable: false);
    final completed = (value['completed'] as List)
        .map((kind) {
          if (kind is! String) {
            throw const FormatException('Invalid completed maintenance target');
          }
          return _enumValue(ComponentKind.values, kind, 'component');
        })
        .toList(growable: false);
    return MaintenanceAttempt(
      targets: targets,
      completed: completed,
      phase: _enumValue(
        MaintenancePhase.values,
        value['phase'] as String,
        'phase',
      ),
      restoreAfterChanges: value['restoreAfterChanges'] as bool,
      startOnly: value['startOnly'] as bool,
      failedKind: value['failedKind'] == null
          ? null
          : _enumValue(
              ComponentKind.values,
              value['failedKind'] as String,
              'component',
            ),
      failureStage: value['failureStage'] == null
          ? null
          : _enumValue(
              MaintenanceFailureStage.values,
              value['failureStage'] as String,
              'failure stage',
            ),
    );
  }
}

class MaintenanceAttemptStore {
  MaintenanceAttemptStore(RuntimeDirectories directories)
    : _directory = directories.config,
      _file = File.fromUri(
        directories.config.uri.resolve('maintenance-attempt.json'),
      );

  final Directory _directory;
  final File _file;

  File get file => _file;

  Future<MaintenanceAttempt?> load() async {
    if (!await _file.exists()) return null;
    final length = await _file.length();
    if (length > 8192) {
      throw const FormatException('Maintenance attempt is too large');
    }
    try {
      return MaintenanceAttempt.fromJson(
        jsonDecode(await _file.readAsString()),
      );
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Maintenance attempt cannot be read');
    }
  }

  Future<void> save(MaintenanceAttempt attempt) async {
    await _directory.create(recursive: true);
    await restrictDirectoryToCurrentUser(_directory);
    final temporary = File(
      '${_file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    var published = false;
    try {
      await temporary.writeAsString(jsonEncode(attempt.toJson()), flush: true);
      await restrictFileToCurrentUser(temporary);
      await temporary.rename(_file.path);
      published = true;
    } finally {
      if (!published && await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  Future<void> clear() async {
    if (await _file.exists()) await _file.delete();
  }
}

T _enumValue<T extends Enum>(List<T> values, String name, String label) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('Invalid maintenance $label');
}

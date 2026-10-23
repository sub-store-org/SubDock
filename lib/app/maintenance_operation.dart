import '../update/component_metadata_store.dart';
import '../update/component_update_service.dart';

/// The file-level action recorded for one independently updatable component.
enum MaintenanceAction { update, rollback }

/// The durable and in-memory stage of a coordinated component operation.
enum MaintenancePhase {
  preparing,
  stopping,
  updating,
  starting,
  completed,
  failed,
  startFailed,
  interrupted,
  awaitingStart,
  blocked,
}

enum MaintenanceFailureStage { stopping, updating, starting, recovery }

enum MaintenanceTargetState { pending, completed, failed }

class MaintenanceTarget {
  const MaintenanceTarget({
    required this.kind,
    required this.action,
    required this.currentVersion,
    required this.targetVersion,
  });

  final ComponentKind kind;
  final MaintenanceAction action;
  final String currentVersion;
  final String targetVersion;

  Map<String, Object> toJson() => {
    'kind': kind.name,
    'action': action.name,
    'currentVersion': currentVersion,
    'targetVersion': targetVersion,
  };

  factory MaintenanceTarget.fromJson(Object? value) {
    if (value is! Map ||
        value['kind'] is! String ||
        value['action'] is! String ||
        value['currentVersion'] is! String ||
        value['targetVersion'] is! String) {
      throw const FormatException('Invalid maintenance target');
    }
    final kindName = value['kind'] as String;
    final actionName = value['action'] as String;
    final kind = ComponentKind.values.where((item) => item.name == kindName);
    final action = MaintenanceAction.values.where(
      (item) => item.name == actionName,
    );
    final currentVersion = value['currentVersion'] as String;
    final targetVersion = value['targetVersion'] as String;
    if (kind.isEmpty ||
        action.isEmpty ||
        currentVersion.isEmpty ||
        targetVersion.isEmpty ||
        currentVersion.length > 128 ||
        targetVersion.length > 128) {
      throw const FormatException('Invalid maintenance target');
    }
    return MaintenanceTarget(
      kind: kind.first,
      action: action.first,
      currentVersion: currentVersion,
      targetVersion: targetVersion,
    );
  }
}

class MaintenanceTargetResult {
  const MaintenanceTargetResult({
    required this.target,
    required this.state,
    this.statusRefreshFailed = false,
  });

  final MaintenanceTarget target;
  final MaintenanceTargetState state;
  final bool statusRefreshFailed;
}

class MaintenanceOperation {
  MaintenanceOperation({
    required this.phase,
    required List<MaintenanceTargetResult> results,
    this.failedKind,
    this.failureStage,
    this.error,
    this.committedRollbackCleanupFailure,
    this.restoreAfterChanges = false,
    this.startOnly = false,
  }) : results = List.unmodifiable(results);

  final MaintenancePhase phase;
  final List<MaintenanceTargetResult> results;
  final ComponentKind? failedKind;
  final MaintenanceFailureStage? failureStage;
  final Object? error;

  /// Preserves committed rollback cleanup independently of the latest error
  /// until cleanup and the coordinator handoff are confirmed. Component metadata
  /// carries the durable cleanup marker across process exits.
  final ComponentRollbackCleanupFailure? committedRollbackCleanupFailure;

  /// Records the original run state for interruption display only. Retries
  /// always inspect the runtime's current state before deciding to resume it.
  final bool restoreAfterChanges;

  /// Set after every file change committed but restoring the running service
  /// failed; retrying this state starts from the latest saved configuration.
  final bool startOnly;

  List<MaintenanceTarget> get targets =>
      List.unmodifiable(results.map((result) => result.target));

  List<MaintenanceTarget> get remainingTargets => List.unmodifiable(
    results
        .where((result) => result.state != MaintenanceTargetState.completed)
        .map((result) => result.target),
  );

  bool get hasCompletedTargets =>
      results.any((result) => result.state == MaintenanceTargetState.completed);

  bool get hasStatusRefreshFailure =>
      results.any((result) => result.statusRefreshFailed);

  bool get isActive =>
      phase == MaintenancePhase.preparing ||
      phase == MaintenancePhase.stopping ||
      phase == MaintenancePhase.updating ||
      phase == MaintenancePhase.starting;

  MaintenanceOperation copyWith({
    MaintenancePhase? phase,
    List<MaintenanceTargetResult>? results,
    ComponentKind? failedKind,
    bool clearFailedKind = false,
    MaintenanceFailureStage? failureStage,
    bool clearFailureStage = false,
    Object? error,
    bool clearError = false,
    ComponentRollbackCleanupFailure? committedRollbackCleanupFailure,
    bool clearCommittedRollbackCleanupFailure = false,
    bool? restoreAfterChanges,
    bool? startOnly,
  }) => MaintenanceOperation(
    phase: phase ?? this.phase,
    results: results ?? this.results,
    failedKind: clearFailedKind ? null : failedKind ?? this.failedKind,
    failureStage: clearFailureStage ? null : failureStage ?? this.failureStage,
    error: clearError ? null : error ?? this.error,
    committedRollbackCleanupFailure: clearCommittedRollbackCleanupFailure
        ? null
        : committedRollbackCleanupFailure ??
              this.committedRollbackCleanupFailure,
    restoreAfterChanges: restoreAfterChanges ?? this.restoreAfterChanges,
    startOnly: startOnly ?? this.startOnly,
  );
}

/// A session activity event kept separate from process output and log runs.
class MaintenanceActivity {
  const MaintenanceActivity({
    required this.timestamp,
    required this.phase,
    this.kind,
  });

  final DateTime timestamp;
  final MaintenancePhase phase;
  final ComponentKind? kind;
}

import '../runtime/backend_runtime.dart';
import '../runtime/runtime_directories.dart';
import 'backend_component_updater.dart';
import 'component_metadata_store.dart';
import 'component_resource_resolver.dart';
import 'component_storage.dart';
import 'component_update_checker.dart';
import 'data_backup_store.dart';
import 'frontend_component_updater.dart';
import 'github_release_client.dart';

abstract class ComponentUpdateOperations {
  Future<ComponentVersionStatus> status(ComponentKind kind);

  Future<ComponentUpdate> check(ComponentKind kind);

  Future<void> update(ComponentUpdate update);

  Future<void> rollback(ComponentKind kind);
}

/// Why the version in [ComponentVersionStatus.previous] cannot be restored.
///
/// The reason is machine-readable so the UI can localize it; it is never
/// guessed from the number of existing snapshots.
enum ComponentRollbackBlocker {
  /// The previous version has no recorded data snapshot, or the snapshot it
  /// records is no longer retained. Restoring the wrong snapshot would silently
  /// overwrite subscription data, so the rollback is refused.
  dataSnapshotMissing,

  /// The previous version has no complete component files on disk.
  componentFilesMissing,
}

class ComponentVersionStatus {
  const ComponentVersionStatus({
    required this.current,
    this.previous,
    this.rollbackBlockedReason,
  });

  final String current;
  final String? previous;

  /// Set when [previous] exists but cannot be safely restored.
  final ComponentRollbackBlocker? rollbackBlockedReason;
}

class ComponentUpdateService implements ComponentUpdateOperations {
  ComponentUpdateService({
    required BackendRuntime runtime,
    required RuntimeDirectories directories,
    required ComponentMetadataStore metadataStore,
    required ComponentResourceResolver resources,
    required GithubReleaseDownloader releases,
    required DataBackupStore backups,
  }) : _runtime = runtime,
       _directories = directories,
       _metadataStore = metadataStore,
       _resources = resources,
       _backups = backups,
       _checker = ComponentUpdateChecker(
         resources: resources,
         releases: releases,
       ),
       _backend = BackendComponentUpdater(
         runtime: runtime,
         directories: directories,
         metadataStore: metadataStore,
         resources: resources,
         downloads: releases,
         backups: backups,
       ),
       _frontend = FrontendComponentUpdater(
         runtime: runtime,
         directories: directories,
         metadataStore: metadataStore,
         resources: resources,
         downloads: releases,
       );

  final BackendRuntime _runtime;
  final RuntimeDirectories _directories;
  final ComponentMetadataStore _metadataStore;
  final ComponentResourceResolver _resources;
  final DataBackupStore _backups;
  final ComponentUpdateChecker _checker;
  final BackendComponentUpdater _backend;
  final FrontendComponentUpdater _frontend;

  ComponentStorage get _storage => ComponentStorage(_directories.components);

  @override
  Future<ComponentVersionStatus> status(ComponentKind kind) async {
    final packaged = await _resources.packagedVersions();
    final baseline = switch (kind) {
      ComponentKind.backend => packaged.backend,
      ComponentKind.frontend => packaged.frontend,
    };
    final resources = await _resources.resolve();
    final metadata = await _metadataStore.load(kind, baseline: baseline);
    return ComponentVersionStatus(
      current: switch (kind) {
        ComponentKind.backend => resources.backendVersion,
        ComponentKind.frontend => resources.frontendVersion,
      },
      previous: metadata.previous,
      rollbackBlockedReason: await _rollbackBlocker(kind, metadata, baseline),
    );
  }

  @override
  Future<ComponentUpdate> check(ComponentKind kind) => _checker.check(kind);

  @override
  Future<void> update(ComponentUpdate update) async {
    _requireStopped();
    await _requireNoPendingOperation();
    await switch (update.kind) {
      ComponentKind.backend => _backend.update(update.release),
      ComponentKind.frontend => _frontend.update(update.release),
    };
  }

  @override
  Future<void> rollback(ComponentKind kind) async {
    _requireStopped();
    await _requireNoPendingOperation();
    final packaged = await _resources.packagedVersions();
    final baseline = switch (kind) {
      ComponentKind.backend => packaged.backend,
      ComponentKind.frontend => packaged.frontend,
    };
    final metadata = await _metadataStore.load(kind, baseline: baseline);
    final target = metadata.previous;
    if (target == null) {
      throw StateError('No previous ${kind.name} component is available');
    }
    final active = metadata.active ?? metadata.baseline;
    // Refuse before touching anything: restoring an unverified version or an
    // unverified data snapshot would discard the snapshot a correct rollback
    // needs without any way back.
    switch (await _rollbackBlocker(kind, metadata, baseline)) {
      case null:
        break;
      case ComponentRollbackBlocker.componentFilesMissing:
        throw StateError(
          'Previous ${kind.name} component is incomplete: $target',
        );
      case ComponentRollbackBlocker.dataSnapshotMissing:
        throw StateError(
          'No data snapshot is linked to previous Backend version $target',
        );
    }
    if (kind != ComponentKind.backend) {
      await _rollbackFrontend(metadata, target, active);
      return;
    }
    final targetBackup = metadata.previousBackupId;
    if (targetBackup == null) {
      throw StateError(
        'No data snapshot is linked to previous Backend version $target',
      );
    }
    await _rollbackBackend(metadata, target, active, targetBackup);
  }

  /// Reports an unsafe rollback before any caller offers it: the previous
  /// version needs both its component files and, for the Backend, the data
  /// snapshot that [ComponentMetadata.previousBackupId] records. A snapshot is
  /// never inferred from the newest backup that happens to exist.
  Future<ComponentRollbackBlocker?> _rollbackBlocker(
    ComponentKind kind,
    ComponentMetadata metadata,
    String baseline,
  ) async {
    final previous = metadata.previous;
    if (previous == null) return null;
    if (!await _resources.hasCompleteVersion(
      kind,
      previous,
      baselineVersion: baseline,
    )) {
      return ComponentRollbackBlocker.componentFilesMissing;
    }
    if (kind == ComponentKind.backend) {
      final linked = metadata.previousBackupId;
      if (linked == null || !(await _backups.list()).contains(linked)) {
        return ComponentRollbackBlocker.dataSnapshotMissing;
      }
    }
    return null;
  }

  Future<void> _rollbackBackend(
    ComponentMetadata metadata,
    String target,
    String active,
    String targetBackup,
  ) async {
    // This snapshot lets pending recovery return to the current component if
    // the rollback itself is interrupted. The target snapshot must survive the
    // retention limit the new snapshot applies.
    final safetyBackup = await _backups.create(
      _directories.data,
      protected: {targetBackup},
    );
    try {
      await _metadataStore.save(
        ComponentKind.backend,
        ComponentMetadata(
          baseline: metadata.baseline,
          active: target == metadata.baseline ? null : target,
          previous: active,
          previousBackupId: safetyBackup,
          pending: ComponentPending(
            version: target,
            backupId: safetyBackup,
            previousBackupId: targetBackup,
            operation: ComponentPendingOperation.rollback,
          ),
        ),
      );
    } catch (_) {
      // A save that throws has published nothing, so this snapshot is unused
      // and the earlier metadata still links the snapshot the rollback was
      // about to consume.
      await _backups.discard(safetyBackup);
      rethrow;
    }
    try {
      await _backups.restore(targetBackup, _directories.data);
      await _storage.retain(ComponentKind.backend, [target, active]);
      await _metadataStore.save(
        ComponentKind.backend,
        ComponentMetadata(
          baseline: metadata.baseline,
          active: target == metadata.baseline ? null : target,
          previous: active,
          previousBackupId: safetyBackup,
        ),
      );
    } catch (_) {
      // Do the same recovery immediately. If this itself fails, leave pending
      // metadata intact so startup recovery can safely retry it.
      var recovered = false;
      try {
        await _backups.restore(safetyBackup, _directories.data);
        await _metadataStore.save(ComponentKind.backend, metadata);
        recovered = true;
      } finally {
        if (recovered) await _backups.discard(safetyBackup);
      }
      rethrow;
    }
    await _backups.discard(targetBackup);
  }

  Future<void> _rollbackFrontend(
    ComponentMetadata metadata,
    String target,
    String active,
  ) async {
    await _metadataStore.save(
      ComponentKind.frontend,
      ComponentMetadata(
        baseline: metadata.baseline,
        active: target == metadata.baseline ? null : target,
        previous: active,
        pending: ComponentPending(
          version: target,
          operation: ComponentPendingOperation.rollback,
        ),
      ),
    );
    try {
      await _storage.retain(ComponentKind.frontend, [target, active]);
      await _metadataStore.save(
        ComponentKind.frontend,
        ComponentMetadata(
          baseline: metadata.baseline,
          active: target == metadata.baseline ? null : target,
          previous: active,
        ),
      );
    } catch (_) {
      await _metadataStore.save(ComponentKind.frontend, metadata);
      rethrow;
    }
  }

  /// Rejects a new mutation while either component still has an unresolved
  /// operation. Otherwise the new transaction would overwrite the record and
  /// snapshots that recovery needs, silently losing the interrupted work.
  Future<void> _requireNoPendingOperation() async {
    final packaged = await _resources.packagedVersions();
    for (final kind in ComponentKind.values) {
      final metadata = await _metadataStore.load(
        kind,
        baseline: switch (kind) {
          ComponentKind.backend => packaged.backend,
          ComponentKind.frontend => packaged.frontend,
        },
      );
      if (metadata.pending != null) {
        throw StateError(
          'A ${kind.name} component operation is pending; recover it before '
          'starting another one',
        );
      }
    }
  }

  void _requireStopped() {
    if (_runtime.currentState.status != RuntimeStatus.stopped) {
      throw StateError('Component mutation requires a stopped Backend');
    }
  }
}

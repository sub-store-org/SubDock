import 'dart:io';

import 'component_metadata_store.dart';
import 'data_backup_store.dart';
import 'packaged_component_versions.dart';

class ComponentRecovery {
  ComponentRecovery({
    required Directory bundleDirectory,
    required this.dataDirectory,
    required this.metadataStore,
    required this.dataBackups,
  }) : _packagedDataDirectory = Directory.fromUri(
         bundleDirectory.uri.resolve('data/'),
       );

  final Directory _packagedDataDirectory;
  final Directory dataDirectory;
  final ComponentMetadataStore metadataStore;
  final DataBackupStore dataBackups;

  Future<bool> recoverPending() async {
    final packaged = await PackagedComponentVersions.read(
      _packagedDataDirectory,
    );
    final backend = await metadataStore.load(
      ComponentKind.backend,
      baseline: packaged.backend,
    );
    final frontend = await metadataStore.load(
      ComponentKind.frontend,
      baseline: packaged.frontend,
    );
    if (backend.pending != null && backend.cleanupBackupId != null) {
      throw StateError(
        'Backend metadata has both an in-flight operation and committed cleanup',
      );
    }
    if (frontend.cleanupBackupId != null) {
      throw StateError('Frontend metadata cannot own a Backend data snapshot');
    }
    if (backend.cleanupBackupId != null &&
        backend.cleanupBackupId == backend.previousBackupId) {
      throw StateError(
        'Backend cleanup snapshot is still linked to the previous version',
      );
    }
    if (backend.pending == null &&
        frontend.pending == null &&
        backend.cleanupBackupId == null) {
      return false;
    }

    var revertedBackend = backend;
    if (backend.pending case final pending?) {
      final backupId = pending.backupId;
      if (backupId == null) {
        throw StateError('Pending Backend update has no data backup');
      }
      await dataBackups.restore(backupId, dataDirectory);
      // A pending update's snapshot holds the data of the version recovery
      // resumes as active, not of the version it publishes as previous; the
      // latter has no provable snapshot, so it must not claim one.
      revertedBackend = _rollBack(
        backend,
        previousBackupId:
            pending.operation == ComponentPendingOperation.rollback
            ? pending.previousBackupId
            : null,
      );
      await metadataStore.save(ComponentKind.backend, revertedBackend);
      if (pending.operation != ComponentPendingOperation.update) {
        await dataBackups.discard(backupId);
      }
    } else if (backend.cleanupBackupId case final cleanupBackupId?) {
      // The component and data were already committed. Recovery only finishes
      // deleting the old snapshot; it must never restore data or change version
      // pointers for this record.
      await dataBackups.discard(cleanupBackupId);
      revertedBackend = ComponentMetadata(
        baseline: backend.baseline,
        active: backend.active,
        previous: backend.previous,
        previousBackupId: backend.previousBackupId,
      );
      await metadataStore.save(ComponentKind.backend, revertedBackend);
    }
    if (frontend.pending != null) {
      await metadataStore.save(ComponentKind.frontend, _rollBack(frontend));
    }
    // Recovery is a safe boundary: no operation is in flight, so the retained
    // snapshot limit applies again while the association the restored metadata
    // still points at survives.
    await dataBackups.prune(protected: {?revertedBackend.previousBackupId});
    return true;
  }

  /// Restores the pointers an interrupted operation was moving away from.
  ///
  /// [previousBackupId] becomes the association of the restored `previous`
  /// version; it is only knowable when the interrupted operation recorded it.
  /// Otherwise the restored version is reported as not safely rollbackable
  /// rather than paired with whichever snapshot happens to be newest.
  ComponentMetadata _rollBack(
    ComponentMetadata metadata, {
    String? previousBackupId,
  }) {
    if (metadata.previous == null) {
      throw StateError('Pending component metadata has no rollback target');
    }
    return ComponentMetadata(
      baseline: metadata.baseline,
      active: metadata.previous == metadata.baseline ? null : metadata.previous,
      previous: metadata.active ?? metadata.baseline,
      previousBackupId: previousBackupId,
    );
  }
}

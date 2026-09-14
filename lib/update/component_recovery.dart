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
    if (backend.pending == null && frontend.pending == null) return false;

    if (backend.pending case final pending?) {
      final backupId = pending.backupId;
      if (backupId == null) {
        throw StateError('Pending Backend update has no data backup');
      }
      await dataBackups.restore(backupId, dataDirectory);
      await metadataStore.save(ComponentKind.backend, _rollBack(backend));
      if (pending.operation != ComponentPendingOperation.update) {
        await dataBackups.discard(backupId);
      }
    }
    if (frontend.pending != null) {
      await metadataStore.save(ComponentKind.frontend, _rollBack(frontend));
    }
    return true;
  }

  ComponentMetadata _rollBack(ComponentMetadata metadata) {
    if (metadata.previous == null) {
      throw StateError('Pending component metadata has no rollback target');
    }
    return ComponentMetadata(
      baseline: metadata.baseline,
      active: metadata.previous == metadata.baseline ? null : metadata.previous,
      previous: metadata.active ?? metadata.baseline,
    );
  }
}

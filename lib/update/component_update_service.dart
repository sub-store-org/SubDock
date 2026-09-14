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

class ComponentVersionStatus {
  const ComponentVersionStatus({required this.current, this.previous});

  final String current;
  final String? previous;
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
    final resources = await _resources.resolve();
    final metadata = await _metadataStore.load(
      kind,
      baseline: switch (kind) {
        ComponentKind.backend => packaged.backend,
        ComponentKind.frontend => packaged.frontend,
      },
    );
    return ComponentVersionStatus(
      current: switch (kind) {
        ComponentKind.backend => resources.backendVersion,
        ComponentKind.frontend => resources.frontendVersion,
      },
      previous: metadata.previous,
    );
  }

  @override
  Future<ComponentUpdate> check(ComponentKind kind) => _checker.check(kind);

  @override
  Future<void> update(ComponentUpdate update) => switch (update.kind) {
    ComponentKind.backend => _backend.update(update.release),
    ComponentKind.frontend => _frontend.update(update.release),
  };

  @override
  Future<void> rollback(ComponentKind kind) async {
    _requireStopped();
    final packaged = await _resources.packagedVersions();
    final metadata = await _metadataStore.load(
      kind,
      baseline: switch (kind) {
        ComponentKind.backend => packaged.backend,
        ComponentKind.frontend => packaged.frontend,
      },
    );
    final target = metadata.previous;
    final active = metadata.active ?? metadata.baseline;
    if (target == null) {
      throw StateError('No previous ${kind.name} component is available');
    }
    if (kind == ComponentKind.backend) {
      await _rollbackBackend(metadata, target, active);
    } else {
      await _rollbackFrontend(metadata, target, active);
    }
  }

  Future<void> _rollbackBackend(
    ComponentMetadata metadata,
    String target,
    String active,
  ) async {
    final available = await _backups.list();
    if (available.isEmpty) {
      throw StateError('No Backend data backup is available for rollback');
    }
    final targetBackup = available.last;
    // This snapshot lets pending recovery return to the current component if
    // the rollback itself is interrupted.
    final safetyBackup = await _backups.create(_directories.data);
    await _metadataStore.save(
      ComponentKind.backend,
      ComponentMetadata(
        baseline: metadata.baseline,
        active: target == metadata.baseline ? null : target,
        previous: active,
        pending: ComponentPending(version: target, backupId: safetyBackup),
      ),
    );
    try {
      await _backups.restore(targetBackup, _directories.data);
      await _metadataStore.save(
        ComponentKind.backend,
        ComponentMetadata(
          baseline: metadata.baseline,
          active: target == metadata.baseline ? null : target,
          previous: active,
        ),
      );
      await _storage.retain(ComponentKind.backend, [target, active]);
      await _backups.discard(safetyBackup);
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
        pending: ComponentPending(version: target),
      ),
    );
    try {
      await _metadataStore.save(
        ComponentKind.frontend,
        ComponentMetadata(
          baseline: metadata.baseline,
          active: target == metadata.baseline ? null : target,
          previous: active,
        ),
      );
      await _storage.retain(ComponentKind.frontend, [target, active]);
    } catch (_) {
      await _metadataStore.save(ComponentKind.frontend, metadata);
      rethrow;
    }
  }

  void _requireStopped() {
    if (_runtime.currentState.status != RuntimeStatus.stopped) {
      throw StateError('Component mutation requires a stopped Backend');
    }
  }
}

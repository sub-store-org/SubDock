part of '../app.dart';

const double _updatesBundleRadius = 10;

class _UpdatesPage extends StatefulWidget {
  const _UpdatesPage({
    super.key,
    required this.active,
    required this.state,
    required this.info,
    required this.coordinator,
    required this.onOpenExternalUri,
  });

  final RuntimeState state;
  final bool active;
  final BackendInfo? info;
  final AppCoordinator coordinator;
  final Future<bool> Function(Uri uri) onOpenExternalUri;

  @override
  State<_UpdatesPage> createState() => _UpdatesPageState();
}

class _UpdatesPageState extends State<_UpdatesPage> {
  Object? _actionError;

  @override
  void initState() {
    super.initState();
    widget.coordinator.maintenanceChanges.addListener(_onMaintenanceChanged);
    unawaited(_refreshStatuses());
    if (widget.active) unawaited(checkAll());
  }

  @override
  void didUpdateWidget(covariant _UpdatesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active) unawaited(checkAll());
  }

  @override
  void dispose() {
    widget.coordinator.maintenanceChanges.removeListener(_onMaintenanceChanged);
    super.dispose();
  }

  void _onMaintenanceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshStatuses() async {
    await Future.wait(
      ComponentKind.values.map((kind) async {
        try {
          await widget.coordinator.componentStatus(kind);
        } catch (_) {
          // Coordinator state retains the status error for this component.
        }
      }),
    );
  }

  Future<void> _check(ComponentKind kind) async {
    try {
      await Future.wait([
        widget.coordinator.componentStatus(kind),
        widget.coordinator.checkComponent(kind),
      ]);
    } catch (_) {
      // Coordinator state retains independent status and release-check errors.
    }
  }

  Future<void> checkAll() async {
    await Future.wait(ComponentKind.values.map(_check));
  }

  String _runtimeLabel(AppLocalizations l10n) => switch (widget.state.status) {
    RuntimeStatus.stopped => l10n.stopped,
    RuntimeStatus.starting => l10n.starting,
    RuntimeStatus.running => l10n.running,
    RuntimeStatus.stopping => l10n.stopping,
    RuntimeStatus.unhealthy => l10n.unhealthy,
    RuntimeStatus.crashed => l10n.crashed,
  };

  String _httpMetaLabel(AppLocalizations l10n) =>
      switch (widget.state.httpMetaStatus) {
        HttpMetaStatus.disabled => l10n.httpMetaDisabled,
        HttpMetaStatus.unavailable => l10n.httpMetaUnavailable,
        HttpMetaStatus.starting => l10n.httpMetaStarting,
        HttpMetaStatus.running => l10n.httpMetaRunning(
          widget.state.httpMetaPort ?? '-',
          widget.state.httpMetaVersion ?? '-',
        ),
        HttpMetaStatus.degraded => l10n.httpMetaDegraded,
        HttpMetaStatus.stopped => l10n.httpMetaStopped,
      };

  bool get _transitioning =>
      widget.state.status == RuntimeStatus.starting ||
      widget.state.status == RuntimeStatus.stopping;

  bool get _busy =>
      _transitioning ||
      (widget.coordinator.maintenanceOperation?.isActive ?? false);

  String _componentName(ComponentKind kind, AppLocalizations l10n) =>
      kind == ComponentKind.frontend
      ? l10n.frontendComponent
      : l10n.backendComponent;

  Map<ComponentKind, ComponentUpdate> _availableUpdates() => {
    for (final entry in widget.coordinator.componentChecks.entries)
      if (entry.value.isAvailable) entry.key: entry.value,
  };

  Future<void> _confirmUpdates(
    Map<ComponentKind, ComponentUpdate> confirmedUpdates,
  ) async {
    if (confirmedUpdates.isEmpty || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final targets = confirmedUpdates.entries
        .map(
          (entry) =>
              '${_componentName(entry.key, l10n)} ${entry.value.availableVersion}',
        )
        .join(', ');
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.maintenanceConfirmTitle),
            content: Text(l10n.maintenanceConfirmDescription(targets)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.continueAction),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() => _actionError = null);
    try {
      await widget.coordinator.runComponentUpdates(confirmedUpdates);
    } catch (error) {
      if (mounted) setState(() => _actionError = error);
    }
  }

  Future<void> _confirmRollback(
    ComponentKind kind,
    ComponentVersionStatus status,
  ) async {
    if (_busy || status.previous == null) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              l10n.confirmComponentRollback(status.current, status.previous!),
            ),
            content: kind == ComponentKind.backend
                ? Text(l10n.maintenanceRollbackDataWarning)
                : null,
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.rollback),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() => _actionError = null);
    try {
      await widget.coordinator.runComponentRollback(
        kind,
        confirmedStatus: status,
      );
    } catch (error) {
      if (mounted) setState(() => _actionError = error);
    }
  }

  Future<void> _retryMaintenance() async {
    final operation = widget.coordinator.maintenanceOperation;
    if (_busy ||
        operation == null ||
        widget.coordinator.maintenanceRecoveryError != null) {
      return;
    }
    setState(() => _actionError = null);
    try {
      if (!operation.startOnly) {
        for (final target in operation.remainingTargets) {
          if (target.action == MaintenanceAction.update) {
            await _check(target.kind);
          }
        }
      }
      await widget.coordinator.retryMaintenance();
    } catch (error) {
      if (mounted) setState(() => _actionError = error);
    }
  }

  Future<void> _openReleaseNotes(ComponentKind kind) async {
    final update = widget.coordinator.componentChecks[kind];
    if (update == null ||
        widget.coordinator.componentCheckErrors.containsKey(kind)) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    try {
      if (!await widget.onOpenExternalUri(update.release.releaseUri)) {
        throw StateError(
          l10n.openSystemBrowserFailed(update.release.releaseUri.toString()),
        );
      }
      if (mounted) setState(() => _actionError = null);
    } catch (error) {
      if (mounted) setState(() => _actionError = error);
    }
  }

  String _phaseLabel(AppLocalizations l10n, MaintenancePhase phase) =>
      switch (phase) {
        MaintenancePhase.preparing => l10n.maintenancePreparing,
        MaintenancePhase.stopping => l10n.maintenanceStopping,
        MaintenancePhase.updating => l10n.maintenanceUpdating,
        MaintenancePhase.starting => l10n.maintenanceStarting,
        MaintenancePhase.completed => l10n.maintenanceCompleted,
        MaintenancePhase.failed => l10n.maintenanceFailed,
        MaintenancePhase.startFailed => l10n.maintenanceStartFailed,
        MaintenancePhase.interrupted => l10n.maintenanceInterrupted,
        MaintenancePhase.awaitingStart => l10n.maintenanceAwaitingStart,
        MaintenancePhase.blocked => l10n.maintenanceBlocked,
      };

  Widget _maintenancePanel(AppLocalizations l10n, AppColors colors) {
    final operation = widget.coordinator.maintenanceOperation;
    final recoveryError = widget.coordinator.maintenanceRecoveryError;
    if (operation == null && recoveryError == null) {
      final error = _actionError;
      if (error == null) return const SizedBox.shrink();
      final typography = Theme.of(context).extension<AppTypography>()!;
      return Padding(
        padding: EdgeInsets.only(bottom: typography.spacingLg),
        child: _SurfacePanel(
          key: const ValueKey('updates-action-error'),
          borderColor: colors.error,
          child: Text(
            _localizedError(l10n, error),
            style: TextStyle(color: colors.error),
          ),
        ),
      );
    }
    final typography = Theme.of(context).extension<AppTypography>()!;
    final retryStart =
        operation?.startOnly == true &&
        (operation?.phase == MaintenancePhase.startFailed ||
            operation?.phase == MaintenancePhase.awaitingStart);
    final retryable =
        operation != null &&
        !operation.isActive &&
        operation.phase != MaintenancePhase.completed &&
        recoveryError == null;
    return Padding(
      padding: EdgeInsets.only(bottom: typography.spacingLg),
      child: _SurfacePanel(
        key: const ValueKey('updates-maintenance-result'),
        borderColor:
            recoveryError != null ||
                operation?.phase == MaintenancePhase.blocked
            ? colors.error
            : colors.divider,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.maintenanceHeading, style: typography.titleMedium),
            SizedBox(height: typography.spacingXs),
            Text(
              recoveryError != null
                  ? l10n.maintenanceRecoveryBlocked
                  : _phaseLabel(l10n, operation!.phase),
              key: const ValueKey('updates-maintenance-phase'),
              style: TextStyle(
                color:
                    recoveryError != null ||
                        operation?.phase == MaintenancePhase.blocked
                    ? colors.error
                    : null,
              ),
            ),
            if (operation != null)
              for (final result in operation.results) ...[
                SizedBox(height: typography.spacingXs),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_componentName(result.target.kind, l10n)} ${result.target.targetVersion}',
                      ),
                    ),
                    Text(switch (result.state) {
                      MaintenanceTargetState.pending =>
                        l10n.maintenanceTargetPending,
                      MaintenanceTargetState.completed =>
                        l10n.maintenanceTargetCompleted,
                      MaintenanceTargetState.failed =>
                        l10n.maintenanceTargetFailed,
                    }),
                  ],
                ),
                if (result.statusRefreshFailed)
                  Text(
                    l10n.maintenanceRefreshFailed,
                    style: TextStyle(color: colors.error),
                  ),
              ],
            if (_actionError != null || operation?.error != null)
              Padding(
                padding: EdgeInsets.only(top: typography.spacingXs),
                child: Text(
                  _localizedError(l10n, _actionError ?? operation!.error),
                  style: TextStyle(color: colors.error),
                ),
              ),
            if (retryable) ...[
              SizedBox(height: typography.spacingSm),
              FilledButton(
                key: const ValueKey('updates-maintenance-retry'),
                onPressed: _busy ? null : _retryMaintenance,
                child: Text(
                  retryStart
                      ? l10n.maintenanceRetryStart
                      : l10n.maintenanceRetry,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final compact = MediaQuery.sizeOf(context).width < navigationBreakpoint;
    final stopped = widget.state.status == RuntimeStatus.stopped;
    final availableUpdates = _availableUpdates();
    final packagedTiles = <Widget>[
      _PackagedResourceTile(
        key: const ValueKey('updates-packaged-http-meta'),
        name: 'HTTP-META',
        version: widget.state.httpMetaVersion ?? '-',
        badge: l10n.httpMetaBundled,
        detail: _httpMetaLabel(l10n),
      ),
      _PackagedResourceTile(
        key: const ValueKey('updates-packaged-mihomo'),
        name: l10n.mihomo,
        version: widget.state.httpMetaMihomoVersion ?? '-',
        badge: l10n.httpMetaResource,
      ),
      _PackagedResourceTile(
        key: const ValueKey('updates-packaged-node'),
        name: l10n.nodeJsRuntime,
        version: widget.info?.nodeVersion ?? '-',
        badge: l10n.httpMetaBundled,
      ),
    ];
    final packagedTilesRow = <Widget>[
      for (var index = 0; index < packagedTiles.length; index++) ...<Widget>[
        if (index > 0) SizedBox(width: typography.spacingSm),
        Expanded(child: packagedTiles[index]),
      ],
    ];
    final packagedTilesColumn = <Widget>[
      for (var index = 0; index < packagedTiles.length; index++) ...<Widget>[
        if (index > 0) SizedBox(height: typography.spacingSm),
        packagedTiles[index],
      ],
    ];

    return SingleChildScrollView(
      key: const ValueKey('updates-list'),
      padding: compact
          ? EdgeInsets.only(
              top: typography.spacingSm,
              left: typography.spacingSm,
              right: typography.spacingSm,
              bottom: typography.spacingLg,
            )
          : EdgeInsets.all(typography.spacingLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SurfacePanel(
            key: const ValueKey('updates-backend-notice'),
            radius: _updatesBundleRadius,
            borderColor: stopped ? colors.divider : colors.warning,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: typography.spacingMd,
                  runSpacing: typography.spacingXs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${l10n.backendRuntime} ${_runtimeLabel(l10n)}',
                      style: typography.titleMedium,
                    ),
                    FilledButton(
                      key: const ValueKey('updates-update-all'),
                      onPressed: _busy || availableUpdates.isEmpty
                          ? null
                          : () => _confirmUpdates(availableUpdates),
                      child: Text(l10n.updateAll),
                    ),
                  ],
                ),
                SizedBox(height: typography.spacingXs),
                Text(l10n.maintenanceDescription),
              ],
            ),
          ),
          SizedBox(height: typography.spacingLg),
          _maintenancePanel(l10n, colors),
          Text(l10n.independentlyUpdatable, style: typography.titleMedium),
          SizedBox(height: typography.spacingSm),
          _SurfacePanel(
            key: const ValueKey('updates-independent-section'),
            padding: EdgeInsets.zero,
            radius: typography.radiusLg,
            child: Column(
              children: [
                _ComponentUpdatePage(
                  key: const ValueKey('component-update-frontend'),
                  kind: ComponentKind.frontend,
                  coordinator: widget.coordinator,
                  enabled: !_busy,
                  onCheck: () => _check(ComponentKind.frontend),
                  onUpdate: () => _confirmUpdates({
                    ComponentKind.frontend: widget
                        .coordinator
                        .componentChecks[ComponentKind.frontend]!,
                  }),
                  onRollback: (status) =>
                      _confirmRollback(ComponentKind.frontend, status),
                  onOpenReleaseNotes: () =>
                      _openReleaseNotes(ComponentKind.frontend),
                ),
                Divider(height: 1, color: colors.divider),
                _ComponentUpdatePage(
                  key: const ValueKey('component-update-backend'),
                  kind: ComponentKind.backend,
                  coordinator: widget.coordinator,
                  enabled: !_busy,
                  onCheck: () => _check(ComponentKind.backend),
                  onUpdate: () => _confirmUpdates({
                    ComponentKind.backend: widget
                        .coordinator
                        .componentChecks[ComponentKind.backend]!,
                  }),
                  onRollback: (status) =>
                      _confirmRollback(ComponentKind.backend, status),
                  onOpenReleaseNotes: () =>
                      _openReleaseNotes(ComponentKind.backend),
                ),
              ],
            ),
          ),
          SizedBox(height: typography.spacingLg),
          Text(l10n.packagedWithSubDock, style: typography.titleMedium),
          SizedBox(height: typography.spacingSm),
          _SurfacePanel(
            key: const ValueKey('updates-packaged-section'),
            radius: typography.radiusLg,
            padding: EdgeInsets.all(typography.spacingSm),
            child: Column(
              key: const ValueKey('updates-packaged-section-layout'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.packagedResourcesDescription,
                  style: typography.bodySmall,
                ),
                SizedBox(height: typography.spacingSm),
                if (compact)
                  Column(
                    key: const ValueKey('updates-packaged-grid'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: packagedTilesColumn,
                  )
                else
                  IntrinsicHeight(
                    child: Row(
                      key: const ValueKey('updates-packaged-grid'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: packagedTilesRow,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PackagedResourceTile extends StatelessWidget {
  const _PackagedResourceTile({
    super.key,
    required this.name,
    required this.version,
    required this.badge,
    this.detail,
  });

  final String name;
  final String version;
  final String badge;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: colors.surfaceLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_updatesBundleRadius),
          side: BorderSide(color: colors.divider),
        ),
        child: Padding(
          padding: EdgeInsets.all(typography.spacingMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: typography.bodySmall),
              SizedBox(height: typography.spacingXs),
              Text(version, style: typography.titleMedium),
              SizedBox(height: typography.spacingXs),
              _OverviewBadge(text: badge),
              if (detail != null) ...[
                SizedBox(height: typography.spacingXs),
                Text(detail!, style: typography.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ComponentUpdatePage extends StatelessWidget {
  const _ComponentUpdatePage({
    super.key,
    required this.kind,
    required this.coordinator,
    required this.enabled,
    required this.onCheck,
    required this.onUpdate,
    required this.onRollback,
    required this.onOpenReleaseNotes,
  });

  final ComponentKind kind;
  final AppCoordinator coordinator;
  final bool enabled;
  final VoidCallback onCheck;
  final VoidCallback onUpdate;
  final ValueChanged<ComponentVersionStatus> onRollback;
  final VoidCallback onOpenReleaseNotes;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final compact = MediaQuery.sizeOf(context).width < navigationBreakpoint;
    final status = coordinator.componentStatuses[kind];
    final update = coordinator.componentChecks[kind];
    final checking = coordinator.componentsChecking.contains(kind);
    final checkError = coordinator.componentCheckErrors[kind];
    final statusError = coordinator.componentStatusErrors[kind];
    final title = kind == ComponentKind.frontend
        ? l10n.frontendComponent
        : l10n.backendComponent;
    final description = kind == ComponentKind.frontend
        ? l10n.frontendComponentDescription
        : l10n.backendComponentDescription;
    final busy = !enabled || checking;
    final latest = update != null && !update.isAvailable && checkError == null;
    final canRollback =
        status?.previous != null && status?.rollbackBlockedReason == null;
    final actions = Wrap(
      key: ValueKey('component-actions-${kind.name}'),
      spacing: typography.spacingXs,
      runSpacing: typography.spacingXs,
      children: [
        if (update != null && checkError == null)
          TextButton(
            key: ValueKey('component-release-notes-${kind.name}'),
            onPressed: busy ? null : onOpenReleaseNotes,
            child: Text(l10n.viewReleaseNotes),
          ),
        OutlinedButton(
          key: ValueKey('component-update-recheck-${kind.name}'),
          onPressed: busy ? null : onCheck,
          child: Text(l10n.recheck),
        ),
        if (update?.isAvailable == true)
          FilledButton(
            key: ValueKey('component-update-action-${kind.name}'),
            onPressed: busy ? null : onUpdate,
            child: Text(l10n.update),
          ),
        if (status?.previous != null)
          TextButton(
            key: ValueKey('component-rollback-action-${kind.name}'),
            onPressed: busy || !canRollback ? null : () => onRollback(status!),
            child: Text(l10n.rollback),
          ),
      ],
    );
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final details = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(child: Text(title, style: typography.titleMedium)),
                if (latest) ...[
                  SizedBox(width: typography.spacingS),
                  _OverviewBadge(text: l10n.latest, color: colors.success),
                ],
              ],
            ),
            SizedBox(height: typography.spacingXs),
            Text(description, style: typography.bodySmall),
            SizedBox(height: typography.spacingXs),
            Text(
              status == null
                  ? (statusError == null
                        ? l10n.componentReadingVersion
                        : '${l10n.componentStatusUnavailable}: ${_localizedError(l10n, statusError)}')
                  : l10n.componentCurrentWithPrevious(
                      status.current,
                      status.previous ?? '-',
                    ),
              key: ValueKey('component-update-local-status-${kind.name}'),
            ),
            SizedBox(height: typography.spacingXs),
            if (checking)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Text(
                checkError != null
                    ? _localizedError(l10n, checkError)
                    : update?.isAvailable == true
                    ? '${l10n.availableVersion}: ${update!.availableVersion}'
                    : update != null
                    ? l10n.componentUpToDate(
                        update.currentVersion,
                        status?.previous ?? '-',
                      )
                    : l10n.componentReadingVersion,
              ),
            if (status?.rollbackBlockedReason != null)
              Text(
                l10n.rollbackUnavailable,
                style: TextStyle(color: colors.error),
              ),
          ],
        );
        final identity = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: compact ? 40 : 42,
              height: compact ? 40 : 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.surfaceHigh,
                border: Border.all(color: colors.divider),
                borderRadius: BorderRadius.circular(typography.radiusMd),
              ),
              child: Icon(
                kind == ComponentKind.frontend
                    ? Icons.web_asset_outlined
                    : Icons.dns_outlined,
                color: colors.accent,
              ),
            ),
            SizedBox(width: typography.spacingMd),
            Expanded(child: details),
          ],
        );
        final content = Flex(
          key: ValueKey('component-layout-${kind.name}'),
          direction: compact ? Axis.vertical : Axis.horizontal,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (compact) identity else Expanded(child: identity),
            if (!compact) ...[
              SizedBox(width: typography.spacingMd),
              Flexible(
                child: Align(alignment: Alignment.topRight, child: actions),
              ),
            ],
            if (compact) ...[
              SizedBox(height: typography.spacingSm),
              SizedBox(width: double.infinity, child: actions),
            ],
          ],
        );
        return Padding(
          padding: EdgeInsets.all(typography.spacingMd),
          child: content,
        );
      },
    );
    return body;
  }
}

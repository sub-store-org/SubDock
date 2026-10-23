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
  final _frontendKey = GlobalKey<_ComponentUpdatePageState>();
  final _backendKey = GlobalKey<_ComponentUpdatePageState>();
  Object? _stopError;

  Future<void> checkAll() async {
    await Future.wait([
      _frontendKey.currentState?._check() ?? Future<void>.value(),
      _backendKey.currentState?._check() ?? Future<void>.value(),
    ]);
  }

  Future<void> _stopBackend() async {
    try {
      await widget.coordinator.stop();
    } catch (error) {
      if (mounted) setState(() => _stopError = error);
    }
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final compact = MediaQuery.sizeOf(context).width < navigationBreakpoint;
    final transitioning =
        widget.state.status == RuntimeStatus.starting ||
        widget.state.status == RuntimeStatus.stopping;
    final stopped = widget.state.status == RuntimeStatus.stopped;

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
          if (!stopped) ...[
            _SurfacePanel(
              key: const ValueKey('updates-backend-notice'),
              radius: _updatesBundleRadius,
              borderColor: colors.warning,
              child: Flex(
                key: const ValueKey('updates-backend-notice-layout'),
                direction: compact ? Axis.vertical : Axis.horizontal,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (compact)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${l10n.backendRuntime} ${_runtimeLabel(l10n)}',
                          style: typography.titleMedium,
                        ),
                        SizedBox(height: typography.spacingXs),
                        Text(l10n.backendMustBeStopped),
                        if (_stopError != null)
                          Text(
                            _localizedError(l10n, _stopError),
                            style: TextStyle(color: colors.error),
                          ),
                      ],
                    )
                  else
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${l10n.backendRuntime} ${_runtimeLabel(l10n)}',
                            style: typography.titleMedium,
                          ),
                          SizedBox(height: typography.spacingXs),
                          Text(l10n.backendMustBeStopped),
                          if (_stopError != null)
                            Text(
                              _localizedError(l10n, _stopError),
                              style: TextStyle(color: colors.error),
                            ),
                        ],
                      ),
                    ),
                  if (!compact) SizedBox(width: typography.spacingMd),
                  if (compact) SizedBox(height: typography.spacingSm),
                  OutlinedButton(
                    key: const ValueKey('updates-backend-stop'),
                    onPressed: transitioning ? null : _stopBackend,
                    child: Text(l10n.stopBackend),
                  ),
                ],
              ),
            ),
            SizedBox(height: typography.spacingLg),
          ],
          Text(l10n.independentlyUpdatable, style: typography.titleMedium),
          SizedBox(height: typography.spacingSm),
          _SurfacePanel(
            key: const ValueKey('updates-independent-section'),
            padding: EdgeInsets.zero,
            radius: typography.radiusLg,
            child: Column(
              children: [
                _ComponentUpdatePage(
                  key: _frontendKey,
                  kind: ComponentKind.frontend,
                  embedded: true,
                  active: widget.active,
                  coordinator: widget.coordinator,
                  onOpenExternalUri: widget.onOpenExternalUri,
                ),
                Divider(height: 1, color: colors.divider),
                _ComponentUpdatePage(
                  key: _backendKey,
                  kind: ComponentKind.backend,
                  embedded: true,
                  active: widget.active,
                  coordinator: widget.coordinator,
                  onOpenExternalUri: widget.onOpenExternalUri,
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

class _ComponentUpdatePage extends StatefulWidget {
  const _ComponentUpdatePage({
    super.key,
    required this.kind,
    this.embedded = false,
    this.active = true,
    required this.coordinator,
    required this.onOpenExternalUri,
  });
  final ComponentKind kind;
  final bool embedded;
  final bool active;
  final AppCoordinator coordinator;
  final Future<bool> Function(Uri uri) onOpenExternalUri;
  @override
  State<_ComponentUpdatePage> createState() => _ComponentUpdatePageState();
}

class _ComponentUpdatePageState extends State<_ComponentUpdatePage> {
  ComponentVersionStatus? _status;
  ComponentUpdate? _update;
  Object? _statusError;
  Object? _checkError;
  Object? _mutationError;
  var _checking = false;
  var _mutating = false;
  var _restarting = false;
  var _restartRequired = false;
  late RuntimeState _runtimeState;
  StreamSubscription<RuntimeState>? _runtimeSubscription;

  @override
  void initState() {
    super.initState();
    _runtimeState = widget.coordinator.runtime.currentState;
    _runtimeSubscription = widget.coordinator.runtime.state.listen((state) {
      if (mounted) setState(() => _runtimeState = state);
    });
    unawaited(_loadStatus());
    if (widget.active) unawaited(_check());
  }

  @override
  void didUpdateWidget(covariant _ComponentUpdatePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active) unawaited(_check());
  }

  @override
  void dispose() {
    _runtimeSubscription?.cancel();
    super.dispose();
  }

  bool get _stopped => _runtimeState.status == RuntimeStatus.stopped;
  bool get _transitioning =>
      _runtimeState.status == RuntimeStatus.starting ||
      _runtimeState.status == RuntimeStatus.stopping;
  Future<void> _loadStatus() async {
    try {
      final status = await widget.coordinator.componentStatus(widget.kind);
      if (mounted) {
        setState(() {
          _status = status;
          _statusError = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _statusError = error);
    }
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _checkError = null;
    });
    try {
      final update = await widget.coordinator.checkComponent(widget.kind);
      if (mounted) setState(() => _update = update);
    } catch (error) {
      if (mounted) {
        setState(() {
          _checkError = error;
          _update = null;
        });
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _stop() async {
    try {
      await widget.coordinator.stop();
    } catch (error) {
      if (mounted) setState(() => _checkError = error);
    }
  }

  Future<void> _applyUpdate() async {
    final update = _update;
    if (update == null ||
        !update.isAvailable ||
        !_stopped ||
        _mutating ||
        _restarting) {
      return;
    }
    setState(() {
      _mutating = true;
      _mutationError = null;
    });
    try {
      await widget.coordinator.updateComponent(update);
      await _loadStatus();
      if (mounted) {
        setState(() {
          _update = null;
          _restartRequired = true;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _mutationError = error);
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _rollback() async {
    final status = _status;
    final previous = status?.previous;
    if (status == null ||
        previous == null ||
        !_stopped ||
        _mutating ||
        _restarting) {
      return;
    }
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            content: Text(
              AppLocalizations.of(context)!
                  .confirmComponentRollback(status.current, previous),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(AppLocalizations.of(context)!.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(AppLocalizations.of(context)!.rollback),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() {
      _mutating = true;
      _mutationError = null;
    });
    try {
      await widget.coordinator.rollbackComponent(widget.kind);
      await _loadStatus();
      if (mounted) {
        setState(() {
          _update = null;
          _restartRequired = true;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _mutationError = error);
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _startBackend() async {
    if (!_restartRequired || _restarting || _mutating) return;
    setState(() {
      _restarting = true;
      _mutationError = null;
    });
    try {
      await widget.coordinator.start();
      if (mounted) setState(() => _restartRequired = false);
    } catch (error) {
      if (mounted) setState(() => _mutationError = error);
    } finally {
      if (mounted) setState(() => _restarting = false);
    }
  }

  Future<void> _openReleaseNotes() async {
    final update = _update;
    if (update == null || _checkError != null) return;
    final l10n = AppLocalizations.of(context)!;
    try {
      if (!await widget.onOpenExternalUri(update.release.releaseUri)) {
        throw StateError(
          l10n.openSystemBrowserFailed(update.release.releaseUri.toString()),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _checkError = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final kind = widget.kind.name;
    final title = widget.kind == ComponentKind.frontend
        ? l10n.frontendComponent
        : l10n.backendComponent;
    final description = widget.kind == ComponentKind.frontend
        ? l10n.frontendComponentDescription
        : l10n.backendComponentDescription;
    final gate = _stopped
        ? l10n.backendStoppedForUpdates
        : _transitioning
        ? l10n.backendTransitioning
        : l10n.backendMustBeStopped;
    final busy = _checking || _mutating || _restarting;
    final latest =
        _update != null && !_update!.isAvailable && _checkError == null;
    final actions = Wrap(
      key: ValueKey('component-actions-$kind'),
      spacing: typography.spacingXs,
      runSpacing: typography.spacingXs,
      children: [
        if (_update != null && _checkError == null)
          TextButton(
            key: ValueKey('component-release-notes-$kind'),
            onPressed: busy ? null : _openReleaseNotes,
            child: Text(l10n.viewReleaseNotes),
          ),
        OutlinedButton(
          key: ValueKey('component-update-recheck-$kind'),
          onPressed: busy ? null : _check,
          child: Text(l10n.recheck),
        ),
        if (!_stopped && !widget.embedded)
          OutlinedButton(
            key: ValueKey('component-update-stop-$kind'),
            onPressed: _transitioning || busy ? null : _stop,
            child: Text(l10n.stopBackend),
          ),
        if (_update?.isAvailable == true)
          FilledButton(
            key: ValueKey('component-update-action-$kind'),
            onPressed: _stopped && !busy ? _applyUpdate : null,
            child: Text(l10n.update),
          ),
        if (_status?.previous != null)
          TextButton(
            key: ValueKey('component-rollback-action-$kind'),
            onPressed: _stopped && !busy ? _rollback : null,
            child: Text(l10n.rollback),
          ),
      ],
    );
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final compact = MediaQuery.sizeOf(context).width < navigationBreakpoint;
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
              _status == null
                  ? (_statusError == null
                        ? l10n.componentReadingVersion
                        : '${l10n.componentStatusUnavailable}: ${_localizedError(l10n, _statusError)}')
                  : '${l10n.currentVersion}: ${_status!.current}\n${l10n.previousVersion}: ${_status!.previous ?? '-'}',
              key: ValueKey('component-update-local-status-$kind'),
            ),
            SizedBox(height: typography.spacingXs),
            if (_checking)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Text(
                _checkError != null
                    ? _localizedError(l10n, _checkError)
                    : _update?.isAvailable == true
                    ? '${l10n.availableVersion}: ${_update!.availableVersion}'
                    : l10n.componentUpToDate(
                        _update?.currentVersion ?? _status?.current ?? '-',
                        _status?.previous ?? '-',
                      ),
              ),
            if (_mutationError != null)
              Text(_localizedError(l10n, _mutationError!)),
            if (_restartRequired) ...[
              SizedBox(height: typography.spacingXs),
              Text(l10n.backendUpdatedStart),
              FilledButton(
                key: ValueKey('component-start-now-$kind'),
                onPressed: busy ? null : _startBackend,
                child: Text(l10n.startBackend),
              ),
            ],
            if (!widget.embedded) ...[
              SizedBox(height: typography.spacingSm),
              Text(gate),
            ],
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
                widget.kind == ComponentKind.frontend
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
          key: ValueKey('component-layout-$kind'),
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
    return widget.embedded ? body : _SurfacePanel(child: body);
  }
}

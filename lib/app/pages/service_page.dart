part of '../app.dart';

class _OverviewBadge extends StatelessWidget {
  const _OverviewBadge({required this.text, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final foreground = color ?? colors.onSurface;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: typography.spacingS,
        vertical: typography.spacingXs,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: foreground),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: typography.labelSmall.copyWith(color: foreground),
      ),
    );
  }
}

class _OverviewPanel extends StatelessWidget {
  const _OverviewPanel({
    super.key,
    required this.child,
    this.padding,
    this.radius,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    return ShadCard(
      padding: padding ?? EdgeInsets.all(typography.spacingMd),
      backgroundColor: colors.surfaceLow,
      radius: BorderRadius.circular(radius ?? typography.radiusLg),
      border: ShadBorder.all(color: colors.divider, width: 1),
      child: child,
    );
  }
}

class _OverviewPage extends StatefulWidget {
  const _OverviewPage({
    super.key,
    required this.state,
    required this.info,
    required this.error,
    required this.observations,
    required this.endpoint,
    required this.componentStatuses,
    required this.unavailableComponents,
    required this.actionInProgress,
    required this.hasPendingConfiguration,
    required this.onStart,
    required this.onStop,
    required this.onRestart,
    required this.onOpenLogs,
    required this.onOpenManage,
  });

  final RuntimeState state;
  final BackendInfo? info;
  final Object? error;
  final RuntimeObservationSnapshot observations;
  final String endpoint;
  final Map<ComponentKind, ComponentVersionStatus> componentStatuses;
  final Set<ComponentKind> unavailableComponents;
  final bool actionInProgress;
  final bool hasPendingConfiguration;
  final ValueChanged<BuildContext> onStart;
  final ValueChanged<BuildContext> onStop;
  final ValueChanged<BuildContext> onRestart;
  final VoidCallback onOpenLogs;
  final VoidCallback onOpenManage;

  @override
  State<_OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<_OverviewPage> {
  bool _showRuntime = true;
  String? _copyError;
  int _feedbackGeneration = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final compact = MediaQuery.sizeOf(context).width < navigationBreakpoint;
    final state = widget.state;
    final statusLabel = switch (state.status) {
      RuntimeStatus.stopped => l10n.stopped,
      RuntimeStatus.starting => l10n.starting,
      RuntimeStatus.running => l10n.running,
      RuntimeStatus.stopping => l10n.stopping,
      RuntimeStatus.unhealthy => l10n.unhealthy,
      RuntimeStatus.crashed => l10n.crashed,
    };
    final statusColor = switch (state.status) {
      RuntimeStatus.running => colors.success,
      RuntimeStatus.starting || RuntimeStatus.stopping => colors.warning,
      RuntimeStatus.unhealthy || RuntimeStatus.crashed => colors.error,
      RuntimeStatus.stopped => colors.onSurface,
    };
    final httpMetaLabel = switch (state.httpMetaStatus) {
      HttpMetaStatus.disabled => l10n.httpMetaDisabled,
      HttpMetaStatus.unavailable =>
        state.httpMetaMessage == null
            ? l10n.httpMetaUnavailable
            : l10n.httpMetaUnavailableDetail(state.httpMetaMessage!),
      HttpMetaStatus.starting => l10n.starting,
      HttpMetaStatus.running => l10n.running,
      HttpMetaStatus.degraded =>
        state.httpMetaMessage == null
            ? l10n.httpMetaDegraded
            : l10n.httpMetaDegradedDetail(state.httpMetaMessage!),
      HttpMetaStatus.stopped => l10n.httpMetaStopped,
    };
    final httpMetaColor = switch (state.httpMetaStatus) {
      HttpMetaStatus.running => colors.success,
      HttpMetaStatus.starting || HttpMetaStatus.degraded => colors.warning,
      HttpMetaStatus.unavailable => colors.error,
      HttpMetaStatus.disabled || HttpMetaStatus.stopped => colors.onSurface,
    };
    final headline = switch (state.status) {
      RuntimeStatus.stopped => l10n.serviceStoppedTitle,
      RuntimeStatus.starting => l10n.serviceStartingTitle,
      RuntimeStatus.running => l10n.serviceRunningTitle,
      RuntimeStatus.stopping => l10n.serviceStoppingTitle,
      RuntimeStatus.unhealthy => l10n.serviceUnhealthyTitle,
      RuntimeStatus.crashed => l10n.serviceCrashedTitle,
    };
    final description = switch (state.status) {
      RuntimeStatus.stopped => l10n.serviceStoppedDescription,
      RuntimeStatus.starting ||
      RuntimeStatus.stopping => l10n.serviceTransitionDescription,
      RuntimeStatus.running => l10n.serviceRunningDescription,
      RuntimeStatus.unhealthy => l10n.serviceUnhealthyDescription,
      RuntimeStatus.crashed => l10n.serviceCrashedDescription,
    };

    Widget actionButton(
      String label,
      VoidCallback? onPressed, {
      bool primary = false,
      Key? key,
    }) {
      final disabled = widget.actionInProgress || onPressed == null;
      return ShadButton.raw(
        key: key,
        variant: primary
            ? ShadButtonVariant.primary
            : ShadButtonVariant.outline,
        enabled: !disabled,
        onPressed: disabled ? null : onPressed,
        backgroundColor: disabled ? colors.surfaceHigh : null,
        foregroundColor: disabled ? colors.onSurface : null,
        hoverForegroundColor: disabled ? colors.onSurface : null,
        pressedForegroundColor: disabled ? colors.onSurface : null,
        decoration: disabled
            ? ShadDecoration(border: ShadBorder.all(color: colors.disabled))
            : null,
        child: Flexible(child: Text(label, softWrap: true)),
      );
    }

    final actionCard = _OverviewPanel(
      key: const ValueKey('overview-service-card'),
      radius: typography.radiusLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                state.status == RuntimeStatus.running
                    ? Icons.check_circle_outline
                    : state.status == RuntimeStatus.unhealthy ||
                          state.status == RuntimeStatus.crashed
                    ? Icons.error_outline
                    : Icons.circle_outlined,
                color: statusColor,
                size: 22,
              ),
              SizedBox(width: typography.spacingSm),
              Expanded(child: Text(headline, style: typography.titleLarge)),
            ],
          ),
          SizedBox(height: typography.spacingXs),
          Text(description, style: typography.bodySmall),
          if (widget.hasPendingConfiguration) ...[
            SizedBox(height: typography.spacingSm),
            Text(
              l10n.runtimeConfigSavedPending,
              key: const ValueKey('overview-pending-configuration'),
              style: TextStyle(color: colors.warning),
            ),
          ],
          if (widget.info != null) ...[
            SizedBox(height: typography.spacingSm),
            Wrap(
              spacing: typography.spacingMd,
              runSpacing: typography.spacingXs,
              children: [
                _OverviewMeta(
                  label: l10n.node,
                  value: widget.info!.nodeVersion,
                ),
                _OverviewMeta(label: l10n.port, value: '${widget.info!.port}'),
              ],
            ),
          ],
          if (widget.error != null || state.message != null) ...[
            SizedBox(height: typography.spacingSm),
            Text(
              widget.error != null
                  ? _localizedError(l10n, widget.error)
                  : state.message!,
              key: const ValueKey('overview-service-error'),
              style: TextStyle(color: colors.error),
            ),
          ],
          if (widget.error != null ||
              state.status == RuntimeStatus.unhealthy ||
              state.status == RuntimeStatus.crashed) ...[
            SizedBox(height: typography.spacingXs),
            actionButton(
              l10n.viewLogs,
              widget.onOpenLogs,
              key: const ValueKey('overview-view-logs'),
            ),
          ],
          SizedBox(height: typography.spacingMd),
          Wrap(
            spacing: typography.spacingS,
            runSpacing: typography.spacingS,
            children: [
              if (state.status == RuntimeStatus.stopped ||
                  state.status == RuntimeStatus.crashed)
                actionButton(
                  l10n.start,
                  () => widget.onStart(context),
                  primary: true,
                ),
              if (state.status == RuntimeStatus.running)
                actionButton(
                  l10n.serviceOpenSubStore,
                  widget.onOpenManage,
                  primary: true,
                  key: const ValueKey('overview-open-manage'),
                ),
              if (state.status == RuntimeStatus.running ||
                  state.status == RuntimeStatus.unhealthy) ...[
                actionButton(l10n.restart, () => widget.onRestart(context)),
                actionButton(l10n.stop, () => widget.onStop(context)),
              ],
            ],
          ),
          if (widget.actionInProgress) ...[
            SizedBox(height: typography.spacingMd),
            Semantics(
              label: statusLabel,
              liveRegion: true,
              child: const ShadProgress(minHeight: 5),
            ),
          ],
        ],
      ),
    );

    final componentRows = _OverviewPanel(
      key: const ValueKey('overview-component-status'),
      radius: typography.radiusLg,
      padding: EdgeInsets.all(typography.spacingMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.serviceComponentsHeading, style: typography.titleMedium),
          SizedBox(height: typography.spacingXs),
          for (final kind in const [
            ComponentKind.backend,
            ComponentKind.frontend,
          ]) ...[
            _OverviewComponentRow(
              key: ValueKey('overview-component-${kind.name}'),
              kind: kind,
              status: widget.componentStatuses[kind],
              unavailable: widget.unavailableComponents.contains(kind),
              statusLabel: kind == ComponentKind.backend
                  ? statusLabel
                  : l10n.componentInstalled,
            ),
            Divider(height: 1, color: colors.divider),
          ],
          _OverviewServiceRow(
            name: l10n.node,
            version: widget.info?.nodeVersion ?? '-',
            status: l10n.httpMetaBundled,
          ),
          Divider(height: 1, color: colors.divider),
          _OverviewServiceRow(
            name: 'HTTP-META',
            version: state.httpMetaVersion ?? '-',
            status: httpMetaLabel,
            statusColor: httpMetaColor,
          ),
          if (state.httpMetaStatus == HttpMetaStatus.unavailable ||
              state.httpMetaStatus == HttpMetaStatus.degraded) ...[
            SizedBox(height: typography.spacingXs),
            Text(httpMetaLabel, style: TextStyle(color: colors.error)),
            ShadButton.ghost(
              key: const ValueKey('overview-http-meta-view-logs'),
              onPressed: widget.onOpenLogs,
              child: Text(l10n.viewLogs),
            ),
          ],
        ],
      ),
    );

    final startTime = _formatDateTime(context, widget.observations.startedAt);
    final runtimeFields = [
      (
        l10n.backendRuntime,
        widget.endpoint,
        const ValueKey('runtime-endpoint-value'),
      ),
      (l10n.httpMetaResource, state.httpMetaPort?.toString() ?? '-', null),
      (l10n.node, widget.info?.nodeVersion ?? '-', null),
      (l10n.sessionLogs, '${widget.observations.currentSessionLogCount}', null),
      (l10n.recentStart, startTime, null),
      (l10n.anomalies24h, '${widget.observations.anomalyCount}', null),
    ];

    return ListView(
      padding: EdgeInsets.all(
        compact ? typography.spacingSm : typography.spacingLg,
      ),
      children: [
        actionCard,
        SizedBox(height: typography.spacingMd),
        componentRows,
        SizedBox(height: typography.spacingMd),
        _OverviewPanel(
          key: const ValueKey('overview-runtime-information'),
          radius: typography.radiusLg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.runtimeHeading,
                      style: typography.titleMedium,
                    ),
                  ),
                  ShadButton.ghost(
                    key: const ValueKey('overview-runtime-toggle'),
                    onPressed: () =>
                        setState(() => _showRuntime = !_showRuntime),
                    child: Text(_showRuntime ? l10n.collapse : l10n.expand),
                  ),
                ],
              ),
              if (_showRuntime) ...[
                SizedBox(height: typography.spacingSm),
                for (var row = 0; row < runtimeFields.length; row += 2) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var column = 0; column < 2; column++) ...[
                        if (column > 0) SizedBox(width: typography.spacingLg),
                        Expanded(
                          child: _OverviewRuntimeField(
                            label: runtimeFields[row + column].$1,
                            value: runtimeFields[row + column].$2,
                            valueKey: runtimeFields[row + column].$3,
                            onCopy: runtimeFields[row + column].$2 == '-'
                                ? null
                                : () => _copyRuntimeValue(
                                    runtimeFields[row + column].$2,
                                  ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  SizedBox(height: typography.spacingMd),
                ],
              ],
              if (_copyError != null) ...[
                SizedBox(height: typography.spacingXs),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _copyError!,
                    style: TextStyle(color: colors.error),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  void _dismissFeedback() {
    _feedbackGeneration++;
    unawaited(ShadToaster.of(context).hide(animate: false));
  }

  Future<void> _copyRuntimeValue(String value) async {
    final feedbackGeneration = _feedbackGeneration;
    final l10n = AppLocalizations.of(context)!;
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (!mounted) return;
      setState(() => _copyError = null);
      if (feedbackGeneration != _feedbackGeneration) return;
      ShadToaster.of(context).show(
        ShadToast(
          alignment: Alignment.bottomRight,
          duration: const Duration(seconds: 4),
          showCloseIconOnlyWhenHovered: false,
          title: Semantics(
            container: true,
            liveRegion: true,
            child: Text(l10n.runtimeValueCopied),
          ),
        ),
      );
    } on Object {
      if (mounted) setState(() => _copyError = l10n.runtimeValueCopyFailed);
    }
  }
}

class _OverviewMeta extends StatelessWidget {
  const _OverviewMeta({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final typography = Theme.of(context).extension<AppTypography>()!;
    return Text.rich(
      TextSpan(
        text: '$label ',
        children: [
          TextSpan(
            text: value ?? '-',
            style: typography.bodySmall.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
      style: typography.bodySmall,
    );
  }
}

class _OverviewComponentRow extends StatelessWidget {
  const _OverviewComponentRow({
    super.key,
    required this.kind,
    required this.status,
    required this.unavailable,
    required this.statusLabel,
  });

  final ComponentKind kind;
  final ComponentVersionStatus? status;
  final bool unavailable;
  final String statusLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final colors = Theme.of(context).extension<AppColors>()!;
    final name = kind == ComponentKind.backend
        ? l10n.backendComponent
        : l10n.frontendComponent;
    final version = unavailable
        ? l10n.unavailable
        : status == null
        ? l10n.unavailable
        : status!.previous == null
        ? l10n.componentCurrent(status!.current)
        : l10n.componentCurrentWithPrevious(status!.current, status!.previous!);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: typography.spacingXs),
      child: Row(
        key: ValueKey('overview-component-${kind.name}-row'),
        children: [
          Expanded(child: Text(name, style: typography.titleSmall)),
          SizedBox(
            width: 130,
            child: Text(version, style: typography.codeSmall),
          ),
          SizedBox(
            width: 150,
            child: Text(
              unavailable || status == null ? l10n.unavailable : statusLabel,
              style: typography.bodySmall.copyWith(
                color: unavailable ? colors.error : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewServiceRow extends StatelessWidget {
  const _OverviewServiceRow({
    required this.name,
    required this.version,
    required this.status,
    this.statusColor,
  });

  final String name;
  final String version;
  final String status;
  final Color? statusColor;

  @override
  Widget build(BuildContext context) {
    final typography = Theme.of(context).extension<AppTypography>()!;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: typography.spacingXs),
      child: Row(
        children: [
          Expanded(child: Text(name, style: typography.titleSmall)),
          SizedBox(
            width: 130,
            child: Text(version, style: typography.codeSmall),
          ),
          SizedBox(
            width: 150,
            child: Text(
              status,
              style: typography.bodySmall.copyWith(color: statusColor),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewRuntimeField extends StatelessWidget {
  const _OverviewRuntimeField({
    required this.label,
    required this.value,
    required this.onCopy,
    this.valueKey,
  });

  final String label;
  final String value;
  final Key? valueKey;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final typography = Theme.of(context).extension<AppTypography>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: typography.bodySmall),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                value,
                key: valueKey,
                style: typography.codeSmall,
              ),
            ),
            ShadButton.ghost(
              key: ValueKey('runtime-copy-$label'),
              enabled: onCopy != null,
              onPressed: onCopy,
              child: const Icon(Icons.copy_outlined, size: 15),
            ),
          ],
        ),
      ],
    );
  }
}

String _formatDateTime(BuildContext context, DateTime? value) {
  if (value == null) return '-';
  final local = value.toLocal();
  final material = MaterialLocalizations.of(context);
  return '${material.formatCompactDate(local)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: true)}';
}

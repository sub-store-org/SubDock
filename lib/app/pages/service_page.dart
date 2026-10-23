part of '../app.dart';

class _OverviewBadge extends StatelessWidget {
  const _OverviewBadge({super.key, required this.text, this.color});

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

class _OverviewStatCard extends StatelessWidget {
  const _OverviewStatCard({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final typography = Theme.of(context).extension<AppTypography>()!;
    return _SurfacePanel(
      radius: typography.radiusLg,
      padding: EdgeInsets.all(typography.spacingSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: typography.titleSmall),
          SizedBox(height: typography.spacingXs),
          Text(value, style: typography.titleMedium),
        ],
      ),
    );
  }
}

class _OverviewPage extends StatelessWidget {
  const _OverviewPage({
    required this.state,
    required this.info,
    required this.error,
    required this.observations,
    required this.endpoint,
    required this.componentStatuses,
    required this.unavailableComponents,
    required this.actionInProgress,
    required this.onStart,
    required this.onStop,
    required this.onRestart,
  });

  final RuntimeState state;
  final BackendInfo? info;
  final Object? error;
  final RuntimeObservationSnapshot observations;
  final String endpoint;
  final Map<ComponentKind, ComponentVersionStatus> componentStatuses;
  final Set<ComponentKind> unavailableComponents;
  final bool actionInProgress;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final compact = MediaQuery.sizeOf(context).width < navigationBreakpoint;
    final label = switch (state.status) {
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
      // Overview 只显示健康状态：常态用简短状态词，异常保留详情供排障。
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
    final backendIdentity = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 160),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: statusColor),
          SizedBox(width: typography.spacingS),
          Flexible(
            child: Text(
              '${l10n.backendRuntime} $label',
              style: typography.titleMedium,
            ),
          ),
        ],
      ),
    );
    final backendBadge = _OverviewBadge(
      text: state.status == RuntimeStatus.running ? l10n.healthy : label,
      color: statusColor,
    );
    final backendPanel = _SurfacePanel(
      key: const ValueKey('overview-backend-hero'),
      radius: typography.radiusLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flex(
            key: const ValueKey('overview-backend-hero-top'),
            direction: compact ? Axis.vertical : Axis.horizontal,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              compact ? backendIdentity : Flexible(child: backendIdentity),
              if (compact) SizedBox(height: typography.spacingSm),
              compact ? backendBadge : Flexible(child: backendBadge),
            ],
          ),
          SizedBox(height: typography.spacingMd),
          Text(
            info?.backendVersion ?? '-',
            style: typography.titleLarge.copyWith(
              fontSize: compact ? 24 : 28,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: typography.spacingS),
          Wrap(
            spacing: typography.spacingMd,
            runSpacing: typography.spacingXs,
            children: [
              _OverviewMeta(label: l10n.node, value: info?.nodeVersion),
              _OverviewMeta(
                label: l10n.port,
                value: info == null ? null : '${info!.port}',
              ),
            ],
          ),
          if (error != null || state.message != null) ...[
            SizedBox(height: typography.spacingSm),
            Text(
              error != null ? _localizedError(l10n, error) : state.message!,
              style: TextStyle(color: colors.error),
            ),
          ],
          SizedBox(height: typography.spacingMd),
          Wrap(
            spacing: typography.spacingS,
            runSpacing: typography.spacingS,
            children: [
              FilledButton.icon(
                onPressed:
                    actionInProgress || state.status == RuntimeStatus.running
                    ? null
                    : onStart,
                icon: const Icon(Icons.play_arrow),
                label: Text(l10n.start),
              ),
              OutlinedButton.icon(
                onPressed:
                    actionInProgress || state.status == RuntimeStatus.stopped
                    ? null
                    : onStop,
                icon: const Icon(Icons.stop),
                label: Text(l10n.stop),
              ),
              OutlinedButton.icon(
                onPressed:
                    actionInProgress || state.status != RuntimeStatus.running
                    ? null
                    : onRestart,
                icon: const Icon(Icons.restart_alt),
                label: Text(l10n.restart),
              ),
            ],
          ),
        ],
      ),
    );
    final httpMetaBadge = _OverviewBadge(
      key: const ValueKey('overview-http-meta-badge'),
      text: state.httpMetaStatus == HttpMetaStatus.running
          ? l10n.healthy
          : httpMetaLabel,
      color: httpMetaColor,
    );
    final httpMetaIdentity = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 10, color: httpMetaColor),
        SizedBox(width: typography.spacingS),
        Flexible(child: Text('HTTP-META', style: typography.titleMedium)),
      ],
    );
    final httpMetaPanel = _SurfacePanel(
      key: const ValueKey('overview-http-meta-hero'),
      radius: typography.radiusLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flex(
            key: const ValueKey('overview-http-meta-hero-top'),
            direction: compact ? Axis.vertical : Axis.horizontal,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              compact ? httpMetaIdentity : Flexible(child: httpMetaIdentity),
              if (compact) SizedBox(height: typography.spacingXs),
              compact ? httpMetaBadge : Flexible(child: httpMetaBadge),
            ],
          ),
          SizedBox(height: typography.spacingS),
          Text(
            state.httpMetaPort == null ? '-' : '${state.httpMetaPort}',
            style: typography.titleLarge.copyWith(
              fontSize: compact ? 24 : 28,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: typography.spacingS),
          Wrap(
            spacing: typography.spacingMd,
            runSpacing: typography.spacingXs,
            children: [_OverviewMeta(label: l10n.status, value: httpMetaLabel)],
          ),
        ],
      ),
    );
    const componentKinds = [ComponentKind.frontend, ComponentKind.backend];
    final componentStatusPanel = Column(
      key: const ValueKey('overview-component-status'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.components, style: typography.titleMedium),
        SizedBox(height: typography.spacingSm),
        _SurfacePanel(
          key: const ValueKey('overview-component-card'),
          padding: EdgeInsets.zero,
          radius: typography.radiusLg,
          child: Column(
            children: [
              for (var index = 0; index < componentKinds.length; index++) ...[
                _OverviewComponentRow(
                  key: ValueKey(
                    'overview-component-${componentKinds[index].name}',
                  ),
                  kind: componentKinds[index],
                  status: componentStatuses[componentKinds[index]],
                  unavailable: unavailableComponents.contains(
                    componentKinds[index],
                  ),
                ),
                if (index < componentKinds.length - 1)
                  Divider(
                    key: const ValueKey('overview-component-divider'),
                    height: 1,
                    color: colors.divider,
                  ),
              ],
            ],
          ),
        ),
      ],
    );
    final heroPanels = compact
        ? Flex(
            key: const ValueKey('overview-hero-grid'),
            direction: Axis.vertical,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              backendPanel,
              SizedBox(height: typography.spacingSm),
              httpMetaPanel,
            ],
          )
        : Flex(
            key: const ValueKey('overview-hero-grid'),
            direction: Axis.horizontal,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: backendPanel),
              SizedBox(width: typography.spacingSm),
              Expanded(flex: 3, child: httpMetaPanel),
            ],
          );
    final startStat = _OverviewStatCard(
      key: const ValueKey('overview-stat-start'),
      label: l10n.recentStart,
      value: _formatDateTime(context, observations.startedAt),
    );
    final anomalyStat = _OverviewStatCard(
      key: const ValueKey('overview-stat-anomalies'),
      label: l10n.anomalies24h,
      value: '${observations.anomalyCount}',
    );
    final logStat = _OverviewStatCard(
      key: const ValueKey('overview-stat-logs'),
      label: l10n.sessionLogs,
      value: '${observations.currentSessionLogCount}',
    );
    final stats = Flex(
      key: const ValueKey('overview-stats'),
      direction: compact ? Axis.vertical : Axis.horizontal,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (compact) ...[
          startStat,
          SizedBox(height: typography.spacingSm),
          anomalyStat,
          SizedBox(height: typography.spacingSm),
          logStat,
        ] else ...[
          Expanded(child: startStat),
          SizedBox(width: typography.spacingSm),
          Expanded(child: anomalyStat),
          SizedBox(width: typography.spacingSm),
          Expanded(child: logStat),
        ],
      ],
    );
    Widget runtimeField(String label, String value, {Key? valueKey}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: typography.bodySmall),
        SizedBox(height: typography.spacingXs),
        SelectableText(value, key: valueKey, style: typography.codeSmall),
      ],
    );
    final runtimeFields = _SurfacePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.runtimeHeading, style: typography.titleMedium),
          SizedBox(height: typography.spacingSm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: runtimeField(
                  l10n.backendRuntime,
                  endpoint,
                  valueKey: const ValueKey('runtime-endpoint-value'),
                ),
              ),
              SizedBox(width: typography.spacingLg),
              Expanded(
                child: runtimeField(l10n.node, info?.nodeVersion ?? '-'),
              ),
            ],
          ),
        ],
      ),
    );
    return ListView(
      padding: EdgeInsets.only(
        left: compact ? typography.spacingSm : typography.spacingLg,
        top: compact ? typography.spacingSm : typography.spacingLg,
        right: compact ? typography.spacingSm : typography.spacingLg,
        bottom: typography.spacingLg,
      ),
      children: [
        heroPanels,
        SizedBox(height: typography.spacingLg),
        componentStatusPanel,
        SizedBox(height: typography.spacingLg),
        stats,
        SizedBox(height: typography.spacingLg),
        runtimeFields,
      ],
    );
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
  });

  final ComponentKind kind;
  final ComponentVersionStatus? status;
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final name = switch (kind) {
      ComponentKind.backend => l10n.backendComponent,
      ComponentKind.frontend => l10n.frontendComponent,
    };
    final description = switch (kind) {
      ComponentKind.backend => l10n.backendComponentDescription,
      ComponentKind.frontend => l10n.frontendComponentDescription,
    };
    final version = unavailable
        ? l10n.unavailable
        : status == null
        ? l10n.componentReadingVersion
        : status!.previous == null
        ? l10n.componentCurrent(status!.current)
        : l10n.componentCurrentWithPrevious(status!.current, status!.previous!);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: typography.spacingMd,
        vertical: typography.spacingSm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: typography.titleSmall),
                Text(description, style: typography.labelSmall),
              ],
            ),
          ),
          Flexible(child: Text(version, style: typography.bodySmall)),
          if (!unavailable && status != null) ...[
            SizedBox(width: typography.spacingS),
            _OverviewBadge(
              text: l10n.latest,
              color: Theme.of(context).extension<AppColors>()!.success,
            ),
          ],
        ],
      ),
    );
  }
}

String _formatDateTime(BuildContext context, DateTime? value) {
  if (value == null) return '-';
  final local = value.toLocal();
  final material = MaterialLocalizations.of(context);
  return '${material.formatCompactDate(local)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: true)}';
}

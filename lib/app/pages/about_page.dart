part of '../app.dart';

class _AboutPage extends StatefulWidget {
  const _AboutPage({
    super.key,
    required this.coordinator,
    required this.runtimeState,
    required this.onOpenExternalUri,
    this.loader,
  });

  final AppCoordinator coordinator;
  final RuntimeState runtimeState;
  final Future<bool> Function(Uri uri) onOpenExternalUri;
  final AboutInfoLoader? loader;

  @override
  State<_AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<_AboutPage> {
  AboutInfo? _info;
  var _loading = true;
  var _metadataUnavailable = false;
  String? _clipboardActionError;
  String? _sourceActionError;

  @override
  void initState() {
    super.initState();
    registerBundledFontLicenses();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _metadataUnavailable = false;
      });
    }
    try {
      final info = await (widget.loader ?? AboutInfoLoader()).load();
      if (mounted) setState(() => _info = info);
    } on Object {
      if (mounted) setState(() => _metadataUnavailable = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _diagnostics(AboutInfo info) => AboutDiagnosticSnapshot(
    info: info,
    runtimeStatus: widget.runtimeState.status,
    httpMetaStatus: widget.runtimeState.httpMetaStatus,
    maintenancePhase: widget.coordinator.maintenanceOperation?.phase,
    backendStatus: widget.coordinator.componentStatuses[ComponentKind.backend],
    frontendStatus:
        widget.coordinator.componentStatuses[ComponentKind.frontend],
  ).format();

  Future<void> _copyDiagnostics() async {
    final info = _info;
    if (info == null) return;
    final l10n = AppLocalizations.of(context)!;
    try {
      await Clipboard.setData(ClipboardData(text: _diagnostics(info)));
      if (!mounted) return;
      setState(() => _clipboardActionError = null);
      ShadToaster.of(context).show(
        ShadToast(
          alignment: Alignment.bottomRight,
          duration: const Duration(seconds: 4),
          showCloseIconOnlyWhenHovered: false,
          title: Semantics(
            container: true,
            liveRegion: true,
            child: Text(l10n.aboutDiagnosticsCopied),
          ),
        ),
      );
    } on Object {
      if (mounted) {
        setState(() => _clipboardActionError = l10n.aboutClipboardFailed);
      }
    }
  }

  Future<void> _openSource(Uri uri) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final opened = await widget.onOpenExternalUri(uri);
      if (mounted) {
        setState(
          () => _sourceActionError = opened ? null : l10n.aboutOpenLinkFailed,
        );
      }
    } on Object {
      if (mounted) {
        setState(() => _sourceActionError = l10n.aboutOpenLinkFailed);
      }
    }
  }

  void _showLicenses() {
    final info = _info;
    showLicensePage(
      context: context,
      applicationName: 'SubDock',
      applicationVersion: info == null
          ? null
          : '${info.version}+${info.buildNumber}',
      applicationLegalese: subDockLicenseId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final info = _info;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final colors = Theme.of(context).extension<AppColors>()!;
    Widget metadataRow({required Key key, required String value}) => Padding(
      key: key,
      padding: EdgeInsets.symmetric(
        horizontal: typography.spacingMd,
        vertical: typography.spacingSm,
      ),
      child: Text(value, style: typography.bodyMedium),
    );
    final diagnostics = info == null ? null : _diagnostics(info);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsSectionTitle(title: l10n.aboutSubDock),
        _SurfacePanel(
          key: const ValueKey('settings-about-card'),
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (info == null)
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: typography.spacingMd,
                    vertical: typography.spacingSm,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _metadataUnavailable
                            ? l10n.aboutMetadataUnavailable
                            : l10n.aboutMetadataLoading,
                      ),
                      if (_metadataUnavailable)
                        TextButton(
                          key: const ValueKey('about-retry-metadata'),
                          onPressed: _loading ? null : () => unawaited(_load()),
                          child: Text(
                            _loading ? l10n.retrying : l10n.aboutRetryMetadata,
                          ),
                        ),
                    ],
                  ),
                )
              else ...[
                metadataRow(
                  key: const ValueKey('about-version'),
                  value: '${l10n.aboutVersion}: ${info.version}',
                ),
                Divider(color: colors.divider, height: 1),
                metadataRow(
                  key: const ValueKey('about-build-number'),
                  value:
                      '${l10n.aboutBuildNumber}: ${info.buildNumber.isEmpty ? '-' : info.buildNumber}',
                ),
                Divider(color: colors.divider, height: 1),
                metadataRow(
                  key: const ValueKey('about-license'),
                  value: '${l10n.aboutLicense}: $subDockLicenseId',
                ),
                Divider(color: colors.divider, height: 1),
                metadataRow(
                  key: const ValueKey('about-homepage'),
                  value:
                      '${l10n.aboutProjectHomepage}: $subDockProjectHomepage',
                ),
                Divider(color: colors.divider, height: 1),
                metadataRow(
                  key: const ValueKey('about-os'),
                  value:
                      '${l10n.aboutOperatingSystem}: ${info.operatingSystem}',
                ),
                Divider(color: colors.divider, height: 1),
                metadataRow(
                  key: const ValueKey('about-architecture'),
                  value: '${l10n.aboutArchitecture}: ${info.architecture}',
                ),
              ],
              Divider(color: colors.divider, height: 1),
              Padding(
                padding: EdgeInsets.all(typography.spacingSm),
                child: Wrap(
                  spacing: typography.spacingS,
                  runSpacing: typography.spacingS,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('about-project-homepage'),
                      onPressed: () => unawaited(
                        _openSource(Uri.parse(subDockProjectHomepage)),
                      ),
                      icon: const Icon(Icons.open_in_new),
                      label: Text(l10n.aboutProjectHomepage),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('about-view-licenses'),
                      onPressed: _showLicenses,
                      icon: const Icon(Icons.description_outlined),
                      label: Text(l10n.aboutViewLicenses),
                    ),
                    FilledButton.icon(
                      key: const ValueKey('about-copy-diagnostics'),
                      onPressed: info == null
                          ? null
                          : () => unawaited(_copyDiagnostics()),
                      icon: const Icon(Icons.copy),
                      label: Text(l10n.aboutCopyDiagnostics),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: typography.spacingLg),
        _SettingsSectionTitle(title: l10n.aboutProjectSourceTitle),
        _SurfacePanel(
          child: Wrap(
            spacing: typography.spacingS,
            runSpacing: typography.spacingS,
            children: [
              _sourceButton(
                key: const ValueKey('about-source-substore'),
                label: l10n.aboutSubStoreSource,
                uri: subStoreProjectSource,
                onOpen: _openSource,
              ),
              _sourceButton(
                key: const ValueKey('about-source-node'),
                label: l10n.aboutNodeSource,
                uri: nodeProjectSource,
                onOpen: _openSource,
              ),
              _sourceButton(
                key: const ValueKey('about-source-http-meta'),
                label: l10n.aboutHttpMetaSource,
                uri: httpMetaProjectSource,
                onOpen: _openSource,
              ),
              _sourceButton(
                key: const ValueKey('about-source-mihomo'),
                label: l10n.aboutMihomoSource,
                uri: mihomoProjectSource,
                onOpen: _openSource,
              ),
            ],
          ),
        ),
        SizedBox(height: typography.spacingLg),
        _SettingsSectionTitle(title: l10n.aboutDiagnosticsTitle),
        _SurfacePanel(
          key: const ValueKey('about-diagnostics-card'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (diagnostics == null)
                Text(l10n.aboutMetadataUnavailable)
              else
                SelectableText(
                  diagnostics,
                  key: const ValueKey('about-diagnostics-value'),
                  style: typography.codeSmall,
                ),
              if (_sourceActionError != null) ...[
                SizedBox(height: typography.spacingSm),
                Text(
                  _sourceActionError!,
                  key: const ValueKey('about-source-action-error'),
                  style: TextStyle(color: colors.error),
                ),
              ],
              if (_clipboardActionError != null) ...[
                SizedBox(height: typography.spacingSm),
                Text(
                  _clipboardActionError!,
                  key: const ValueKey('about-clipboard-action-error'),
                  style: TextStyle(color: colors.error),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _sourceButton({
    required Key key,
    required String label,
    required String uri,
    required Future<void> Function(Uri uri) onOpen,
  }) => TextButton.icon(
    key: key,
    onPressed: () => unawaited(onOpen(Uri.parse(uri))),
    icon: const Icon(Icons.open_in_new),
    label: Text(label),
  );
}

/// Provides scrolling for the About content inside the shared shell.
class _ShellAboutPage extends StatelessWidget {
  const _ShellAboutPage({
    super.key,
    required this.coordinator,
    required this.runtimeState,
    required this.onOpenExternalUri,
    this.loader,
  });

  final AppCoordinator coordinator;
  final RuntimeState runtimeState;
  final Future<bool> Function(Uri uri) onOpenExternalUri;
  final AboutInfoLoader? loader;

  @override
  Widget build(BuildContext context) {
    final typography = Theme.of(context).extension<AppTypography>()!;
    final compact = MediaQuery.sizeOf(context).width < navigationBreakpoint;
    return ListView(
      key: const ValueKey('about-list'),
      padding: EdgeInsets.only(
        left: compact ? typography.spacingSm : typography.spacingLg,
        top: compact ? typography.spacingSm : typography.spacingLg,
        right: compact ? typography.spacingSm : typography.spacingLg,
        bottom: typography.spacingLg,
      ),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: _AboutPage(
              loader: loader,
              coordinator: coordinator,
              runtimeState: runtimeState,
              onOpenExternalUri: onOpenExternalUri,
            ),
          ),
        ),
      ],
    );
  }
}

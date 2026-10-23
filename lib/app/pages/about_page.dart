part of '../app.dart';

class _AboutPage extends StatefulWidget {
  const _AboutPage({
    super.key,
    required this.coordinator,
    required this.runtimeState,
    required this.onOpenExternalUri,
    required this.onOpenServiceDetails,
    required this.active,
    this.loader,
  });

  final AppCoordinator coordinator;
  final RuntimeState runtimeState;
  final Future<bool> Function(Uri uri) onOpenExternalUri;
  final VoidCallback onOpenServiceDetails;
  final bool active;
  final AboutInfoLoader? loader;

  @override
  State<_AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<_AboutPage> {
  AboutInfo? _info;
  var _loading = true;
  var _metadataUnavailable = false;
  var _showingLicenses = false;
  var _loadingLicenses = false;
  var _licensesUnavailable = false;
  String? _subDockLicenseText;
  List<LicenseEntry>? _licenses;
  int? _selectedLicenseIndex;
  var _showingSubDockLicense = false;
  String? _clipboardActionError;
  String? _sourceActionError;
  var _feedbackGeneration = 0;
  final _licensesFocusNode = FocusNode(debugLabel: 'About licenses');

  @override
  void initState() {
    super.initState();
    registerBundledFontLicenses();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _AboutPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) _feedbackGeneration++;
  }

  @override
  void dispose() {
    _feedbackGeneration++;
    _licensesFocusNode.dispose();
    super.dispose();
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
    final feedbackGeneration = _feedbackGeneration;
    try {
      await Clipboard.setData(ClipboardData(text: _diagnostics(info)));
      if (!mounted) return;
      setState(() => _clipboardActionError = null);
      if (_canShowFeedback(feedbackGeneration)) {
        _showSuccess(l10n.aboutDiagnosticsCopied);
      }
    } on Object {
      if (mounted) {
        setState(() => _clipboardActionError = l10n.aboutClipboardFailed);
      }
    }
  }

  Future<void> _openSource(Uri uri) async {
    final l10n = AppLocalizations.of(context)!;
    final feedbackGeneration = _feedbackGeneration;
    try {
      final opened = await widget.onOpenExternalUri(uri);
      if (mounted) {
        setState(
          () => _sourceActionError = opened ? null : l10n.aboutOpenLinkFailed,
        );
        if (opened && _canShowFeedback(feedbackGeneration)) {
          _showSuccess(l10n.aboutProjectLinkOpened);
        }
      }
    } on Object {
      if (mounted) {
        setState(() => _sourceActionError = l10n.aboutOpenLinkFailed);
      }
    }
  }

  bool _canShowFeedback(int generation) =>
      mounted && widget.active && generation == _feedbackGeneration;

  void _showSuccess(String message) => ShadToaster.of(context).show(
    ShadToast(
      alignment: Alignment.bottomRight,
      duration: const Duration(seconds: 4),
      showCloseIconOnlyWhenHovered: false,
      title: Semantics(container: true, liveRegion: true, child: Text(message)),
    ),
  );

  void _showLicenses() {
    _feedbackGeneration++;
    setState(() => _showingLicenses = true);
    if (!_loadingLicenses &&
        (_licenses == null || _subDockLicenseText == null)) {
      unawaited(_loadLicenses());
    }
  }

  Future<void> _loadLicenses() async {
    if (mounted) {
      setState(() {
        _loadingLicenses = true;
        _licensesUnavailable = false;
      });
    }
    try {
      final subDockLicense = await rootBundle.loadString('LICENSE');
      final licenses = await LicenseRegistry.licenses.toList();
      if (mounted) {
        setState(() {
          _subDockLicenseText = subDockLicense;
          _licenses = licenses;
        });
      }
    } on Object {
      if (mounted) setState(() => _licensesUnavailable = true);
    } finally {
      if (mounted) setState(() => _loadingLicenses = false);
    }
  }

  void _returnFromLicenses() {
    _feedbackGeneration++;
    setState(() => _showingLicenses = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _licensesFocusNode.requestFocus();
    });
  }

  Widget _licenseDetail(LicenseEntry license, AppTypography typography) =>
      ShadCard(
        key: const ValueKey('about-component-license-detail'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShadButton.ghost(
              key: const ValueKey('about-license-list-back'),
              onPressed: () => setState(() => _selectedLicenseIndex = null),
              leading: const Icon(Icons.arrow_back),
              child: Text(AppLocalizations.of(context)!.aboutViewLicenses),
            ),
            if (license.packages.isNotEmpty)
              Text(license.packages.join(', '), style: typography.titleSmall),
            for (final paragraph in license.paragraphs) ...[
              SizedBox(height: typography.spacingSm),
              SelectableText(
                paragraph.text,
                style: paragraph.indent == LicenseParagraph.centeredIndent
                    ? typography.bodyMedium.copyWith(
                        fontWeight: FontWeight.w600,
                      )
                    : typography.bodySmall,
                textAlign: paragraph.indent == LicenseParagraph.centeredIndent
                    ? TextAlign.center
                    : TextAlign.start,
              ),
            ],
          ],
        ),
      );

  Widget _subDockLicenseDetail(AppTypography typography) => ShadCard(
    key: const ValueKey('about-sublicense-content'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ShadButton.ghost(
          key: const ValueKey('about-license-list-back'),
          onPressed: () => setState(() => _showingSubDockLicense = false),
          leading: const Icon(Icons.arrow_back),
          child: Text(AppLocalizations.of(context)!.aboutViewLicenses),
        ),
        Text('SubDock · $subDockLicenseId', style: typography.titleSmall),
        SizedBox(height: typography.spacingSm),
        SelectableText(_subDockLicenseText!, style: typography.bodySmall),
      ],
    ),
  );

  Widget _componentSources(
    AppLocalizations l10n,
    AppTypography typography,
    AppColors colors,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(height: typography.spacingMd),
      Text(l10n.aboutProjectSourceTitle, style: typography.titleSmall),
      Wrap(
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
      if (_sourceActionError != null)
        Padding(
          padding: EdgeInsets.only(top: typography.spacingSm),
          child: Semantics(
            key: const ValueKey('about-source-action-error'),
            container: true,
            liveRegion: true,
            child: Text(
              _sourceActionError!,
              style: TextStyle(color: colors.error),
            ),
          ),
        ),
    ],
  );

  Widget _buildLicenses(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final colors = Theme.of(context).extension<AppColors>()!;
    final licenses = _licenses;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.aboutViewLicenses,
                style: typography.titleMedium,
              ),
            ),
            ShadButton.ghost(
              key: const ValueKey('about-license-back'),
              onPressed: _returnFromLicenses,
              leading: const Icon(Icons.arrow_back),
              child: Text(l10n.aboutLicenseBack),
            ),
          ],
        ),
        _componentSources(l10n, typography, colors),
        if (_loadingLicenses)
          Padding(
            padding: EdgeInsets.all(typography.spacingMd),
            child: Semantics(
              container: true,
              liveRegion: true,
              child: Text(l10n.aboutLicensesLoading),
            ),
          )
        else if (_licensesUnavailable || _subDockLicenseText == null)
          ShadCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  container: true,
                  liveRegion: true,
                  child: Text(
                    l10n.aboutLicensesUnavailable,
                    style: TextStyle(color: colors.error),
                  ),
                ),
                SizedBox(height: typography.spacingSm),
                ShadButton.outline(
                  key: const ValueKey('about-retry-licenses'),
                  enabled: !_loadingLicenses,
                  onPressed: _loadingLicenses
                      ? null
                      : () => unawaited(_loadLicenses()),
                  child: Text(
                    _loadingLicenses ? l10n.retrying : l10n.aboutRetryLicenses,
                  ),
                ),
              ],
            ),
          )
        else if (_showingSubDockLicense)
          _subDockLicenseDetail(typography)
        else if (licenses != null && _selectedLicenseIndex != null)
          _licenseDetail(licenses[_selectedLicenseIndex!], typography)
        else if (licenses != null) ...[
          SizedBox(height: typography.spacingMd),
          Text(l10n.aboutViewLicenses, style: typography.titleSmall),
          ShadButton.ghost(
            key: const ValueKey('about-sublicense-open'),
            onPressed: () => setState(() => _showingSubDockLicense = true),
            child: Text('SubDock · $subDockLicenseId'),
          ),
          for (var index = 0; index < licenses.length; index++)
            ShadButton.ghost(
              key: ValueKey('about-component-license-$index'),
              onPressed: () => setState(() => _selectedLicenseIndex = index),
              child: Text(
                licenses[index].packages.isEmpty
                    ? l10n.aboutLicense
                    : licenses[index].packages.join(', '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final info = _info;
    if (_showingLicenses) return _buildLicenses(context);
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
        ShadCard(
          key: const ValueKey('settings-about-card'),
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.all(typography.spacingMd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SubDock', style: typography.titleLarge),
                    SizedBox(height: typography.spacingXs),
                    Text(
                      l10n.aboutSubDockSubtitle,
                      style: typography.bodySmall,
                    ),
                  ],
                ),
              ),
              if (info == null)
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: typography.spacingMd,
                    vertical: typography.spacingSm,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_metadataUnavailable)
                        Semantics(
                          key: const ValueKey('about-metadata-error'),
                          container: true,
                          liveRegion: true,
                          child: Text(
                            l10n.aboutMetadataUnavailable,
                            style: TextStyle(color: colors.error),
                          ),
                        )
                      else
                        Text(l10n.aboutMetadataLoading),
                      if (_metadataUnavailable)
                        ShadButton.outline(
                          key: const ValueKey('about-retry-metadata'),
                          enabled: !_loading,
                          onPressed: _loading ? null : () => unawaited(_load()),
                          child: Text(
                            _loading ? l10n.retrying : l10n.aboutRetryMetadata,
                          ),
                        ),
                    ],
                  ),
                )
              else ...[
                Padding(
                  key: const ValueKey('about-version-build'),
                  padding: EdgeInsets.symmetric(
                    horizontal: typography.spacingMd,
                    vertical: typography.spacingXs,
                  ),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        WidgetSpan(
                          alignment: PlaceholderAlignment.baseline,
                          baseline: TextBaseline.alphabetic,
                          child: Text(
                            '${l10n.aboutVersion}: ${info.version}',
                            key: const ValueKey('about-version'),
                            style: typography.codeSmall,
                          ),
                        ),
                        const TextSpan(text: '  ·  '),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.baseline,
                          baseline: TextBaseline.alphabetic,
                          child: Text(
                            '${l10n.aboutBuildNumber}: ${info.buildNumber.isEmpty ? '-' : info.buildNumber}',
                            key: const ValueKey('about-build-number'),
                            style: typography.codeSmall,
                          ),
                        ),
                      ],
                    ),
                    style: typography.codeSmall,
                  ),
                ),
                Padding(
                  key: const ValueKey('about-license'),
                  padding: EdgeInsets.symmetric(
                    horizontal: typography.spacingMd,
                    vertical: typography.spacingXs,
                  ),
                  child: Text(
                    '${l10n.aboutLicense}: $subDockLicenseId',
                    style: typography.bodySmall,
                  ),
                ),
              ],
              Padding(
                padding: EdgeInsets.all(typography.spacingSm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: typography.spacingS,
                      runSpacing: typography.spacingS,
                      children: [
                        ShadButton.outline(
                          key: const ValueKey('about-project-homepage'),
                          onPressed: () => unawaited(
                            _openSource(Uri.parse(subDockProjectHomepage)),
                          ),
                          leading: const Icon(Icons.open_in_new),
                          child: Text(l10n.aboutProjectHomepage),
                        ),
                        ShadButton.outline(
                          key: const ValueKey('about-view-licenses'),
                          focusNode: _licensesFocusNode,
                          onPressed: _showLicenses,
                          leading: const Icon(Icons.description_outlined),
                          child: Text(l10n.aboutViewLicenses),
                        ),
                        ShadButton(
                          key: const ValueKey('about-copy-diagnostics'),
                          enabled: info != null,
                          onPressed: info == null
                              ? null
                              : () => unawaited(_copyDiagnostics()),
                          leading: const Icon(Icons.copy),
                          child: Text(l10n.aboutCopyDiagnostics),
                        ),
                      ],
                    ),
                    if (_sourceActionError != null)
                      Padding(
                        padding: EdgeInsets.only(top: typography.spacingSm),
                        child: Semantics(
                          key: const ValueKey('about-source-action-error'),
                          container: true,
                          liveRegion: true,
                          child: Text(
                            _sourceActionError!,
                            style: TextStyle(color: colors.error),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: typography.spacingLg),
        _SettingsSectionTitle(title: l10n.aboutDiagnosticsTitle),
        ShadCard(
          key: const ValueKey('about-diagnostics-card'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.aboutDiagnosticsPrivacy, style: typography.bodySmall),
              if (info != null) ...[
                metadataRow(
                  key: const ValueKey('about-os'),
                  value:
                      '${l10n.aboutOperatingSystem}: ${info.operatingSystem}',
                ),
                metadataRow(
                  key: const ValueKey('about-architecture'),
                  value: '${l10n.aboutArchitecture}: ${info.architecture}',
                ),
              ],
              SizedBox(height: typography.spacingMd),
              if (diagnostics == null)
                Text(l10n.aboutMetadataUnavailable)
              else
                SelectableText(
                  diagnostics,
                  key: const ValueKey('about-diagnostics-value'),
                  style: typography.codeSmall,
                ),
              if (_clipboardActionError != null) ...[
                SizedBox(height: typography.spacingSm),
                Semantics(
                  key: const ValueKey('about-clipboard-action-error'),
                  container: true,
                  liveRegion: true,
                  child: Text(
                    _clipboardActionError!,
                    style: TextStyle(color: colors.error),
                  ),
                ),
              ],
              SizedBox(height: typography.spacingMd),
              ShadButton.outline(
                key: const ValueKey('about-service-details'),
                onPressed: widget.onOpenServiceDetails,
                leading: const Icon(Icons.settings_outlined),
                child: Text(l10n.manageServiceDetails),
              ),
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
  }) => ShadButton.outline(
    key: key,
    onPressed: () => unawaited(onOpen(Uri.parse(uri))),
    leading: const Icon(Icons.open_in_new),
    child: Text(label),
  );
}

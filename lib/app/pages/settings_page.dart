part of '../app.dart';

enum _SettingsSection { home, backendConfig, advancedEnv, about }

enum _NullableBoolDraft { inherit, enabled, disabled }

class _SettingsSectionTile extends StatelessWidget {
  const _SettingsSectionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    return Material(
      color: colors.surfaceLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(typography.radiusMd),
        side: BorderSide(color: colors.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(typography.spacingMd),
          child: Row(
            children: [
              Icon(icon, color: colors.accent),
              SizedBox(width: typography.spacingMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: typography.titleMedium),
                    SizedBox(height: typography.spacingXs),
                    Text(subtitle, style: typography.bodySmall),
                  ],
                ),
              ),
              SizedBox(width: typography.spacingSm),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

enum _LeaveDecision { save, discard, cancel }

/// Section title rendered above a settings card (sketch `.section-title`:
/// 14px/600 with a `spacingSm` gap down to the card body).
class _SettingsSectionTitle extends StatelessWidget {
  const _SettingsSectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final typography = Theme.of(context).extension<AppTypography>()!;
    return Padding(
      padding: EdgeInsets.only(bottom: typography.spacingSm),
      child: Text(
        title,
        style: typography.titleSmall.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({
    super.key,
    required this.environment,
    required this.configuration,
    required this.configurationError,
    required this.coordinator,
    required this.onSaveConfiguration,
    required this.onSaveEnvironment,
    required this.savedPreferences,
    required this.onSavePreferences,
    required this.onPreviewTheme,
    required this.onPreviewLocale,
    required this.onResetConfiguration,
    required this.onChildStateChanged,
    required this.onOpenExternalUri,
    this.aboutInfoLoader,
  });

  final BackendEnvDocument environment;
  final SubDockConfig configuration;
  final AppConfigError? configurationError;
  final AppCoordinator coordinator;
  final Future<void> Function(SubDockConfig configuration) onSaveConfiguration;
  final Future<void> Function(BackendEnvDocument document) onSaveEnvironment;
  final DesktopPreferences savedPreferences;
  final Future<void> Function(
    DesktopPreferences Function(DesktopPreferences current) mutate,
  )
  onSavePreferences;
  final Future<void> Function(ThemeMode mode) onPreviewTheme;
  final Future<void> Function(Locale? locale) onPreviewLocale;
  final Future<void> Function() onResetConfiguration;
  final ValueChanged<bool> onChildStateChanged;
  final Future<bool> Function(Uri uri) onOpenExternalUri;
  final AboutInfoLoader? aboutInfoLoader;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  late ThemeMode _generalThemeMode;
  late String? _generalLocale;
  late CloseBehavior _generalCloseBehavior;
  late int _generalRecentLogLimit;
  bool _generalLaunchAtLogin = false;
  bool _generalStartHiddenToTray = false;
  late final TextEditingController _recentLogLimit;
  late BackendEnvDocument _document;
  late SubDockConfig _configuration;
  late final TextEditingController _raw;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _path;
  late final TextEditingController _cors;
  var _updating = false;
  var _section = _SettingsSection.home;
  var _dirty = false;
  var _configurationDirty = false;
  var _generalRevision = 0;
  var _environmentRevision = 0;
  var _configurationRevision = 0;
  var _pendingSaveCount = 0;
  Completer<void>? _saveBarrier;
  late SubDockBackendConfig _savedBackend;
  late SubDockBackendConfig _backendDraft;
  SubDockBackendConfig? _pendingBackendSave;
  late _NullableBoolDraft _mergeDraft;
  var _httpMetaEnabled = true;

  @override
  void initState() {
    super.initState();
    _syncGeneral();
    _document = widget.environment;
    _configuration = widget.configuration;
    _savedBackend = widget.configuration.backend;
    _backendDraft = _savedBackend;
    _mergeDraft = _mergeState(_backendDraft.merge);
    _raw = TextEditingController();
    _host = TextEditingController();
    _port = TextEditingController();
    _path = TextEditingController();
    _cors = TextEditingController();
    _recentLogLimit = TextEditingController();
    _recentLogLimit.text = '$_generalRecentLogLimit';
    _syncControllers();
    _syncConfiguration();
  }

  @override
  void didUpdateWidget(covariant _SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.savedPreferences != widget.savedPreferences &&
        !_generalDirty) {
      _syncGeneral();
      _recentLogLimit.text = '$_generalRecentLogLimit';
    }
    if (!_dirty &&
        oldWidget.environment.rawText != widget.environment.rawText) {
      _document = widget.environment;
      _syncControllers();
    }
    if (!_configurationDirty &&
        oldWidget.configuration != widget.configuration) {
      _configuration = widget.configuration;
      _syncConfiguration();
    }
    if (oldWidget.configuration != widget.configuration &&
        !_backendDirty &&
        _pendingBackendSave == null) {
      _savedBackend = widget.configuration.backend;
      _backendDraft = _savedBackend;
      _mergeDraft = _mergeState(_backendDraft.merge);
      _syncBackendControllers();
    }
  }

  @override
  void dispose() {
    _raw.dispose();
    _host.dispose();
    _port.dispose();
    _path.dispose();
    _cors.dispose();
    _recentLogLimit.dispose();
    super.dispose();
  }

  int? get _parsedRecentLogLimit {
    final value = int.tryParse(_recentLogLimit.text.trim());
    return value != null && value >= 50 && value <= 2000 ? value : null;
  }

  bool get _generalDirty =>
      _generalThemeMode != widget.savedPreferences.themeMode ||
      _generalLocale != widget.savedPreferences.locale ||
      _generalCloseBehavior != widget.savedPreferences.closeBehavior ||
      _generalLaunchAtLogin != widget.savedPreferences.launchAtLogin ||
      _generalStartHiddenToTray != widget.savedPreferences.startHiddenToTray ||
      _recentLogLimit.text.trim() !=
          '${widget.savedPreferences.recentLogLimit}';

  bool get _backendDirty =>
      _backendDraft != _savedBackend ||
      _host.text.trim() != (_savedBackend.apiHost ?? '') ||
      _port.text.trim() != (_savedBackend.apiPort?.toString() ?? '') ||
      _path.text.trim() != (_savedBackend.frontendBackendPath ?? '') ||
      _cors.text.trim() != (_savedBackend.corsAllowedOrigins ?? '');

  _NullableBoolDraft _mergeState(bool? value) => switch (value) {
    null => _NullableBoolDraft.inherit,
    true => _NullableBoolDraft.enabled,
    false => _NullableBoolDraft.disabled,
  };

  bool? get _mergeValue => switch (_mergeDraft) {
    _NullableBoolDraft.inherit => null,
    _NullableBoolDraft.enabled => true,
    _NullableBoolDraft.disabled => false,
  };

  String? get _backendIssue {
    final l10n = AppLocalizations.of(context)!;
    final port = _port.text.trim();
    if (port.isNotEmpty) {
      final value = int.tryParse(port);
      if (value == null || value < 1 || value > 65535) {
        return l10n.configErrorPortRange('backend.apiPort');
      }
    }
    try {
      SubDockConfig.fromJson(
        widget.configuration
            .copyWith(backend: _backendDraft.copyWith(merge: _mergeValue))
            .toJson(),
      );
    } on AppConfigError catch (error) {
      return _localizedConfigError(l10n, error);
    }
    return null;
  }

  void _syncGeneral() {
    final preferences = widget.savedPreferences;
    _generalThemeMode = preferences.themeMode;
    _generalLocale = preferences.locale;
    _generalCloseBehavior = preferences.closeBehavior;
    _generalRecentLogLimit = preferences.recentLogLimit;
    _generalLaunchAtLogin = preferences.launchAtLogin;
    _generalStartHiddenToTray = preferences.startHiddenToTray;
  }

  Future<T> _withPendingSave<T>(Future<T> Function() operation) async {
    _pendingSaveCount++;
    _saveBarrier ??= Completer<void>();
    try {
      return await operation();
    } finally {
      _pendingSaveCount--;
      if (_pendingSaveCount == 0) {
        _saveBarrier!.complete();
        _saveBarrier = null;
      }
    }
  }

  Future<void> _waitForPendingSaves() async {
    while (_pendingSaveCount != 0) {
      await _saveBarrier!.future;
    }
  }

  Future<bool> _saveGeneral() => _withPendingSave(_saveGeneralImpl);

  Future<bool> _saveGeneralImpl() async {
    final limit = _parsedRecentLogLimit;
    if (limit == null) return false;
    final revision = _generalRevision;
    final themeMode = _generalThemeMode;
    final locale = _generalLocale;
    final closeBehavior = _generalCloseBehavior;
    final launchAtLogin = _generalLaunchAtLogin;
    final startHiddenToTray = _generalStartHiddenToTray;
    try {
      await widget.onSavePreferences(
        (current) => current.copyWith(
          themeMode: themeMode,
          locale: locale,
          closeBehavior: closeBehavior,
          recentLogLimit: limit,
          launchAtLogin: launchAtLogin,
          startHiddenToTray: startHiddenToTray,
        ),
      );
    } on Object {
      return false;
    }
    if (!mounted) return false;
    if (revision == _generalRevision &&
        _generalThemeMode == themeMode &&
        _generalLocale == locale &&
        _generalCloseBehavior == closeBehavior &&
        _generalLaunchAtLogin == launchAtLogin &&
        _generalStartHiddenToTray == startHiddenToTray &&
        _recentLogLimit.text.trim() == '$limit') {
      setState(() => _generalRecentLogLimit = limit);
    }
    return true;
  }

  Future<void> _discardGeneral() async {
    _generalRevision++;
    _syncGeneral();
    _recentLogLimit.text = '$_generalRecentLogLimit';
    await widget.onPreviewTheme(_generalThemeMode);
    await widget.onPreviewLocale(
      _generalLocale == null ? null : Locale(_generalLocale!),
    );
    setState(() {});
  }

  void _syncControllers() {
    _updating = true;
    _raw.text = _document.rawText;
    _syncBackendControllers();
    _updating = false;
  }

  void _syncBackendControllers() {
    _host.text = _backendDraft.apiHost ?? '';
    _port.text = _backendDraft.apiPort?.toString() ?? '';
    _path.text = _backendDraft.frontendBackendPath ?? '';
    _cors.text = _backendDraft.corsAllowedOrigins ?? '';
    _mergeDraft = _mergeState(_backendDraft.merge);
  }

  void _updateBackend(SubDockBackendConfig next) {
    if (_updating) return;
    setState(() {
      _backendDraft = next;
    });
  }

  void _syncConfiguration() {
    _httpMetaEnabled = _configuration.httpMeta.enabled;
  }

  void _updateConfiguration(SubDockHttpMetaConfig httpMeta) {
    if (_updating) return;
    setState(() {
      _configuration = _configuration.copyWith(httpMeta: httpMeta);
      _configurationDirty = true;
      _configurationRevision++;
      _syncConfiguration();
    });
  }

  SubDockConfig? _validatedConfiguration;
  String? get _configurationIssue {
    if (_validatedConfiguration != _configuration) {
      _validatedConfiguration = null;
      try {
        SubDockConfig.fromJson(_configuration.toJson());
        _validatedConfiguration = _configuration;
      } on AppConfigError catch (error) {
        return _localizedConfigError(AppLocalizations.of(context)!, error);
      }
    }
    return null;
  }

  Future<void> _saveConfiguration() => _withPendingSave(_saveConfigurationImpl);

  Future<void> _saveConfigurationImpl() async {
    final l10n = AppLocalizations.of(context)!;
    final issue = _configurationIssue;
    if (issue != null) return;
    final revision = _configurationRevision;
    final snapshot = _configuration;
    final effective = EffectiveRuntimeConfig.resolve(
      systemEnvironment: Platform.environment,
      backendEnvironment: widget.environment,
      config: snapshot,
    ).environment;
    final effectiveDocument = BackendEnvDocument.parse(
      '${BackendEnvPolicy.host}=${effective[BackendEnvPolicy.host]}\n'
      '${BackendEnvPolicy.port}=${effective[BackendEnvPolicy.port]}\n'
      '${BackendEnvPolicy.corsAllowedOrigins}=${effective[BackendEnvPolicy.corsAllowedOrigins]}',
    );
    final externalCors = BackendEnvPolicy.externalOrigins(effectiveDocument)
        .isNotEmpty;
    final nonLoopback = BackendEnvPolicy.hasNonLoopbackHost(effectiveDocument);
    if (externalCors && !await _confirm(l10n.confirmExternalCors)) return;
    if (nonLoopback && !await _confirm(l10n.confirmNonLoopback)) return;
    try {
      await widget.onSaveConfiguration(
        widget.configuration.copyWith(httpMeta: snapshot.httpMeta),
      );
    } on Object {
      return;
    }
    if (!mounted) return;
    if (revision == _configurationRevision && _configuration == snapshot) {
      setState(() {
        _configurationDirty = false;
        _configuration = snapshot;
      });
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.saved)));
  }

  Future<void> _saveBackendConfiguration() {
    if (_pendingBackendSave != null) return Future<void>.value();
    return _withPendingSave(_saveBackendConfigurationImpl);
  }

  Future<void> _saveBackendConfigurationImpl() async {
    final l10n = AppLocalizations.of(context)!;
    if (_backendIssue != null) return;
    final portText = _port.text.trim();
    final backend = _backendDraft.copyWith(
      apiPort: portText.isEmpty ? null : int.parse(portText),
      merge: _mergeValue,
    );
    final next = widget.configuration.copyWith(backend: backend);
    try {
      final effective = EffectiveRuntimeConfig.resolve(
        systemEnvironment: Platform.environment,
        backendEnvironment: widget.environment,
        config: next,
      ).environment;
      final document = BackendEnvDocument.parse(
        '${BackendEnvPolicy.host}=${effective[BackendEnvPolicy.host]}\n'
        '${BackendEnvPolicy.port}=${effective[BackendEnvPolicy.port]}\n'
        '${BackendEnvPolicy.corsAllowedOrigins}=${effective[BackendEnvPolicy.corsAllowedOrigins]}',
      );
      if (BackendEnvPolicy.externalOrigins(document).isNotEmpty &&
          !await _confirm(l10n.confirmExternalCors)) {
        return;
      }
      if (BackendEnvPolicy.hasNonLoopbackHost(document) &&
          !await _confirm(l10n.confirmNonLoopback)) {
        return;
      }
      _pendingBackendSave = backend;
      await widget.onSaveConfiguration(next);
    } on Object {
      return;
    } finally {
      if (mounted) {
        setState(() => _pendingBackendSave = null);
      } else {
        _pendingBackendSave = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _savedBackend = backend;
      if (_backendDraft == backend) {
        _backendDraft = backend;
        _syncBackendControllers();
      }
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.saved)));
  }

  void _updateRaw(String value) {
    if (_updating) return;
    setState(() {
      _document = BackendEnvDocument.parse(value);
      _dirty = true;
      _environmentRevision++;
      _syncControllers();
    });
  }

  Future<void> _save() => _withPendingSave(_saveEnvironmentImpl);

  Future<void> _saveEnvironmentImpl() async {
    final l10n = AppLocalizations.of(context)!;
    final revision = _environmentRevision;
    final snapshot = _document;
    final issues = BackendEnvPolicy.validate(snapshot);
    if (issues.isNotEmpty) return;
    if (BackendEnvPolicy.externalOrigins(snapshot).isNotEmpty &&
        !await _confirm(l10n.confirmExternalCors)) {
      return;
    }
    if (BackendEnvPolicy.hasNonLoopbackHost(snapshot) &&
        !await _confirm(l10n.confirmNonLoopback)) {
      return;
    }
    try {
      await widget.onSaveEnvironment(snapshot);
    } on Object {
      // _saveEnvironment records the error into _error for display.
      return;
    }
    if (!mounted) return;
    if (revision == _environmentRevision &&
        _document.rawText == snapshot.rawText) {
      setState(() => _dirty = false);
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.saved)));
  }

  Future<bool> _confirm(String message) async {
    final l10n = AppLocalizations.of(context)!;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            content: Text(message),
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
  }

  Future<bool> requestLeave() async {
    await _waitForPendingSaves();
    if (!mounted) return true;
    if (!_generalDirty && !_dirty && !_configurationDirty && !_backendDirty) {
      return true;
    }
    final l10n = AppLocalizations.of(context)!;
    final decision = await showDialog<_LeaveDecision>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.unsavedChanges),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _LeaveDecision.cancel),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _LeaveDecision.discard),
            child: Text(l10n.discard),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _LeaveDecision.save),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    if (decision == null || decision == _LeaveDecision.cancel) return false;
    if (decision == _LeaveDecision.discard) {
      _environmentRevision++;
      _configurationRevision++;
      if (_generalDirty) await _discardGeneral();
      if (_dirty) {
        _document = widget.environment;
        _syncControllers();
        _dirty = false;
      }
      if (_configurationDirty) {
        _configuration = widget.configuration;
        _syncConfiguration();
        _configurationDirty = false;
      }
      if (_backendDirty) {
        _backendDraft = widget.configuration.backend;
        _savedBackend = _backendDraft;
        _syncBackendControllers();
        _mergeDraft = _mergeState(_backendDraft.merge);
      }
      setState(() {});
      return true;
    }
    if (_generalDirty && !await _saveGeneral()) return false;
    if (_configurationDirty) {
      await _saveConfiguration();
      if (_configurationDirty) return false;
    }
    if (_backendDirty) {
      await _saveBackendConfiguration();
      if (_backendDirty) return false;
    }
    if (_dirty) {
      await _save();
      if (_dirty) return false;
    }
    return true;
  }

  Future<void> _openSection(_SettingsSection section) async {
    if (!await requestLeave() || !mounted) return;
    setState(() => _section = section);
    widget.onChildStateChanged(section != _SettingsSection.home);
  }

  void _backToHome() => unawaited(_openSection(_SettingsSection.home));

  @override
  Widget build(BuildContext context) {
    final issues = BackendEnvPolicy.validate(_document);
    final configurationIssue = _configurationIssue;
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    Widget settingRow({
      Key? key,
      required String title,
      required String subtitle,
      required Widget control,
    }) => LayoutBuilder(
      builder: (context, constraints) {
        final compact = MediaQuery.sizeOf(context).width < navigationBreakpoint;
        final details = Column(
          key: key,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: typography.titleMedium),
            SizedBox(height: typography.spacingXs),
            Text(subtitle, style: typography.bodySmall),
          ],
        );
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: typography.spacingMd,
            vertical: typography.spacingSm,
          ),
          child: Flex(
            direction: compact ? Axis.vertical : Axis.horizontal,
            crossAxisAlignment: compact
                ? CrossAxisAlignment.stretch
                : CrossAxisAlignment.center,
            children: [
              Expanded(flex: compact ? 0 : 1, child: details),
              SizedBox(
                width: compact ? double.infinity : 280,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: control,
                ),
              ),
            ],
          ),
        );
      },
    );
    Widget divider() => const Divider(height: 1);
    Widget configRow({
      Key? key,
      required String label,
      required Widget control,
    }) => LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 580;
        final labelWidget = Text(label, style: typography.bodyMedium);
        return Padding(
          key: key,
          padding: EdgeInsets.symmetric(
            horizontal: typography.spacingMd,
            vertical: typography.spacingSm,
          ),
          child: Flex(
            direction: compact ? Axis.vertical : Axis.horizontal,
            crossAxisAlignment: compact
                ? CrossAxisAlignment.stretch
                : CrossAxisAlignment.center,
            children: [
              if (compact) ...[
                labelWidget,
                SizedBox(height: typography.spacingXs),
              ] else
                SizedBox(width: 220, child: labelWidget),
              if (compact) control else Expanded(child: control),
            ],
          ),
        );
      },
    );
    Widget sectionCard({
      required Key key,
      required String title,
      required List<Widget> rows,
    }) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsSectionTitle(title: title),
        _SurfacePanel(
          key: key,
          padding: EdgeInsets.zero,
          radius: typography.radiusLg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) divider(),
                rows[i],
              ],
            ],
          ),
        ),
      ],
    );
    final content = ListView(
      key: const ValueKey('settings-list'),
      padding: EdgeInsets.all(typography.spacingLg),
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_section != _SettingsSection.home)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const ValueKey('settings-back'),
                      onPressed: _backToHome,
                      child: Text(l10n.back),
                    ),
                  ),
                if (_section == _SettingsSection.home) ...[
                  sectionCard(
                    key: const ValueKey('settings-appearance'),
                    title: l10n.appearanceLanguageHeading,
                    rows: [
                      settingRow(
                        key: const ValueKey('settings-theme-row'),
                        title: l10n.themeHeading,
                        subtitle: l10n.themeSubtitle,
                        control: SegmentedButton<ThemeMode>(
                          key: const ValueKey('settings-theme-mode'),
                          segments: [
                            ButtonSegment(
                              value: ThemeMode.system,
                              icon: const Icon(Icons.brightness_auto),
                              label: Text(l10n.themeFollowSystem),
                            ),
                            ButtonSegment(
                              value: ThemeMode.light,
                              icon: const Icon(Icons.light_mode),
                              label: Text(l10n.themeLight),
                            ),
                            ButtonSegment(
                              value: ThemeMode.dark,
                              icon: const Icon(Icons.dark_mode),
                              label: Text(l10n.themeDark),
                            ),
                          ],
                          selected: {_generalThemeMode},
                          onSelectionChanged: (selection) {
                            setState(() {
                              _generalThemeMode = selection.first;
                              _generalRevision++;
                            });
                            unawaited(widget.onPreviewTheme(selection.first));
                          },
                        ),
                      ),
                      settingRow(
                        key: const ValueKey('settings-language-row'),
                        title: l10n.languageHeading,
                        subtitle: l10n.languageSubtitle,
                        control: DropdownButtonFormField<String>(
                          key: const ValueKey('settings-language'),
                          initialValue: _generalLocale ?? 'system',
                          items: [
                            DropdownMenuItem(
                              value: 'system',
                              child: Text(l10n.languageFollowSystem),
                            ),
                            for (final language
                                in LocalePreferenceStore.supported)
                              DropdownMenuItem(
                                value: language,
                                child: Text(_languageLabel(language)),
                              ),
                          ],
                          onChanged: (value) {
                            final locale = value == null || value == 'system'
                                ? null
                                : value;
                            setState(() {
                              _generalLocale = locale;
                              _generalRevision++;
                            });
                            unawaited(
                              widget.onPreviewLocale(
                                locale == null ? null : Locale(locale),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: typography.spacingLg),
                  sectionCard(
                    key: const ValueKey('settings-runtime'),
                    title: l10n.runtimeHeading,
                    rows: [
                      settingRow(
                        key: const ValueKey('settings-http-meta'),
                        title: l10n.enableHttpMeta,
                        subtitle: _configurationDirty
                            ? '${l10n.enableHttpMetaSubtitle} (${l10n.unsaved})'
                            : l10n.enableHttpMetaSubtitle,
                        control: Switch(
                          value: _httpMetaEnabled,
                          onChanged: (value) => _updateConfiguration(
                            _configuration.httpMeta.copyWith(enabled: value),
                          ),
                        ),
                      ),
                      if (widget.configurationError != null)
                        Padding(
                          padding: EdgeInsets.all(typography.spacingMd),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  l10n.configurationInvalid(
                                    _localizedConfigError(
                                      l10n,
                                      widget.configurationError!,
                                    ),
                                  ),
                                  style: TextStyle(color: colors.error),
                                ),
                              ),
                              OutlinedButton(
                                onPressed: _configurationDirty
                                    ? null
                                    : () => unawaited(
                                        widget.onResetConfiguration(),
                                      ),
                                child: Text(l10n.resetSubdockConfig),
                              ),
                            ],
                          ),
                        ),
                      if (configurationIssue != null)
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: typography.spacingMd,
                            vertical: typography.spacingSm,
                          ),
                          child: Text(
                            configurationIssue,
                            style: TextStyle(color: colors.error),
                          ),
                        ),
                      settingRow(
                        key: const ValueKey('settings-backend-config-row'),
                        title: l10n.backendConfigHeading,
                        subtitle: _backendDirty
                            ? '${l10n.apiFieldsSummary} (${l10n.unsaved})'
                            : l10n.apiFieldsSummary,
                        control: OutlinedButton.icon(
                          key: const ValueKey('settings-card-backend-config'),
                          onPressed: () => unawaited(
                            _openSection(_SettingsSection.backendConfig),
                          ),
                          icon: const Icon(Icons.dns_outlined),
                          label: Text(l10n.open),
                        ),
                      ),
                      settingRow(
                        key: const ValueKey('settings-advanced-env-row'),
                        title: l10n.advancedRawEnv,
                        subtitle: _dirty
                            ? '${l10n.advancedRawEnvSubtitle} (${l10n.unsaved})'
                            : l10n.advancedRawEnvSubtitle,
                        control: OutlinedButton.icon(
                          key: const ValueKey('settings-card-advanced-env'),
                          onPressed: () => unawaited(
                            _openSection(_SettingsSection.advancedEnv),
                          ),
                          icon: const Icon(Icons.terminal),
                          label: Text(l10n.open),
                        ),
                      ),
                      settingRow(
                        key: const ValueKey('settings-recent-logs-row'),
                        title: l10n.recentLogs,
                        subtitle: l10n.recentLogsSubtitle,
                        control: TextField(
                          key: const ValueKey('settings-recent-log-limit'),
                          controller: _recentLogLimit,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(),
                          onChanged: (_) => setState(() => _generalRevision++),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: typography.spacingLg),
                  sectionCard(
                    key: const ValueKey('settings-desktop-behavior'),
                    title: l10n.desktopBehaviorHeading,
                    rows: [
                      settingRow(
                        key: const ValueKey('settings-close-behavior-row'),
                        title: l10n.closeBehaviorHeading,
                        subtitle: l10n.closeBehaviorSubtitle,
                        control: DropdownButtonFormField<CloseBehavior>(
                          key: const ValueKey('settings-close-behavior'),
                          initialValue: _generalCloseBehavior,
                          items: [
                            DropdownMenuItem(
                              value: CloseBehavior.exitApp,
                              child: Text(l10n.exitApp),
                            ),
                            DropdownMenuItem(
                              value: CloseBehavior.closeToTray,
                              child: Text(l10n.closeToTray),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() {
                                _generalCloseBehavior = value;
                                _generalRevision++;
                              });
                            }
                          },
                        ),
                      ),
                      settingRow(
                        key: const ValueKey('settings-launch-at-login-row'),
                        title: l10n.launchAtLoginHeading,
                        subtitle: l10n.launchAtLoginSubtitle,
                        control: Switch(
                          key: const ValueKey('settings-launch-at-login'),
                          value: _generalLaunchAtLogin,
                          onChanged: (value) {
                            setState(() {
                              _generalLaunchAtLogin = value;
                              _generalRevision++;
                            });
                          },
                        ),
                      ),
                      settingRow(
                        key: const ValueKey('settings-start-hidden-row'),
                        title: l10n.startHiddenToTrayHeading,
                        subtitle: l10n.startHiddenToTraySubtitle,
                        control: Switch(
                          key: const ValueKey('settings-start-hidden'),
                          value: _generalStartHiddenToTray,
                          onChanged: (value) {
                            setState(() {
                              _generalStartHiddenToTray = value;
                              _generalRevision++;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: typography.spacingLg),
                  _SettingsSectionTile(
                    icon: Icons.info_outline,
                    key: const ValueKey('settings-card-about'),
                    title: l10n.aboutSubDock,
                    subtitle: l10n.aboutSubDockSubtitle,
                    onTap: () =>
                        unawaited(_openSection(_SettingsSection.about)),
                  ),
                ],
                SizedBox(height: typography.spacingLg),
                if (_section == _SettingsSection.backendConfig) ...[
                  _SettingsSectionTitle(title: l10n.backendConfigHeading),
                  _SurfacePanel(
                    key: const ValueKey('settings-backend-config'),
                    padding: EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_backendIssue != null)
                          Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: typography.spacingMd,
                              vertical: typography.spacingXs,
                            ),
                            child: Text(
                              _backendIssue!,
                              style: TextStyle(color: colors.error),
                            ),
                          ),
                        configRow(
                          key: const ValueKey('settings-backend-host-row'),
                          label: l10n.apiHost,
                          control: TextField(
                            controller: _host,
                            decoration: const InputDecoration(),
                            onChanged: (value) => _updateBackend(
                              _backendDraft.copyWith(
                                apiHost: value.trim().isEmpty ? null : value,
                              ),
                            ),
                          ),
                        ),
                        divider(),
                        configRow(
                          key: const ValueKey('settings-backend-port-row'),
                          label: l10n.apiPort,
                          control: TextField(
                            controller: _port,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              errorText:
                                  _port.text.trim().isNotEmpty &&
                                      _backendIssue != null
                                  ? _backendIssue
                                  : null,
                            ),
                            onChanged: (value) => _updateBackend(
                              _backendDraft.copyWith(
                                apiPort: int.tryParse(value.trim()),
                              ),
                            ),
                          ),
                        ),
                        divider(),
                        configRow(
                          key: const ValueKey('settings-backend-merge-row'),
                          label: l10n.mergeMode,
                          control: DropdownButtonFormField<_NullableBoolDraft>(
                            key: ValueKey('settings-merge-mode-$_mergeDraft'),
                            initialValue: _mergeDraft,
                            decoration: const InputDecoration(),
                            items: [
                              DropdownMenuItem(
                                value: _NullableBoolDraft.inherit,
                                child: Text(l10n.inherit),
                              ),
                              DropdownMenuItem(
                                value: _NullableBoolDraft.enabled,
                                child: Text(l10n.enabled),
                              ),
                              DropdownMenuItem(
                                value: _NullableBoolDraft.disabled,
                                child: Text(l10n.disabled),
                              ),
                            ],
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() {
                                _mergeDraft = value;
                                _backendDraft = _backendDraft.copyWith(
                                  merge: _mergeValue,
                                );
                              });
                            },
                          ),
                        ),
                        divider(),
                        configRow(
                          key: const ValueKey('settings-backend-path-row'),
                          label: l10n.frontendBackendPath,
                          control: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _path,
                                  decoration: const InputDecoration(),
                                  onChanged: (value) => _updateBackend(
                                    _backendDraft.copyWith(
                                      frontendBackendPath:
                                          value.trim().isEmpty ? null : value,
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(width: typography.spacingSm),
                              OutlinedButton.icon(
                                key: const ValueKey(
                                  'settings-backend-path-regenerate',
                                ),
                                onPressed: () {
                                  final path = randomBackendPath();
                                  _path.text = path;
                                  _updateBackend(
                                    _backendDraft.copyWith(
                                      frontendBackendPath: path,
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.refresh),
                                label: Text(l10n.regenerateBackendPath),
                              ),
                            ],
                          ),
                        ),
                        divider(),
                        configRow(
                          key: const ValueKey('settings-backend-cors-row'),
                          label: l10n.corsAllowedOrigins,
                          control: TextField(
                            controller: _cors,
                            decoration: const InputDecoration(),
                            onChanged: (value) => _updateBackend(
                              _backendDraft.copyWith(
                                corsAllowedOrigins: value.trim().isEmpty
                                    ? null
                                    : value,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                SizedBox(height: typography.spacingLg),
                if (_section == _SettingsSection.advancedEnv) ...[
                  _SettingsSectionTitle(title: l10n.advancedRawEnv),
                  _SurfacePanel(
                    key: const ValueKey('settings-raw-env'),
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: typography.spacingMd,
                            vertical: typography.spacingSm,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.warning_amber,
                                color: colors.error,
                              ),
                              SizedBox(width: typography.spacingSm),
                              Expanded(
                                child: Text(
                                  l10n.structuredEnvPrecedenceWarning,
                                  style: typography.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                        ExpansionTile(
                          key: const ValueKey('settings-raw-env-expansion'),
                          tilePadding: EdgeInsets.symmetric(
                            horizontal: typography.spacingMd,
                            vertical: typography.spacingSm,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              typography.radiusMd,
                            ),
                          ),
                          collapsedShape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              typography.radiusMd,
                            ),
                          ),
                          title: Text(l10n.advancedRawEnvSubtitle),
                          initiallyExpanded: false,
                          childrenPadding: EdgeInsets.symmetric(
                            horizontal: typography.spacingMd,
                            vertical: typography.spacingSm,
                          ),
                          children: [
                            TextField(
                              key: const ValueKey('settings-raw-env-editor'),
                              controller: _raw,
                              minLines: 8,
                              maxLines: 16,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                              ),
                              onChanged: _updateRaw,
                            ),
                            if (issues.isNotEmpty) ...[
                              SizedBox(height: typography.spacingS),
                              for (final issue in issues)
                                Text(
                                  '${issue.line == null ? '' : l10n.lineNumber(issue.line!)}${_localizedIssue(l10n, issue)}',
                                  style: TextStyle(color: colors.error),
                                ),
                            ],
                            SizedBox(height: typography.spacingMd),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
                SizedBox(height: typography.spacingLg),
                if (_section == _SettingsSection.about)
                  _AboutPage(
                    key: const ValueKey('settings-about-page'),
                    loader: widget.aboutInfoLoader,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
    return Column(
      children: [
        Expanded(child: content),
        if (_section == _SettingsSection.home)
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.all(typography.spacingMd),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const ValueKey('settings-save-all'),
                  onPressed:
                      (_configurationDirty ||
                          (_generalDirty && _parsedRecentLogLimit != null))
                      ? () async {
                          var generalSaved = true;
                          if (_generalDirty) {
                            generalSaved = await _saveGeneral();
                          }
                          if (generalSaved && _configurationDirty) {
                            await _saveConfiguration();
                          } else if (generalSaved && mounted) {
                            messenger.showSnackBar(
                              SnackBar(content: Text(l10n.saved)),
                            );
                          }
                        }
                      : null,
                  child: Text(l10n.saveAll),
                ),
              ),
            ),
          ),
        if (_section == _SettingsSection.backendConfig ||
            _section == _SettingsSection.advancedEnv)
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.all(typography.spacingMd),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const ValueKey('settings-child-save'),
                  onPressed: switch (_section) {
                    _SettingsSection.backendConfig =>
                      _backendDirty &&
                              _backendIssue == null &&
                              _pendingBackendSave == null
                          ? _saveBackendConfiguration
                          : null,
                    _SettingsSection.advancedEnv =>
                      _dirty && BackendEnvPolicy.validate(_document).isEmpty
                          ? _save
                          : null,
                    _SettingsSection.about => null,
                    _SettingsSection.home => null,
                  },
                  child: Text(l10n.save),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

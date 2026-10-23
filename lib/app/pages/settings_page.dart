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
    required this.onSaveRuntimeConfiguration,
    required this.onApplySavedConfiguration,
    required this.onStartSavedConfiguration,
    required this.savedPreferences,
    required this.onSavePreferences,
    required this.autostartApplyFailed,
    required this.autostartSupported,
    required this.onRetryAutostart,
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
  final Future<void> Function(
    BackendEnvDocument environment,
    SubDockConfig configuration,
  )
  onSaveRuntimeConfiguration;
  final Future<void> Function() onApplySavedConfiguration;
  final Future<void> Function() onStartSavedConfiguration;
  final DesktopPreferences savedPreferences;
  final _PreferenceSave onSavePreferences;
  final bool autostartApplyFailed;
  final bool? autostartSupported;
  final Future<void> Function() onRetryAutostart;
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
  late bool _autoSavePreferences;
  bool _generalLaunchAtLogin = false;
  bool _generalStartHiddenToTray = false;
  late final TextEditingController _recentLogLimit;
  Timer? _recentLogSaveTimer;
  late BackendEnvDocument _document;
  late BackendEnvDocument _savedEnvironment;
  late SubDockConfig _configuration;
  late SubDockConfig _savedConfiguration;
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
  var _backendRevision = 0;
  var _generalSaveInProgress = false;
  var _generalSaveFailed = false;
  var _runtimeSaveFailed = false;
  var _applyConfigurationFailed = false;
  var _applyConfigurationInProgress = false;
  var _environmentRevision = 0;
  var _configurationRevision = 0;
  var _pendingSaveCount = 0;
  Completer<void>? _saveBarrier;
  late SubDockBackendConfig _savedBackend;
  late SubDockBackendConfig _backendDraft;
  late _NullableBoolDraft _mergeDraft;
  var _httpMetaEnabled = true;

  @override
  void initState() {
    super.initState();
    _syncGeneral();
    _document = widget.environment;
    _savedEnvironment = widget.environment;
    _configuration = widget.configuration;
    _savedConfiguration = widget.configuration;
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
    _syncEnvironmentController();
    _syncBackendControllers();
    _syncConfiguration();
  }

  @override
  void didUpdateWidget(covariant _SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.savedPreferences != widget.savedPreferences) {
      if (!_generalDirty) {
        _syncGeneral();
        _recentLogLimit.text = '$_generalRecentLogLimit';
      } else {
        _generalRecentLogLimit = widget.savedPreferences.recentLogLimit;
      }
    }
    if (oldWidget.environment.rawText != widget.environment.rawText &&
        !_dirty) {
      _document = widget.environment;
      _savedEnvironment = widget.environment;
      _syncEnvironmentController();
    }
    if (oldWidget.configuration != widget.configuration &&
        !_configurationDirty) {
      _configuration = widget.configuration;
      _savedConfiguration = widget.configuration;
      _syncConfiguration();
    }
    if (oldWidget.configuration != widget.configuration && !_backendDirty) {
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
    _recentLogSaveTimer?.cancel();
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
      _autoSavePreferences != widget.savedPreferences.autoSavePreferences ||
      _generalLaunchAtLogin != widget.savedPreferences.launchAtLogin ||
      _generalStartHiddenToTray != widget.savedPreferences.startHiddenToTray ||
      _recentLogLimit.text.trim() !=
          '${widget.savedPreferences.recentLogLimit}';

  bool get _runtimeDraftDirty => _dirty || _configurationDirty || _backendDirty;

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
        _configuration
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
    _autoSavePreferences = preferences.autoSavePreferences;
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

  Future<bool> _saveGeneral({
    bool automatic = false,
    bool includeRecentLogLimit = true,
  }) => _withPendingSave(
    () => _saveGeneralImpl(
      automatic: automatic,
      includeRecentLogLimit: includeRecentLogLimit,
    ),
  );

  Future<bool> _saveGeneralImpl({
    required bool automatic,
    required bool includeRecentLogLimit,
  }) async {
    final requestedLimit = _parsedRecentLogLimit;
    final limit = includeRecentLogLimit
        ? requestedLimit ??
              (automatic ? widget.savedPreferences.recentLogLimit : null)
        : widget.savedPreferences.recentLogLimit;
    if (limit == null) return false;
    final revision = _generalRevision;
    final themeMode = _generalThemeMode;
    final locale = _generalLocale;
    final closeBehavior = _generalCloseBehavior;
    final launchAtLogin = _generalLaunchAtLogin;
    final startHiddenToTray = _generalStartHiddenToTray;
    final autoSave = _autoSavePreferences;
    setState(() => _generalSaveInProgress = true);
    var saved = false;
    try {
      saved = await widget.onSavePreferences(
        (current) => current.copyWith(
          themeMode: themeMode,
          locale: locale,
          closeBehavior: closeBehavior,
          recentLogLimit: includeRecentLogLimit && requestedLimit != null
              ? requestedLimit
              : current.recentLogLimit,
          launchAtLogin: launchAtLogin,
          startHiddenToTray: startHiddenToTray,
          autoSavePreferences: autoSave,
        ),
        canSave: automatic
            ? () =>
                  mounted &&
                  _autoSavePreferences &&
                  revision == _generalRevision
            : null,
      );
    } on Object {
      if (mounted) setState(() => _generalSaveFailed = true);
      return false;
    } finally {
      if (mounted) setState(() => _generalSaveInProgress = false);
    }
    if (!mounted || !saved) return false;
    if (revision == _generalRevision &&
        _generalThemeMode == themeMode &&
        _generalLocale == locale &&
        _generalCloseBehavior == closeBehavior &&
        _generalLaunchAtLogin == launchAtLogin &&
        _generalStartHiddenToTray == startHiddenToTray &&
        _autoSavePreferences == autoSave &&
        _recentLogLimit.text.trim() == '$limit') {
      setState(() => _generalRecentLogLimit = limit);
    }
    setState(() => _generalSaveFailed = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.saved)),
    );
    return true;
  }

  void _recordGeneralEdit({bool recentLogLimit = false}) {
    setState(() {
      _generalRevision++;
      if (!_generalDirty) _generalSaveFailed = false;
    });
    if (!_autoSavePreferences) return;
    if (recentLogLimit) {
      _queueRecentLogSave();
    } else {
      // An elapsed debounce still belongs in the latest queued preference save.
      unawaited(
        _saveGeneral(
          automatic: true,
          includeRecentLogLimit: _recentLogSaveTimer?.isActive == false,
        ),
      );
    }
  }

  void _queueRecentLogSave() {
    _recentLogSaveTimer?.cancel();
    if (!_autoSavePreferences || _parsedRecentLogLimit == null) return;
    _recentLogSaveTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted || !_autoSavePreferences || _parsedRecentLogLimit == null) {
        return;
      }
      unawaited(_saveGeneral(automatic: true));
    });
  }

  void _submitRecentLogLimit(String _) {
    _recentLogSaveTimer?.cancel();
    if (_autoSavePreferences && _parsedRecentLogLimit != null) {
      unawaited(_saveGeneral(automatic: true));
    }
  }

  Future<void> _setPreferenceAutoSave(bool enabled) async {
    if (_autoSavePreferences == enabled) return;
    _recentLogSaveTimer?.cancel();
    setState(() {
      _autoSavePreferences = enabled;
      _generalRevision++;
      if (!_generalDirty) _generalSaveFailed = false;
    });
    if (enabled) {
      await _saveGeneral(automatic: true);
    } else {
      setState(() => _generalSaveInProgress = true);
      try {
        final saved = await _withPendingSave(
          () => widget.onSavePreferences(
            (current) => current.copyWith(autoSavePreferences: false),
          ),
        );
        if (mounted && saved) {
          setState(() => _generalSaveFailed = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context)!.saved)),
          );
        }
      } on Object {
        if (mounted) setState(() => _generalSaveFailed = true);
      } finally {
        if (mounted) setState(() => _generalSaveInProgress = false);
      }
    }
  }

  Future<void> _discardGeneral() async {
    _recentLogSaveTimer?.cancel();
    final revision = ++_generalRevision;
    await _waitForPendingSaves();
    if (!mounted) return;
    // Consume the saved snapshot rebuilt after any already-dispatched writes.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || revision != _generalRevision) return;
    _syncGeneral();
    _recentLogLimit.text = '$_generalRecentLogLimit';
    await widget.onPreviewTheme(_generalThemeMode);
    await widget.onPreviewLocale(
      _generalLocale == null ? null : Locale(_generalLocale!),
    );
    setState(() => _generalSaveFailed = false);
  }

  void _syncEnvironmentController() {
    _updating = true;
    _raw.text = _document.rawText;
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
      _backendRevision++;
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

  String? get _runtimeIssue {
    final environmentIssues = BackendEnvPolicy.validate(_document);
    if (environmentIssues.isNotEmpty) {
      return _localizedIssue(
        AppLocalizations.of(context)!,
        environmentIssues.first,
      );
    }
    return _backendIssue ?? _configurationIssue;
  }

  ({BackendEnvDocument environment, SubDockConfig configuration})?
  get _runtimeCandidate {
    if (_runtimeIssue != null) return null;
    final portText = _port.text.trim();
    final backend = _backendDraft.copyWith(
      apiPort: portText.isEmpty ? null : int.parse(portText),
      merge: _mergeValue,
    );
    final configuration = _configuration.copyWith(backend: backend);
    try {
      SubDockConfig.fromJson(configuration.toJson());
    } on AppConfigError {
      return null;
    }
    return (environment: _document, configuration: configuration);
  }

  (int, int, int) get _runtimeRevision =>
      (_environmentRevision, _configurationRevision, _backendRevision);

  Future<void> _applySavedConfiguration() =>
      _withPendingSave(_applySavedConfigurationImpl);

  Future<void> _applySavedConfigurationImpl() async {
    setState(() {
      _applyConfigurationFailed = false;
      _applyConfigurationInProgress = true;
    });
    try {
      if (widget.coordinator.runtime.currentState.status ==
          RuntimeStatus.stopped) {
        await widget.onStartSavedConfiguration();
      } else {
        await widget.onApplySavedConfiguration();
      }
    } on Object {
      if (mounted) setState(() => _applyConfigurationFailed = true);
    } finally {
      if (mounted) setState(() => _applyConfigurationInProgress = false);
    }
  }

  Future<bool> _saveRuntimeDraft() => _withPendingSave(_saveRuntimeDraftImpl);

  Future<bool> _saveRuntimeDraftImpl() async {
    final l10n = AppLocalizations.of(context)!;
    final snapshot = _runtimeCandidate;
    if (snapshot == null) return false;
    final revision = _runtimeRevision;
    final effective = EffectiveRuntimeConfig.resolve(
      systemEnvironment: Platform.environment,
      backendEnvironment: snapshot.environment,
      config: snapshot.configuration,
    ).environment;
    final effectiveDocument = BackendEnvDocument.parse(
      '${BackendEnvPolicy.host}=${effective[BackendEnvPolicy.host]}\n'
      '${BackendEnvPolicy.port}=${effective[BackendEnvPolicy.port]}\n'
      '${BackendEnvPolicy.corsAllowedOrigins}=${effective[BackendEnvPolicy.corsAllowedOrigins]}',
    );
    if (BackendEnvPolicy.externalOrigins(effectiveDocument).isNotEmpty &&
        !await _confirm(l10n.confirmExternalCors)) {
      return false;
    }
    if (!mounted || revision != _runtimeRevision) return false;
    if (BackendEnvPolicy.hasNonLoopbackHost(effectiveDocument) &&
        !await _confirm(l10n.confirmNonLoopback)) {
      return false;
    }
    if (!mounted || revision != _runtimeRevision) return false;
    try {
      await widget.onSaveRuntimeConfiguration(
        snapshot.environment,
        snapshot.configuration,
      );
    } on Object {
      if (mounted) setState(() => _runtimeSaveFailed = true);
      return false;
    }
    if (!mounted) return false;
    setState(() {
      _savedEnvironment = snapshot.environment;
      _savedConfiguration = snapshot.configuration;
      _savedBackend = snapshot.configuration.backend;
      _configuration = _configuration.copyWith(
        backend: snapshot.configuration.backend,
      );
      _dirty = _document.rawText != _savedEnvironment.rawText;
      _configurationDirty =
          _configuration.httpMeta != _savedConfiguration.httpMeta;
      _runtimeSaveFailed = false;
      if (_backendRevision == revision.$3) {
        _syncBackendControllers();
      }
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.saved)));
    return true;
  }

  void _updateRaw(String value) {
    if (_updating) return;
    setState(() {
      _document = BackendEnvDocument.parse(value);
      _dirty = _document.rawText != _savedEnvironment.rawText;
      _environmentRevision++;
    });
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

  bool get _hasUnsavedChanges => _generalDirty || _runtimeDraftDirty;

  bool get _canSavePreferenceDraft =>
      _parsedRecentLogLimit != null || !_generalDirty;

  bool get _canSaveAllDrafts =>
      _canSavePreferenceDraft && _runtimeIssue == null;

  bool get _hasSaveableGeneralChanges =>
      _hasSaveableAutomaticPreferences ||
      _autoSavePreferences != widget.savedPreferences.autoSavePreferences;

  bool get _hasSaveableAutomaticPreferences =>
      _generalThemeMode != widget.savedPreferences.themeMode ||
      _generalLocale != widget.savedPreferences.locale ||
      _generalCloseBehavior != widget.savedPreferences.closeBehavior ||
      _generalLaunchAtLogin != widget.savedPreferences.launchAtLogin ||
      _generalStartHiddenToTray != widget.savedPreferences.startHiddenToTray ||
      _parsedRecentLogLimit != null &&
          _parsedRecentLogLimit != widget.savedPreferences.recentLogLimit;

  (int, int, int, int) get _draftRevision => (
    _generalRevision,
    _environmentRevision,
    _configurationRevision,
    _backendRevision,
  );

  Future<bool> requestLeave() async {
    await _waitForPendingSaves();
    if (!mounted) return true;
    if (_autoSavePreferences &&
        _hasSaveableAutomaticPreferences &&
        _generalDirty) {
      _recentLogSaveTimer?.cancel();
      await _saveGeneral(automatic: true);
      await _waitForPendingSaves();
      if (!mounted) return true;
    }
    while (_hasUnsavedChanges) {
      final revision = _draftRevision;
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
              onPressed: _canSaveAllDrafts
                  ? () => Navigator.pop(context, _LeaveDecision.save)
                  : null,
              child: Text(l10n.save),
            ),
          ],
        ),
      );
      if (!mounted) return true;
      if (_draftRevision != revision) continue;
      if (decision == null || decision == _LeaveDecision.cancel) return false;
      if (decision == _LeaveDecision.discard) {
        _recentLogSaveTimer?.cancel();
        _environmentRevision++;
        _configurationRevision++;
        _backendRevision++;
        final runtimeRevision = _runtimeRevision;
        if (_generalDirty) await _discardGeneral();
        if (!mounted) return true;
        if (_generalDirty || runtimeRevision != _runtimeRevision) return false;
        setState(() {
          _document = _savedEnvironment;
          _configuration = _savedConfiguration;
          _configurationDirty = false;
          _backendDraft = _savedBackend;
          _dirty = false;
          _runtimeSaveFailed = false;
          _syncEnvironmentController();
          _syncBackendControllers();
          _syncConfiguration();
        });
        return true;
      }
      if (_generalDirty && !await _saveGeneral()) return false;
      if (_runtimeDraftDirty && !await _saveRuntimeDraft()) return false;
      await _waitForPendingSaves();
      if (!mounted || !_hasUnsavedChanges) return true;
      if (_draftRevision == revision) return false;
    }
    return true;
  }

  void _openSection(_SettingsSection section) {
    if (_section == section) return;
    setState(() => _section = section);
    widget.onChildStateChanged(section != _SettingsSection.home);
  }

  void _backToHome() => _openSection(_SettingsSection.home);

  @override
  Widget build(BuildContext context) {
    final issues = BackendEnvPolicy.validate(_document);
    final configurationIssue = _configurationIssue;
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final runtimePending = widget.coordinator.hasPendingConfiguration;
    final runtimeHasApplied =
        widget.coordinator.runtime.appliedConfiguration != null;
    final runtimeStopped =
        widget.coordinator.runtime.currentState.status == RuntimeStatus.stopped;
    final runtimeCanStart =
        runtimeStopped && widget.coordinator.savedRevision > 0;
    final runtimeStatus = _runtimeDraftDirty
        ? l10n.runtimeConfigDraftStatus
        : runtimePending
        ? l10n.runtimeConfigSavedPending
        : runtimeHasApplied
        ? l10n.runtimeConfigApplied
        : l10n.runtimeConfigSavedForNextStart;
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
                child: Align(alignment: Alignment.centerRight, child: control),
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
    Widget persistentStatus({
      required Key key,
      required String message,
      required String action,
      required VoidCallback? onPressed,
    }) => Padding(
      key: key,
      padding: EdgeInsets.only(bottom: typography.spacingMd),
      child: _SurfacePanel(
        borderColor: colors.accent,
        child: Row(
          children: [
            Expanded(child: Text(message)),
            OutlinedButton(onPressed: onPressed, child: Text(action)),
          ],
        ),
      ),
    );
    Widget persistentError({
      required Key key,
      required String message,
      required String action,
      required VoidCallback? onPressed,
    }) => Padding(
      key: key,
      padding: EdgeInsets.only(bottom: typography.spacingMd),
      child: _SurfacePanel(
        borderColor: colors.error,
        child: Row(
          children: [
            Expanded(
              child: Text(message, style: TextStyle(color: colors.error)),
            ),
            OutlinedButton(onPressed: onPressed, child: Text(action)),
          ],
        ),
      ),
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
                if (widget.autostartSupported == false)
                  Padding(
                    key: const ValueKey('settings-autostart-unavailable'),
                    padding: EdgeInsets.only(bottom: typography.spacingMd),
                    child: _SurfacePanel(
                      borderColor: colors.error,
                      child: Text(
                        l10n.autostartUnsupported,
                        style: TextStyle(color: colors.error),
                      ),
                    ),
                  ),
                if (_generalSaveFailed)
                  persistentError(
                    key: const ValueKey('settings-preferences-error'),
                    message: l10n.preferenceSaveFailed,
                    action: l10n.retryPreferencesSave,
                    onPressed:
                        _generalSaveInProgress || !_hasSaveableGeneralChanges
                        ? null
                        : () => unawaited(
                            _saveGeneral(
                              automatic: _autoSavePreferences,
                              includeRecentLogLimit:
                                  _parsedRecentLogLimit != null,
                            ),
                          ),
                  ),
                if (widget.autostartApplyFailed &&
                    widget.autostartSupported != false)
                  persistentError(
                    key: const ValueKey('settings-autostart-error'),
                    message: l10n.autostartApplyFailed,
                    action: l10n.retryAutostart,
                    onPressed: widget.autostartSupported == false
                        ? null
                        : () => unawaited(widget.onRetryAutostart()),
                  ),
                if (_runtimeSaveFailed)
                  persistentError(
                    key: const ValueKey('settings-runtime-save-error'),
                    message: l10n.runtimeSaveFailed,
                    action: l10n.retrySave,
                    onPressed: _runtimeCandidate == null
                        ? null
                        : () => unawaited(_saveRuntimeDraft()),
                  ),
                if (_applyConfigurationFailed)
                  persistentError(
                    key: const ValueKey('settings-apply-runtime-error'),
                    message: l10n.runtimeApplyFailed,
                    action: l10n.retryApplyRuntime,
                    onPressed:
                        (runtimePending || runtimeCanStart) &&
                            !_applyConfigurationInProgress
                        ? () => unawaited(_applySavedConfiguration())
                        : null,
                  ),
                if (_section != _SettingsSection.home &&
                    (runtimePending || runtimeCanStart))
                  persistentStatus(
                    key: const ValueKey('settings-runtime-pending-status'),
                    message: runtimePending
                        ? l10n.runtimeConfigSavedPending
                        : l10n.runtimeConfigSavedForNextStart,
                    action: runtimeStopped
                        ? l10n.startBackend
                        : l10n.applySavedConfiguration,
                    onPressed: _applyConfigurationInProgress
                        ? null
                        : () => unawaited(_applySavedConfiguration()),
                  ),
                if (_section == _SettingsSection.home) ...[
                  _SurfacePanel(
                    key: const ValueKey('settings-auto-save-card'),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.autoSavePreferencesHeading,
                                style: typography.titleMedium,
                              ),
                              SizedBox(height: typography.spacingXs),
                              Text(
                                _generalSaveInProgress
                                    ? l10n.autoSavePreferencesSaving
                                    : _autoSavePreferences
                                    ? l10n.autoSavePreferencesEnabledSubtitle
                                    : l10n.autoSavePreferencesManualSubtitle,
                                style: typography.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          key: const ValueKey('settings-auto-save'),
                          value: _autoSavePreferences,
                          onChanged: (value) =>
                              unawaited(_setPreferenceAutoSave(value)),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: typography.spacingLg),
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
                            setState(() => _generalThemeMode = selection.first);
                            _recordGeneralEdit();
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
                            setState(() => _generalLocale = locale);
                            _recordGeneralEdit();
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
                        key: const ValueKey('settings-runtime-application'),
                        title: l10n.runtimeConfigurationStatus,
                        subtitle: runtimeStatus,
                        control: runtimePending || runtimeCanStart
                            ? OutlinedButton(
                                key: const ValueKey(
                                  'settings-apply-saved-runtime',
                                ),
                                onPressed: _applyConfigurationInProgress
                                    ? null
                                    : () =>
                                          unawaited(_applySavedConfiguration()),
                                child: Text(
                                  runtimeStopped
                                      ? l10n.startBackend
                                      : l10n.applySavedConfiguration,
                                ),
                              )
                            : Text(
                                runtimeHasApplied
                                    ? l10n.runtimeConfigApplied
                                    : l10n.runtimeConfigSavedForNextStart,
                              ),
                      ),
                      settingRow(
                        key: const ValueKey('settings-http-meta'),
                        title: l10n.enableHttpMeta,
                        subtitle: _configurationDirty
                            ? '${l10n.enableHttpMetaSubtitle} (${l10n.unsaved})'
                            : l10n.enableHttpMetaSubtitle,
                        control: Switch(
                          key: const ValueKey('settings-http-meta-toggle'),
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
                          onPressed: () =>
                              _openSection(_SettingsSection.backendConfig),
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
                          onPressed: () =>
                              _openSection(_SettingsSection.advancedEnv),
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
                          decoration: InputDecoration(
                            errorText:
                                _recentLogLimit.text.trim().isEmpty ||
                                    _parsedRecentLogLimit == null
                                ? l10n.recentLogRangeError
                                : null,
                          ),
                          onChanged: (_) =>
                              _recordGeneralEdit(recentLogLimit: true),
                          onSubmitted: _submitRecentLogLimit,
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
                              setState(() => _generalCloseBehavior = value);
                              _recordGeneralEdit();
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
                            setState(() => _generalLaunchAtLogin = value);
                            _recordGeneralEdit();
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
                            setState(() => _generalStartHiddenToTray = value);
                            _recordGeneralEdit();
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
                    onTap: () => _openSection(_SettingsSection.about),
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
                                _backendRevision++;
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
                                      frontendBackendPath: value.trim().isEmpty
                                          ? null
                                          : value,
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
                              Icon(Icons.warning_amber, color: colors.error),
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
        if (_section == _SettingsSection.home &&
            ((!_autoSavePreferences && _generalDirty) || _runtimeDraftDirty))
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.all(typography.spacingMd),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_autoSavePreferences && _generalDirty)
                    Padding(
                      padding: EdgeInsets.only(bottom: typography.spacingSm),
                      child: Row(
                        children: [
                          Expanded(child: Text(l10n.unsavedChanges)),
                          TextButton(
                            key: const ValueKey('settings-discard-preferences'),
                            onPressed: () => unawaited(_discardGeneral()),
                            child: Text(l10n.discard),
                          ),
                          FilledButton(
                            key: const ValueKey('settings-save-preferences'),
                            onPressed: _parsedRecentLogLimit == null
                                ? null
                                : () => unawaited(_saveGeneral()),
                            child: Text(l10n.save),
                          ),
                        ],
                      ),
                    ),
                  if (_runtimeDraftDirty)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _runtimeSaveFailed
                                ? l10n.runtimeSaveFailed
                                : l10n.runtimeDraftPending,
                          ),
                        ),
                        FilledButton(
                          key: const ValueKey('settings-save-all'),
                          onPressed: _runtimeCandidate == null
                              ? null
                              : () => unawaited(_saveRuntimeDraft()),
                          child: Text(l10n.saveRuntimeConfiguration),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        if ((_section == _SettingsSection.backendConfig ||
                _section == _SettingsSection.advancedEnv) &&
            _runtimeDraftDirty)
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.all(typography.spacingMd),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const ValueKey('settings-child-save'),
                  onPressed: _runtimeCandidate == null
                      ? null
                      : () => unawaited(_saveRuntimeDraft()),
                  child: Text(l10n.save),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

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
    this.detail,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  /// Optional live value rendered under [subtitle] (for example the applied
  /// runtime address), so a tile can summarize state without an extra button.
  final Widget? detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    return ShadCard(
      padding: EdgeInsets.zero,
      child: ShadButton.raw(
        variant: ShadButtonVariant.ghost,
        width: double.infinity,
        height: 0,
        expands: true,
        mainAxisAlignment: MainAxisAlignment.start,
        padding: EdgeInsets.all(typography.spacingMd),
        onPressed: onTap,
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
                  if (detail != null) ...[
                    SizedBox(height: typography.spacingXs),
                    detail!,
                  ],
                ],
              ),
            ),
            SizedBox(width: typography.spacingSm),
            const Icon(Icons.chevron_right),
          ],
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
    required this.active,
    required this.runtimeState,
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
    required this.onOpenServiceDetails,
    this.aboutInfoLoader,
  });

  final bool active;
  final RuntimeState runtimeState;
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
  final VoidCallback onOpenServiceDetails;
  final AboutInfoLoader? aboutInfoLoader;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  final _scrollController = ScrollController();
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
  var _rawEnvironmentExpanded = false;
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

  /// Measures the floating bottom-right action group so the scroll view can
  /// reserve end-of-list clearance for it.
  final _actionGroupKey = GlobalKey();

  /// Laid-out height of the floating action group.
  var _actionGroupHeight = 0.0;

  /// Set while a post-frame measurement of the action group is outstanding.
  var _actionGroupMeasurementScheduled = false;

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
    _scrollController.dispose();
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
        if (mounted && saved) setState(() => _generalSaveFailed = false);
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

  Future<void> _saveAndApplyRuntime() async {
    if (_pendingSaveCount > 0 ||
        _applyConfigurationInProgress ||
        _runtimeCandidate == null) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final initialStatus = widget.coordinator.runtime.currentState.status;
    if (initialStatus == RuntimeStatus.starting ||
        initialStatus == RuntimeStatus.stopping) {
      return;
    }
    final stopped = initialStatus == RuntimeStatus.stopped;
    if (!await _confirm(
      stopped
          ? l10n.confirmSaveAndStartBackend
          : l10n.confirmSaveAndRestartBackend,
    )) {
      return;
    }
    final confirmedStatus = widget.coordinator.runtime.currentState.status;
    if (!mounted ||
        confirmedStatus == RuntimeStatus.starting ||
        confirmedStatus == RuntimeStatus.stopping ||
        (confirmedStatus == RuntimeStatus.stopped) != stopped ||
        !await _saveRuntimeDraft()) {
      return;
    }
    await _applySavedConfiguration();
  }

  Future<void> _revertRuntimeDraft() async {
    if (!_runtimeDraftDirty ||
        _pendingSaveCount > 0 ||
        _applyConfigurationInProgress) {
      return;
    }
    final revision = _runtimeRevision;
    if (!await _confirm(
      AppLocalizations.of(context)!.confirmRevertRuntimeDraft,
    )) {
      return;
    }
    if (!mounted || revision != _runtimeRevision) return;
    setState(() {
      _environmentRevision++;
      _configurationRevision++;
      _backendRevision++;
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
    return await showShadDialog<bool>(
          context: context,
          builder: (dialogContext) => ShadDialog(
            title: Text(l10n.settingsConfirmChangesTitle),
            description: Text(message),
            actions: [
              ShadButton.outline(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.cancel),
              ),
              ShadButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(l10n.continueAction),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _measureActionGroup() {
    if (_actionGroupMeasurementScheduled) return;
    _actionGroupMeasurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _actionGroupMeasurementScheduled = false;
      if (!mounted) return;
      final height = _actionGroupKey.currentContext?.size?.height ?? 0.0;
      if (height == _actionGroupHeight) return;
      setState(() => _actionGroupHeight = height);
    });
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
      final decision = await showShadDialog<_LeaveDecision>(
        context: context,
        builder: (dialogContext) => ShadDialog(
          key: const ValueKey('settings-leave-dialog'),
          title: Text(l10n.settingsConfirmChangesTitle),
          description: Text(l10n.unsavedChanges),
          actions: [
            ShadButton.outline(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_LeaveDecision.cancel),
              child: Text(l10n.cancel),
            ),
            ShadButton.outline(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_LeaveDecision.discard),
              child: Text(l10n.discard),
            ),
            ShadButton(
              enabled: _canSaveAllDrafts,
              onPressed: _canSaveAllDrafts
                  ? () => Navigator.of(dialogContext).pop(_LeaveDecision.save)
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
      if (mounted) await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_hasUnsavedChanges) return true;
      if (_draftRevision == revision) return false;
    }
    return true;
  }

  void _openSection(_SettingsSection section) {
    if (_section == section) return;
    final resetScroll =
        section == _SettingsSection.about || _section == _SettingsSection.about;
    setState(() => _section = section);
    widget.onChildStateChanged(section != _SettingsSection.home);
    if (resetScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
    }
  }

  void _backToHome() => _openSection(
    _section == _SettingsSection.advancedEnv
        ? _SettingsSection.backendConfig
        : _SettingsSection.home,
  );

  @override
  Widget build(BuildContext context) {
    final issues = BackendEnvPolicy.validate(_document);
    final configurationIssue = _configurationIssue;
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    String runtimeApiAddress(Map<String, String> environment) => Uri(
      scheme: 'http',
      host:
          environment[BackendEnvPolicy.host] ??
          InternetAddress.loopbackIPv4.address,
      port: int.tryParse(environment[BackendEnvPolicy.port] ?? '') ?? 3001,
      path: environment[BackendEnvPolicy.frontendBackendPath] ?? '/',
    ).toString();
    final runtimeState = widget.coordinator.runtime.currentState;
    final isRuntimeTask =
        _section == _SettingsSection.backendConfig ||
        _section == _SettingsSection.advancedEnv;
    final runtimePending = widget.coordinator.hasPendingConfiguration;
    final runtimeApplied = widget.coordinator.runtime.appliedConfiguration;
    final runtimeHasApplied = runtimeApplied != null;
    final runtimeStopped = runtimeState.status == RuntimeStatus.stopped;
    final runtimeActionBusy =
        _pendingSaveCount > 0 ||
        _applyConfigurationInProgress ||
        runtimeState.status == RuntimeStatus.starting ||
        runtimeState.status == RuntimeStatus.stopping;
    final runtimeCanStart =
        runtimeStopped && widget.coordinator.savedRevision > 0;
    final runtimeCanRetry =
        _applyConfigurationFailed &&
        runtimeState.status == RuntimeStatus.crashed &&
        widget.coordinator.savedRevision > 0;
    final runtimeCandidate = _runtimeCandidate;
    final runtimePreview = runtimeCandidate == null
        ? null
        : EffectiveRuntimeConfig.resolve(
            systemEnvironment: Platform.environment,
            backendEnvironment: runtimeCandidate.environment,
            config: runtimeCandidate.configuration,
          );
    final runtimeNeedsApply =
        runtimePreview != null &&
        (runtimeApplied == null ||
            runtimeApplied.httpMetaEnabled != runtimePreview.httpMetaEnabled ||
            !mapEquals(runtimeApplied.environment, runtimePreview.environment));
    final currentApiAddress = runtimeApplied == null
        ? null
        : runtimeApiAddress(runtimeApplied.environment);
    final proposedApiAddress = runtimePreview == null
        ? null
        : runtimeApiAddress(runtimePreview.environment);
    final runtimeStatus = _runtimeDraftDirty
        ? l10n.runtimeConfigDraftStatus
        : runtimePending
        ? l10n.runtimeConfigSavedPending
        : runtimeHasApplied
        ? l10n.runtimeConfigApplied
        : l10n.runtimeConfigSavedForNextStart;
    final runtimeStatusLabel = runtimeActionBusy
        ? l10n.processing
        : _runtimeDraftDirty && runtimeCandidate == null
        ? l10n.runtimePreviewUnavailable
        : runtimeStatus;
    // A saved configuration awaiting activation (or a first start) is public
    // state the form reports now that the action corner holds buttons only.
    final pendingStatusVisible =
        !_runtimeDraftDirty &&
        !runtimeActionBusy &&
        (runtimePending || runtimeCanStart);
    Widget settingRow({
      Key? key,
      required String title,
      required String subtitle,
      required Widget control,
    }) => LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
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
    Widget divider() => ShadSeparator.horizontal(margin: EdgeInsets.zero);
    Widget actionButton({
      Key? key,
      required String label,
      required VoidCallback? onPressed,
      bool primary = false,
      bool ghost = false,
      bool wrapLabel = false,
      IconData? icon,
    }) {
      final disabled = onPressed == null;
      // ShadButton dims a disabled button to 50% opacity over the theme variant
      // colors, which leaves a pale accent label on a pale accent fill. Paint
      // disabled buttons with the neutral surface/foreground tokens instead so
      // both the label and the outline stay readable while the control is
      // clearly inactive.
      return ShadButton.raw(
        key: key,
        variant: primary
            ? ShadButtonVariant.primary
            : ghost
            ? ShadButtonVariant.ghost
            : ShadButtonVariant.outline,
        enabled: onPressed != null,
        onPressed: onPressed,
        height: wrapLabel ? 0 : null,
        expands: wrapLabel,
        leading: icon == null ? null : Icon(icon, size: 16),
        backgroundColor: disabled ? colors.surfaceHigh : null,
        foregroundColor: disabled ? colors.onSurface : null,
        hoverForegroundColor: disabled ? colors.onSurface : null,
        pressedForegroundColor: disabled ? colors.onSurface : null,
        decoration: disabled
            ? ShadDecoration(
                border: ShadBorder.all(color: colors.disabled, width: 1),
              )
            : null,
        child: Text(label),
      );
    }

    Widget preferenceThemeSelector() {
      final choices = [
        (ThemeMode.system, l10n.themeFollowSystem),
        (ThemeMode.light, l10n.themeLight),
        (ThemeMode.dark, l10n.themeDark),
      ];
      IconData iconFor(ThemeMode mode) => switch (mode) {
        ThemeMode.system => Icons.desktop_windows_outlined,
        ThemeMode.light => Icons.light_mode_outlined,
        ThemeMode.dark => Icons.dark_mode_outlined,
      };
      return Wrap(
        key: const ValueKey('settings-theme-mode'),
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final choice in choices)
            ShadButton.raw(
              key: ValueKey('settings-theme-option-${choice.$1.name}'),
              variant: _generalThemeMode == choice.$1
                  ? ShadButtonVariant.secondary
                  : ShadButtonVariant.outline,
              leading: Icon(iconFor(choice.$1), size: 16),
              onPressed: () {
                setState(() => _generalThemeMode = choice.$1);
                _recordGeneralEdit();
                unawaited(widget.onPreviewTheme(choice.$1));
              },
              child: Text(choice.$2),
            ),
        ],
      );
    }

    Widget preferenceLanguageSelector() => ShadSelect<String>(
      key: const ValueKey('settings-language'),
      initialValue: _generalLocale ?? 'system',
      minWidth: 230,
      maxWidth: 230,
      selectedOptionBuilder: (_, value) => Text(switch (value) {
        'system' => l10n.languageFollowSystem,
        'zh' || 'en' => _languageLabel(value),
        _ => value,
      }),
      options: [
        ShadOption(value: 'system', child: Text(l10n.languageFollowSystem)),
        for (final language in LocalePreferenceStore.supported)
          ShadOption(value: language, child: Text(_languageLabel(language))),
      ],
      onChanged: (value) {
        if (value == null) return;
        final locale = value == 'system' ? null : value;
        setState(() => _generalLocale = locale);
        _recordGeneralEdit();
        unawaited(
          widget.onPreviewLocale(locale == null ? null : Locale(locale)),
        );
      },
    );
    final currentRuntime = runtimeState;
    final currentRuntimeLabel = switch (currentRuntime.status) {
      RuntimeStatus.stopped => l10n.stopped,
      RuntimeStatus.starting => l10n.starting,
      RuntimeStatus.running => l10n.running,
      RuntimeStatus.stopping => l10n.stopping,
      RuntimeStatus.unhealthy => l10n.unhealthy,
      RuntimeStatus.crashed => l10n.crashed,
    };
    final currentHttpMetaLabel = switch (currentRuntime.httpMetaStatus) {
      HttpMetaStatus.disabled => l10n.httpMetaDisabled,
      HttpMetaStatus.unavailable => l10n.httpMetaUnavailable,
      HttpMetaStatus.starting => l10n.starting,
      HttpMetaStatus.running => l10n.running,
      HttpMetaStatus.degraded => l10n.httpMetaDegraded,
      HttpMetaStatus.stopped => l10n.httpMetaStopped,
    };
    final currentServiceAddress =
        widget.coordinator.appliedWebUiApiUri ??
        widget.coordinator.runtime.endpoint;
    Widget localServiceCard() => KeyedSubtree(
      key: const ValueKey('settings-local-service-card'),
      child: _SettingsSectionTile(
        key: const ValueKey('settings-card-backend-config'),
        icon: Icons.dns_outlined,
        title: l10n.settingsLocalServiceHeading,
        subtitle:
            '${l10n.backendRuntime}: $currentRuntimeLabel · HTTP-META $currentHttpMetaLabel',
        detail: Text(
          currentServiceAddress.toString(),
          style: typography.codeSmall,
        ),
        onTap: () => _openSection(_SettingsSection.backendConfig),
      ),
    );
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
    Widget preferenceField({
      Key? key,
      required String title,
      required String subtitle,
      required Widget control,
      double controlWidth = 300,
    }) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final copy = Column(
            key: key,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: typography.bodyMedium.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 3),
              Text(subtitle, style: typography.bodySmall),
            ],
          );
          final editor = Semantics(
            label: title,
            container: true,
            child: SizedBox(
              width: constraints.maxWidth < controlWidth
                  ? constraints.maxWidth
                  : controlWidth,
              child: Align(
                alignment: constraints.maxWidth >= 700
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: control,
              ),
            ),
          );
          return constraints.maxWidth >= 700
              ? Row(
                  children: [
                    Expanded(child: copy),
                    const SizedBox(width: 24),
                    editor,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [copy, const SizedBox(height: 9), editor],
                );
        },
      ),
    );
    Widget preferenceGroup({
      required Key key,
      required String title,
      required List<Widget> fields,
    }) => Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: typography.titleSmall.copyWith(fontWeight: FontWeight.w600),
        ),
        for (var i = 0; i < fields.length; i++) ...[
          if (i > 0) divider(),
          fields[i],
        ],
      ],
    );
    // Floating bottom-right action group shared by the connection/ENV runtime
    // editor and the manual preference save. It holds buttons only and is drawn
    // over the full-height scroll viewport: status and error copy belongs to the
    // form, so this corner never becomes a separate footer band.
    Widget actionGroup({required Key key, required List<Widget> actions}) =>
        KeyedSubtree(
          key: _actionGroupKey,
          child: KeyedSubtree(
            key: key,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: typography.spacingXs,
              runSpacing: typography.spacingXs,
              children: actions,
            ),
          ),
        );

    List<Widget> runtimeActions() {
      final readyToSave = runtimeCandidate != null && !runtimeActionBusy;
      final canRetryApply =
          (runtimePending || runtimeCanStart || runtimeCanRetry) &&
          !runtimeActionBusy;
      return [
        actionButton(
          key: const ValueKey('settings-child-revert'),
          label: l10n.revertRuntimeDraft,
          ghost: true,
          onPressed: _runtimeDraftDirty && !runtimeActionBusy
              ? () => unawaited(_revertRuntimeDraft())
              : null,
        ),
        if (_runtimeDraftDirty)
          actionButton(
            key: const ValueKey('settings-child-save'),
            label: l10n.saveRuntimeConfiguration,
            onPressed: readyToSave
                ? () => unawaited(_saveRuntimeDraft())
                : null,
          ),
        if (_runtimeDraftDirty && runtimeNeedsApply)
          actionButton(
            key: const ValueKey('settings-child-save-and-apply'),
            label: runtimeStopped
                ? l10n.saveAndStartBackend
                : l10n.saveAndRestartBackend,
            primary: true,
            onPressed: readyToSave
                ? () => unawaited(_saveAndApplyRuntime())
                : null,
          ),
        if (!_runtimeDraftDirty && canRetryApply && !_applyConfigurationFailed)
          actionButton(
            key: const ValueKey('settings-apply-saved-runtime'),
            label: runtimeStopped
                ? l10n.startBackend
                : l10n.applySavedConfiguration,
            primary: true,
            onPressed: () => unawaited(_applySavedConfiguration()),
          ),
      ];
    }

    Widget persistentError({
      required Key key,
      required String message,
      required String action,
      required VoidCallback? onPressed,
    }) => Padding(
      key: key,
      padding: EdgeInsets.only(bottom: typography.spacingMd),
      child: ShadCard(
        border: ShadBorder.all(color: colors.error, width: 1),
        child: Row(
          children: [
            Expanded(
              // Failure copy is announced when it appears; the card and its
              // surroundings add no live region of their own.
              child: Semantics(
                liveRegion: true,
                child: Text(message, style: TextStyle(color: colors.error)),
              ),
            ),
            actionButton(label: action, onPressed: onPressed),
          ],
        ),
      ),
    );
    final hasActionGroup =
        isRuntimeTask ||
        (_section == _SettingsSection.home && !_autoSavePreferences);
    final content = ListView(
      key: const ValueKey('settings-list'),
      controller: _scrollController,
      // The viewport keeps the full content height; only the scroll end grows so
      // the last control stays operable above the floating action group.
      padding: EdgeInsets.fromLTRB(
        typography.spacingLg,
        typography.spacingLg,
        typography.spacingLg,
        typography.spacingLg +
            (hasActionGroup ? _actionGroupHeight + typography.spacingMd : 0),
      ),
      children: [
        Align(
          // The approved quick-settings frame is the wider, left-aligned one;
          // runtime, ENV, and About keep their narrower centered frame.
          alignment: _section == _SettingsSection.home
              ? Alignment.topLeft
              : Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: _section == _SettingsSection.home ? 1060 : 960,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_section != _SettingsSection.home)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: actionButton(
                      key: const ValueKey('settings-back'),
                      label: l10n.back,
                      onPressed: _backToHome,
                      ghost: true,
                      icon: Icons.arrow_back,
                    ),
                  ),
                if (widget.autostartSupported == false)
                  Padding(
                    key: const ValueKey('settings-autostart-unavailable'),
                    padding: EdgeInsets.only(bottom: typography.spacingMd),
                    child: ShadCard(
                      border: ShadBorder.all(color: colors.error, width: 1),
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
                // A failed shared-draft save or apply must stay visible and
                // retryable in every view that edits that draft, so it lives in
                // the form rather than in one section's card or the action corner.
                if (_runtimeSaveFailed)
                  persistentError(
                    key: const ValueKey('settings-runtime-save-error'),
                    message: l10n.runtimeSaveFailed,
                    action: l10n.retrySave,
                    // The retry re-enters the shared draft, so it needs the same
                    // readiness gate as the Save button in the action corner:
                    // never while another runtime operation is in flight.
                    onPressed: _runtimeCandidate == null || runtimeActionBusy
                        ? null
                        : () => unawaited(_saveRuntimeDraft()),
                  ),
                if (_applyConfigurationFailed)
                  persistentError(
                    key: const ValueKey('settings-apply-runtime-error'),
                    message: l10n.runtimeApplyFailed,
                    action: l10n.retryApplyRuntime,
                    onPressed:
                        (runtimePending ||
                                runtimeCanStart ||
                                runtimeCanRetry) &&
                            !runtimeActionBusy
                        ? () => unawaited(_applySavedConfiguration())
                        : null,
                  ),
                if (_section == _SettingsSection.home) ...[
                  localServiceCard(),
                  SizedBox(height: typography.spacingMd),
                  ShadCard(
                    key: const ValueKey('settings-auto-save-card'),
                    padding: EdgeInsets.all(typography.spacingMd),
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
                        Semantics(
                          label: l10n.autoSavePreferencesHeading,
                          child: ShadSwitch(
                            key: const ValueKey('settings-auto-save'),
                            value: _autoSavePreferences,
                            onChanged: (value) =>
                                unawaited(_setPreferenceAutoSave(value)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: typography.spacingLg),
                  Builder(
                    builder: (context) {
                      final appearance = preferenceGroup(
                        key: const ValueKey('settings-appearance'),
                        title: l10n.settingsQuickAppearanceHeading,
                        fields: [
                          preferenceField(
                            key: const ValueKey('settings-theme-row'),
                            title: l10n.themeHeading,
                            subtitle: _autoSavePreferences
                                ? l10n.themeSubtitleAutomatic
                                : l10n.themeSubtitle,
                            controlWidth: 320,
                            control: preferenceThemeSelector(),
                          ),
                          preferenceField(
                            key: const ValueKey('settings-language-row'),
                            title: l10n.languageHeading,
                            subtitle: _autoSavePreferences
                                ? l10n.languageSubtitleAutomatic
                                : l10n.languageSubtitle,
                            control: preferenceLanguageSelector(),
                          ),
                          preferenceField(
                            key: const ValueKey('settings-recent-logs-row'),
                            title: l10n.recentLogs,
                            subtitle: l10n.recentLogsSubtitle,
                            control: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 140,
                                  child: ShadInput(
                                    key: const ValueKey(
                                      'settings-recent-log-limit',
                                    ),
                                    controller: _recentLogLimit,
                                    keyboardType: TextInputType.number,
                                    onChanged: (_) => _recordGeneralEdit(
                                      recentLogLimit: true,
                                    ),
                                    onSubmitted: _submitRecentLogLimit,
                                    decoration: _parsedRecentLogLimit == null
                                        ? ShadDecoration(
                                            border: ShadBorder.all(
                                              color: colors.error,
                                              width: 1,
                                            ),
                                          )
                                        : null,
                                  ),
                                ),
                                if (_parsedRecentLogLimit == null) ...[
                                  SizedBox(height: typography.spacingXs),
                                  Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      l10n.recentLogRangeError,
                                      style: typography.bodySmall.copyWith(
                                        color: colors.error,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      );
                      final desktop = preferenceGroup(
                        key: const ValueKey('settings-desktop-behavior'),
                        title: l10n.settingsQuickDesktopHeading,
                        fields: [
                          preferenceField(
                            key: const ValueKey('settings-close-behavior-row'),
                            title: l10n.closeBehaviorHeading,
                            subtitle: l10n.closeBehaviorSubtitle,
                            control: ShadSelect<CloseBehavior>(
                              key: const ValueKey('settings-close-behavior'),
                              initialValue: _generalCloseBehavior,
                              minWidth: 230,
                              maxWidth: 230,
                              selectedOptionBuilder: (_, value) => Text(
                                value == CloseBehavior.exitApp
                                    ? l10n.exitApp
                                    : l10n.closeToTray,
                              ),
                              options: [
                                ShadOption(
                                  value: CloseBehavior.exitApp,
                                  child: Text(l10n.exitApp),
                                ),
                                ShadOption(
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
                          preferenceField(
                            key: const ValueKey('settings-launch-at-login-row'),
                            title: l10n.launchAtLoginHeading,
                            subtitle: l10n.launchAtLoginSubtitle,
                            controlWidth: 70,
                            control: ShadSwitch(
                              key: const ValueKey('settings-launch-at-login'),
                              value: _generalLaunchAtLogin,
                              label: Semantics(
                                label: l10n.launchAtLoginHeading,
                              ),
                              onChanged: (value) {
                                setState(() => _generalLaunchAtLogin = value);
                                _recordGeneralEdit();
                              },
                            ),
                          ),
                          preferenceField(
                            key: const ValueKey('settings-start-hidden-row'),
                            title: l10n.startHiddenToTrayHeading,
                            subtitle: l10n.startHiddenToTraySubtitle,
                            controlWidth: 70,
                            control: ShadSwitch(
                              key: const ValueKey('settings-start-hidden'),
                              value: _generalStartHiddenToTray,
                              label: Semantics(
                                label: l10n.startHiddenToTrayHeading,
                              ),
                              onChanged: (value) {
                                setState(
                                  () => _generalStartHiddenToTray = value,
                                );
                                _recordGeneralEdit();
                              },
                            ),
                          ),
                        ],
                      );
                      return ShadCard(
                        key: const ValueKey('settings-preferences-panel'),
                        padding: const EdgeInsets.all(20),
                        child: LayoutBuilder(
                          builder: (context, panel) => panel.maxWidth >= 900
                              ? Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(flex: 6, child: appearance),
                                    const SizedBox(width: 32),
                                    Container(
                                      key: const ValueKey(
                                        'settings-preferences-divider',
                                      ),
                                      width: 1,
                                      height: 346,
                                      color: colors.divider,
                                    ),
                                    const SizedBox(width: 28),
                                    Expanded(flex: 5, child: desktop),
                                  ],
                                )
                              : Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    appearance,
                                    const SizedBox(height: 18),
                                    ShadSeparator.horizontal(
                                      key: const ValueKey(
                                        'settings-preferences-divider',
                                      ),
                                      margin: EdgeInsets.zero,
                                    ),
                                    const SizedBox(height: 22),
                                    desktop,
                                  ],
                                ),
                        ),
                      );
                    },
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
                  ShadCard(
                    key: const ValueKey('settings-runtime'),
                    padding: EdgeInsets.zero,
                    child: Column(
                      key: const ValueKey('settings-backend-config'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        KeyedSubtree(
                          key: const ValueKey('settings-runtime-application'),
                          child: Padding(
                            padding: EdgeInsets.all(typography.spacingMd),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.runtimeConfigurationStatus,
                                  style: typography.titleMedium,
                                ),
                                SizedBox(height: typography.spacingXs),
                                Semantics(
                                  key: pendingStatusVisible
                                      ? const ValueKey(
                                          'settings-runtime-pending-status',
                                        )
                                      : null,
                                  liveRegion: true,
                                  child: Text(
                                    runtimeStatusLabel,
                                    style: typography.bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: typography.spacingMd,
                            vertical: typography.spacingXs,
                          ),
                          child: Text(
                            l10n.runtimeSharedDraftScope,
                            style: typography.bodySmall,
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.all(typography.spacingMd),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              Widget summaryColumn({
                                required Key key,
                                required String heading,
                                required String? address,
                                required String missingAddress,
                                required String meta,
                              }) => KeyedSubtree(
                                key: key,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(heading, style: typography.bodySmall),
                                    SizedBox(height: typography.spacingXs),
                                    SelectableText(
                                      address ?? missingAddress,
                                      style: typography.bodySmall.copyWith(
                                        fontFamily: uiMonoFontFamily,
                                      ),
                                    ),
                                    SizedBox(height: typography.spacingXs),
                                    Text(meta, style: typography.bodySmall),
                                  ],
                                ),
                              );
                              final current = summaryColumn(
                                key: const ValueKey(
                                  'settings-current-runtime-summary',
                                ),
                                heading: l10n.runtimeCurrentConfiguration,
                                address: currentApiAddress,
                                missingAddress:
                                    l10n.runtimeNoAppliedConfiguration,
                                meta:
                                    '${l10n.backendRuntime}: $currentRuntimeLabel · ${l10n.enableHttpMeta}: $currentHttpMetaLabel',
                              );
                              final proposed = summaryColumn(
                                key: const ValueKey(
                                  'settings-proposed-runtime-summary',
                                ),
                                heading: l10n.runtimeProposedConfiguration,
                                address: proposedApiAddress,
                                missingAddress: l10n.runtimePreviewUnavailable,
                                meta:
                                    '${l10n.enableHttpMeta}: ${runtimePreview == null
                                        ? l10n.unavailable
                                        : runtimePreview.httpMetaEnabled
                                        ? l10n.enabled
                                        : l10n.disabled}',
                              );
                              return constraints.maxWidth >= 640
                                  ? Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(child: current),
                                        SizedBox(width: typography.spacingMd),
                                        Expanded(child: proposed),
                                      ],
                                    )
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        current,
                                        SizedBox(height: typography.spacingMd),
                                        proposed,
                                      ],
                                    );
                            },
                          ),
                        ),
                        divider(),
                        settingRow(
                          key: const ValueKey('settings-http-meta'),
                          title: l10n.enableHttpMeta,
                          subtitle: _configurationDirty
                              ? '${l10n.enableHttpMetaSubtitle} (${l10n.unsaved})'
                              : l10n.enableHttpMetaSubtitle,
                          control: ShadSwitch(
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
                                actionButton(
                                  label: l10n.resetSubdockConfig,
                                  onPressed: _configurationDirty
                                      ? null
                                      : () => unawaited(
                                          widget.onResetConfiguration(),
                                        ),
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
                        divider(),
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
                          control: ShadInput(
                            controller: _host,
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
                          control: ShadInput(
                            controller: _port,
                            keyboardType: TextInputType.number,
                            decoration:
                                _port.text.trim().isNotEmpty &&
                                    _backendIssue != null
                                ? ShadDecoration(
                                    border: ShadBorder.all(
                                      color: colors.error,
                                      width: 1,
                                    ),
                                  )
                                : null,
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
                          control: Align(
                            alignment: Alignment.centerLeft,
                            child: ShadSelect<_NullableBoolDraft>(
                              key: ValueKey('settings-merge-mode-$_mergeDraft'),
                              initialValue: _mergeDraft,
                              minWidth: 250,
                              maxWidth: 280,
                              selectedOptionBuilder: (_, value) => Text(
                                switch (value) {
                                  _NullableBoolDraft.inherit => l10n.inherit,
                                  _NullableBoolDraft.enabled => l10n.enabled,
                                  _NullableBoolDraft.disabled => l10n.disabled,
                                },
                              ),
                              options: [
                                ShadOption(
                                  value: _NullableBoolDraft.inherit,
                                  child: Text(l10n.inherit),
                                ),
                                ShadOption(
                                  value: _NullableBoolDraft.enabled,
                                  child: Text(l10n.enabled),
                                ),
                                ShadOption(
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
                        ),
                        divider(),
                        configRow(
                          key: const ValueKey('settings-backend-path-row'),
                          label: l10n.frontendBackendPath,
                          control: Row(
                            children: [
                              Expanded(
                                child: ShadInput(
                                  controller: _path,
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
                              actionButton(
                                key: const ValueKey(
                                  'settings-backend-path-regenerate',
                                ),
                                label: l10n.regenerateBackendPath,
                                icon: Icons.refresh,
                                onPressed: () {
                                  final path = randomBackendPath();
                                  _path.text = path;
                                  _updateBackend(
                                    _backendDraft.copyWith(
                                      frontendBackendPath: path,
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        divider(),
                        configRow(
                          key: const ValueKey('settings-backend-cors-row'),
                          label: l10n.corsAllowedOrigins,
                          control: ShadInput(
                            controller: _cors,
                            onChanged: (value) => _updateBackend(
                              _backendDraft.copyWith(
                                corsAllowedOrigins: value.trim().isEmpty
                                    ? null
                                    : value,
                              ),
                            ),
                          ),
                        ),
                        divider(),
                        configRow(
                          key: const ValueKey('settings-advanced-env-row'),
                          label: l10n.advancedRawEnv,
                          control: actionButton(
                            key: const ValueKey('settings-card-advanced-env'),
                            label: l10n.open,
                            icon: Icons.terminal,
                            onPressed: () =>
                                _openSection(_SettingsSection.advancedEnv),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                SizedBox(height: typography.spacingLg),
                if (_section == _SettingsSection.advancedEnv) ...[
                  _SettingsSectionTitle(title: l10n.advancedRawEnv),
                  Padding(
                    padding: EdgeInsets.only(bottom: typography.spacingMd),
                    child: Text(
                      l10n.runtimeSharedDraftScope,
                      style: typography.bodySmall,
                    ),
                  ),
                  ShadCard(
                    key: const ValueKey('settings-raw-env'),
                    padding: EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
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
                        ShadButton.raw(
                          key: const ValueKey('settings-raw-env-expansion'),
                          variant: ShadButtonVariant.ghost,
                          width: double.infinity,
                          height: 0,
                          expands: true,
                          mainAxisAlignment: MainAxisAlignment.start,
                          padding: EdgeInsets.symmetric(
                            horizontal: typography.spacingMd,
                            vertical: typography.spacingSm,
                          ),
                          onPressed: () => setState(
                            () => _rawEnvironmentExpanded =
                                !_rawEnvironmentExpanded,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(l10n.advancedRawEnvSubtitle),
                              ),
                              Icon(
                                _rawEnvironmentExpanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                              ),
                            ],
                          ),
                        ),
                        if (_rawEnvironmentExpanded)
                          Padding(
                            padding: EdgeInsets.all(typography.spacingMd),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                ShadInput(
                                  key: const ValueKey(
                                    'settings-raw-env-editor',
                                  ),
                                  controller: _raw,
                                  minLines: 8,
                                  maxLines: 16,
                                  onChanged: _updateRaw,
                                ),
                                if (issues.isNotEmpty) ...[
                                  SizedBox(height: typography.spacingS),
                                  for (final issue in issues)
                                    Padding(
                                      padding: EdgeInsets.only(
                                        bottom: typography.spacingXs,
                                      ),
                                      child: Semantics(
                                        liveRegion: true,
                                        child: Text(
                                          '${issue.line == null ? '' : l10n.lineNumber(issue.line!)}${_localizedIssue(l10n, issue)}',
                                          style: TextStyle(color: colors.error),
                                        ),
                                      ),
                                    ),
                                ],
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                SizedBox(height: typography.spacingLg),
                if (_section == _SettingsSection.about)
                  _AboutPage(
                    key: const ValueKey('settings-about-page'),
                    active: widget.active && _section == _SettingsSection.about,
                    loader: widget.aboutInfoLoader,
                    coordinator: widget.coordinator,
                    runtimeState: widget.runtimeState,
                    onOpenExternalUri: widget.onOpenExternalUri,
                    onOpenServiceDetails: widget.onOpenServiceDetails,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
    final actions = <Widget>[
      if (_section == _SettingsSection.home && !_autoSavePreferences) ...[
        actionButton(
          key: const ValueKey('settings-discard-preferences'),
          label: l10n.discard,
          onPressed: _generalDirty ? () => unawaited(_discardGeneral()) : null,
          ghost: true,
        ),
        actionButton(
          key: const ValueKey('settings-save-preferences'),
          label: l10n.save,
          primary: true,
          onPressed:
              !_generalDirty ||
                  _parsedRecentLogLimit == null ||
                  _generalSaveInProgress
              ? null
              : () => unawaited(_saveGeneral()),
        ),
      ],
      if (isRuntimeTask) ...runtimeActions(),
    ];
    if (actions.isEmpty) return content;
    _measureActionGroup();
    final home = _section == _SettingsSection.home;
    // The form owns the whole content area; only the last control needs room to
    // clear the floating buttons, which the list padding below reserves.
    return Stack(
      children: [
        Positioned.fill(child: content),
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(
              left: typography.spacingLg,
              right: typography.spacingLg,
              bottom: typography.spacingMd,
            ),
            child: SafeArea(
              top: false,
              child: Align(
                alignment: home ? Alignment.bottomLeft : Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: home ? 1060 : 960),
                  // Bottom-right inside the content frame, so the buttons sit on
                  // the frame's baseline rather than centered in the viewport.
                  child: Align(
                    alignment: Alignment.bottomRight,
                    child: actionGroup(
                      key: ValueKey(
                        home
                            ? 'settings-preferences-actions'
                            : 'settings-runtime-actions',
                      ),
                      actions: actions,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

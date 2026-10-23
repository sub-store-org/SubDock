import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:file_selector/file_selector.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/generated/app_localizations.dart';
import '../runtime/backend_runtime.dart';
import '../runtime/runtime_log_store.dart';
import '../settings/backend_env.dart';
import '../settings/config_error.dart';
import '../settings/desktop_preferences.dart';
import '../settings/desktop_preferences_store.dart';
import '../settings/autostart.dart';
import '../settings/locale_preference_store.dart';
import '../settings/subdock_config.dart';
import '../update/component_metadata_store.dart';
import '../update/component_update_checker.dart';
import '../update/component_update_service.dart';
import 'app_colors.dart';
import 'app_coordinator.dart';
import 'maintenance_operation.dart';
import 'app_typography.dart';
import 'about_info.dart';
import 'close_request_guard.dart';
import 'embedded_webview.dart';
import 'runtime_observations.dart';
import 'log_reader_state.dart';

part 'pages/manage_page.dart';
part 'pages/logs_page.dart';
part 'pages/service_page.dart';
part 'pages/settings_page.dart';
part 'pages/updates_page.dart';
part 'pages/about_page.dart';

const navigationBreakpoint = 600.0;
final _notMaximized = ValueNotifier<bool>(false);

Future<bool> _launchExternalUri(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

enum _AppPage { overview, manage, logs, updates, settings, about }

typedef _PreferenceMutation = DesktopPreferences Function(
  DesktopPreferences current,
);
typedef _PreferenceSave = Future<bool> Function(
  _PreferenceMutation mutate, {
  bool Function()? canSave,
});

class _ShellDestination {
  const _ShellDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final Widget icon;
  final Widget selectedIcon;
  final String label;
}

class SubDockApp extends StatefulWidget {
  const SubDockApp({
    super.key,
    required this.coordinator,
    this.autoStart = true,
    this.enableWebView = true,
    this.initialError,
    this.desktopWarning,
    this.onMinimize,
    this.onToggleMaximize,
    this.onClose,
    this.onRetryExit,
    this.isMaximized,
    this.closeRequestGuard,
    this.onStartDragging,
    this.preferences,
    this.preferencesStore,
    this.onLocaleChanged,
    this.locale,
    this.onOpenExternalUri,
    this.aboutInfoLoader,
    this.webViewControllerFactory,
    this.showCustomDesktopChrome = true,
    this.onAutostartChanged,
  });

  final AppCoordinator coordinator;
  final bool autoStart;
  final bool enableWebView;
  final Object? initialError;
  final ValueListenable<Object?>? desktopWarning;
  final Future<void> Function()? onMinimize;
  final Future<void> Function()? onToggleMaximize;
  final Future<void> Function()? onClose;
  final Future<void> Function()? onRetryExit;
  final ValueListenable<bool>? isMaximized;
  final CloseRequestGuard? closeRequestGuard;
  final Future<void> Function()? onStartDragging;
  final DesktopPreferences? preferences;
  final DesktopPreferencesStore? preferencesStore;

  /// Notified with the effective locale after a locale change or a successful
  /// preference load at startup, so the caller (desktop_main) can rebuild the
  /// tray menu in the same language.
  final Future<void> Function(Locale?)? onLocaleChanged;

  /// Initial locale override used when no saved preference selects a language.
  final Locale? locale;

  /// Notified when the launch-at-login preference changes so the caller can
  /// install or remove the autostart entry (declared here rather than inside
  /// the settings page so the platform mechanism stays in the desktop entry).
  final Future<void> Function(bool enabled)? onAutostartChanged;
  final Future<bool> Function(Uri uri)? onOpenExternalUri;
  final AboutInfoLoader? aboutInfoLoader;
  final EmbeddedWebViewController Function({
    required EmbeddedNavigationHandler onNavigationRequest,
    required void Function(String message) onBlobMessage,
    required String bridgeScript,
    EmbeddedPageChangeHandler? onPageChanged,
    EmbeddedMainFrameFailureHandler? onMainFrameFailure,
  })?
  webViewControllerFactory;
  final bool showCustomDesktopChrome;

  @override
  State<SubDockApp> createState() => _SubDockAppState();
}

class _SubDockAppState extends State<SubDockApp> {
  final _settingsKey = GlobalKey<_SettingsPageState>();
  final _updatesKey = GlobalKey<_UpdatesPageState>();
  late final _lightShadTheme = _buildShadTheme(
    Brightness.light,
    AppColors.light,
    AppTypography.light,
  );
  late final _darkShadTheme = _buildShadTheme(
    Brightness.dark,
    AppColors.dark,
    AppTypography.dark,
  );
  late final StreamSubscription<RuntimeState> _stateSubscription;
  late final StreamSubscription<RuntimeLog> _logSubscription;
  late final StreamSubscription<RuntimeLogRunStarted>
  _logRunStartedSubscription;
  late final StreamSubscription<RuntimeLogRunUpdate> _logRunUpdatesSubscription;
  late final AppLifecycleListener _lifecycleListener;
  late RuntimeState _state;
  final _observations = RuntimeObservations();
  late final LogReaderState _logReader;
  _AppPage _page = _AppPage.overview;
  final _overviewComponentStatuses = <ComponentKind, ComponentVersionStatus>{};
  final _overviewComponentUnavailable = <ComponentKind>{};
  final _logRunUpdates = <String, RuntimeLogRunUpdate>{};
  final _retryingLogFinalizations = <String>{};
  BackendInfo? _info;
  Object? _error;
  var _actionInProgress = false;
  var _autostartApplyFailed = false;
  late ThemeMode _themeMode;
  Locale? _localeOverride;
  late DesktopPreferences _savedPreferences;
  late Future<void> _preferenceQueue;
  var _historyRefreshGeneration = 0;
  var _settingsChild = false;
  var _maintenanceRefreshQueued = false;
  var _retryingLogRecovery = false;
  CloseApprovalHandler? _previousCloseApproval;

  @override
  void initState() {
    super.initState();
    _preferenceQueue = Future<void>.value();
    registerBundledFontLicenses();
    final preferences = widget.preferences ?? DesktopPreferences.defaults;
    _savedPreferences = preferences;
    _logReader = LogReaderState(limit: preferences.recentLogLimit);
    _themeMode = preferences.themeMode;
    _localeOverride = preferences.locale == null
        ? widget.locale
        : Locale(preferences.locale!);
    _state = widget.coordinator.runtime.currentState;
    _observations.observeState(_state);
    _error = widget.initialError;
    if (_error != null) _page = _AppPage.overview;
    _stateSubscription = widget.coordinator.runtime.state.listen(_onState);
    _logSubscription = widget.coordinator.runtime.logs.listen(_appendLog);
    _logRunStartedSubscription = widget.coordinator.runtime.logRunStarted
        .listen(_onLogRunStarted);
    _logRunUpdatesSubscription = widget.coordinator.runtime.logRunUpdates
        .listen(_onLogRunUpdate);
    widget.coordinator.maintenanceChanges.addListener(_onMaintenanceChanged);
    _lifecycleListener = AppLifecycleListener(
      onDetach: () => unawaited(widget.coordinator.dispose()),
    );
    widget.desktopWarning?.addListener(_onDesktopWarning);
    final guard = widget.closeRequestGuard;
    if (guard != null) {
      _previousCloseApproval = guard.approvalHandler;
      guard.approvalHandler = _approveCloseRequest;
    }
    unawaited(_loadOverviewComponentStatuses());
    if (widget.autoStart) unawaited(_autoStart());
  }

  @override
  void dispose() {
    final guard = widget.closeRequestGuard;
    if (guard != null) guard.approvalHandler = _previousCloseApproval;
    widget.desktopWarning?.removeListener(_onDesktopWarning);
    _lifecycleListener.dispose();
    widget.coordinator.maintenanceChanges.removeListener(_onMaintenanceChanged);
    _stateSubscription.cancel();
    _logSubscription.cancel();
    _logRunStartedSubscription.cancel();
    _logRunUpdatesSubscription.cancel();
    super.dispose();
  }

  void _onDesktopWarning() {
    if (mounted) setState(() {});
  }

  Future<void> _onThemeModeSelected(ThemeMode mode) async {
    setState(() => _themeMode = mode);
  }

  Future<void> _onLocaleSelected(Locale? locale) async {
    setState(() => _localeOverride = locale);
    if (widget.onLocaleChanged != null) {
      await widget.onLocaleChanged!(locale);
    }
  }

  Future<void> _autoStart() async {
    final maintenance = widget.coordinator.maintenanceOperation;
    if (widget.coordinator.logRecoveryError != null ||
        widget.coordinator.maintenanceRecoveryError != null ||
        maintenance != null) {
      return;
    }
    try {
      await widget.coordinator.start();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _page = _AppPage.overview;
        _error = error;
      });
    }
  }

  void _onState(RuntimeState state) {
    if (!mounted) return;
    _observations.observeState(state);
    setState(() {
      _state = state;
      if (state.status == RuntimeStatus.stopped ||
          state.status == RuntimeStatus.crashed) {
        _historyRefreshGeneration++;
      }
    });
    if (state.status == RuntimeStatus.running) unawaited(_loadInfo());
  }

  void _onLogRunStarted(RuntimeLogRunStarted event) {
    if (!mounted) return;
    setState(() {
      _logReader.beginRun(event.runId);
      _retainVisibleLogRunUpdates();
    });
  }

  void _onLogRunUpdate(RuntimeLogRunUpdate event) {
    if (!mounted) return;
    setState(() {
      _logRunUpdates[event.runId] = event;
      _retainVisibleLogRunUpdates();
    });
  }

  void _retainVisibleLogRunUpdates() {
    final retained = <String?>{_logReader.currentRunId, _logReader.frozenRunId};
    _logRunUpdates.removeWhere((id, _) => !retained.contains(id));
  }

  Future<void> _retryLogRecovery() async {
    if (_retryingLogRecovery) return;
    setState(() => _retryingLogRecovery = true);
    try {
      await widget.coordinator.retryLogRecovery();
    } on Object {
      // The coordinator retains the error for the persistent recovery banner.
    } finally {
      if (mounted) setState(() => _retryingLogRecovery = false);
    }
  }

  Future<void> _retryLogFinalization(String runId) async {
    if (_retryingLogFinalizations.contains(runId)) return;
    setState(() => _retryingLogFinalizations.add(runId));
    try {
      await widget.coordinator.retryLogFinalization(runId);
    } on Object {
      // The runtime publishes a fixed incomplete status and keeps retry ready.
    } finally {
      if (mounted) {
        setState(() => _retryingLogFinalizations.remove(runId));
      }
    }
  }

  void _onMaintenanceChanged() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      setState(() {});
      return;
    }
    if (_maintenanceRefreshQueued) return;
    _maintenanceRefreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maintenanceRefreshQueued = false;
      if (mounted) setState(() {});
    });
  }

  void _appendLog(RuntimeLog log) {
    if (!mounted) return;
    _observations.observeLog(log);
    setState(() => _logReader.append(log));
  }

  Future<void> _loadOverviewComponentStatuses() async {
    for (final kind in ComponentKind.values) {
      try {
        final status = await widget.coordinator.componentStatus(kind);
        if (!mounted) return;
        setState(() {
          _overviewComponentStatuses[kind] = status;
          _overviewComponentUnavailable.remove(kind);
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _overviewComponentUnavailable.add(kind));
      }
    }
  }

  Future<bool> _approveCloseRequest() async {
    final dialogContext = _settingsKey.currentContext;
    if (!mounted || dialogContext == null) return false;
    final l10n = AppLocalizations.of(dialogContext);
    if (l10n == null) return false;
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: Text(l10n.exitConfirmationTitle),
        content: Text(l10n.exitConfirmationMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.exitApp),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return false;

    final previous = _previousCloseApproval;
    if (previous != null && !await previous()) return false;
    if (_page != _AppPage.settings) return true;
    return _settingsKey.currentState?.requestLeave() ?? true;
  }

  Future<void> _retryDesktopExit() async {
    try {
      await widget.onRetryExit?.call();
    } catch (_) {}
  }

  Future<void> _selectPage(_AppPage page) async {
    if (_page == page) return;
    if (_page == _AppPage.settings &&
        !await (_settingsKey.currentState?.requestLeave() ?? true)) {
      return;
    }
    setState(() => _page = page);
    if (page == _AppPage.overview) {
      unawaited(_loadOverviewComponentStatuses());
    }
  }

  Future<void> _onLogSortChanged(LogSort sort) async {
    await _mutatePreferences((current) => current.copyWith(logSort: sort));
  }

  Future<bool> _mutatePreferences(
    _PreferenceMutation mutate, {
    bool Function()? canSave,
  }) {
    final operation = _preferenceQueue.then((_) async {
      if (canSave != null && !canSave()) return false;
      final previous = _savedPreferences;
      final next = mutate(previous);
      if (next == previous) return true;
      try {
        await widget.preferencesStore?.save(next);
      } catch (error) {
        if (mounted) setState(() => _error = error);
        rethrow;
      }
      if (!mounted) return true;
      setState(() {
        _savedPreferences = next;
        _logReader.updateLimit(next.recentLogLimit);
        _error = null;
      });
      final autostart = widget.onAutostartChanged;
      if (autostart != null && next.launchAtLogin != previous.launchAtLogin) {
        await _applyAutostart(next.launchAtLogin);
      }
      return true;
    });
    _preferenceQueue = operation.then<void>((_) {}).catchError((_) {});
    return operation;
  }

  Future<void> _applyAutostart(bool enabled) async {
    try {
      await widget.onAutostartChanged!(enabled);
      if (mounted) setState(() => _autostartApplyFailed = false);
    } on Object {
      if (mounted) setState(() => _autostartApplyFailed = true);
    }
  }

  Future<void> _retryAutostart() async {
    if (widget.onAutostartChanged == null) return;
    final operation = _preferenceQueue.then(
      (_) => _applyAutostart(_savedPreferences.launchAtLogin),
    );
    _preferenceQueue = operation.catchError((_) {});
    await operation;
  }

  Future<void> _loadInfo() async {
    try {
      final info = await widget.coordinator.runtime.info();
      if (mounted) setState(() => _info = info);
    } on StateError {
      // The runtime state holds the actionable failure.
    }
  }

  Future<void> _confirmServiceAction(
    BuildContext actionContext, {
    required bool restart,
  }) async {
    if (_actionInProgress) return;
    final l10n = AppLocalizations.of(actionContext)!;
    final confirmed = await showDialog<bool>(
      context: actionContext,
      builder: (context) => AlertDialog(
        title: Text(
          restart
              ? l10n.confirmRestartServiceTitle
              : l10n.confirmStopServiceTitle,
        ),
        content: Text(
          restart
              ? l10n.confirmRestartServiceMessage
              : l10n.confirmStopServiceMessage,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(restart ? l10n.restart : l10n.stop),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _run(restart ? widget.coordinator.restart : widget.coordinator.stop);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_actionInProgress) return;
    setState(() {
      _actionInProgress = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  Future<void> _applySavedConfiguration() async {
    if (_actionInProgress) {
      throw StateError(AppLocalizations.of(context)!.operationInProgress);
    }
    setState(() {
      _actionInProgress = true;
      _error = null;
    });
    try {
      await widget.coordinator.applyConfiguration();
    } catch (error) {
      if (mounted) setState(() => _error = error);
      rethrow;
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  Future<void> _startSavedConfiguration() async {
    if (_actionInProgress) {
      throw StateError(AppLocalizations.of(context)!.operationInProgress);
    }
    setState(() {
      _actionInProgress = true;
      _error = null;
    });
    try {
      await widget.coordinator.start();
    } catch (error) {
      if (mounted) setState(() => _error = error);
      rethrow;
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  Future<void> _saveRuntimeConfiguration(
    BackendEnvDocument environment,
    SubDockConfig configuration,
  ) async {
    if (_actionInProgress) {
      throw StateError(AppLocalizations.of(context)!.operationInProgress);
    }
    setState(() {
      _actionInProgress = true;
      _error = null;
    });
    try {
      await widget.coordinator.saveRuntimeConfiguration(
        environment,
        configuration,
      );
    } catch (error) {
      if (mounted) setState(() => _error = error);
      rethrow;
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  Future<bool> _saveDesktopPreferences(
    _PreferenceMutation mutate, {
    bool Function()? canSave,
  }) => _mutatePreferences(mutate, canSave: canSave);

  @override
  Widget build(BuildContext context) {
    return ShadApp.custom(
      theme: _lightShadTheme,
      darkTheme: _darkShadTheme,
      themeMode: _themeMode,
      appBuilder: (_) => MaterialApp(
        title: 'SubDock',
        locale: _localeOverride,
        // GlobalShadLocalizations is registered here because a custom ShadApp
        // host does not add it; without it shadcn_ui's own controls fall back
        // to English even when the app language is Chinese.
        localizationsDelegates: const [
          ...AppLocalizations.localizationsDelegates,
          GlobalShadLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: _buildTheme(
          Brightness.light,
          AppColors.light,
          AppTypography.light,
        ),
        darkTheme: _buildTheme(
          Brightness.dark,
          AppColors.dark,
          AppTypography.dark,
        ),
        themeMode: _themeMode,
        // ShadAppBuilder supplies the shared overlay hosts (toast and sonner)
        // above every page, so success feedback does not need a per-page host.
        builder: (context, child) => ShadAppBuilder(child: child!),
        home: Builder(builder: _buildHome),
      ),
    );
  }

  /// Maps the shared [AppColors] / [AppTypography] tokens onto shadcn_ui's
  /// theme so Material and Shad controls use the same visual tokens.
  ShadThemeData _buildShadTheme(
    Brightness brightness,
    AppColors colors,
    AppTypography typography,
  ) {
    final border = ShadBorder.all(color: colors.divider, width: 1);
    return ShadThemeData(
      brightness: brightness,
      radius: BorderRadius.circular(typography.radiusMd),
      colorScheme: ShadColorScheme(
        background: colors.surfaceLowest,
        foreground: colors.onSurface,
        card: colors.surfaceLow,
        cardForeground: colors.onSurface,
        popover: colors.surfaceLow,
        popoverForeground: colors.onSurface,
        primary: colors.accent,
        primaryForeground: colors.surfaceLowest,
        secondary: colors.surfaceHigh,
        secondaryForeground: colors.onSurface,
        muted: colors.surfaceLow,
        mutedForeground: colors.disabled,
        accent: colors.surfaceHigh,
        accentForeground: colors.onSurface,
        destructive: colors.error,
        destructiveForeground: colors.surfaceLowest,
        border: colors.divider,
        input: colors.divider,
        ring: colors.accent,
        selection: colors.surfaceHigh,
      ),
      textTheme: ShadTextTheme(
        family: uiTextFontFamily,
        h1: typography.titleLarge,
        h2: typography.titleMedium,
        h3: typography.titleSmall,
        p: typography.bodyMedium,
        small: typography.bodySmall,
        muted: typography.bodySmall.copyWith(color: colors.disabled),
      ),
      inputTheme: ShadInputTheme(
        style: typography.bodyMedium,
        decoration: ShadDecoration(border: border),
      ),
      selectTheme: ShadSelectTheme(decoration: ShadDecoration(border: border)),
    );
  }

  ThemeData _buildTheme(
    Brightness brightness,
    AppColors colors,
    AppTypography typography,
  ) {
    final radius = BorderRadius.circular(typography.radiusMd);
    final enabledBorder = OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: colors.divider),
    );
    final focusedBorder = OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: colors.accent),
    );
    final buttonShape = RoundedRectangleBorder(borderRadius: radius);

    return ThemeData(
      fontFamily: uiTextFontFamily,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.teal,
        brightness: brightness,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: colors.surfaceLowest,
      dividerTheme: DividerThemeData(color: colors.divider),
      cardTheme: CardThemeData(
        color: colors.surfaceLow,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(typography.radiusLg),
          side: BorderSide(color: colors.divider),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        border: enabledBorder,
        enabledBorder: enabledBorder,
        focusedBorder: focusedBorder,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: buttonShape),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: buttonShape),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: buttonShape),
      ),
      extensions: [colors, typography],
    );
  }

  Widget _buildHome(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<AppColors>()!;
    final destinations = <_ShellDestination>[
      _ShellDestination(
        icon: const Icon(Icons.dashboard_outlined),
        selectedIcon: const Icon(Icons.dashboard),
        label: l10n.overview,
      ),
      _ShellDestination(
        icon: const Icon(Icons.web_asset_outlined),
        selectedIcon: const Icon(Icons.web_asset),
        label: l10n.manage,
      ),
      _ShellDestination(
        icon: const Icon(Icons.subject_outlined),
        selectedIcon: const Icon(Icons.subject),
        label: l10n.logs,
      ),
      _ShellDestination(
        icon: const Icon(Icons.system_update_alt_outlined),
        selectedIcon: const Icon(Icons.system_update_alt),
        label: l10n.updates,
      ),
      _ShellDestination(
        icon: const Icon(Icons.settings_outlined),
        selectedIcon: const Icon(Icons.settings),
        label: l10n.settings,
      ),
      _ShellDestination(
        icon: const Icon(Icons.info_outline),
        selectedIcon: const Icon(Icons.info),
        label: l10n.aboutSubDock,
      ),
    ];
    final pages = <Widget>[
      _OverviewPage(
        state: _state,
        info: _info,
        error: _error,
        observations: _observations.snapshot(),
        endpoint: widget.coordinator.webUiApiUri.toString(),
        componentStatuses: _overviewComponentStatuses,
        unavailableComponents: _overviewComponentUnavailable,
        actionInProgress: _actionInProgress,
        onStart: () => _run(widget.coordinator.start),
        onStop: (BuildContext actionContext) =>
            unawaited(_confirmServiceAction(actionContext, restart: false)),
        onRestart: (BuildContext actionContext) =>
            unawaited(_confirmServiceAction(actionContext, restart: true)),
        onOpenLogs: () => unawaited(_selectPage(_AppPage.logs)),
      ),
      _ManagePage(
        state: _state,
        coordinator: widget.coordinator,
        appliedWebUiUri: widget.coordinator.appliedWebUiUri,
        appliedWebUiApiUri: widget.coordinator.appliedWebUiApiUri,
        runtimeRunId: _logReader.currentRunId,
        sessionIdentity:
            _logReader.currentRunId ??
            'revision-${widget.coordinator.appliedRevision}',
        error: _error,
        enabled: widget.enableWebView,
        onOpenExternalUri: widget.onOpenExternalUri ?? _launchExternalUri,
        webViewControllerFactory: widget.webViewControllerFactory,
        onRecover: () => _selectPage(
          widget.coordinator.canOpenWebUi
              ? _AppPage.overview
              : _AppPage.settings,
        ),
      ),
      _LogsPage(
        reader: _logReader,
        historyRefreshGeneration: _historyRefreshGeneration,
        historyMutationsEnabled: widget.coordinator.logRecoveryError == null,
        logStore: widget.coordinator.logStore,
        sort: _savedPreferences.logSort,
        maintenanceActivity: widget.coordinator.maintenanceActivity,
        logRunUpdates: Map.unmodifiable(_logRunUpdates),
        retryingLogFinalizations: Set.unmodifiable(_retryingLogFinalizations),
        onRetryLogFinalization: _retryLogFinalization,
        onSortChanged: _onLogSortChanged,
      ),
      _UpdatesPage(
        key: _updatesKey,
        active: _page == _AppPage.updates,
        state: _state,
        info: _info,
        coordinator: widget.coordinator,
        onOpenExternalUri: widget.onOpenExternalUri ?? _launchExternalUri,
      ),
      _SettingsPage(
        key: _settingsKey,
        environment: widget.coordinator.environment,
        configuration: widget.coordinator.configuration,
        configurationError: widget.coordinator.configurationError,
        coordinator: widget.coordinator,
        onSaveRuntimeConfiguration: _saveRuntimeConfiguration,
        onApplySavedConfiguration: _applySavedConfiguration,
        onStartSavedConfiguration: _startSavedConfiguration,
        savedPreferences: _savedPreferences,
        onSavePreferences: _saveDesktopPreferences,
        autostartApplyFailed: _autostartApplyFailed,
        autostartSupported: widget.onAutostartChanged == null
            ? null
            : const AutostartManager().isSupported,
        onRetryAutostart: _retryAutostart,
        onPreviewTheme: _onThemeModeSelected,
        onPreviewLocale: _onLocaleSelected,
        onResetConfiguration: () => _run(widget.coordinator.resetConfiguration),
        onChildStateChanged: (child) => setState(() => _settingsChild = child),
        onOpenExternalUri: widget.onOpenExternalUri ?? _launchExternalUri,
        aboutInfoLoader: widget.aboutInfoLoader,
      ),
      _ShellAboutPage(
        key: const ValueKey('about-page'),
        loader: widget.aboutInfoLoader,
        coordinator: widget.coordinator,
        runtimeState: _state,
        onOpenExternalUri: widget.onOpenExternalUri ?? _launchExternalUri,
      ),
    ];
    final body = Stack(
      children: [
        for (var index = 0; index < pages.length; index++)
          ExcludeFocus(
            excluding: index != _page.index,
            child: Offstage(
              key: ValueKey('page-${_AppPage.values[index].name}'),
              offstage: index != _page.index,
              child: pages[index],
            ),
          ),
      ],
    );
    final pageFrame = _PageFrame(
      title: destinations[_page.index].label,
      trailing: _page == _AppPage.updates
          ? OutlinedButton.icon(
              key: const ValueKey('updates-check-all'),
              onPressed: () => unawaited(
                _updatesKey.currentState?.checkAll() ?? Future<void>.value(),
              ),
              icon: const Icon(Icons.refresh),
              label: Text(l10n.checkForUpdates),
            )
          : null,
      child: body,
    );
    return Scaffold(
      body: Column(
        children: [
          if (widget.showCustomDesktopChrome)
            _DesktopChrome(
              title: l10n.appTitle,
              onStartDragging: widget.onStartDragging,
              onMinimize: widget.onMinimize,
              onToggleMaximize: widget.onToggleMaximize,
              onClose: widget.onClose,
              isMaximized: widget.isMaximized,
              minimizeTooltip: l10n.minimizeTooltip,
              maximizeTooltip: l10n.maximizeTooltip,
              restoreTooltip: l10n.restoreTooltip,
              closeTooltip: l10n.closeTooltip,
            ),
          if (widget.coordinator.logRecoveryError != null)
            MaterialBanner(
              key: const ValueKey('log-recovery-banner'),
              content: Text(l10n.logRecoveryFailed),
              actions: [
                TextButton(
                  onPressed: _retryingLogRecovery
                      ? null
                      : () => unawaited(_retryLogRecovery()),
                  child: Text(
                    _retryingLogRecovery ? l10n.retrying : l10n.retry,
                  ),
                ),
              ],
            ),
          if (widget.desktopWarning?.value case final warning?)
            Container(
              width: double.infinity,
              color: colors.errorSurface,
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _localizedError(l10n, warning),
                      style: TextStyle(color: colors.error),
                    ),
                  ),
                  if (warning is AppConfigError &&
                      warning.code == AppConfigErrorCode.exitFailed &&
                      widget.onRetryExit != null)
                    TextButton(
                      onPressed: () => unawaited(_retryDesktopExit()),
                      child: Text(l10n.retryExit),
                    ),
                ],
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final pageWithViewport = MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                  ),
                  child: pageFrame,
                );
                if (constraints.maxWidth < navigationBreakpoint) {
                  return Column(
                    children: [
                      Expanded(child: pageWithViewport),
                      if (!(_page == _AppPage.settings && _settingsChild))
                        _MobileNavigationBar(
                          selectedIndex: _page.index,
                          destinations: destinations,
                          onDestinationSelected: (index) =>
                              unawaited(_selectPage(_AppPage.values[index])),
                        ),
                    ],
                  );
                }
                return Row(
                  children: [
                    _DesktopSidebar(
                      key: const Key('desktop-sidebar'),
                      selectedIndex: _page.index,
                      destinations: destinations,
                      onDestinationSelected: (index) =>
                          unawaited(_selectPage(_AppPage.values[index])),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: pageWithViewport),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({
    super.key,
    required this.selectedIndex,
    required this.destinations,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final List<_ShellDestination> destinations;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    return SizedBox(
      width: 140,
      child: DecoratedBox(
        decoration: BoxDecoration(color: colors.surfaceLow),
        child: ListView.builder(
          padding: EdgeInsets.symmetric(
            vertical: typography.spacingSm,
            horizontal: typography.spacingS,
          ),
          itemCount: destinations.length,
          itemBuilder: (context, index) {
            final destination = destinations[index];
            final selected = index == selectedIndex;
            return Padding(
              padding: EdgeInsets.only(bottom: typography.spacingXs),
              child: Material(
                color: selected ? colors.surfaceHigh : Colors.transparent,
                borderRadius: BorderRadius.circular(typography.radiusLg),
                child: Semantics(
                  key: Key('nav-item-${_AppPage.values[index].name}'),
                  button: true,
                  selected: selected,
                  label: destination.label,
                  onTap: () => onDestinationSelected(index),
                  excludeSemantics: true,
                  child: InkWell(
                    excludeFromSemantics: true,
                    borderRadius: BorderRadius.circular(typography.radiusLg),
                    onTap: () => onDestinationSelected(index),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: typography.spacingS,
                        vertical: typography.spacingSm,
                      ),
                      child: Row(
                        children: [
                          IconTheme(
                            data: IconThemeData(
                              color: selected
                                  ? colors.accent
                                  : colors.onSurface,
                            ),
                            child: selected
                                ? destination.selectedIcon
                                : destination.icon,
                          ),
                          SizedBox(width: typography.spacingS),
                          Expanded(
                            child: DefaultTextStyle(
                              style: typography.bodyMedium.copyWith(
                                color: selected
                                    ? colors.accent
                                    : colors.onSurface,
                              ),
                              child: Text(
                                destination.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MobileNavigationBar extends StatelessWidget {
  const _MobileNavigationBar({
    required this.selectedIndex,
    required this.destinations,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final List<_ShellDestination> destinations;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    return SizedBox(
      key: const ValueKey('mobile-navigation'),
      height: 68,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceLow,
          border: Border(top: BorderSide(color: colors.divider)),
        ),
        child: Row(
          children: [
            for (var index = 0; index < destinations.length; index++)
              Expanded(
                child: _MobileNavigationDestination(
                  navigationKey: ValueKey(
                    'nav-item-${_AppPage.values[index].name}',
                  ),
                  destination: destinations[index],
                  selected: index == selectedIndex,
                  onTap: () => onDestinationSelected(index),
                  typography: typography,
                  colors: colors,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MobileNavigationDestination extends StatelessWidget {
  const _MobileNavigationDestination({
    required this.navigationKey,
    required this.destination,
    required this.selected,
    required this.onTap,
    required this.typography,
    required this.colors,
  });

  final Key navigationKey;
  final _ShellDestination destination;
  final bool selected;
  final VoidCallback onTap;
  final AppTypography typography;
  final AppColors colors;

  @override
  Widget build(BuildContext context) => Semantics(
    key: navigationKey,
    button: true,
    selected: selected,
    label: destination.label,
    onTap: onTap,
    excludeSemantics: true,
    child: InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconTheme(
            data: IconThemeData(
              color: selected ? colors.accent : colors.onSurface,
            ),
            child: selected ? destination.selectedIcon : destination.icon,
          ),
          SizedBox(height: typography.spacingXs),
          Text(
            destination.label,
            style: typography.labelSmall.copyWith(
              color: selected ? colors.accent : colors.onSurface,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    ),
  );
}

class _DesktopChrome extends StatelessWidget {
  const _DesktopChrome({
    required this.title,
    required this.onStartDragging,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onClose,
    required this.isMaximized,
    required this.minimizeTooltip,
    required this.maximizeTooltip,
    required this.restoreTooltip,
    required this.closeTooltip,
  });
  final String title,
      minimizeTooltip,
      maximizeTooltip,
      restoreTooltip,
      closeTooltip;
  final Future<void> Function()? onStartDragging,
      onMinimize,
      onToggleMaximize,
      onClose;
  final ValueListenable<bool>? isMaximized;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    return SizedBox(
      key: const Key('desktop-chrome'),
      height: 44,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceLow,
          border: Border(bottom: BorderSide(color: colors.divider)),
        ),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                key: const ValueKey('titlebar-drag-area'),
                behavior: HitTestBehavior.translucent,
                onDoubleTap:
                    onToggleMaximize == null ||
                        !(Platform.isLinux || Platform.isWindows)
                    ? null
                    : () => unawaited(onToggleMaximize!()),
                onPanStart: onStartDragging == null
                    ? null
                    : (_) => unawaited(onStartDragging!()),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: typography.spacingS,
                    ),
                    child: Text(title, style: typography.titleSmall),
                  ),
                ),
              ),
            ),
            if (onMinimize != null)
              IconButton(
                tooltip: minimizeTooltip,
                onPressed: () => unawaited(onMinimize!()),
                icon: const Icon(Icons.minimize),
              ),
            if (onToggleMaximize != null)
              ValueListenableBuilder<bool>(
                valueListenable: isMaximized ?? _notMaximized,
                builder: (context, maximized, child) => IconButton(
                  tooltip: maximized ? restoreTooltip : maximizeTooltip,
                  onPressed: () => unawaited(onToggleMaximize!()),
                  icon: Icon(maximized ? Icons.filter_none : Icons.crop_square),
                ),
              ),
            if (onClose != null)
              IconButton(
                tooltip: closeTooltip,
                onPressed: () => unawaited(onClose!()),
                icon: const Icon(Icons.close),
              ),
          ],
        ),
      ),
    );
  }
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({required this.title, this.trailing, required this.child});
  final String title;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _PageHeader(title: title, trailing: trailing),
      Expanded(child: child),
    ],
  );
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.title, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final compact = MediaQuery.sizeOf(context).width < navigationBreakpoint;
    return Semantics(
      header: true,
      child: Container(
        key: const Key('page-title'),
        height: compact ? 56 : 64,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? typography.spacingMd : typography.spacingLg,
        ),
        decoration: BoxDecoration(
          color: compact ? colors.surfaceLow : colors.surfaceLowest,
          border: Border(bottom: BorderSide(color: colors.divider)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: compact
                    ? typography.titleLarge.copyWith(fontSize: 20)
                    : typography.titleLarge,
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _SurfacePanel extends StatelessWidget {
  const _SurfacePanel({
    super.key,
    required this.child,
    this.padding,
    this.radius,
    this.borderColor,
    this.clipBehavior = Clip.hardEdge,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double? radius;
  final Color? borderColor;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    return Material(
      color: colors.surfaceLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius ?? typography.radiusLg),
        side: BorderSide(color: borderColor ?? colors.divider),
      ),
      clipBehavior: clipBehavior,
      child: Padding(
        padding: padding ?? EdgeInsets.all(typography.spacingMd),
        child: child,
      ),
    );
  }
}

/// Localizes an environment issue produced by the parse/validate layers.
String _localizedIssue(AppLocalizations l10n, BackendEnvIssue issue) =>
    switch (issue.code) {
      BackendEnvIssueCode.missingPair => l10n.envIssueMissingPair,
      BackendEnvIssueCode.invalidKey => l10n.envIssueInvalidKey(issue.key!),
      BackendEnvIssueCode.duplicateKey => l10n.envIssueDuplicateKey(issue.key!),
      BackendEnvIssueCode.reservedKey => l10n.envIssueReservedKey(issue.key!),
      BackendEnvIssueCode.portRange => l10n.envIssuePortRange,
      BackendEnvIssueCode.mergeBool => l10n.envIssueMergeBool,
      BackendEnvIssueCode.pathPrefix => l10n.envIssuePathPrefix,
      BackendEnvIssueCode.corsOrigin => l10n.envIssueCorsOrigin(issue.origin!),
    };

/// Localizes a config error raised by the parse/validate layers.
String _localizedConfigError(AppLocalizations l10n, AppConfigError error) {
  return switch (error.code) {
    AppConfigErrorCode.unsupportedVersion => l10n.configErrorUnsupportedVersion,
    AppConfigErrorCode.emptyHost => l10n.configErrorNotEmpty(error.key!),
    AppConfigErrorCode.notAnObject => l10n.configErrorNotAnObject(error.name!),
    AppConfigErrorCode.invalidFieldName => l10n.configErrorInvalidFieldName(
      error.name!,
    ),
    AppConfigErrorCode.unknownField => l10n.configErrorUnknownField(
      error.field!,
    ),
    AppConfigErrorCode.stringWithNewline => l10n.configErrorStringWithNewline(
      error.key!,
    ),
    AppConfigErrorCode.mustBeBoolean => l10n.configErrorNotBoolean(error.key!),
    AppConfigErrorCode.portRange => l10n.configErrorPortRange(error.key!),
    AppConfigErrorCode.pathPrefix => l10n.configErrorPathPrefix(error.key!),
    AppConfigErrorCode.corsOrigin => l10n.configErrorCorsOrigin(error.origin!),
    AppConfigErrorCode.readFailed => l10n.configErrorReadFailed(error.detail!),
    AppConfigErrorCode.pendingMetadataInvalid =>
      l10n.configErrorPendingMetadataInvalid,
    AppConfigErrorCode.metadataInvalid => l10n.configErrorMetadataInvalid,
    AppConfigErrorCode.configStoreDisabled => l10n.configErrorStoreDisabled,
    AppConfigErrorCode.updaterDisabled => l10n.configErrorUpdaterDisabled,
    AppConfigErrorCode.componentRecoveryFailed =>
      l10n.configErrorRecoveryFailed(error.detail ?? ''),
    AppConfigErrorCode.environmentInvalid => _localizedIssue(
      l10n,
      error.issue!,
    ),
    AppConfigErrorCode.trayUnavailable => l10n.configErrorTrayUnavailable,
    AppConfigErrorCode.exitFailed => l10n.configErrorExitFailed(
      error.detail ?? '',
    ),
  };
}

/// Renders any shell error as a localized message when it is a coded domain
/// error, otherwise falls back to the exception's own text.
String _localizedError(AppLocalizations l10n, Object? error) {
  if (error is BackendEnvIssue) return _localizedIssue(l10n, error);
  if (error is AppConfigError) return _localizedConfigError(l10n, error);
  return '$error';
}

/// The language-autonym label for a supported locale code. These are not
/// translated (Chinese stays "中文" even in the English UI).
String _languageLabel(String language) => switch (language) {
  'zh' => '中文',
  'en' => 'English',
  _ => language,
};

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_all/webview_all.dart';

import '../l10n/generated/app_localizations.dart';
import '../runtime/backend_runtime.dart';
import '../runtime/runtime_log_store.dart';
import '../settings/backend_env.dart';
import '../settings/config_error.dart';
import '../settings/desktop_preferences.dart';
import '../settings/desktop_preferences_store.dart';
import '../settings/locale_preference_store.dart';
import '../settings/subdock_config.dart';
import '../update/component_metadata_store.dart';
import '../update/component_update_checker.dart';
import '../update/component_update_service.dart';
import 'app_colors.dart';
import 'app_coordinator.dart';
import 'app_typography.dart';
import 'close_request_guard.dart';

const navigationBreakpoint = 600.0;
final _notMaximized = ValueNotifier<bool>(false);

enum _AppPage { overview, manage, logs, settings }

enum _SettingsSection { home, subDockConfig, backendConfig, advancedEnv }

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
    this.isMaximized,
    this.closeRequestGuard,
    this.onStartDragging,
    this.preferences,
    this.preferencesStore,
    this.onLocaleChanged,
    this.locale,
  });

  final AppCoordinator coordinator;
  final bool autoStart;
  final bool enableWebView;
  final Object? initialError;
  final ValueListenable<Object?>? desktopWarning;
  final Future<void> Function()? onMinimize;
  final Future<void> Function()? onToggleMaximize;
  final Future<void> Function()? onClose;
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

  @override
  State<SubDockApp> createState() => _SubDockAppState();
}

class _SubDockAppState extends State<SubDockApp> {
  final _settingsKey = GlobalKey<_SettingsPageState>();
  late final StreamSubscription<RuntimeState> _stateSubscription;
  late final StreamSubscription<RuntimeLog> _logSubscription;
  late final AppLifecycleListener _lifecycleListener;
  late RuntimeState _state;
  final _logs = <RuntimeLog>[];
  _AppPage _page = _AppPage.overview;
  final _overviewComponentStatuses = <ComponentKind, ComponentVersionStatus>{};
  final _overviewComponentUnavailable = <ComponentKind>{};
  BackendInfo? _info;
  Object? _error;
  var _actionInProgress = false;
  late ThemeMode _themeMode;
  Locale? _localeOverride;
  late DesktopPreferences _savedPreferences;
  late int _currentRunLogLimit;
  var _logsEntryGeneration = 0;
  var _historyRefreshGeneration = 0;
  var _settingsChild = false;
  CloseApprovalHandler? _previousCloseApproval;

  @override
  void initState() {
    super.initState();
    final preferences = widget.preferences ?? DesktopPreferences.defaults;
    _savedPreferences = preferences;
    _currentRunLogLimit = preferences.recentLogLimit;
    _themeMode = preferences.themeMode;
    _localeOverride = preferences.locale == null
        ? widget.locale
        : Locale(preferences.locale!);
    _state = widget.coordinator.runtime.currentState;
    _error = widget.initialError;
    if (_error != null) _page = _AppPage.overview;
    _stateSubscription = widget.coordinator.runtime.state.listen(_onState);
    _logSubscription = widget.coordinator.runtime.logs.listen(_appendLog);
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
    _stateSubscription.cancel();
    _logSubscription.cancel();
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
    setState(() {
      _state = state;
      if (state.status == RuntimeStatus.starting) {
        _currentRunLogLimit = _savedPreferences.recentLogLimit;
        _logs.clear();
      } else if (state.status == RuntimeStatus.stopped ||
          state.status == RuntimeStatus.crashed) {
        _logs.clear();
        _historyRefreshGeneration++;
      }
    });
    if (state.status == RuntimeStatus.running) unawaited(_loadInfo());
  }

  void _appendLog(RuntimeLog log) {
    if (!mounted) return;
    setState(() {
      _logs.add(log);
      if (_logs.length > _currentRunLogLimit) {
        _logs.removeRange(0, _logs.length - _currentRunLogLimit);
      }
    });
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
    final previous = _previousCloseApproval;
    if (previous != null && !await previous()) return false;
    if (_page != _AppPage.settings) return true;
    return _settingsKey.currentState?.requestLeave() ?? true;
  }

  Future<void> _selectPage(_AppPage page) async {
    if (_page == page) return;
    if (_page == _AppPage.settings &&
        !await (_settingsKey.currentState?.requestLeave() ?? true)) {
      return;
    }
    if (_page != _AppPage.logs && page == _AppPage.logs) {
      _logsEntryGeneration++;
    }
    setState(() => _page = page);
    if (page == _AppPage.overview) {
      unawaited(_loadOverviewComponentStatuses());
    }
  }

  Future<void> _onLogSortChanged(LogSort sort) async {
    final next = _savedPreferences.copyWith(logSort: sort);
    if (widget.preferencesStore != null) {
      try {
        await widget.preferencesStore!.save(next);
      } catch (error) {
        if (mounted) setState(() => _error = error);
        return;
      }
    }
    if (mounted) setState(() => _savedPreferences = next);
  }

  Future<void> _loadInfo() async {
    try {
      final info = await widget.coordinator.runtime.info();
      if (mounted) setState(() => _info = info);
    } on StateError {
      // The runtime state holds the actionable failure.
    }
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

  Future<void> _saveEnvironment(BackendEnvDocument document) async {
    final l10n = AppLocalizations.of(context)!;
    if (_actionInProgress) throw StateError(l10n.operationInProgress);
    setState(() {
      _actionInProgress = true;
      _error = null;
    });
    try {
      await widget.coordinator.saveEnvironment(document);
    } catch (error) {
      if (mounted) setState(() => _error = error);
      rethrow;
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  Future<void> _saveConfiguration(SubDockConfig configuration) async {
    if (_actionInProgress) {
      throw StateError('operation already in progress');
    }
    setState(() {
      _actionInProgress = true;
      _error = null;
    });
    try {
      await widget.coordinator.saveConfiguration(configuration);
    } catch (error) {
      if (mounted) setState(() => _error = error);
      rethrow;
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  Future<void> _saveDesktopPreferences(DesktopPreferences preferences) async {
    try {
      await widget.preferencesStore?.save(preferences);
    } catch (error) {
      if (mounted) setState(() => _error = error);
      rethrow;
    }
    if (!mounted) return;
    setState(() {
      _savedPreferences = preferences;
      _themeMode = preferences.themeMode;
      _localeOverride = preferences.locale == null
          ? null
          : Locale(preferences.locale!);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SubDock',
      locale: _localeOverride,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
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
      home: Builder(builder: _buildHome),
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
          borderRadius: radius,
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
        icon: const Icon(Icons.settings_outlined),
        selectedIcon: const Icon(Icons.settings),
        label: l10n.settings,
      ),
    ];
    final pages = <Widget>[
      _OverviewPage(
        state: _state,
        info: _info,
        error: _error,
        componentStatuses: _overviewComponentStatuses,
        unavailableComponents: _overviewComponentUnavailable,
        actionInProgress: _actionInProgress,
        onStart: () => _run(widget.coordinator.start),
        onStop: () => _run(widget.coordinator.stop),
        onRestart: () => _run(widget.coordinator.restart),
      ),
      _ManagePage(
        state: _state,
        coordinator: widget.coordinator,
        error: _error,
        enabled: widget.enableWebView,
        onRecover: () => _selectPage(
          widget.coordinator.canOpenWebUi
              ? _AppPage.overview
              : _AppPage.settings,
        ),
      ),
      _LogsPage(
        logs: _logs,
        historyRefreshGeneration: _historyRefreshGeneration,
        logStore: widget.coordinator.logStore,
        sort: _savedPreferences.logSort,
        entryGeneration: _logsEntryGeneration,
        onSortChanged: _onLogSortChanged,
      ),
      _SettingsPage(
        key: _settingsKey,
        environment: widget.coordinator.environment,
        configuration: widget.coordinator.configuration,
        configurationError: widget.coordinator.configurationError,
        coordinator: widget.coordinator,
        onSaveConfiguration: _saveConfiguration,
        onSaveEnvironment: _saveEnvironment,
        savedPreferences: _savedPreferences,
        onSavePreferences: _saveDesktopPreferences,
        onPreviewTheme: _onThemeModeSelected,
        onPreviewLocale: _onLocaleSelected,
        onResetConfiguration: () => _run(widget.coordinator.resetConfiguration),
        onChildStateChanged: (child) => setState(() => _settingsChild = child),
      ),
    ];
    final body = Stack(
      children: [
        for (var index = 0; index < pages.length; index++)
          Offstage(
            key: ValueKey('page-${_AppPage.values[index].name}'),
            offstage: index != _page.index,
            child: pages[index],
          ),
      ],
    );
    final pageFrame = _PageFrame(
      title: destinations[_page.index].label,
      child: body,
    );
    return Scaffold(
      body: Column(
        children: [
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
          if (widget.desktopWarning?.value case final warning?)
            Container(
              width: double.infinity,
              color: colors.errorSurface,
              padding: const EdgeInsets.all(12),
              child: Text(
                _localizedError(l10n, warning),
                style: TextStyle(color: colors.error),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < navigationBreakpoint) {
                  return Column(
                    children: [
                      Expanded(child: pageFrame),
                      if (!(_page == _AppPage.settings && _settingsChild))
                        NavigationBar(
                          selectedIndex: _page.index,
                          onDestinationSelected: (index) =>
                              unawaited(_selectPage(_AppPage.values[index])),
                          destinations: destinations
                              .map(
                                (destination) => NavigationDestination(
                                  icon: destination.icon,
                                  selectedIcon: destination.selectedIcon,
                                  label: destination.label,
                                ),
                              )
                              .toList(growable: false),
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
                    Expanded(child: pageFrame),
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
      child: ListView.builder(
        padding: EdgeInsets.all(typography.spacingSm),
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
                excludeSemantics: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(typography.radiusLg),
                  onTap: () => onDestinationSelected(index),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: typography.spacingSm,
                    ),
                    child: Row(
                      children: [
                        IconTheme(
                          data: IconThemeData(
                            color: selected ? colors.accent : colors.onSurface,
                          ),
                          child: selected
                              ? destination.selectedIcon
                              : destination.icon,
                        ),
                        SizedBox(width: typography.spacingXs),
                        Expanded(
                          child: DefaultTextStyle(
                            style: typography.labelSmall.copyWith(
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
    );
  }
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
      height: 40,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceLowest,
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
                  icon: Icon(maximized ? Icons.filter_none : Icons.maximize),
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
  const _PageFrame({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _PageHeader(title: title),
      Expanded(child: child),
    ],
  );
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    return Semantics(
      header: true,
      child: Container(
        key: const Key('page-title'),
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: typography.spacingLg,
          vertical: typography.spacingMd,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceLowest,
          border: Border(bottom: BorderSide(color: colors.divider)),
        ),
        child: Text(title, style: typography.titleLarge),
      ),
    );
  }
}

class _ManagePage extends StatefulWidget {
  const _ManagePage({
    required this.state,
    required this.coordinator,
    required this.error,
    required this.enabled,
    required this.onRecover,
  });

  final RuntimeState state;
  final AppCoordinator coordinator;
  final Object? error;
  final bool enabled;
  final VoidCallback onRecover;

  @override
  State<_ManagePage> createState() => _ManagePageState();
}

class _ManagePageState extends State<_ManagePage> {
  static const _maxBlobBytes = 16 * 1024 * 1024;
  static final _webView2DownloadUri = Uri.parse(
    'https://developer.microsoft.com/microsoft-edge/webview2/',
  );

  WebViewController? _controller;
  String? _webViewError;
  var _missingWebView2 = false;

  bool get _ready =>
      widget.state.status == RuntimeStatus.running &&
      widget.enabled &&
      widget.coordinator.canOpenWebUi;

  @override
  void initState() {
    super.initState();
    unawaited(_ensureController());
  }

  @override
  void didUpdateWidget(covariant _ManagePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) {
      _controller = null;
      return;
    }
    unawaited(_ensureController());
  }

  Future<void> _ensureController() async {
    if (!_ready || _controller != null) return;
    final controller = WebViewController();
    setState(() {
      _controller = controller;
      _webViewError = null;
      _missingWebView2 = false;
    });
    try {
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(
        NavigationDelegate(onNavigationRequest: _onNavigationRequest),
      );
      await controller.addJavaScriptChannel(
        'SubDockBlob',
        onMessageReceived: (message) => unawaited(_saveBlob(message.message)),
      );
      await controller.addUserScript(
        const WebViewUserScript(source: _blobDownloadBridge),
      );
      await controller.loadRequest(widget.coordinator.webUiUri);
    } catch (error) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        setState(() {
          _missingWebView2 = _isMissingWebView2(error);
          _webViewError = _missingWebView2 ? l10n.webView2Missing : '$error';
        });
      }
    }
  }

  Future<NavigationDecision> _onNavigationRequest(
    NavigationRequest request,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;
    if (_sameOrigin(uri, widget.coordinator.webUiUri)) {
      if (_isDownloadUri(uri)) {
        unawaited(_saveHttpDownload(uri));
        return NavigationDecision.prevent;
      }
      return NavigationDecision.navigate;
    }
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      try {
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          throw StateError(l10n.openSystemBrowserFailed(uri.toString()));
        }
      } catch (error) {
        if (mounted) setState(() => _webViewError = '$error');
      }
    }
    return NavigationDecision.prevent;
  }

  Future<void> _saveHttpDownload(Uri uri) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final location = await getSaveLocation(
        suggestedName: _downloadName(uri.pathSegments.lastOrNull),
      );
      if (location == null) return;

      final client = HttpClient();
      try {
        final response = await (await client.getUrl(uri)).close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException(
            l10n.downloadFailedHttp(response.statusCode),
            uri: uri,
          );
        }
        final sink = File(location.path).openWrite();
        try {
          await response.forEach(sink.add);
          await sink.flush();
        } finally {
          await sink.close();
        }
      } finally {
        client.close(force: true);
      }
    } catch (error) {
      if (mounted) setState(() => _webViewError = '$error');
    }
  }

  Future<void> _saveBlob(String message) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final payload = jsonDecode(message);
      if (payload is! Map<String, dynamic>) {
        throw FormatException(l10n.blobExportInvalid);
      }
      if (payload['error'] case final String error) throw StateError(error);
      final data = payload['data'];
      if (data is! String || data.length > (_maxBlobBytes * 4 ~/ 3) + 4) {
        throw FormatException(l10n.blobExportTooLarge);
      }
      final bytes = base64Decode(data);
      if (bytes.length > _maxBlobBytes) {
        throw FormatException(l10n.blobExportTooLarge);
      }
      final location = await getSaveLocation(
        suggestedName: _downloadName(payload['name'] as String?),
      );
      if (location == null) return;
      await File(location.path).writeAsBytes(bytes, flush: true);
    } catch (error) {
      if (mounted) setState(() => _webViewError = '$error');
    }
  }

  static bool _sameOrigin(Uri first, Uri second) =>
      first.scheme == second.scheme &&
      first.host == second.host &&
      first.port == second.port;

  bool _isMissingWebView2(Object error) {
    if (!Platform.isWindows) return false;
    final message = '$error'.toLowerCase();
    return message.contains('webview2') || message.contains('edge runtime');
  }

  Future<void> _openWebView2Download() async {
    final l10n = AppLocalizations.of(context)!;
    if (!await launchUrl(
      _webView2DownloadUri,
      mode: LaunchMode.externalApplication,
    )) {
      if (mounted) {
        setState(() => _webViewError = l10n.openWebView2DownloadFailed);
      }
    }
  }

  Future<void> _reloadCurrentPage() async {
    try {
      await _controller!.reload();
    } catch (error) {
      if (mounted) setState(() => _webViewError = '$error');
    }
  }

  Future<void> _openCurrentPage() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final value = await _controller!.currentUrl();
      final uri = value == null ? null : Uri.tryParse(value);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        throw StateError(l10n.webViewCurrentUrlUnavailable);
      }
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError(l10n.openSystemBrowserFailed(uri.toString()));
      }
    } catch (error) {
      if (mounted) setState(() => _webViewError = '$error');
    }
  }

  bool _isDownloadUri(Uri uri) {
    final path = widget.coordinator.webUiApiUri.path;
    final prefix = path == '/' ? '' : path.replaceFirst(RegExp(r'/$'), '');
    return uri.path == '$prefix/download' ||
        uri.path.startsWith('$prefix/download/');
  }

  static String _downloadName(String? value) {
    final name = (value == null || value.isEmpty ? 'download' : value)
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return name.isEmpty || name == '.' || name == '..' ? 'download' : name;
  }

  static const _blobDownloadBridge = r'''(() => {
  document.addEventListener('click', async event => {
    if (!(event.target instanceof Element)) return;
    const link = event.target.closest('a[download]');
    if (!link || !link.href.startsWith('blob:')) return;
    event.preventDefault();
    try {
      const blob = await (await fetch(link.href)).blob();
      if (blob.size > 16 * 1024 * 1024) {
        SubDockBlob.postMessage(JSON.stringify({error: 'Blob export exceeds 16 MiB'}));
        return;
      }
      const reader = new FileReader();
      reader.onload = () => SubDockBlob.postMessage(JSON.stringify({
        name: link.download || 'download',
        data: String(reader.result).split(',', 2)[1],
      }));
      reader.readAsDataURL(blob);
    } catch (error) {
      SubDockBlob.postMessage(JSON.stringify({error: String(error)}));
    }
  }, true);
})();''';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    if (widget.state.status == RuntimeStatus.starting ||
        widget.state.status == RuntimeStatus.stopping) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: EdgeInsets.all(typography.spacingLg),
            child: _SurfacePanel(
              key: const ValueKey('manage-transition'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  SizedBox(height: typography.spacingMd),
                  Text(
                    widget.state.status == RuntimeStatus.starting
                        ? l10n.starting
                        : l10n.stopping,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (!_ready || _controller == null) {
      final issues = widget.coordinator.environmentIssues;
      final reason = issues.isNotEmpty
          ? _localizedIssue(l10n, issues.first)
          : widget.error == null
          ? widget.state.message ?? l10n.backendNotRunning
          : _localizedError(l10n, widget.error);
      return Center(
        child: Padding(
          padding: EdgeInsets.all(typography.spacingLg),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: _SurfacePanel(
              key: const ValueKey('manage-recovery'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.web_asset_off_outlined, size: 48),
                  SizedBox(height: typography.spacingSm),
                  Text(reason, textAlign: TextAlign.center),
                  SizedBox(height: typography.spacingSm),
                  FilledButton(
                    onPressed: widget.onRecover,
                    child: Text(
                      widget.coordinator.canOpenWebUi
                          ? l10n.viewOverview
                          : l10n.fixConfiguration,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: Column(
            children: [
              Material(
                color: colors.surfaceLow,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: l10n.refresh,
                      onPressed: () => unawaited(_reloadCurrentPage()),
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      tooltip: l10n.openInSystemBrowser,
                      onPressed: () => unawaited(_openCurrentPage()),
                      icon: const Icon(Icons.open_in_browser),
                    ),
                  ],
                ),
              ),
              Expanded(child: WebViewWidget(controller: _controller!)),
            ],
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: colors.divider),
              ),
            ),
          ),
        ),
        if (_webViewError != null)
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: EdgeInsets.all(typography.spacingSm),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: _SurfacePanel(
                  key: const ValueKey('manage-webview-error'),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _webViewError!,
                        style: TextStyle(color: colors.error),
                      ),
                      if (_missingWebView2)
                        TextButton(
                          onPressed: () => unawaited(_openWebView2Download()),
                          child: Text(l10n.openWebView2DownloadPage),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SurfacePanel extends StatelessWidget {
  const _SurfacePanel({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

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
      child: Padding(
        padding: padding ?? EdgeInsets.all(typography.spacingMd),
        child: child,
      ),
    );
  }
}

class _RuntimeInfoItem extends StatelessWidget {
  const _RuntimeInfoItem({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final typography = Theme.of(context).extension<AppTypography>()!;
    return SizedBox(
      width: 160,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: typography.labelSmall),
          Text(value ?? '-', style: typography.bodyMedium),
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
      HttpMetaStatus.disabled => l10n.httpMetaDisabled,
      HttpMetaStatus.unavailable =>
        state.httpMetaMessage == null
            ? l10n.httpMetaUnavailable
            : l10n.httpMetaUnavailableDetail(state.httpMetaMessage!),
      HttpMetaStatus.starting => l10n.httpMetaStarting,
      HttpMetaStatus.running => l10n.httpMetaRunning(
        state.httpMetaPort ?? '-',
        state.httpMetaVersion ?? '-',
      ),
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
    final backendPanel = _SurfacePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.circle, size: 12, color: statusColor),
              SizedBox(width: typography.spacingS),
              Text(label, style: typography.titleLarge),
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
    final httpMetaPanel = _SurfacePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('HTTP-META', style: typography.titleMedium),
          SizedBox(height: typography.spacingS),
          Text(httpMetaLabel, style: TextStyle(color: httpMetaColor)),
        ],
      ),
    );
    final componentStatusPanel = _SurfacePanel(
      key: const ValueKey('overview-component-status'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.componentStatusHeading, style: typography.titleMedium),
          SizedBox(height: typography.spacingS),
          for (final kind in ComponentKind.values)
            Text(
              '${kind.name}: ${unavailableComponents.contains(kind)
                  ? l10n.unavailable
                  : componentStatuses[kind] == null
                  ? l10n.componentReadingVersion
                  : '${l10n.componentCurrent(componentStatuses[kind]!.current)}; '
                        '${componentStatuses[kind]!.previous == null ? l10n.rollbackUnavailable : '${l10n.componentPrevious(componentStatuses[kind]!.previous!)}; '
                                  '${l10n.rollbackAvailable}'}'}',
            ),
        ],
      ),
    );
    return ListView(
      padding: EdgeInsets.all(typography.spacingLg),
      children: [
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth < 760
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    backendPanel,
                    SizedBox(height: typography.spacingLg),
                    httpMetaPanel,
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 2, child: backendPanel),
                    SizedBox(width: typography.spacingLg),
                    Expanded(child: httpMetaPanel),
                  ],
                ),
        ),
        SizedBox(height: typography.spacingLg),
        _SurfacePanel(
          child: Wrap(
            spacing: typography.spacingLg,
            runSpacing: typography.spacingMd,
            children: [
              _RuntimeInfoItem(label: 'Node', value: info?.nodeVersion),
              _RuntimeInfoItem(label: 'Backend', value: info?.backendVersion),
              _RuntimeInfoItem(
                label: 'Port',
                value: info == null ? null : '${info!.port}',
              ),
            ],
          ),
        ),
        SizedBox(height: typography.spacingLg),
        componentStatusPanel,
      ],
    );
  }
}

enum _LogLevel { debug, info, warning, error }

enum _LogsMode { current, history }

class _ClassifiedLog {
  const _ClassifiedLog(this.log, this.source, this.level);

  final RuntimeLog log;
  final String source;
  final _LogLevel level;
}

_ClassifiedLog _classifyLog(RuntimeLog log) {
  final source = switch (log.source) {
    RuntimeLogSource.stdout || RuntimeLogSource.stderr => 'Backend',
    RuntimeLogSource.httpMetaStdout ||
    RuntimeLogSource.httpMetaStderr => 'HTTP-META',
  };
  final token = RegExp(
    r'(?<![A-Za-z0-9_])(trace|debug|info|warn|warning|error|fatal|panic)(?![A-Za-z0-9_])',
    caseSensitive: false,
  ).firstMatch(log.message)?.group(1)?.toLowerCase();
  final level = switch (token) {
    'trace' || 'debug' => _LogLevel.debug,
    'info' => _LogLevel.info,
    'warn' || 'warning' => _LogLevel.warning,
    'error' || 'fatal' || 'panic' => _LogLevel.error,
    _
        when log.source == RuntimeLogSource.stderr ||
            log.source == RuntimeLogSource.httpMetaStderr =>
      _LogLevel.error,
    _ => _LogLevel.info,
  };
  return _ClassifiedLog(log, source, level);
}

String _formatLog(_ClassifiedLog item, AppLocalizations l10n) {
  final now = DateTime.now();
  final local = item.log.timestamp.toLocal();
  final sameDay =
      now.year == local.year &&
      now.month == local.month &&
      now.day == local.day;
  final time = sameDay
      ? '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}'
      : '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  final level = switch (item.level) {
    _LogLevel.debug => l10n.logLevelDebug,
    _LogLevel.info => l10n.logLevelInfo,
    _LogLevel.warning => l10n.logLevelWarning,
    _LogLevel.error => l10n.logLevelError,
  };
  return '$time [${item.source}] [$level] ${item.log.message}';
}

class _LogsPage extends StatefulWidget {
  const _LogsPage({
    required this.logs,
    required this.historyRefreshGeneration,
    required this.logStore,
    required this.sort,
    required this.entryGeneration,
    required this.onSortChanged,
  });

  final List<RuntimeLog> logs;
  final int historyRefreshGeneration;
  final RuntimeLogStore? logStore;
  final LogSort sort;
  final int entryGeneration;
  final Future<void> Function(LogSort) onSortChanged;

  @override
  State<_LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<_LogsPage> {
  final _query = TextEditingController();
  final _historyScroll = ScrollController();
  var _sources = <String>{'Backend', 'HTTP-META'};
  var _levels = Set<_LogLevel>.of(_LogLevel.values);
  var _mode = _LogsMode.current;
  var _historyListLoading = false;
  Object? _historyListError;
  var _historyDetailLoading = false;
  Object? _historyDetailError;
  List<RuntimeLogRun> _historyRuns = const [];
  RuntimeLogRun? _selectedRun;
  List<RuntimeLog> _historyLogs = const [];
  var _historyPage = 0;
  var _historyHasNext = false;
  var _historyListGeneration = 0;
  var _historyGeneration = 0;
  var _hasRecentDeletion = false;

  @override
  void didUpdateWidget(covariant _LogsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entryGeneration != widget.entryGeneration) {
      _query.clear();
      _sources = {'Backend', 'HTTP-META'};
      _levels = Set<_LogLevel>.of(_LogLevel.values);
      _mode = _LogsMode.current;
      _selectedRun = null;
      _historyGeneration++;
      _historyDetailLoading = false;
      _historyLogs = const [];
      _historyDetailError = null;
    }
    if (oldWidget.sort != widget.sort && _selectedRun != null) {
      unawaited(_loadHistoryPage(_selectedRun!, page: 0));
    }
    if (oldWidget.historyRefreshGeneration != widget.historyRefreshGeneration &&
        _mode == _LogsMode.history) {
      unawaited(_loadHistoryRuns());
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _historyScroll.dispose();
    super.dispose();
  }

  Future<void> _loadHistoryRuns() async {
    final store = widget.logStore;
    if (store == null) return;
    final generation = ++_historyListGeneration;
    setState(() => _historyListLoading = true);
    try {
      final runs = await store.listRuns();
      if (!mounted || generation != _historyListGeneration) return;
      setState(() {
        _historyRuns = runs;
        _historyListError = null;
      });
    } catch (error) {
      if (mounted && generation == _historyListGeneration) {
        setState(() => _historyListError = error);
      }
    } finally {
      if (mounted && generation == _historyListGeneration) {
        setState(() => _historyListLoading = false);
      }
    }
  }

  Future<void> _loadHistoryPage(RuntimeLogRun run, {required int page}) async {
    final store = widget.logStore;
    if (store == null) return;
    final generation = ++_historyGeneration;
    setState(() {
      _selectedRun = run;
      _historyDetailLoading = true;
      _historyDetailError = null;
      _historyLogs = const [];
      _historyPage = page;
      _historyHasNext = false;
    });
    try {
      final pageLogs = <RuntimeLog>[];
      var matchingIndex = 0;
      await for (final log in store.readRunStream(
        run.id,
        reverse: widget.sort == LogSort.newestFirst,
      )) {
        final classified = _classifyLog(log);
        if (!_matchesLog(classified)) continue;
        if (matchingIndex++ < page * 200) continue;
        if (pageLogs.length < 201) pageLogs.add(log);
        if (pageLogs.length == 201) break;
      }
      if (!mounted || generation != _historyGeneration) return;
      setState(() {
        _historyPage = page;
        _historyHasNext = pageLogs.length > 200;
        _historyLogs = pageLogs.take(200).toList();
      });
    } catch (error) {
      if (mounted && generation == _historyGeneration) {
        setState(() => _historyDetailError = error);
      }
    } finally {
      if (mounted && generation == _historyGeneration) {
        setState(() => _historyDetailLoading = false);
      }
    }
  }

  Widget _buildHistoryList(AppLocalizations l10n) {
    if (_historyListLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_historyListError != null) {
      return Center(child: Text(l10n.historyLoadError));
    }
    if (_historyRuns.isEmpty && !_hasRecentDeletion) {
      return Center(child: Text(l10n.noHistory));
    }
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => unawaited(_clearHistory(l10n)),
            child: Text(l10n.clearHistory),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _historyScroll,
            itemCount: _historyRuns.length + (_hasRecentDeletion ? 1 : 0),
            itemBuilder: (context, index) {
              if (_hasRecentDeletion && index == 0) {
                return ListTile(
                  key: const ValueKey('recently-deleted'),
                  title: Text(l10n.recentlyDeleted),
                  trailing: TextButton(
                    onPressed: () => unawaited(_undoDeletion()),
                    child: Text(l10n.undo),
                  ),
                );
              }
              final run = _historyRuns[index - (_hasRecentDeletion ? 1 : 0)];
              return ListTile(
                key: ValueKey('history-run-${run.id}'),
                title: Text(_formatRunDate(run.start)),
                subtitle: Text(
                  '${_formatDuration(run)} · ${run.eventCount} ${l10n.logEvents}',
                ),
                trailing: IconButton(
                  tooltip: l10n.deleteRun,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => unawaited(_deleteRun(run, l10n)),
                ),
                onTap: () => unawaited(_loadHistoryPage(run, page: 0)),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _deleteRun(RuntimeLogRun run, AppLocalizations l10n) async {
    final store = widget.logStore;
    if (store == null) return;
    try {
      await store.deleteRun(run.id);
      if (mounted) setState(() => _hasRecentDeletion = true);
      await _loadHistoryRuns();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.recentlyDeleted),
            action: SnackBarAction(
              label: l10n.undo,
              onPressed: () => unawaited(_undoDeletion()),
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _historyListError = error);
    }
  }

  Future<void> _clearHistory(AppLocalizations l10n) async {
    final store = widget.logStore;
    if (store == null || _historyRuns.isEmpty) return;
    try {
      await store.clearHistory();
      if (mounted) setState(() => _hasRecentDeletion = true);
      await _loadHistoryRuns();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.recentlyDeleted),
            action: SnackBarAction(
              label: l10n.undo,
              onPressed: () => unawaited(_undoDeletion()),
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _historyListError = error);
    }
  }

  Future<void> _undoDeletion() async {
    final store = widget.logStore;
    if (store == null) return;
    try {
      await store.undoLastDeletion();
      if (mounted) setState(() => _hasRecentDeletion = false);
      await _loadHistoryRuns();
    } catch (error) {
      if (mounted) setState(() => _historyListError = error);
    }
  }

  List<_ClassifiedLog> get _visible {
    final source = _selectedRun == null ? widget.logs : _historyLogs;
    final result = source.map(_classifyLog).where(_matchesLog).toList();
    if (_selectedRun == null && widget.sort == LogSort.newestFirst) {
      return result.reversed.toList();
    }
    return result;
  }

  bool _matchesLog(_ClassifiedLog item) =>
      _sources.contains(item.source) &&
      _levels.contains(item.level) &&
      item.log.message.toLowerCase().contains(_query.text.toLowerCase());

  void _toggleSource(String source) {
    setState(() {
      if (!_sources.remove(source)) _sources.add(source);
    });
    if (_selectedRun != null) {
      unawaited(_loadHistoryPage(_selectedRun!, page: 0));
    }
  }

  void _toggleLevel(_LogLevel level) {
    setState(() {
      if (!_levels.remove(level)) _levels.add(level);
    });
    if (_selectedRun != null) {
      unawaited(_loadHistoryPage(_selectedRun!, page: 0));
    }
  }

  Future<void> _copy(
    AppLocalizations l10n,
    Iterable<_ClassifiedLog> logs,
  ) async {
    await Clipboard.setData(
      ClipboardData(text: logs.map((log) => _formatLog(log, l10n)).join('\n')),
    );
  }

  Future<void> _copyFilteredHistory(AppLocalizations l10n) async {
    final store = widget.logStore;
    final run = _selectedRun;
    if (store == null || run == null) return;
    final query = _query.text.toLowerCase();
    final sources = Set<String>.of(_sources);
    final levels = Set<_LogLevel>.of(_levels);
    bool matchesSnapshot(_ClassifiedLog item) =>
        sources.contains(item.source) &&
        levels.contains(item.level) &&
        item.log.message.toLowerCase().contains(query);
    final buffer = StringBuffer();
    var first = true;
    await for (final log in store.readRunStream(
      run.id,
      reverse: widget.sort == LogSort.newestFirst,
    )) {
      final classified = _classifyLog(log);
      if (!matchesSnapshot(classified)) continue;
      if (!first) buffer.writeln();
      first = false;
      buffer.write(_formatLog(classified, l10n));
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final visible = _visible;
    return Padding(
      padding: EdgeInsets.all(typography.spacingLg),
      child: _SurfacePanel(
        key: const ValueKey('logs-surface'),
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            SegmentedButton<_LogsMode>(
              segments: [
                ButtonSegment(
                  value: _LogsMode.current,
                  label: Text(l10n.current),
                ),
                ButtonSegment(
                  value: _LogsMode.history,
                  label: Text(l10n.history),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (value) {
                final next = value.first;
                if (next == _mode) return;
                setState(() {
                  _mode = next;
                  _historyGeneration++;
                  _selectedRun = null;
                  _historyLogs = const [];
                  _historyDetailLoading = false;
                  _historyDetailError = null;
                });
                if (next == _LogsMode.history) unawaited(_loadHistoryRuns());
              },
            ),
            if (_mode == _LogsMode.history && _selectedRun == null)
              Expanded(child: _buildHistoryList(l10n))
            else ...[
              if (_selectedRun != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('history-back'),
                    onPressed: () => setState(() {
                      _historyGeneration++;
                      _selectedRun = null;
                      _historyLogs = const [];
                      _historyDetailLoading = false;
                      _historyDetailError = null;
                    }),
                    child: Text(l10n.back),
                  ),
                ),
              Padding(
                padding: EdgeInsets.all(typography.spacingSm),
                child: Column(
                  children: [
                    TextField(
                      controller: _query,
                      onChanged: (_) {
                        setState(() {});
                        if (_selectedRun != null) {
                          unawaited(_loadHistoryPage(_selectedRun!, page: 0));
                        }
                      },
                      decoration: InputDecoration(
                        hintText: l10n.logSearch,
                        prefixIcon: const Icon(Icons.search),
                      ),
                    ),
                    Wrap(
                      spacing: 4,
                      children: [
                        for (final source in ['Backend', 'HTTP-META'])
                          FilterChip(
                            label: Text(source),
                            selected: _sources.contains(source),
                            onSelected: (_) => _toggleSource(source),
                          ),
                        for (final level in _LogLevel.values)
                          FilterChip(
                            label: Text(_levelLabel(l10n, level)),
                            selected: _levels.contains(level),
                            onSelected: (_) => _toggleLevel(level),
                          ),
                      ],
                    ),
                    Row(
                      children: [
                        SegmentedButton<LogSort>(
                          segments: [
                            ButtonSegment(
                              value: LogSort.newestFirst,
                              label: Text(l10n.logNewest),
                            ),
                            ButtonSegment(
                              value: LogSort.newestLast,
                              label: Text(l10n.logOldest),
                            ),
                          ],
                          selected: {widget.sort},
                          onSelectionChanged: (value) =>
                              unawaited(widget.onSortChanged(value.first)),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: visible.isEmpty
                              ? null
                              : () => unawaited(
                                  _selectedRun == null
                                      ? _copy(l10n, visible)
                                      : _copyFilteredHistory(l10n),
                                ),
                          child: Text(l10n.copyFilteredLogs),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _historyDetailLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _selectedRun != null && _historyDetailError != null
                    ? Center(child: Text(l10n.historyLoadError))
                    : visible.isEmpty
                    ? Center(
                        child: Text(
                          _selectedRun == null
                              ? (widget.logs.isEmpty
                                    ? l10n.noLogs
                                    : l10n.noFilteredLogs)
                              : (_selectedRun!.eventCount == 0
                                    ? l10n.noLogs
                                    : l10n.noFilteredLogs),
                        ),
                      )
                    : ListView.separated(
                        itemCount: visible.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = visible[index];
                          return Padding(
                            padding: EdgeInsets.all(typography.spacingSm),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: SelectableText(
                                    _formatLog(item, l10n),
                                    style: typography.bodySmall.copyWith(
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: l10n.copyLog,
                                  icon: const Icon(Icons.copy, size: 18),
                                  onPressed: () =>
                                      unawaited(_copy(l10n, [item])),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              if (_selectedRun != null)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: _historyPage > 0
                          ? () => unawaited(
                              _loadHistoryPage(
                                _selectedRun!,
                                page: _historyPage - 1,
                              ),
                            )
                          : null,
                      child: Text(l10n.previousPage),
                    ),
                    TextButton(
                      onPressed: _historyHasNext
                          ? () => unawaited(
                              _loadHistoryPage(
                                _selectedRun!,
                                page: _historyPage + 1,
                              ),
                            )
                          : null,
                      child: Text(l10n.nextPage),
                    ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }
}

String _levelLabel(AppLocalizations l10n, _LogLevel level) => switch (level) {
  _LogLevel.debug => l10n.logLevelDebug,
  _LogLevel.info => l10n.logLevelInfo,
  _LogLevel.warning => l10n.logLevelWarning,
  _LogLevel.error => l10n.logLevelError,
};

String _formatRunDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

String _formatDuration(RuntimeLogRun run) {
  final duration = (run.end ?? run.start).difference(run.start);
  final seconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  return '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${((seconds % 3600) ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class _SettingsSectionTile extends StatelessWidget {
  const _SettingsSectionTile({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

enum _LeaveDecision { save, discard, cancel }

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
  });

  final BackendEnvDocument environment;
  final SubDockConfig configuration;
  final AppConfigError? configurationError;
  final AppCoordinator coordinator;
  final Future<void> Function(SubDockConfig configuration) onSaveConfiguration;
  final Future<void> Function(BackendEnvDocument document) onSaveEnvironment;
  final DesktopPreferences savedPreferences;
  final Future<void> Function(DesktopPreferences preferences) onSavePreferences;
  final Future<void> Function(ThemeMode mode) onPreviewTheme;
  final Future<void> Function(Locale? locale) onPreviewLocale;
  final Future<void> Function() onResetConfiguration;
  final ValueChanged<bool> onChildStateChanged;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  late ThemeMode _generalThemeMode;
  late String? _generalLocale;
  late CloseBehavior _generalCloseBehavior;
  late int _generalRecentLogLimit;
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
  late SubDockBackendConfig _savedBackend;
  late SubDockBackendConfig _backendDraft;
  var _httpMetaEnabled = true;
  final _componentUpdates = <ComponentKind, ComponentUpdate>{};
  final _componentStatuses = <ComponentKind, ComponentVersionStatus>{};
  final _componentErrors = <ComponentKind, Object?>{};
  final _componentBusy = <ComponentKind>{};

  @override
  void initState() {
    super.initState();
    _syncGeneral();
    _document = widget.environment;
    _configuration = widget.configuration;
    _savedBackend = widget.configuration.backend;
    _backendDraft = _savedBackend;
    _raw = TextEditingController();
    _host = TextEditingController();
    _port = TextEditingController();
    _path = TextEditingController();
    _cors = TextEditingController();
    _recentLogLimit = TextEditingController();
    _recentLogLimit.text = '$_generalRecentLogLimit';
    _syncControllers();
    _syncConfiguration();
    unawaited(_loadComponentStatuses());
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
    if (oldWidget.configuration != widget.configuration && !_backendDirty) {
      _savedBackend = widget.configuration.backend;
      _backendDraft = _savedBackend;
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

  DesktopPreferences get _generalPreferences =>
      widget.savedPreferences.copyWith(
        themeMode: _generalThemeMode,
        locale: _generalLocale,
        closeBehavior: _generalCloseBehavior,
        recentLogLimit: _generalRecentLogLimit,
      );

  int? get _parsedRecentLogLimit {
    final value = int.tryParse(_recentLogLimit.text.trim());
    return value != null && value >= 50 && value <= 2000 ? value : null;
  }

  bool get _generalDirty =>
      _generalThemeMode != widget.savedPreferences.themeMode ||
      _generalLocale != widget.savedPreferences.locale ||
      _generalCloseBehavior != widget.savedPreferences.closeBehavior ||
      _recentLogLimit.text.trim() !=
          '${widget.savedPreferences.recentLogLimit}';

  bool get _backendDirty => _backendDraft != _savedBackend;

  void _syncGeneral() {
    final preferences = widget.savedPreferences;
    _generalThemeMode = preferences.themeMode;
    _generalLocale = preferences.locale;
    _generalCloseBehavior = preferences.closeBehavior;
    _generalRecentLogLimit = preferences.recentLogLimit;
  }

  Future<bool> _saveGeneral() async {
    final limit = _parsedRecentLogLimit;
    if (limit == null) return false;
    try {
      await widget.onSavePreferences(
        _generalPreferences.copyWith(recentLogLimit: limit),
      );
    } on Object {
      return false;
    }
    if (!mounted) return false;
    setState(() => _generalRecentLogLimit = limit);
    return true;
  }

  Future<void> _discardGeneral() async {
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
  }

  void _updateBackend(SubDockBackendConfig next) {
    if (_updating) return;
    setState(() => _backendDraft = next);
  }

  void _syncConfiguration() {
    _httpMetaEnabled = _configuration.httpMeta.enabled;
  }

  void _updateConfiguration(SubDockHttpMetaConfig httpMeta) {
    if (_updating) return;
    setState(() {
      _configuration = _configuration.copyWith(httpMeta: httpMeta);
      _configurationDirty = true;
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

  Future<void> _saveConfiguration() async {
    final l10n = AppLocalizations.of(context)!;
    final issue = _configurationIssue;
    if (issue != null) return;
    final effective = EffectiveRuntimeConfig.resolve(
      systemEnvironment: Platform.environment,
      backendEnvironment: widget.environment,
      config: _configuration,
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
        widget.configuration.copyWith(httpMeta: _configuration.httpMeta),
      );
    } on Object {
      return;
    }
    if (!mounted) return;
    setState(() {
      _configurationDirty = false;
      _configuration = widget.configuration.copyWith(
        httpMeta: _configuration.httpMeta,
      );
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.saved)));
  }

  Future<void> _saveBackendConfiguration() async {
    final l10n = AppLocalizations.of(context)!;
    final next = widget.configuration.copyWith(backend: _backendDraft);
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
      await widget.onSaveConfiguration(next);
    } on Object {
      return;
    }
    if (!mounted) return;
    setState(() => _savedBackend = _backendDraft);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.saved)));
  }

  void _updateRaw(String value) {
    if (_updating) return;
    setState(() {
      _document = BackendEnvDocument.parse(value);
      _dirty = true;
      _syncControllers();
    });
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final issues = BackendEnvPolicy.validate(_document);
    if (issues.isNotEmpty) return;
    if (BackendEnvPolicy.externalOrigins(_document).isNotEmpty &&
        !await _confirm(l10n.confirmExternalCors)) {
      return;
    }
    if (BackendEnvPolicy.hasNonLoopbackHost(_document) &&
        !await _confirm(l10n.confirmNonLoopback)) {
      return;
    }
    try {
      await widget.onSaveEnvironment(_document);
    } on Object {
      // _saveEnvironment records the error into _error for display.
      return;
    }
    if (!mounted) return;
    setState(() => _dirty = false);
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

  Future<void> _checkComponent(ComponentKind kind) async {
    setState(() {
      _componentBusy.add(kind);
      _componentErrors.remove(kind);
    });
    try {
      final update = await widget.coordinator.checkComponent(kind);
      if (mounted) setState(() => _componentUpdates[kind] = update);
    } catch (error) {
      if (mounted) setState(() => _componentErrors[kind] = error);
    } finally {
      if (mounted) setState(() => _componentBusy.remove(kind));
    }
  }

  Future<void> _loadComponentStatuses() async {
    for (final kind in ComponentKind.values) {
      try {
        final status = await widget.coordinator.componentStatus(kind);
        if (mounted) setState(() => _componentStatuses[kind] = status);
      } catch (_) {
        // The check button surfaces platform or resource errors explicitly.
      }
    }
  }

  Future<void> _applyComponent(ComponentUpdate update) async {
    final l10n = AppLocalizations.of(context)!;
    final kind = update.kind;
    setState(() {
      _componentBusy.add(kind);
      _componentErrors.remove(kind);
    });
    try {
      await widget.coordinator.updateComponent(update);
      if (mounted) {
        setState(() {
          _componentUpdates.remove(kind);
          _componentStatuses[kind] = ComponentVersionStatus(
            current: update.availableVersion,
            previous: update.currentVersion,
          );
          _componentErrors[kind] = l10n.componentUpdatedTo(
            update.availableVersion,
          );
        });
      }
    } catch (error) {
      if (mounted) setState(() => _componentErrors[kind] = error);
    } finally {
      if (mounted) setState(() => _componentBusy.remove(kind));
    }
  }

  Future<void> _rollbackComponent(ComponentKind kind) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _componentBusy.add(kind);
      _componentErrors.remove(kind);
    });
    try {
      await widget.coordinator.rollbackComponent(kind);
      if (mounted) {
        setState(() {
          _componentUpdates.remove(kind);
          final previous = _componentStatuses[kind]?.current;
          if (previous != null) {
            _componentStatuses[kind] = ComponentVersionStatus(
              current:
                  _componentStatuses[kind]?.previous ??
                  l10n.componentPackageVersion,
              previous: previous,
            );
          }
          _componentErrors[kind] = l10n.componentRolledBack;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _componentErrors[kind] = error);
    } finally {
      if (mounted) setState(() => _componentBusy.remove(kind));
    }
  }

  Future<bool> requestLeave() async {
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
                  _SettingsSectionTile(
                    title: l10n.subdockConfigHeading,
                    subtitle: l10n.enableHttpMetaSubtitle,
                    onTap: () =>
                        unawaited(_openSection(_SettingsSection.subDockConfig)),
                  ),
                  _SettingsSectionTile(
                    title: l10n.backendConfigHeading,
                    subtitle: 'Host, Port, Merge, Path, CORS',
                    onTap: () =>
                        unawaited(_openSection(_SettingsSection.backendConfig)),
                  ),
                  _SettingsSectionTile(
                    title: l10n.advancedRawEnv,
                    subtitle: l10n.advancedRawEnvSubtitle,
                    onTap: () =>
                        unawaited(_openSection(_SettingsSection.advancedEnv)),
                  ),
                ],
                if (_section == _SettingsSection.home) ...[
                  _SurfacePanel(
                    key: const ValueKey('settings-appearance'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.appearanceHeading,
                          style: typography.titleMedium,
                        ),
                        SizedBox(height: typography.spacingSm),
                        Wrap(
                          spacing: typography.spacingLg,
                          runSpacing: typography.spacingSm,
                          children: [
                            SegmentedButton<ThemeMode>(
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
                                setState(
                                  () => _generalThemeMode = selection.first,
                                );
                                unawaited(
                                  widget.onPreviewTheme(selection.first),
                                );
                              },
                            ),
                            SizedBox(
                              width: 220,
                              child: DropdownButton<String>(
                                isExpanded: true,
                                value: _generalLocale ?? 'system',
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
                                  final locale =
                                      value == null || value == 'system'
                                      ? null
                                      : value;
                                  setState(() => _generalLocale = locale);
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
                        DropdownButton<CloseBehavior>(
                          key: const ValueKey('settings-close-behavior'),
                          value: _generalCloseBehavior,
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
                            }
                          },
                        ),
                        DropdownButton<int>(
                          key: const ValueKey('settings-recent-log-presets'),
                          value:
                              const [
                                100,
                                200,
                                500,
                                1000,
                                2000,
                              ].contains(_parsedRecentLogLimit)
                              ? _parsedRecentLogLimit
                              : null,
                          hint: Text(l10n.recentLogPresets),
                          items: [
                            for (final value in const [
                              100,
                              200,
                              500,
                              1000,
                              2000,
                            ])
                              DropdownMenuItem(
                                value: value,
                                child: Text('$value'),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              _recentLogLimit.text = '$value';
                              setState(() {});
                            }
                          },
                        ),
                        TextField(
                          key: const ValueKey('settings-recent-log-limit'),
                          controller: _recentLogLimit,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: l10n.recentLogs,
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ],
                    ),
                  ),
                ],
                SizedBox(height: typography.spacingLg),
                if (_section == _SettingsSection.subDockConfig) ...[
                  _SurfacePanel(
                    key: const ValueKey('settings-subdock-config'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.subdockConfigHeading,
                          style: typography.titleMedium,
                        ),
                        if (widget.configurationError != null) ...[
                          Text(
                            l10n.configurationInvalid(
                              _localizedConfigError(
                                l10n,
                                widget.configurationError!,
                              ),
                            ),
                            style: TextStyle(color: colors.error),
                          ),
                          SizedBox(height: typography.spacingS),
                          OutlinedButton(
                            onPressed: _configurationDirty
                                ? null
                                : () =>
                                      unawaited(widget.onResetConfiguration()),
                            child: Text(l10n.resetSubdockConfig),
                          ),
                        ],
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(l10n.enableHttpMeta),
                          subtitle: Text(l10n.enableHttpMetaSubtitle),
                          value: _httpMetaEnabled,
                          onChanged: (value) => _updateConfiguration(
                            _configuration.httpMeta.copyWith(enabled: value),
                          ),
                        ),
                        if (configurationIssue != null)
                          Text(
                            configurationIssue,
                            style: TextStyle(color: colors.error),
                          ),
                      ],
                    ),
                  ),
                ],
                SizedBox(height: typography.spacingLg),
                if (_section == _SettingsSection.backendConfig) ...[
                  _SurfacePanel(
                    key: const ValueKey('settings-backend-config'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.backendConfigHeading,
                          style: typography.titleMedium,
                        ),
                        TextField(
                          controller: _host,
                          decoration: const InputDecoration(
                            labelText: 'API Host',
                          ),
                          onChanged: (value) => _updateBackend(
                            _backendDraft.copyWith(
                              apiHost: value.trim().isEmpty ? null : value,
                            ),
                          ),
                        ),
                        TextField(
                          controller: _port,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'API Port',
                          ),
                          onChanged: (value) => _updateBackend(
                            _backendDraft.copyWith(
                              apiPort: int.tryParse(value.trim()),
                            ),
                          ),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(l10n.mergeMode),
                          value: _backendDraft.merge ?? false,
                          onChanged: (value) => _updateBackend(
                            _backendDraft.copyWith(merge: value),
                          ),
                        ),
                        TextField(
                          controller: _path,
                          decoration: const InputDecoration(
                            labelText: 'Frontend Backend Path',
                          ),
                          onChanged: (value) => _updateBackend(
                            _backendDraft.copyWith(
                              frontendBackendPath: value.trim().isEmpty
                                  ? null
                                  : value,
                            ),
                          ),
                        ),
                        TextField(
                          controller: _cors,
                          decoration: const InputDecoration(
                            labelText: 'CORS Allowed Origins',
                          ),
                          onChanged: (value) => _updateBackend(
                            _backendDraft.copyWith(
                              corsAllowedOrigins: value.trim().isEmpty
                                  ? null
                                  : value,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                SizedBox(height: typography.spacingLg),
                if (_section == _SettingsSection.advancedEnv)
                  _SurfacePanel(
                    key: const ValueKey('settings-raw-env'),
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.warning_amber),
                          title: Text(l10n.structuredEnvPrecedenceWarning),
                        ),
                        ExpansionTile(
                          key: const ValueKey('settings-raw-env-expansion'),
                          title: Text(l10n.advancedRawEnv),
                          subtitle: Text(l10n.advancedRawEnvSubtitle),
                          initiallyExpanded: false,
                          childrenPadding: EdgeInsets.fromLTRB(
                            typography.spacingMd,
                            0,
                            typography.spacingMd,
                            typography.spacingMd,
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
                SizedBox(height: typography.spacingLg),
                if (_section == _SettingsSection.home)
                  _SurfacePanel(
                    key: const ValueKey('settings-component-updates'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.componentUpdatesHeading,
                          style: typography.titleMedium,
                        ),
                        SizedBox(height: typography.spacingSm),
                        for (final kind in ComponentKind.values)
                          _ComponentCard(
                            kind: kind,
                            status: _componentStatuses[kind],
                            update: _componentUpdates[kind],
                            error: _componentErrors[kind],
                            busy: _componentBusy.contains(kind),
                            onCheck: () => _checkComponent(kind),
                            onUpdate: _componentUpdates[kind] == null
                                ? null
                                : () =>
                                      _applyComponent(_componentUpdates[kind]!),
                            onRollback: () => _rollbackComponent(kind),
                          ),
                      ],
                    ),
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
                  onPressed: _generalDirty && _parsedRecentLogLimit != null
                      ? () async {
                          if (await _saveGeneral() && mounted) {
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
        if (_section != _SettingsSection.home)
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.all(typography.spacingMd),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const ValueKey('settings-child-save'),
                  onPressed: switch (_section) {
                    _SettingsSection.subDockConfig =>
                      _configurationDirty ? _saveConfiguration : null,
                    _SettingsSection.backendConfig =>
                      _backendDirty ? _saveBackendConfiguration : null,
                    _SettingsSection.advancedEnv =>
                      _dirty && BackendEnvPolicy.validate(_document).isEmpty
                          ? _save
                          : null,
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

class _ComponentCard extends StatelessWidget {
  const _ComponentCard({
    required this.kind,
    required this.status,
    required this.update,
    required this.error,
    required this.busy,
    required this.onCheck,
    required this.onUpdate,
    required this.onRollback,
  });

  final ComponentKind kind;
  final ComponentVersionStatus? status;
  final ComponentUpdate? update;
  final Object? error;
  final bool busy;
  final VoidCallback onCheck;
  final VoidCallback? onUpdate;
  final VoidCallback onRollback;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final l10n = AppLocalizations.of(context)!;
    final name = kind == ComponentKind.backend ? 'Backend' : 'Frontend';
    final text = update == null
        ? status == null
              ? l10n.componentReadingVersion
              : l10n.componentCurrentWithPrevious(
                  status!.current,
                  status!.previous ?? '-',
                )
        : update!.isAvailable
        ? l10n.componentUpdateAvailable(
            update!.availableVersion,
            update!.currentVersion,
            status?.previous ?? '-',
          )
        : l10n.componentUpToDate(
            update!.currentVersion,
            status?.previous ?? '-',
          );
    return Padding(
      padding: EdgeInsets.symmetric(vertical: typography.spacingSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: typography.titleMedium),
          SizedBox(height: typography.spacingXs),
          Text(text),
          if (error != null) ...[
            SizedBox(height: typography.spacingXs),
            Text(
              _localizedError(l10n, error),
              style: TextStyle(color: colors.error),
            ),
          ],
          SizedBox(height: typography.spacingSm),
          Wrap(
            spacing: typography.spacingS,
            runSpacing: typography.spacingS,
            children: [
              OutlinedButton(
                onPressed: busy ? null : onCheck,
                child: Text(l10n.checkForUpdates),
              ),
              FilledButton(
                onPressed: busy || update?.isAvailable != true
                    ? null
                    : onUpdate,
                child: Text(l10n.update),
              ),
              TextButton(
                onPressed: busy ? null : onRollback,
                child: Text(l10n.rollback),
              ),
              if (busy)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(),
                ),
            ],
          ),
        ],
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

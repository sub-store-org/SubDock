import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_all/webview_all.dart';

import '../l10n/generated/app_localizations.dart';
import '../runtime/backend_runtime.dart';
import '../settings/backend_env.dart';
import '../settings/config_error.dart';
import '../settings/locale_preference_store.dart';
import '../settings/subdock_config.dart';
import '../settings/theme_mode_store.dart';
import '../update/component_metadata_store.dart';
import '../update/component_update_checker.dart';
import '../update/component_update_service.dart';
import 'app_colors.dart';
import 'app_coordinator.dart';
import 'app_typography.dart';

const navigationBreakpoint = 600.0;

enum _AppPage { manage, overview, logs, settings }

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
    this.onToggleFullscreen,
    this.onCloseToTray,
    this.onStartDragging,
    this.onThemeSaveScheduled,
    this.themeModeStore,
    this.localeStore,
    this.onLocaleChanged,
    this.locale,
  });

  final AppCoordinator coordinator;
  final bool autoStart;
  final bool enableWebView;
  final Object? initialError;
  final ValueListenable<Object?>? desktopWarning;
  final Future<void> Function()? onMinimize;
  final Future<void> Function()? onToggleFullscreen;
  final Future<void> Function()? onCloseToTray;
  final Future<void> Function()? onStartDragging;
  final void Function(Future<void>)? onThemeSaveScheduled;
  final ThemeModeStore? themeModeStore;
  final LocalePreferenceStore? localeStore;

  /// Notified with the effective locale after a locale change or a successful
  /// preference load at startup, so the caller (desktop_main) can rebuild the
  /// tray menu in the same language.
  final Future<void> Function(Locale?)? onLocaleChanged;

  /// Initial locale override; a [localeStore] load replaces it at startup.
  final Locale? locale;

  @override
  State<SubDockApp> createState() => _SubDockAppState();
}

class _SubDockAppState extends State<SubDockApp> {
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
  ThemeMode _themeMode = ThemeMode.system;
  Future<void> _themeSaveQueue = Future<void>.value();
  Locale? _localeOverride;

  @override
  void initState() {
    super.initState();
    _localeOverride = widget.locale;
    _state = widget.coordinator.runtime.currentState;
    _error = widget.initialError;
    if (_error != null) _page = _AppPage.overview;
    _stateSubscription = widget.coordinator.runtime.state.listen(_onState);
    _logSubscription = widget.coordinator.runtime.logs.listen(_appendLog);
    _lifecycleListener = AppLifecycleListener(
      onDetach: () => unawaited(widget.coordinator.dispose()),
    );
    widget.desktopWarning?.addListener(_onDesktopWarning);
    unawaited(_loadLogTail());
    unawaited(_loadOverviewComponentStatuses());
    unawaited(_loadThemeMode());
    unawaited(_loadLocalePreference());
    if (widget.autoStart) unawaited(_autoStart());
  }

  @override
  void dispose() {
    widget.desktopWarning?.removeListener(_onDesktopWarning);
    _lifecycleListener.dispose();
    _stateSubscription.cancel();
    _logSubscription.cancel();
    super.dispose();
  }

  void _onDesktopWarning() {
    if (mounted) setState(() {});
  }

  Future<void> _loadThemeMode() async {
    final store = widget.themeModeStore;
    if (store == null) return;
    final mode = await store.load();
    if (!mounted || mode == null) return;
    setState(() => _themeMode = mode);
  }

  Future<void> _onThemeModeSelected(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    final store = widget.themeModeStore;
    if (store == null) return;
    _themeSaveQueue = _themeSaveQueue.then((_) async {
      try {
        await store.save(mode);
      } catch (error) {
        debugPrint('Failed to persist theme mode: $error');
      }
    });
    widget.onThemeSaveScheduled?.call(_themeSaveQueue);
    await _themeSaveQueue;
  }

  Future<void> _loadLocalePreference() async {
    final store = widget.localeStore;
    if (store == null) return;
    final language = await store.load();
    if (!mounted || language == null) return;
    setState(() => _localeOverride = Locale(language));
    if (widget.onLocaleChanged != null) {
      await widget.onLocaleChanged!(Locale(language));
    }
  }

  Future<void> _onLocaleSelected(Locale? locale) async {
    setState(() => _localeOverride = locale);
    final store = widget.localeStore;
    if (store == null) return;
    try {
      if (locale == null) {
        await store.clear();
      } else {
        await store.save(locale.languageCode);
      }
    } catch (error) {
      debugPrint('Failed to persist locale: $error');
    }
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
    setState(() => _state = state);
    if (state.status == RuntimeStatus.running) unawaited(_loadInfo());
  }

  void _appendLog(RuntimeLog log) {
    if (!mounted) return;
    setState(() {
      _logs.add(log);
      if (_logs.length > 2000) _logs.removeRange(0, _logs.length - 2000);
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

  void _selectPage(_AppPage page) {
    setState(() => _page = page);
    if (page == _AppPage.overview) {
      unawaited(_loadOverviewComponentStatuses());
    }
  }

  Future<void> _loadLogTail() async {
    final file = File.fromUri(
      widget.coordinator.environmentStore.directories.logs.uri.resolve(
        'backend.log',
      ),
    );
    if (!await file.exists()) return;
    final length = await file.length();
    final start = length > 64 * 1024 ? length - 64 * 1024 : 0;
    final lines = await file
        .openRead(start)
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList();
    for (final line in lines) {
      _appendLog(
        RuntimeLog(
          timestamp: DateTime.now(),
          source: RuntimeLogSource.stdout,
          message: line,
        ),
      );
    }
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
        icon: const Icon(Icons.web_asset_outlined),
        selectedIcon: const Icon(Icons.web_asset),
        label: l10n.manage,
      ),
      _ShellDestination(
        icon: const Icon(Icons.dashboard_outlined),
        selectedIcon: const Icon(Icons.dashboard),
        label: l10n.overview,
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
      _OverviewPage(
        state: _state,
        info: _info,
        error: _error,
        logs: _logs,
        componentStatuses: _overviewComponentStatuses,
        unavailableComponents: _overviewComponentUnavailable,
        actionInProgress: _actionInProgress,
        onStart: () => _run(widget.coordinator.start),
        onStop: () => _run(widget.coordinator.stop),
        onRestart: () => _run(widget.coordinator.restart),
      ),
      _LogsPage(logs: _logs),
      _SettingsPage(
        environment: widget.coordinator.environment,
        configuration: widget.coordinator.configuration,
        configurationError: widget.coordinator.configurationError,
        coordinator: widget.coordinator,
        themeMode: _themeMode,
        onThemeModeSelected: (mode) => unawaited(_onThemeModeSelected(mode)),
        localeOverride: _localeOverride,
        onLocaleSelected: (locale) => unawaited(_onLocaleSelected(locale)),
        onSave: _saveEnvironment,
        onSaveConfiguration: (configuration) =>
            _run(() => widget.coordinator.saveConfiguration(configuration)),
        onResetConfiguration: () => _run(widget.coordinator.resetConfiguration),
        onRestart: () => _run(widget.coordinator.restart),
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
            onToggleFullscreen: widget.onToggleFullscreen,
            onCloseToTray: widget.onCloseToTray,
            minimizeTooltip: l10n.minimizeTooltip,
            toggleFullscreenTooltip: l10n.toggleFullscreenTooltip,
            closeToTrayTooltip: l10n.closeToTrayTooltip,
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
                      NavigationBar(
                        selectedIndex: _page.index,
                        onDestinationSelected: (index) =>
                            _selectPage(_AppPage.values[index]),
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
                          _selectPage(_AppPage.values[index]),
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
    required this.onToggleFullscreen,
    required this.onCloseToTray,
    required this.minimizeTooltip,
    required this.toggleFullscreenTooltip,
    required this.closeToTrayTooltip,
  });
  final String title,
      minimizeTooltip,
      toggleFullscreenTooltip,
      closeToTrayTooltip;
  final Future<void> Function()? onStartDragging,
      onMinimize,
      onToggleFullscreen,
      onCloseToTray;

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
                behavior: HitTestBehavior.translucent,
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
            if (onToggleFullscreen != null)
              IconButton(
                tooltip: toggleFullscreenTooltip,
                onPressed: () => unawaited(onToggleFullscreen!()),
                icon: const Icon(Icons.fullscreen),
              ),
            if (onCloseToTray != null)
              IconButton(
                tooltip: closeToTrayTooltip,
                onPressed: () => unawaited(onCloseToTray!()),
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
        Positioned.fill(child: WebViewWidget(controller: _controller!)),
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
    required this.logs,
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
  final List<RuntimeLog> logs;
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
    final recentLogs = logs.length <= 3 ? logs : logs.sublist(logs.length - 3);
    final recentLogsPanel = _SurfacePanel(
      key: const ValueKey('overview-recent-logs'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.recentLogsHeading, style: typography.titleMedium),
          SizedBox(height: typography.spacingS),
          if (recentLogs.isEmpty)
            Text(l10n.noLogs)
          else
            for (final log in recentLogs)
              Text(
                '${log.timestamp.toIso8601String()} [${log.source.name}] ${log.message}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typography.bodySmall.copyWith(fontFamily: 'monospace'),
              ),
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
                  : l10n.componentCurrentWithPrevious(componentStatuses[kind]!.current, componentStatuses[kind]!.previous ?? '-')}',
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
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth < 760
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    recentLogsPanel,
                    SizedBox(height: typography.spacingLg),
                    componentStatusPanel,
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: recentLogsPanel),
                    SizedBox(width: typography.spacingLg),
                    Expanded(child: componentStatusPanel),
                  ],
                ),
        ),
      ],
    );
  }
}

class _LogsPage extends StatelessWidget {
  const _LogsPage({required this.logs});

  final List<RuntimeLog> logs;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    return Padding(
      padding: EdgeInsets.all(typography.spacingLg),
      child: SizedBox.expand(
        child: _SurfacePanel(
          key: const ValueKey('logs-surface'),
          padding: EdgeInsets.zero,
          child: logs.isEmpty
              ? Center(child: Text(l10n.noLogs))
              : ListView.builder(
                  padding: EdgeInsets.all(typography.spacingSm),
                  itemCount: logs.length,
                  itemBuilder: (context, index) {
                    final log = logs[index];
                    return SelectableText(
                      '${log.timestamp.toIso8601String()} [${log.source.name}] ${log.message}',
                      style: typography.bodySmall.copyWith(
                        fontFamily: 'monospace',
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({
    required this.environment,
    required this.configuration,
    required this.configurationError,
    required this.coordinator,
    required this.themeMode,
    required this.onThemeModeSelected,
    required this.localeOverride,
    required this.onLocaleSelected,
    required this.onSave,
    required this.onSaveConfiguration,
    required this.onResetConfiguration,
    required this.onRestart,
  });

  final BackendEnvDocument environment;
  final SubDockConfig configuration;
  final AppConfigError? configurationError;
  final AppCoordinator coordinator;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeSelected;
  final Locale? localeOverride;
  final ValueChanged<Locale?> onLocaleSelected;
  final Future<void> Function(BackendEnvDocument document) onSave;
  final Future<void> Function(SubDockConfig configuration) onSaveConfiguration;
  final Future<void> Function() onResetConfiguration;
  final VoidCallback onRestart;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  late BackendEnvDocument _document;
  late SubDockConfig _configuration;
  late final TextEditingController _raw;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _path;
  late final TextEditingController _cors;
  var _updating = false;
  var _dirty = false;
  var _configurationDirty = false;
  var _httpMetaEnabled = true;
  final _componentUpdates = <ComponentKind, ComponentUpdate>{};
  final _componentStatuses = <ComponentKind, ComponentVersionStatus>{};
  final _componentErrors = <ComponentKind, Object?>{};
  final _componentBusy = <ComponentKind>{};

  @override
  void initState() {
    super.initState();
    _document = widget.environment;
    _configuration = widget.configuration;
    _raw = TextEditingController();
    _host = TextEditingController();
    _port = TextEditingController();
    _path = TextEditingController();
    _cors = TextEditingController();
    _syncControllers();
    _syncConfiguration();
    unawaited(_loadComponentStatuses());
  }

  @override
  void didUpdateWidget(covariant _SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
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
  }

  @override
  void dispose() {
    _raw.dispose();
    _host.dispose();
    _port.dispose();
    _path.dispose();
    _cors.dispose();
    super.dispose();
  }

  String _value(String key, String fallback) =>
      _document.values[key] ?? fallback;

  void _syncControllers() {
    _updating = true;
    _raw.text = _document.rawText;
    _host.text = _value(BackendEnvPolicy.host, '127.0.0.1');
    _port.text = _value(BackendEnvPolicy.port, '3001');
    _path.text = _value(BackendEnvPolicy.frontendBackendPath, '/');
    _cors.text = _value(
      BackendEnvPolicy.corsAllowedOrigins,
      BackendEnvPolicy.localOrigin(_document).origin,
    );
    _updating = false;
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
    await widget.onSaveConfiguration(_configuration);
    if (!mounted) return;
    setState(() => _configurationDirty = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.configSavedNoRestart)));
  }

  void _updateRaw(String value) {
    if (_updating) return;
    setState(() {
      _document = BackendEnvDocument.parse(value);
      _dirty = true;
      _syncControllers();
    });
  }

  void _updateField(String key, String value) {
    if (_updating) return;
    setState(() {
      _document = _document.withValue(key, value);
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
      await widget.onSave(_document);
    } on Object {
      // _saveEnvironment records the error into _error for display.
      return;
    }
    if (!mounted) return;
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.savedRestartToApply),
        action: SnackBarAction(
          label: l10n.restartNow,
          onPressed: widget.onRestart,
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final issues = BackendEnvPolicy.validate(_document);
    final configurationIssue = _configurationIssue;
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    return ListView(
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
                            selected: {widget.themeMode},
                            onSelectionChanged: (selection) =>
                                widget.onThemeModeSelected(selection.first),
                          ),
                          SizedBox(
                            width: 220,
                            child: DropdownButton<String>(
                              isExpanded: true,
                              value:
                                  widget.localeOverride?.languageCode ??
                                  'system',
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
                              onChanged: (value) => widget.onLocaleSelected(
                                value == null || value == 'system'
                                    ? null
                                    : Locale(value),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(height: typography.spacingLg),
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
                              : () => unawaited(widget.onResetConfiguration()),
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
                      FilledButton(
                        onPressed:
                            configurationIssue == null && _configurationDirty
                            ? _saveConfiguration
                            : null,
                        child: Text(l10n.saveSubdockConfig),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: typography.spacingLg),
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
                        onChanged: (value) =>
                            _updateField(BackendEnvPolicy.host, value),
                      ),
                      TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'API Port',
                        ),
                        onChanged: (value) =>
                            _updateField(BackendEnvPolicy.port, value),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.mergeMode),
                        value: BackendEnvPolicy.isMergeEnabledFor(_document),
                        onChanged: (value) => _updateField(
                          BackendEnvPolicy.merge,
                          value ? 'true' : 'false',
                        ),
                      ),
                      TextField(
                        controller: _path,
                        decoration: const InputDecoration(
                          labelText: 'Frontend Backend Path',
                        ),
                        onChanged: (value) => _updateField(
                          BackendEnvPolicy.frontendBackendPath,
                          value,
                        ),
                      ),
                      TextField(
                        controller: _cors,
                        decoration: const InputDecoration(
                          labelText: 'CORS Allowed Origins',
                        ),
                        onChanged: (value) => _updateField(
                          BackendEnvPolicy.corsAllowedOrigins,
                          value,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: typography.spacingLg),
                _SurfacePanel(
                  key: const ValueKey('settings-raw-env'),
                  padding: EdgeInsets.zero,
                  child: ExpansionTile(
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
                      FilledButton(
                        onPressed: issues.isEmpty && _dirty ? _save : null,
                        child: Text(l10n.save),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: typography.spacingLg),
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
                              : () => _applyComponent(_componentUpdates[kind]!),
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

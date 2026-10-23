part of '../app.dart';

class _ManagePage extends StatefulWidget {
  const _ManagePage({
    required this.state,
    required this.coordinator,
    required this.error,
    required this.enabled,
    required this.onOpenExternalUri,
    this.webViewControllerFactory,
    required this.onRecover,
  });

  final RuntimeState state;
  final AppCoordinator coordinator;
  final Object? error;
  final bool enabled;
  final Future<bool> Function(Uri uri) onOpenExternalUri;
  final EmbeddedWebViewController Function({
    required EmbeddedNavigationHandler onNavigationRequest,
    required void Function(String message) onBlobMessage,
    required String bridgeScript,
    EmbeddedPageChangeHandler? onPageChanged,
  })?
  webViewControllerFactory;
  final VoidCallback onRecover;

  @override
  State<_ManagePage> createState() => _ManagePageState();
}

class _ManagePageState extends State<_ManagePage> {
  static const _maxBlobBytes = 16 * 1024 * 1024;
  static final _webView2DownloadUri = Uri.parse(
    'https://developer.microsoft.com/microsoft-edge/webview2/',
  );

  EmbeddedWebViewController? _controller;
  Uri? _currentUri;
  var _canGoBack = false;
  var _canGoForward = false;
  var _webViewInitialized = false;
  var _webViewLoading = false;
  var _webViewLoaded = false;
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
      _currentUri = null;
      _canGoBack = false;
      _canGoForward = false;
      _webViewInitialized = false;
      _webViewLoading = false;
      _webViewLoaded = false;
      return;
    }
    unawaited(_ensureController());
  }

  Future<void> _ensureController() async {
    if (!_ready || _controller != null) return;
    try {
      late final EmbeddedWebViewController controller;
      final createController =
          widget.webViewControllerFactory ?? EmbeddedWebViewController.create;
      controller = createController(
        onNavigationRequest: _onNavigationRequest,
        onBlobMessage: (message) => unawaited(_onBridgeMessage(message)),
        bridgeScript: _blobDownloadBridge,
        onPageChanged: (uri) => unawaited(_onPageChanged(controller, uri)),
      );
      if (!mounted || !_ready) return;
      setState(() {
        _controller = controller;
        _currentUri = widget.coordinator.webUiUri;
        _canGoBack = false;
        _canGoForward = false;
        _webViewInitialized = false;
        _webViewLoading = true;
        _webViewLoaded = false;
        _webViewError = null;
        _missingWebView2 = false;
      });
      await controller.initialize();
      if (!mounted || !identical(_controller, controller)) return;
      setState(() => _webViewInitialized = true);
      await controller.loadRequest(widget.coordinator.webUiUri);
    } catch (error) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        setState(() {
          _missingWebView2 = _isMissingWebView2(error);
          _webViewError = _missingWebView2 ? l10n.webView2Missing : '$error';
          _webViewLoading = false;
          _webViewLoaded = false;
        });
      }
    }
  }

  Future<void> _onPageChanged(
    EmbeddedWebViewController controller,
    Uri uri,
  ) async {
    if (!mounted || !identical(_controller, controller)) return;
    setState(() {
      _currentUri = uri;
      _webViewLoading = false;
      _webViewLoaded = true;
    });
    try {
      final canGoBack = await controller.canGoBack();
      final canGoForward = await controller.canGoForward();
      if (!mounted || !identical(_controller, controller)) return;
      setState(() {
        _canGoBack = canGoBack;
        _canGoForward = canGoForward;
      });
    } catch (error) {
      if (mounted && identical(_controller, controller)) {
        setState(() => _webViewError = '$error');
      }
    }
  }

  Future<void> _refreshHistory(EmbeddedWebViewController controller) async {
    try {
      final canGoBack = await controller.canGoBack();
      final canGoForward = await controller.canGoForward();
      if (!mounted || !identical(_controller, controller)) return;
      setState(() {
        _canGoBack = canGoBack;
        _canGoForward = canGoForward;
      });
    } catch (error) {
      if (mounted && identical(_controller, controller)) {
        setState(() => _webViewError = '$error');
      }
    }
  }

  Future<void> _goBack() async {
    final controller = _controller;
    if (controller == null || !_canGoBack) return;
    try {
      await controller.goBack();
      await _refreshHistory(controller);
    } catch (error) {
      if (mounted) setState(() => _webViewError = '$error');
    }
  }

  Future<void> _goForward() async {
    final controller = _controller;
    if (controller == null || !_canGoForward) return;
    try {
      await controller.goForward();
      await _refreshHistory(controller);
    } catch (error) {
      if (mounted) setState(() => _webViewError = '$error');
    }
  }

  Future<EmbeddedNavigationDecision> _onNavigationRequest(
    EmbeddedNavigationRequest request,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final uri = request.uri;
    if (_sameOrigin(uri, widget.coordinator.webUiUri)) {
      if (_isDownloadUri(uri)) {
        unawaited(_saveHttpDownload(uri));
        return EmbeddedNavigationDecision.prevent;
      }
      return EmbeddedNavigationDecision.navigate;
    }
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      try {
        if (!await widget.onOpenExternalUri(uri)) {
          throw StateError(l10n.openSystemBrowserFailed(uri.toString()));
        }
      } catch (error) {
        if (mounted) setState(() => _webViewError = '$error');
      }
    }
    return EmbeddedNavigationDecision.prevent;
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

  Future<void> _onBridgeMessage(String message) async {
    final payload = jsonDecode(message);
    if (payload is Map<String, dynamic> && payload['type'] == 'url') {
      if (payload['url'] case final String url) {
        final controller = _controller;
        final uri = Uri.tryParse(url);
        if (controller != null && uri != null) {
          await _onPageChanged(controller, uri);
        }
      }
      return;
    }
    await _saveBlob(message);
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
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.reload();
      await _refreshHistory(controller);
    } catch (error) {
      if (mounted) setState(() => _webViewError = '$error');
    }
  }

  Future<void> _openCurrentPage() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final uri = _currentUri;
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        throw StateError(l10n.webViewCurrentUrlUnavailable);
      }
      if (!await widget.onOpenExternalUri(uri)) {
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
  const reportUrl = () => {
    SubDockBlob.postMessage(JSON.stringify({type: 'url', url: location.href}));
  };
  const wrapHistory = method => {
    const original = history[method];
    history[method] = function(...args) {
      const result = original.apply(this, args);
      window.setTimeout(reportUrl, 0);
      return result;
    };
  };
  wrapHistory('pushState');
  wrapHistory('replaceState');
  window.addEventListener('popstate', reportUrl);
  window.addEventListener('hashchange', reportUrl);
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
    if (!_ready) {
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
    final compact = MediaQuery.sizeOf(context).width < navigationBreakpoint;
    final controller = _controller;
    final webView = controller == null || !_webViewInitialized
        ? null
        : controller.build();
    return Padding(
      padding: compact ? EdgeInsets.zero : EdgeInsets.all(typography.spacingMd),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceLowest,
          border: compact ? null : Border.all(color: colors.divider),
          borderRadius: BorderRadius.circular(
            compact ? 0 : typography.radiusLg,
          ),
        ),
        // webview_all renders Linux WebViews as native GTK overlays. A
        // non-rectangular Flutter clip hides that overlay, leaving a blank
        // surface even after navigation reports success.
        child: Stack(
          children: [
            Positioned.fill(
              child: Column(
                children: [
                  Material(
                    key: const ValueKey('manage-browser-toolbar'),
                    color: colors.surfaceLow,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: colors.divider),
                        ),
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: typography.spacingXs,
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              key: const ValueKey('manage-back'),
                              tooltip: l10n.back,
                              onPressed: _canGoBack
                                  ? () => unawaited(_goBack())
                                  : null,
                              icon: const Icon(Icons.arrow_back),
                            ),
                            SizedBox(width: typography.spacingXs),
                            IconButton(
                              key: const ValueKey('manage-forward'),
                              tooltip: l10n.forward,
                              onPressed: _canGoForward
                                  ? () => unawaited(_goForward())
                                  : null,
                              icon: const Icon(Icons.arrow_forward),
                            ),
                            SizedBox(width: typography.spacingXs),
                            IconButton(
                              key: const ValueKey('manage-reload'),
                              tooltip: l10n.refresh,
                              onPressed: () => unawaited(_reloadCurrentPage()),
                              icon: const Icon(Icons.refresh),
                            ),
                            SizedBox(width: typography.spacingXs),
                            if (!compact)
                              Expanded(
                                child: Container(
                                  key: const ValueKey('manage-url'),
                                  height: 32,
                                  alignment: Alignment.centerLeft,
                                  margin: EdgeInsets.symmetric(
                                    vertical: typography.spacingXs,
                                  ),
                                  padding: EdgeInsets.symmetric(
                                    horizontal: typography.spacingSm,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colors.surfaceLowest,
                                    border: Border.all(color: colors.divider),
                                    borderRadius: BorderRadius.circular(
                                      typography.radiusMd,
                                    ),
                                  ),
                                  child: Text(
                                    _currentUri?.toString() ?? '',
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                    style: typography.bodySmall.copyWith(
                                      color: colors.disabled,
                                    ),
                                  ),
                                ),
                              ),
                            if (!compact) SizedBox(width: typography.spacingXs),
                            IconButton(
                              key: const ValueKey('manage-open-external'),
                              tooltip: l10n.openInSystemBrowser,
                              onPressed: () => unawaited(_openCurrentPage()),
                              icon: const Icon(Icons.open_in_browser),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: _webViewError != null
                        ? _manageWebViewState(
                            key: const ValueKey('manage-webview-error'),
                            icon: Icons.web_asset_off_outlined,
                            message: _webViewError!,
                            action: FilledButton(
                              onPressed: widget.onRecover,
                              child: Text(
                                widget.coordinator.canOpenWebUi
                                    ? l10n.viewOverview
                                    : l10n.fixConfiguration,
                              ),
                            ),
                          )
                        : !_webViewLoading && _webViewLoaded && webView != null
                        ? webView
                        : Stack(
                            children: [
                              if (webView != null)
                                Positioned.fill(child: webView),
                              _manageWebViewState(
                                key: const ValueKey('manage-webview-loading'),
                                icon: Icons.hourglass_top,
                                message: l10n.processing,
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _manageWebViewState({
    required Key key,
    required IconData icon,
    required String message,
    Widget? action,
  }) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(typography.spacingLg),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: _SurfacePanel(
            key: key,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 40, color: colors.onSurface),
                SizedBox(height: typography.spacingSm),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _webViewError == null
                        ? colors.onSurface
                        : colors.error,
                  ),
                ),
                if (_missingWebView2)
                  TextButton(
                    onPressed: () => unawaited(_openWebView2Download()),
                    child: Text(
                      AppLocalizations.of(context)!.openWebView2DownloadPage,
                    ),
                  ),
                if (action != null) ...[
                  SizedBox(height: typography.spacingSm),
                  action,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

part of '../app.dart';

class _ManagePage extends StatefulWidget {
  const _ManagePage({
    required this.state,
    required this.coordinator,
    required this.appliedWebUiUri,
    required this.appliedWebUiApiUri,
    required this.runtimeRunId,
    required this.sessionIdentity,
    required this.error,
    required this.enabled,
    required this.onOpenExternalUri,
    this.webViewControllerFactory,
    required this.onRecover,
  });

  final RuntimeState state;
  final AppCoordinator coordinator;
  final Uri? appliedWebUiUri;
  final Uri? appliedWebUiApiUri;
  final String? runtimeRunId;
  final String sessionIdentity;
  final Object? error;
  final bool enabled;
  final Future<bool> Function(Uri uri) onOpenExternalUri;
  final EmbeddedWebViewController Function({
    required EmbeddedNavigationHandler onNavigationRequest,
    required void Function(String message) onBlobMessage,
    required String bridgeScript,
    EmbeddedPageChangeHandler? onPageChanged,
    EmbeddedMainFrameFailureHandler? onMainFrameFailure,
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
  var _mainFrameFailurePending = false;
  String? _webViewError;
  String? _fallbackBrowserError;
  var _missingWebView2 = false;
  var _sessionGeneration = 0;
  late bool _lastReady;
  late bool _lastFallbackAvailable;
  String? _activeSessionIdentity;
  Uri? _activeWebUiUri;
  Uri? _activeWebUiApiUri;
  late final StreamSubscription<RuntimeLogRunStarted> _runStartedSubscription;
  String? _activeRuntimeRunId;

  bool get _fallbackAvailable =>
      widget.state.status == RuntimeStatus.running &&
      widget.coordinator.canOpenWebUi &&
      widget.appliedWebUiUri != null &&
      widget.appliedWebUiApiUri != null;

  bool get _ready => widget.enabled && _fallbackAvailable;

  @override
  void initState() {
    super.initState();
    _activeRuntimeRunId = widget.runtimeRunId;
    _lastReady = _ready;
    _lastFallbackAvailable = _fallbackAvailable;
    _runStartedSubscription = widget.coordinator.runtime.logRunStarted.listen(
      _onRunStarted,
    );
    unawaited(_ensureController());
  }

  @override
  void dispose() {
    _runStartedSubscription.cancel();
    super.dispose();
  }

  void _onRunStarted(RuntimeLogRunStarted event) {
    if (_activeRuntimeRunId == event.runId) return;
    _activeRuntimeRunId = event.runId;
    if (mounted) setState(_invalidateSession);
  }

  @override
  void didUpdateWidget(covariant _ManagePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final readinessChanged = _lastReady != _ready;
    _lastReady = _ready;
    final fallbackAvailabilityChanged =
        _lastFallbackAvailable != _fallbackAvailable;
    _lastFallbackAvailable = _fallbackAvailable;
    final sessionChanged =
        oldWidget.enabled != widget.enabled ||
        oldWidget.sessionIdentity != widget.sessionIdentity ||
        oldWidget.runtimeRunId != widget.runtimeRunId ||
        oldWidget.appliedWebUiUri != widget.appliedWebUiUri ||
        oldWidget.appliedWebUiApiUri != widget.appliedWebUiApiUri;
    if (readinessChanged || fallbackAvailabilityChanged || sessionChanged) {
      _invalidateSession();
      if (_ready) unawaited(_ensureController());
      return;
    }
    unawaited(_ensureController());
  }

  void _invalidateSession() {
    _sessionGeneration++;
    _controller = null;
    _activeSessionIdentity = null;
    _activeWebUiUri = null;
    _activeWebUiApiUri = null;
    _currentUri = null;
    _canGoBack = false;
    _canGoForward = false;
    _webViewInitialized = false;
    _webViewLoading = false;
    _webViewLoaded = false;
    _mainFrameFailurePending = false;
    _webViewError = null;
    _fallbackBrowserError = null;
    _missingWebView2 = false;
  }

  bool _requestIsCurrent(
    int generation,
    String identity,
    Uri webUiUri,
    Uri apiUri,
  ) =>
      mounted &&
      _ready &&
      generation == _sessionGeneration &&
      identity == _activeSessionIdentity &&
      identity == widget.sessionIdentity &&
      widget.runtimeRunId == _activeRuntimeRunId &&
      webUiUri == _activeWebUiUri &&
      webUiUri == widget.appliedWebUiUri &&
      webUiUri == widget.coordinator.appliedWebUiUri &&
      apiUri == _activeWebUiApiUri &&
      apiUri == widget.appliedWebUiApiUri &&
      apiUri == widget.coordinator.appliedWebUiApiUri;

  bool _isCurrentController(
    EmbeddedWebViewController controller,
    int generation,
    String identity,
    Uri webUiUri,
    Uri apiUri,
  ) =>
      _requestIsCurrent(generation, identity, webUiUri, apiUri) &&
      identical(_controller, controller);

  Future<void> _ensureController() async {
    if (!_ready || _controller != null) return;
    final generation = ++_sessionGeneration;
    final identity = widget.sessionIdentity;
    final webUiUri = widget.appliedWebUiUri!;
    final apiUri = widget.appliedWebUiApiUri!;
    _activeSessionIdentity = identity;
    _activeWebUiUri = webUiUri;
    _activeWebUiApiUri = apiUri;
    try {
      late final EmbeddedWebViewController controller;
      final createController =
          widget.webViewControllerFactory ?? EmbeddedWebViewController.create;
      controller = createController(
        onNavigationRequest: (request) => _onNavigationRequest(
          controller,
          generation,
          identity,
          webUiUri,
          apiUri,
          request,
        ),
        onBlobMessage: (message) => unawaited(
          _onBridgeMessage(
            controller,
            generation,
            identity,
            webUiUri,
            apiUri,
            message,
          ),
        ),
        bridgeScript: _blobDownloadBridge,
        onPageChanged: (uri) => unawaited(
          _onPageChanged(
            controller,
            generation,
            identity,
            webUiUri,
            apiUri,
            uri,
          ),
        ),
        onMainFrameFailure: (failure) => _onMainFrameFailure(
          controller,
          generation,
          identity,
          webUiUri,
          apiUri,
          failure,
        ),
      );
      if (!_requestIsCurrent(generation, identity, webUiUri, apiUri)) return;
      setState(() {
        _controller = controller;
        _currentUri = webUiUri;
        _canGoBack = false;
        _canGoForward = false;
        _webViewInitialized = false;
        _webViewLoading = true;
        _webViewLoaded = false;
        _webViewError = null;
        _missingWebView2 = false;
      });
      await controller.initialize();
      if (!_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        return;
      }
      setState(() => _webViewInitialized = true);
      await controller.loadRequest(webUiUri);
      if (!_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        return;
      }
    } catch (error) {
      if (mounted &&
          _requestIsCurrent(generation, identity, webUiUri, apiUri)) {
        final l10n = AppLocalizations.of(context)!;
        setState(() {
          _missingWebView2 = _isMissingWebView2(error);
          _webViewError = _missingWebView2
              ? l10n.webView2Missing
              : l10n.webViewLoadFailure;
          _webViewLoading = false;
          _webViewLoaded = false;
        });
      }
    }
  }

  void _onMainFrameFailure(
    EmbeddedWebViewController controller,
    int generation,
    String identity,
    Uri webUiUri,
    Uri apiUri,
    EmbeddedMainFrameFailure failure,
  ) {
    if (!_isCurrentController(
      controller,
      generation,
      identity,
      webUiUri,
      apiUri,
    )) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _mainFrameFailurePending = true;
      _webViewError = l10n.webViewMainFrameFailure;
      _webViewLoading = false;
      _webViewLoaded = false;
      _missingWebView2 = false;
    });
  }

  Future<void> _onPageChanged(
    EmbeddedWebViewController controller,
    int generation,
    String identity,
    Uri webUiUri,
    Uri apiUri,
    Uri uri,
  ) async {
    if (!_isCurrentController(
          controller,
          generation,
          identity,
          webUiUri,
          apiUri,
        ) ||
        !_sameOrigin(uri, webUiUri) ||
        _mainFrameFailurePending) {
      return;
    }
    setState(() {
      _currentUri = uri;
      _webViewLoading = false;
      _webViewLoaded = true;
      _webViewError = null;
      _missingWebView2 = false;
    });
    try {
      final canGoBack = await controller.canGoBack();
      if (!_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        return;
      }
      final canGoForward = await controller.canGoForward();
      if (!_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        return;
      }
      setState(() {
        _canGoBack = canGoBack;
        _canGoForward = canGoForward;
      });
    } on Object {
      if (_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        setState(
          () =>
              _webViewError = AppLocalizations.of(context)!
                  .webViewActionFailure,
        );
      }
    }
  }

  Future<void> _refreshHistory(
    EmbeddedWebViewController controller,
    int generation,
    String identity,
    Uri webUiUri,
    Uri apiUri,
  ) async {
    try {
      final canGoBack = await controller.canGoBack();
      if (!_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        return;
      }
      final canGoForward = await controller.canGoForward();
      if (!_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        return;
      }
      setState(() {
        _canGoBack = canGoBack;
        _canGoForward = canGoForward;
      });
    } on Object {
      if (_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        setState(
          () =>
              _webViewError = AppLocalizations.of(context)!
                  .webViewActionFailure,
        );
      }
    }
  }

  Future<void> _goBack() async {
    final controller = _controller;
    final generation = _sessionGeneration;
    final identity = _activeSessionIdentity;
    final webUiUri = _activeWebUiUri;
    final apiUri = _activeWebUiApiUri;
    if (controller == null ||
        identity == null ||
        webUiUri == null ||
        apiUri == null ||
        !_canGoBack) {
      return;
    }
    try {
      await controller.goBack();
      if (!_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        return;
      }
      await _refreshHistory(controller, generation, identity, webUiUri, apiUri);
    } on Object {
      if (_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        setState(
          () =>
              _webViewError = AppLocalizations.of(context)!
                  .webViewActionFailure,
        );
      }
    }
  }

  Future<void> _goForward() async {
    final controller = _controller;
    final generation = _sessionGeneration;
    final identity = _activeSessionIdentity;
    final webUiUri = _activeWebUiUri;
    final apiUri = _activeWebUiApiUri;
    if (controller == null ||
        identity == null ||
        webUiUri == null ||
        apiUri == null ||
        !_canGoForward) {
      return;
    }
    try {
      await controller.goForward();
      if (!_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        return;
      }
      await _refreshHistory(controller, generation, identity, webUiUri, apiUri);
    } on Object {
      if (_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        setState(
          () =>
              _webViewError = AppLocalizations.of(context)!
                  .webViewActionFailure,
        );
      }
    }
  }

  Future<EmbeddedNavigationDecision> _onNavigationRequest(
    EmbeddedWebViewController controller,
    int generation,
    String identity,
    Uri webUiUri,
    Uri apiUri,
    EmbeddedNavigationRequest request,
  ) async {
    if (!_isCurrentController(
      controller,
      generation,
      identity,
      webUiUri,
      apiUri,
    )) {
      return EmbeddedNavigationDecision.prevent;
    }
    final uri = request.uri;
    if (_sameOrigin(uri, webUiUri)) {
      if (_isDownloadUri(uri, apiUri)) {
        unawaited(
          _saveHttpDownload(
            controller,
            generation,
            identity,
            webUiUri,
            apiUri,
            uri,
          ),
        );
        return EmbeddedNavigationDecision.prevent;
      }
      return EmbeddedNavigationDecision.navigate;
    }
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      try {
        final opened = await widget.onOpenExternalUri(uri);
        if (!opened &&
            _isCurrentController(
              controller,
              generation,
              identity,
              webUiUri,
              apiUri,
            )) {
          setState(
            () =>
                _webViewError = AppLocalizations.of(context)!
                    .browserLaunchFailure,
          );
        }
      } on Object {
        if (_isCurrentController(
          controller,
          generation,
          identity,
          webUiUri,
          apiUri,
        )) {
          setState(
            () =>
                _webViewError = AppLocalizations.of(context)!
                    .browserLaunchFailure,
          );
        }
      }
    }
    return EmbeddedNavigationDecision.prevent;
  }

  Future<void> _saveHttpDownload(
    EmbeddedWebViewController controller,
    int generation,
    String identity,
    Uri webUiUri,
    Uri apiUri,
    Uri uri,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final location = await getSaveLocation(
        suggestedName: _downloadName(uri.pathSegments.lastOrNull),
      );
      if (location == null ||
          !_isCurrentController(
            controller,
            generation,
            identity,
            webUiUri,
            apiUri,
          )) {
        return;
      }
      final client = HttpClient();
      try {
        final request = await client.getUrl(uri);
        if (!_isCurrentController(
          controller,
          generation,
          identity,
          webUiUri,
          apiUri,
        )) {
          return;
        }
        final response = await request.close();
        if (!_isCurrentController(
          controller,
          generation,
          identity,
          webUiUri,
          apiUri,
        )) {
          return;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          setState(
            () => _webViewError = l10n.downloadFailedHttp(response.statusCode),
          );
          return;
        }
        final sink = File(location.path).openWrite();
        try {
          await for (final chunk in response) {
            if (!_isCurrentController(
              controller,
              generation,
              identity,
              webUiUri,
              apiUri,
            )) {
              return;
            }
            sink.add(chunk);
          }
          if (!_isCurrentController(
            controller,
            generation,
            identity,
            webUiUri,
            apiUri,
          )) {
            return;
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
      } finally {
        client.close(force: true);
      }
    } on Object {
      if (_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        setState(() => _webViewError = l10n.downloadFailed);
      }
    }
  }

  Future<void> _onBridgeMessage(
    EmbeddedWebViewController controller,
    int generation,
    String identity,
    Uri webUiUri,
    Uri apiUri,
    String message,
  ) async {
    if (!_isCurrentController(
      controller,
      generation,
      identity,
      webUiUri,
      apiUri,
    )) {
      return;
    }
    Object? payload;
    try {
      payload = jsonDecode(message);
    } on FormatException {
      setState(
        () => _webViewError = AppLocalizations.of(context)!.blobExportInvalid,
      );
      return;
    }
    if (payload is Map<String, dynamic> && payload['type'] == 'url') {
      if (payload['url'] case final String url) {
        final uri = Uri.tryParse(url);
        if (uri != null && _sameOrigin(uri, webUiUri)) {
          await _onPageChanged(
            controller,
            generation,
            identity,
            webUiUri,
            apiUri,
            uri,
          );
        }
      }
      return;
    }
    await _saveBlob(
      controller,
      generation,
      identity,
      webUiUri,
      apiUri,
      message,
    );
  }

  Future<void> _saveBlob(
    EmbeddedWebViewController controller,
    int generation,
    String identity,
    Uri webUiUri,
    Uri apiUri,
    String message,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final payload = jsonDecode(message);
      if (payload is! Map<String, dynamic>) {
        setState(() => _webViewError = l10n.blobExportInvalid);
        return;
      }
      if (payload['error'] case final String error) {
        setState(
          () => _webViewError = error == 'Blob export exceeds 16 MiB'
              ? l10n.blobExportTooLarge
              : l10n.blobExportFailed,
        );
        return;
      }
      final data = payload['data'];
      if (data is! String || data.length > (_maxBlobBytes * 4 ~/ 3) + 4) {
        setState(() => _webViewError = l10n.blobExportTooLarge);
        return;
      }
      final bytes = base64Decode(data);
      if (bytes.length > _maxBlobBytes) {
        setState(() => _webViewError = l10n.blobExportTooLarge);
        return;
      }
      final location = await getSaveLocation(
        suggestedName: _downloadName(payload['name'] as String?),
      );
      if (location == null ||
          !_isCurrentController(
            controller,
            generation,
            identity,
            webUiUri,
            apiUri,
          )) {
        return;
      }
      await File(location.path).writeAsBytes(bytes, flush: true);
    } on Object {
      if (_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        setState(() => _webViewError = l10n.blobExportFailed);
      }
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

  bool _pageContextIsCurrent({
    required String identity,
    required String? runtimeRunId,
    required int generation,
    required Uri webUiUri,
    required Uri apiUri,
  }) =>
      mounted &&
      widget.state.status == RuntimeStatus.running &&
      widget.sessionIdentity == identity &&
      widget.runtimeRunId == runtimeRunId &&
      _activeRuntimeRunId == runtimeRunId &&
      generation == _sessionGeneration &&
      widget.appliedWebUiUri == webUiUri &&
      widget.coordinator.appliedWebUiUri == webUiUri &&
      widget.appliedWebUiApiUri == apiUri &&
      widget.coordinator.appliedWebUiApiUri == apiUri;

  Future<void> _openWebView2Download() async {
    final identity = widget.sessionIdentity;
    final runtimeRunId = widget.runtimeRunId;
    final generation = _sessionGeneration;
    final webUiUri = widget.appliedWebUiUri;
    final apiUri = widget.appliedWebUiApiUri;
    if (webUiUri == null || apiUri == null) return;
    try {
      final opened = await launchUrl(
        _webView2DownloadUri,
        mode: LaunchMode.externalApplication,
      );
      if (!opened &&
          _pageContextIsCurrent(
            identity: identity,
            runtimeRunId: runtimeRunId,
            generation: generation,
            webUiUri: webUiUri,
            apiUri: apiUri,
          )) {
        setState(
          () =>
              _webViewError = AppLocalizations.of(context)!
                  .openWebView2DownloadFailed,
        );
      }
    } on Object {
      if (_pageContextIsCurrent(
        identity: identity,
        runtimeRunId: runtimeRunId,
        generation: generation,
        webUiUri: webUiUri,
        apiUri: apiUri,
      )) {
        setState(
          () =>
              _webViewError = AppLocalizations.of(context)!
                  .openWebView2DownloadFailed,
        );
      }
    }
  }

  Future<void> _retryWebView() async {
    _invalidateSession();
    await _ensureController();
  }

  Future<void> _reloadCurrentPage() async {
    final controller = _controller;
    final generation = _sessionGeneration;
    final identity = _activeSessionIdentity;
    final webUiUri = _activeWebUiUri;
    final apiUri = _activeWebUiApiUri;
    if (controller == null ||
        identity == null ||
        webUiUri == null ||
        apiUri == null) {
      return;
    }
    try {
      await controller.reload();
      if (!_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        return;
      }
      await _refreshHistory(controller, generation, identity, webUiUri, apiUri);
    } on Object {
      if (_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        setState(
          () =>
              _webViewError = AppLocalizations.of(context)!
                  .webViewActionFailure,
        );
      }
    }
  }

  Future<void> _openCurrentPage() async {
    final controller = _controller;
    final generation = _sessionGeneration;
    final identity = _activeSessionIdentity;
    final webUiUri = _activeWebUiUri;
    final apiUri = _activeWebUiApiUri;
    final uri = _currentUri;
    if (controller == null ||
        identity == null ||
        webUiUri == null ||
        apiUri == null ||
        uri == null ||
        !_isCurrentController(
          controller,
          generation,
          identity,
          webUiUri,
          apiUri,
        )) {
      return;
    }
    try {
      final opened = await widget.onOpenExternalUri(uri);
      if (!opened &&
          _isCurrentController(
            controller,
            generation,
            identity,
            webUiUri,
            apiUri,
          )) {
        setState(
          () =>
              _webViewError = AppLocalizations.of(context)!
                  .browserLaunchFailure,
        );
      }
    } on Object {
      if (_isCurrentController(
        controller,
        generation,
        identity,
        webUiUri,
        apiUri,
      )) {
        setState(
          () =>
              _webViewError = AppLocalizations.of(context)!
                  .browserLaunchFailure,
        );
      }
    }
  }

  Future<void> _openFallbackBrowser() async {
    final identity = widget.sessionIdentity;
    final runtimeRunId = widget.runtimeRunId;
    final generation = _sessionGeneration;
    final webUiUri = widget.appliedWebUiUri;
    final apiUri = widget.appliedWebUiApiUri;
    if (webUiUri == null ||
        apiUri == null ||
        !_pageContextIsCurrent(
          identity: identity,
          runtimeRunId: runtimeRunId,
          generation: generation,
          webUiUri: webUiUri,
          apiUri: apiUri,
        )) {
      return;
    }
    try {
      final opened = await widget.onOpenExternalUri(webUiUri);
      if (!_pageContextIsCurrent(
        identity: identity,
        runtimeRunId: runtimeRunId,
        generation: generation,
        webUiUri: webUiUri,
        apiUri: apiUri,
      )) {
        return;
      }
      if (opened) {
        if (_fallbackBrowserError != null) {
          setState(() => _fallbackBrowserError = null);
        }
      } else {
        setState(
          () =>
              _fallbackBrowserError = AppLocalizations.of(context)!
                  .browserLaunchFailure,
        );
      }
    } on Object {
      if (_pageContextIsCurrent(
        identity: identity,
        runtimeRunId: runtimeRunId,
        generation: generation,
        webUiUri: webUiUri,
        apiUri: apiUri,
      )) {
        setState(
          () =>
              _fallbackBrowserError = AppLocalizations.of(context)!
                  .browserLaunchFailure,
        );
      }
    }
  }

  bool _isDownloadUri(Uri uri, Uri apiUri) {
    final path = apiUri.path;
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
      final hasAppliedAddress = widget.appliedWebUiUri != null;
      final canOpenInBrowser =
          widget.state.status == RuntimeStatus.running &&
          widget.coordinator.canOpenWebUi &&
          hasAppliedAddress;
      final reason =
          _webViewError ??
          _fallbackBrowserError ??
          (issues.isNotEmpty
              ? _localizedIssue(l10n, issues.first)
              : widget.state.status == RuntimeStatus.running && !widget.enabled
              ? l10n.webViewUnavailable
              : widget.error == null
              ? widget.state.message ?? l10n.backendNotRunning
              : _localizedError(l10n, widget.error));
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
                  if (canOpenInBrowser) ...[
                    OutlinedButton.icon(
                      key: const ValueKey('manage-open-fallback-browser'),
                      onPressed: () => unawaited(_openFallbackBrowser()),
                      icon: const Icon(Icons.open_in_browser),
                      label: Text(l10n.openInSystemBrowser),
                    ),
                    SizedBox(height: typography.spacingXs),
                  ],
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
                            action: Wrap(
                              alignment: WrapAlignment.center,
                              spacing: typography.spacingS,
                              runSpacing: typography.spacingS,
                              children: [
                                FilledButton.icon(
                                  key: const ValueKey('manage-retry-load'),
                                  onPressed: () => unawaited(_retryWebView()),
                                  icon: const Icon(Icons.refresh),
                                  label: Text(l10n.retry),
                                ),
                                OutlinedButton.icon(
                                  key: const ValueKey(
                                    'manage-open-failed-browser',
                                  ),
                                  onPressed: () =>
                                      unawaited(_openCurrentPage()),
                                  icon: const Icon(Icons.open_in_browser),
                                  label: Text(l10n.openInSystemBrowser),
                                ),
                                TextButton(
                                  onPressed: widget.onRecover,
                                  child: Text(l10n.viewOverview),
                                ),
                              ],
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

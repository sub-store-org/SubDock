import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_all/webview_all.dart' as fallback;
import 'package:webview_flutter/webview_flutter.dart' as official;
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart'
    as webkit;

enum EmbeddedNavigationDecision { navigate, prevent }

class EmbeddedNavigationRequest {
  const EmbeddedNavigationRequest(this.uri);

  final Uri uri;
}

typedef EmbeddedNavigationHandler = Future<EmbeddedNavigationDecision> Function(
  EmbeddedNavigationRequest request,
);
typedef EmbeddedPageChangeHandler = void Function(Uri uri);
typedef EmbeddedMainFrameFailureHandler = void Function(
  EmbeddedMainFrameFailure failure,
);
typedef EmbeddedWebViewControllerFactory = EmbeddedWebViewController Function({
  required EmbeddedNavigationHandler onNavigationRequest,
  required void Function(String message) onBlobMessage,
  required String bridgeScript,
  required Uri trustedOrigin,
  EmbeddedPageChangeHandler? onPageChanged,
  EmbeddedMainFrameFailureHandler? onMainFrameFailure,
  bool? initialDarkMode,
});

/// Calls the app-owned macOS channel that applies appearance to one WKWebView.
class EmbeddedWebViewAppearanceChannel {
  static const _channel = MethodChannel(
    'com.subdock/embedded_webview_appearance',
  );

  static Future<bool> setAppearance({
    required int webViewIdentifier,
    required bool isDark,
    required Uri trustedOrigin,
    required bool beforeLoad,
  }) async =>
      await _channel.invokeMethod<bool>('setAppearance', {
        'webViewIdentifier': webViewIdentifier,
        'isDark': isDark,
        'trustedOrigin': trustedOrigin.origin,
        'beforeLoad': beforeLoad,
      }) ??
      false;
}

/// A main-document failure reported by the platform WebView delegate.
/// Platform messages, URLs, and exception text are deliberately not retained.
class EmbeddedMainFrameFailure {
  const EmbeddedMainFrameFailure({required this.errorCode});

  final int errorCode;
}

class EmbeddedWebViewController {
  EmbeddedWebViewController._({
    required this._initialize,
    required this._buildWidget,
    required this._loadRequest,
    required this._reload,
    required this._currentUrl,
    required this._canGoBack,
    required this._goBack,
    required this._canGoForward,
    required this._goForward,
    required this._setColorScheme,
  });

  EmbeddedWebViewController.testing({
    required Future<void> Function() initialize,
    required Widget Function() buildWidget,
    required Future<void> Function(Uri uri) loadRequest,
    required Future<void> Function() reload,
    required Future<Uri?> Function() currentUrl,
    required Future<bool> Function() canGoBack,
    required Future<void> Function() goBack,
    required Future<bool> Function() canGoForward,
    required Future<void> Function() goForward,
    Future<bool> Function(bool isDark, Uri trustedOrigin)? setColorScheme,
  }) : this._(
         initialize: initialize,
         buildWidget: buildWidget,
         loadRequest: loadRequest,
         reload: reload,
         currentUrl: currentUrl,
         canGoBack: canGoBack,
         goBack: goBack,
         canGoForward: canGoForward,
         goForward: goForward,
         setColorScheme: setColorScheme ?? _ignoreColorScheme,
       );

  final Future<void> Function() _initialize;
  final Widget Function() _buildWidget;
  final Future<void> Function(Uri uri) _loadRequest;
  final Future<void> Function() _reload;
  final Future<Uri?> Function() _currentUrl;
  final Future<bool> Function() _canGoBack;
  final Future<void> Function() _goBack;
  final Future<bool> Function() _canGoForward;
  final Future<void> Function() _goForward;
  final Future<bool> Function(bool isDark, Uri trustedOrigin) _setColorScheme;

  static Future<bool> _ignoreColorScheme(
    bool isDark,
    Uri trustedOrigin,
  ) async => false;

  static const String colorSchemeBridgeSource = r'''(() => {
  const trustedOrigin = __SUBDOCK_TRUSTED_ORIGIN__;
  if (window.location.origin !== trustedOrigin) return;
  const query = '(prefers-color-scheme: dark)';
  const nativeMatchMedia = window.matchMedia.bind(window);
  let dark = __SUBDOCK_INITIAL_DARK__;
  let onChange = null;
  const mediaQuery = new EventTarget();
  const legacyListeners = new Set();
  Object.defineProperties(mediaQuery, {
    matches: { get: () => dark, enumerable: true },
    media: { value: query, enumerable: true },
    onchange: {
      get: () => onChange,
      set: (listener) => { onChange = listener; },
      enumerable: true
    }
  });
  mediaQuery.addListener = (listener) => { legacyListeners.add(listener); };
  mediaQuery.removeListener = (listener) => { legacyListeners.delete(listener); };
  window.matchMedia = (media) => media === query
    ? mediaQuery
    : nativeMatchMedia(media);
  Object.defineProperty(globalThis, '__subDockSetColorScheme', {
    configurable: false,
    value: (nextDark) => {
      const next = Boolean(nextDark);
      if (dark === next) return;
      dark = next;
      const event = new Event('change');
      Object.defineProperties(event, {
        matches: { value: dark },
        media: { value: query }
      });
      mediaQuery.dispatchEvent(event);
      for (const listener of legacyListeners) listener.call(mediaQuery, event);
      if (typeof onChange === 'function') onChange.call(mediaQuery, event);
    }
  });
})();''';

  static String colorSchemeScript({
    required bool initialDark,
    required Uri trustedOrigin,
  }) => colorSchemeBridgeSource
      .replaceAll('__SUBDOCK_INITIAL_DARK__', initialDark ? 'true' : 'false')
      .replaceAll(
        '__SUBDOCK_TRUSTED_ORIGIN__',
        jsonEncode(trustedOrigin.origin),
      );

  static const String colorSchemeLiveUpdateSource =
      r'''if (window.location.origin === __SUBDOCK_TRUSTED_ORIGIN__) {
  globalThis.__subDockSetColorScheme?.(__SUBDOCK_NEXT_DARK__);
}''';

  static String colorSchemeLiveUpdateScript({
    required bool isDark,
    required Uri trustedOrigin,
  }) => colorSchemeLiveUpdateSource
      .replaceAll(
        '__SUBDOCK_TRUSTED_ORIGIN__',
        jsonEncode(trustedOrigin.origin),
      )
      .replaceAll('__SUBDOCK_NEXT_DARK__', isDark ? 'true' : 'false');

  static EmbeddedWebViewController create({
    required EmbeddedNavigationHandler onNavigationRequest,
    required void Function(String message) onBlobMessage,
    required String bridgeScript,
    EmbeddedPageChangeHandler? onPageChanged,
    EmbeddedMainFrameFailureHandler? onMainFrameFailure,
    required Uri trustedOrigin,
    bool initialDarkMode = false,
  }) {
    if (Platform.isMacOS) {
      final controller = official.WebViewController();
      final webViewIdentifier =
          (controller.platform as webkit.WebKitWebViewController)
              .webViewIdentifier;
      return EmbeddedWebViewController._(
        initialize: () async {
          final appearanceApplied =
              await EmbeddedWebViewAppearanceChannel.setAppearance(
                webViewIdentifier: webViewIdentifier,
                isDark: initialDarkMode,
                trustedOrigin: trustedOrigin,
                beforeLoad: true,
              );
          if (!appearanceApplied) {
            throw StateError('Could not set embedded WebView appearance.');
          }
          await controller.setJavaScriptMode(
            official.JavaScriptMode.unrestricted,
          );
          await controller.setNavigationDelegate(
            official.NavigationDelegate(
              onNavigationRequest: (request) async {
                final decision = await _navigationDecision(
                  onNavigationRequest,
                  request.url,
                );
                return decision == EmbeddedNavigationDecision.navigate
                    ? official.NavigationDecision.navigate
                    : official.NavigationDecision.prevent;
              },
              onPageFinished: (url) async {
                _publishPage(onPageChanged, url);
                await controller.runJavaScript(bridgeScript);
              },
              onWebResourceError: (error) => _publishMainFrameFailure(
                onMainFrameFailure,
                error.isForMainFrame,
                error.errorCode,
              ),
            ),
          );
          await controller.addJavaScriptChannel(
            'SubDockBlob',
            onMessageReceived: (message) => onBlobMessage(message.message),
          );
        },
        buildWidget: () => official.WebViewWidget(controller: controller),
        loadRequest: controller.loadRequest,
        reload: controller.reload,
        currentUrl: () async => _parseCurrentUrl(await controller.currentUrl()),
        canGoBack: controller.canGoBack,
        goBack: controller.goBack,
        canGoForward: controller.canGoForward,
        goForward: controller.goForward,
        setColorScheme: (isDark, origin) =>
            EmbeddedWebViewAppearanceChannel.setAppearance(
              webViewIdentifier: webViewIdentifier,
              isDark: isDark,
              trustedOrigin: origin,
              beforeLoad: false,
            ),
      );
    }

    if (!Platform.isWindows && !Platform.isLinux) {
      throw UnsupportedError(
        'Embedded WebView is implemented only for macOS, Windows, and Linux',
      );
    }

    final controller = fallback.WebViewController();
    return EmbeddedWebViewController._(
      initialize: () async {
        await controller.setJavaScriptMode(
          fallback.JavaScriptMode.unrestricted,
        );
        await controller.setNavigationDelegate(
          fallback.NavigationDelegate(
            onNavigationRequest: (request) async {
              final decision = await _navigationDecision(
                onNavigationRequest,
                request.url,
              );
              return decision == EmbeddedNavigationDecision.navigate
                  ? fallback.NavigationDecision.navigate
                  : fallback.NavigationDecision.prevent;
            },
            onPageFinished: (url) => _publishPage(onPageChanged, url),
            onWebResourceError: (error) => _publishMainFrameFailure(
              onMainFrameFailure,
              error.isForMainFrame,
              error.errorCode,
            ),
          ),
        );
        await controller.addJavaScriptChannel(
          'SubDockBlob',
          onMessageReceived: (message) => onBlobMessage(message.message),
        );
        await controller.addUserScript(
          fallback.WebViewUserScript(
            source: colorSchemeScript(
              initialDark: initialDarkMode,
              trustedOrigin: trustedOrigin,
            ),
            forMainFrameOnly: true,
          ),
        );
        await controller.addUserScript(
          fallback.WebViewUserScript(source: bridgeScript),
        );
      },
      buildWidget: () => fallback.WebViewWidget(controller: controller),
      loadRequest: controller.loadRequest,
      reload: controller.reload,
      currentUrl: () async => _parseCurrentUrl(await controller.currentUrl()),
      canGoBack: controller.canGoBack,
      goBack: controller.goBack,
      canGoForward: controller.canGoForward,
      goForward: controller.goForward,
      setColorScheme: (isDark, origin) async {
        await controller.runJavaScript(
          colorSchemeLiveUpdateScript(isDark: isDark, trustedOrigin: origin),
        );
        return true;
      },
    );
  }

  Future<void> initialize() => _initialize();

  Future<void> loadRequest(Uri uri) => _loadRequest(uri);

  Future<void> reload() => _reload();

  Future<Uri?> currentUrl() => _currentUrl();

  Future<bool> canGoBack() => _canGoBack();

  Future<void> goBack() => _goBack();

  Future<bool> canGoForward() => _canGoForward();

  Future<void> goForward() => _goForward();

  Future<bool> setColorScheme({
    required bool isDark,
    required Uri trustedOrigin,
  }) async {
    if (!supportsEffectiveColorSchemeSync) return false;
    final current = await _currentUrl();
    if (current == null || !_sameOrigin(current, trustedOrigin)) return false;
    return _setColorScheme(isDark, trustedOrigin);
  }

  static bool get supportsDocumentStartColorSchemeBridge =>
      Platform.isLinux || Platform.isWindows;

  static bool get supportsNativeColorSchemeAppearance => Platform.isMacOS;

  static bool get supportsEffectiveColorSchemeSync =>
      supportsDocumentStartColorSchemeBridge ||
      supportsNativeColorSchemeAppearance;

  Widget build() => _buildWidget();
}

void _publishMainFrameFailure(
  EmbeddedMainFrameFailureHandler? handler,
  bool? isForMainFrame,
  int errorCode,
) {
  if (isForMainFrame == true) {
    handler?.call(EmbeddedMainFrameFailure(errorCode: errorCode));
  }
}

void _publishPage(EmbeddedPageChangeHandler? handler, String value) {
  final uri = Uri.tryParse(value);
  if (uri != null) handler?.call(uri);
}

Future<EmbeddedNavigationDecision> _navigationDecision(
  EmbeddedNavigationHandler handler,
  String value,
) {
  final uri = Uri.tryParse(value);
  if (uri == null) {
    return Future.value(EmbeddedNavigationDecision.prevent);
  }
  return handler(EmbeddedNavigationRequest(uri));
}

bool _sameOrigin(Uri first, Uri second) =>
    first.scheme == second.scheme &&
    first.host == second.host &&
    first.port == second.port;

Uri? _parseCurrentUrl(String? value) =>
    value == null ? null : Uri.tryParse(value);

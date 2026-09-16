import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_all/webview_all.dart' as fallback;
import 'package:webview_flutter/webview_flutter.dart' as official;

enum EmbeddedNavigationDecision { navigate, prevent }

class EmbeddedNavigationRequest {
  const EmbeddedNavigationRequest(this.uri);

  final Uri uri;
}

typedef EmbeddedNavigationHandler = Future<EmbeddedNavigationDecision> Function(
  EmbeddedNavigationRequest request,
);
typedef EmbeddedPageChangeHandler = void Function(Uri uri);

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

  static EmbeddedWebViewController create({
    required EmbeddedNavigationHandler onNavigationRequest,
    required void Function(String message) onBlobMessage,
    required String bridgeScript,
    EmbeddedPageChangeHandler? onPageChanged,
  }) {
    if (Platform.isMacOS) {
      final controller = official.WebViewController();
      return EmbeddedWebViewController._(
        initialize: () async {
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
          ),
        );
        await controller.addJavaScriptChannel(
          'SubDockBlob',
          onMessageReceived: (message) => onBlobMessage(message.message),
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

  Widget build() => _buildWidget();
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

Uri? _parseCurrentUrl(String? value) =>
    value == null ? null : Uri.tryParse(value);

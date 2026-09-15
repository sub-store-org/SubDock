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

class EmbeddedWebViewController {
  EmbeddedWebViewController._({
    required this._controller,
    required this._initialize,
    required this._buildWidget,
    required this._reload,
    required this._currentUrl,
  });

  final Object _controller;
  final Future<void> Function() _initialize;
  final Widget Function() _buildWidget;
  final Future<void> Function() _reload;
  final Future<Uri?> Function() _currentUrl;

  static EmbeddedWebViewController create({
    required EmbeddedNavigationHandler onNavigationRequest,
    required void Function(String message) onBlobMessage,
    required String bridgeScript,
  }) {
    if (Platform.isMacOS) {
      final controller = official.WebViewController();
      return EmbeddedWebViewController._(
        controller: controller,
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
              onPageFinished: (_) async {
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
        reload: controller.reload,
        currentUrl: () async => _parseCurrentUrl(await controller.currentUrl()),
      );
    }

    if (!Platform.isWindows && !Platform.isLinux) {
      throw UnsupportedError(
        'Embedded WebView is implemented only for macOS, Windows, and Linux',
      );
    }

    final controller = fallback.WebViewController();
    return EmbeddedWebViewController._(
      controller: controller,
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
      reload: controller.reload,
      currentUrl: () async => _parseCurrentUrl(await controller.currentUrl()),
    );
  }

  Future<void> initialize() => _initialize();

  Future<void> loadRequest(Uri uri) => switch (_controller) {
    official.WebViewController controller => controller.loadRequest(uri),
    fallback.WebViewController controller => controller.loadRequest(uri),
    _ => throw StateError('Unsupported WebView controller'),
  };

  Future<void> reload() => _reload();

  Future<Uri?> currentUrl() => _currentUrl();

  Widget build() => _buildWidget();
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

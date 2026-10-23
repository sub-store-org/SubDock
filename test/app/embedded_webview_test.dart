import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/embedded_webview.dart';
// The adapter boundary is owned by webview_all's platform interface.
// ignore: depend_on_referenced_packages
import 'package:webview_platform_interface/webview_platform_interface.dart'
    as webview_platform;

void main() {
  test(
    'Linux WebView adapter reports only main-frame resource failures',
    () async {
      final previousPlatform = webview_platform.WebViewPlatform.instance;
      final platform = _TestWebViewPlatform();
      webview_platform.WebViewPlatform.instance = platform;
      try {
        final failures = <EmbeddedMainFrameFailure>[];
        final controller = EmbeddedWebViewController.create(
          onNavigationRequest: (_) async => EmbeddedNavigationDecision.navigate,
          onBlobMessage: (_) {},
          bridgeScript: 'window.fixture = true;',
          onMainFrameFailure: failures.add,
        );
        await controller.initialize();

        final reportError = platform.navigationDelegate.onWebResourceError!;
        reportError(
          const webview_platform.WebResourceError(
            errorCode: -2,
            description: 'subresource failure',
            isForMainFrame: false,
          ),
        );
        expect(failures, isEmpty);

        reportError(
          const webview_platform.WebResourceError(
            errorCode: -105,
            description: 'main document failure',
            isForMainFrame: true,
          ),
        );
        expect(failures.map((failure) => failure.errorCode), [-105]);
      } finally {
        if (previousPlatform != null) {
          webview_platform.WebViewPlatform.instance = previousPlatform;
        }
      }
    },
    skip: !Platform.isLinux,
  );
}

class _TestWebViewPlatform extends webview_platform.WebViewPlatform {
  late _TestPlatformWebViewController controller;
  late _TestPlatformNavigationDelegate navigationDelegate;

  @override
  webview_platform.PlatformWebViewController createPlatformWebViewController(
    webview_platform.PlatformWebViewControllerCreationParams params,
  ) {
    return controller = _TestPlatformWebViewController(params);
  }

  @override
  webview_platform.PlatformNavigationDelegate createPlatformNavigationDelegate(
    webview_platform.PlatformNavigationDelegateCreationParams params,
  ) {
    return navigationDelegate = _TestPlatformNavigationDelegate(params);
  }
}

class _TestPlatformWebViewController
    extends webview_platform.PlatformWebViewController {
  _TestPlatformWebViewController(super.params) : super.implementation();

  @override
  Future<void> setJavaScriptMode(webview_platform.JavaScriptMode mode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    webview_platform.PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> addJavaScriptChannel(
    webview_platform.JavaScriptChannelParams javaScriptChannelParams,
  ) async {}

  @override
  Future<bool> isUserScriptInjectionSupported(
    webview_platform.WebViewUserScriptInjectionTime injectionTime,
  ) async => true;

  @override
  Future<String> addUserScript(
    webview_platform.WebViewUserScript userScript,
  ) async => 'fixture-script';
}

class _TestPlatformNavigationDelegate
    extends webview_platform.PlatformNavigationDelegate {
  _TestPlatformNavigationDelegate(super.params) : super.implementation();

  webview_platform.WebResourceErrorCallback? onWebResourceError;

  @override
  Future<void> setOnNavigationRequest(
    webview_platform.NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageFinished(
    webview_platform.PageEventCallback onPageFinished,
  ) async {}

  @override
  Future<void> setOnWebResourceError(
    webview_platform.WebResourceErrorCallback onWebResourceError,
  ) async {
    this.onWebResourceError = onWebResourceError;
  }
}

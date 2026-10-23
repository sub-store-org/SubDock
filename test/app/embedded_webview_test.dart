import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/embedded_webview.dart';
// The adapter boundary is owned by webview_all's platform interface.
// ignore: depend_on_referenced_packages
import 'package:webview_platform_interface/webview_platform_interface.dart'
    as webview_platform;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('macOS appearance channel targets one current WebView', () async {
    const channel = MethodChannel('com.subdock/embedded_webview_appearance');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final origin = Uri.parse('http://127.0.0.1:3001/');

    expect(
      await EmbeddedWebViewAppearanceChannel.setAppearance(
        webViewIdentifier: 42,
        isDark: true,
        trustedOrigin: origin,
        beforeLoad: true,
      ),
      isTrue,
    );
    expect(
      await EmbeddedWebViewAppearanceChannel.setAppearance(
        webViewIdentifier: 42,
        isDark: false,
        trustedOrigin: origin,
        beforeLoad: false,
      ),
      isTrue,
    );
    expect(calls.map((call) => call.method), [
      'setAppearance',
      'setAppearance',
    ]);
    expect(calls.first.arguments, {
      'webViewIdentifier': 42,
      'isDark': true,
      'trustedOrigin': 'http://127.0.0.1:3001',
      'beforeLoad': true,
    });
    expect(calls.last.arguments, {
      'webViewIdentifier': 42,
      'isDark': false,
      'trustedOrigin': 'http://127.0.0.1:3001',
      'beforeLoad': false,
    });
  });

  test(
    'Linux WebView applies document-start and live theme through its adapter',
    () async {
      final previousPlatform = webview_platform.WebViewPlatform.instance;
      final platform = _TestWebViewPlatform();
      webview_platform.WebViewPlatform.instance = platform;
      try {
        final controller = EmbeddedWebViewController.create(
          onNavigationRequest: (_) async => EmbeddedNavigationDecision.navigate,
          onBlobMessage: (_) {},
          bridgeScript: 'window.fixture = true;',
          trustedOrigin: Uri.parse('http://127.0.0.1:3001/'),
          initialDarkMode: true,
        );
        await controller.initialize();

        final script = platform.controller.userScripts.first;
        final blobScript = platform.controller.userScripts.last;
        expect(platform.controller.userScripts, hasLength(2));
        expect(blobScript.source, 'window.fixture = true;');
        expect(
          blobScript.forMainFrameOnly,
          const webview_platform.WebViewUserScript(source: '').forMainFrameOnly,
        );
        expect(
          script.injectionTime,
          webview_platform.WebViewUserScriptInjectionTime.documentStart,
        );
        expect(script.forMainFrameOnly, isTrue);
        expect(script.source, contains('window.matchMedia ='));
        expect(script.source, contains('let dark = true;'));
        expect(
          script.source,
          contains('window.location.origin !== trustedOrigin'),
        );
        expect(
          script.source,
          contains('const trustedOrigin = "http://127.0.0.1:3001";'),
        );
        expect(script.source, contains('media === query'));
        expect(script.source, isNot(contains('window.fixture = true;')));

        platform.controller.url = Uri.parse('http://127.0.0.1:3001/subs');
        final trustedOrigin = Uri.parse('http://127.0.0.1:3001/');
        expect(
          await controller.setColorScheme(
            isDark: false,
            trustedOrigin: trustedOrigin,
          ),
          isTrue,
        );
        expect(platform.controller.javaScriptCalls, [
          'if (window.location.origin === "http://127.0.0.1:3001") {\n'
              '  globalThis.__subDockSetColorScheme?.(false);\n'
              '}',
        ]);

        platform.controller.url = Uri.parse('https://example.com/');
        expect(
          await controller.setColorScheme(
            isDark: true,
            trustedOrigin: trustedOrigin,
          ),
          isFalse,
        );
        expect(platform.controller.javaScriptCalls, hasLength(1));
      } finally {
        if (previousPlatform != null) {
          webview_platform.WebViewPlatform.instance = previousPlatform;
        }
      }
    },
    skip: !Platform.isLinux,
  );

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
          trustedOrigin: Uri.parse('http://127.0.0.1:3001/'),
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

  final List<webview_platform.WebViewUserScript> userScripts = [];
  final List<String> javaScriptCalls = [];
  Uri? url;

  @override
  Future<String?> currentUrl() async => url?.toString();

  @override
  Future<void> runJavaScript(String javaScript) async {
    javaScriptCalls.add(javaScript);
  }

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
  ) async {
    userScripts.add(userScript);
    return 'fixture-script';
  }
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

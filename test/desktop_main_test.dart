import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/desktop_main.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  test('uses the native title bar and no custom chrome on macOS', () {
    expect(
      desktopWindowOptions(isMacOS: true).titleBarStyle,
      TitleBarStyle.normal,
    );
    expect(usesCustomDesktopChrome(isMacOS: true), isFalse);
  });

  test('keeps the custom title bar on Windows and Linux', () {
    expect(
      desktopWindowOptions(isMacOS: false).titleBarStyle,
      TitleBarStyle.hidden,
    );
    expect(usesCustomDesktopChrome(isMacOS: false), isTrue);
  });

  for (final hidden in [true, false]) {
    test('applies ${hidden ? 'hidden' : 'visible'} startup visibility', () async {
      final calls = <String>[];
      final visibilityApplied = Completer<void>();
      Future<void> applyVisibility(String action) async {
        await Future<void>.value();
        calls.add(action);
        if (calls.contains('ready')) visibilityApplied.complete();
      }

      await prepareStartupWindow(
        startHiddenToTray: hidden,
        hide: () => applyVisibility('hide'),
        show: () => applyVisibility('show'),
        waitUntilReady: (options, callback) async {
          calls.add('ready');
          // window_manager invokes its readiness callback without awaiting it.
          unawaited(callback!());
        },
      );
      await visibilityApplied.future;

      expect(calls, hidden ? ['hide', 'ready', 'hide'] : ['ready', 'show']);
    });
  }

  group('resolveEffectiveLocale', () {
    test('uses the system locale without a saved preference', () {
      expect(
        resolveEffectiveLocale(null, const [Locale('en')]),
        const Locale('en'),
      );
      expect(
        resolveEffectiveLocale(null, const [Locale('zh')]),
        const Locale('zh'),
      );
    });

    test('keeps a saved preference over the system locale', () {
      expect(
        resolveEffectiveLocale('zh', const [Locale('en')]),
        const Locale('zh'),
      );
      expect(
        resolveEffectiveLocale('en', const [Locale('zh')]),
        const Locale('en'),
      );
    });

    test('uses Flutter locale fallback for unsupported system locales', () {
      expect(
        resolveEffectiveLocale(null, const [Locale('fr')]),
        const Locale('en'),
      );
    });
  });
}

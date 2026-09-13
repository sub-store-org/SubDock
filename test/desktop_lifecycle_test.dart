import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/desktop_lifecycle.dart';
import 'package:subdock/settings/desktop_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uses the packaged platform tray icon', () {
    final bundle = Directory('/opt/subdock');

    expect(
      trayIconPath(bundleDirectory: bundle, isWindows: false),
      '/opt/subdock/data/tray_icon.png',
    );
    expect(
      trayIconPath(bundleDirectory: bundle, isWindows: true),
      '/opt/subdock/data/tray_icon.ico',
    );
  });

  test('does not use unsupported Linux tray tooltips', () {
    expect(traySupportsToolTip(isLinux: true), isFalse);
    expect(traySupportsToolTip(isLinux: false), isTrue);
  });

  test('only supported desktops pop up tray context menus', () {
    expect(
      traySupportsPopupContextMenu(isWindows: true, isMacOS: false),
      isTrue,
    );
    expect(
      traySupportsPopupContextMenu(isWindows: false, isMacOS: true),
      isTrue,
    );
    expect(
      traySupportsPopupContextMenu(isWindows: false, isMacOS: false),
      isFalse,
    );
  });

  test('intercepts native close events before initializing the tray', () async {
    final windowCalls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const windowChannel = MethodChannel('window_manager');
    const trayChannel = MethodChannel('tray_manager');
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      windowCalls.add(call);
      return true;
    });
    messenger.setMockMethodCallHandler(trayChannel, (call) async => true);
    addTearDown(() {
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(trayChannel, null);
    });

    await DesktopLifecycle(onExit: () async {}).initialize();

    expect(windowCalls.map((call) => call.method), [
      'setPreventClose',
      'isMaximized',
    ]);
  });

  test(
    'forwards minimize and maximize controls to the desktop window',
    () async {
      final windowCalls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const windowChannel = MethodChannel('window_manager');
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        windowCalls.add(call);
        if (call.method == 'isMaximized') return false;
        return true;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(windowChannel, null),
      );
      final lifecycle = DesktopLifecycle(onExit: () async {});

      await lifecycle.minimize();
      await lifecycle.toggleMaximize();

      expect(windowCalls.map((call) => call.method), [
        'minimize',
        'isMaximized',
        'maximize',
      ]);
      expect(windowCalls.last.arguments, {'vertically': false});
    },
  );

  test('close behavior exits or hides only after approval', () async {
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('window_manager');
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final exiting = DesktopLifecycle(
      onExit: () async => calls.add('exit'),
      closeBehavior: () async => CloseBehavior.exitApp,
    );
    exiting.onWindowClose();
    await Future<void>.delayed(Duration.zero);
    expect(calls, contains('exit'));
    expect(calls, contains('destroy'));

    calls.clear();
    final tray = DesktopLifecycle(
      onExit: () async => calls.add('exit'),
      closeBehavior: () async => CloseBehavior.closeToTray,
    );
    tray.onWindowClose();
    await Future<void>.delayed(Duration.zero);
    expect(calls, contains('exit'));
  });

  test('maximize events update the public state', () {
    final lifecycle = DesktopLifecycle(onExit: () async {});
    expect(lifecycle.isMaximized.value, isFalse);
    lifecycle.onWindowMaximize();
    expect(lifecycle.isMaximized.value, isTrue);
    lifecycle.onWindowUnmaximize();
    expect(lifecycle.isMaximized.value, isFalse);
  });

  test('restores a minimized window when opening it from the tray', () async {
    final windowCalls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const windowChannel = MethodChannel('window_manager');
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      windowCalls.add(call);
      if (call.method == 'isMinimized') return true;
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));

    final lifecycle = DesktopLifecycle(onExit: () async {});
    lifecycle.onTrayIconMouseDown();
    await Future<void>.delayed(Duration.zero);

    final methods = windowCalls.map((call) => call.method).toList();
    expect(methods.first, 'isMinimized');
    expect(methods, contains('restore'));
    expect(methods, containsAllInOrder(['show', 'focus']));
  });

  test('shows a hidden non-minimized window from the tray', () async {
    final methods = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('window_manager');
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'isMinimized') return false;
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    DesktopLifecycle(onExit: () async {}).onTrayIconMouseDown();
    await Future<void>.delayed(Duration.zero);

    expect(methods.first, 'isMinimized');
    expect(methods, containsAllInOrder(['show', 'focus']));
    expect(methods, isNot(contains('restore')));
  });
}

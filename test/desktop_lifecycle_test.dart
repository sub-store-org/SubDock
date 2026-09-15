import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/close_request_guard.dart';
import 'package:subdock/desktop_lifecycle.dart';
import 'package:subdock/settings/desktop_preferences.dart';
import 'package:tray_manager/tray_manager.dart';

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

  test('a failed exit can be retried', () async {
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const windowChannel = MethodChannel('window_manager');
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      calls.add(call.method);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));
    var attempts = 0;
    final lifecycle = DesktopLifecycle(
      onExit: () async {
        attempts++;
        if (attempts == 1) {
          throw StateError('fixture cleanup failure');
        }
      },
    );

    await expectLater(lifecycle.exit(), throwsStateError);
    expect(attempts, 1);
    expect(calls, isNot(contains('destroy')));

    await lifecycle.exit();

    expect(attempts, 2);
    expect(calls.where((method) => method == 'destroy'), hasLength(1));
  });

  test('hides a ready tray instead of exiting', () async {
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const windowChannel = MethodChannel('window_manager');
    const trayChannel = MethodChannel('tray_manager');
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      calls.add(call.method);
      if (call.method == 'isMaximized') return false;
      return true;
    });
    messenger.setMockMethodCallHandler(trayChannel, (call) async {
      calls.add('tray:${call.method}');
      return true;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(trayChannel, null);
    });
    var exits = 0;
    final lifecycle = DesktopLifecycle(
      onExit: () async => exits++,
      closeBehavior: () async => CloseBehavior.closeToTray,
      bundleDirectory: Directory('/opt/subdock'),
    );
    await lifecycle.initialize();
    calls.clear();

    lifecycle.onWindowClose();
    await Future<void>.delayed(Duration.zero);

    expect(calls, contains('hide'));
    expect(exits, 0);
  });

  test('rejecting approval prevents lifecycle shutdown', () async {
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('window_manager');
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final lifecycle = DesktopLifecycle(
      onExit: () async => calls.add('exit'),
      closeRequestGuard: CloseRequestGuard(approvalHandler: () async => false),
      closeBehavior: () async => CloseBehavior.exitApp,
    );

    lifecycle.onWindowClose();
    await Future<void>.delayed(Duration.zero);

    expect(calls, isEmpty);
  });

  test(
    'tray Exit uses the guard and exits once for concurrent requests',
    () async {
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('window_manager');
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      var approvals = 0;
      var exits = 0;
      final lifecycle = DesktopLifecycle(
        onExit: () async {
          exits++;
          await Future<void>.delayed(Duration.zero);
        },
        closeRequestGuard: CloseRequestGuard(
          approvalHandler: () async {
            approvals++;
            await Future<void>.delayed(Duration.zero);
            return true;
          },
        ),
      );

      lifecycle.onTrayMenuItemClick(MenuItem(key: TrayItem.exit.name));
      lifecycle.onTrayMenuItemClick(MenuItem(key: TrayItem.exit.name));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(approvals, 1);
      expect(exits, 1);
      expect(calls, contains('destroy'));
    },
  );

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

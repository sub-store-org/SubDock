import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/close_request_guard.dart';
import 'package:subdock/desktop_lifecycle.dart';
import 'package:subdock/desktop_tray.dart';
import 'package:subdock/settings/config_error.dart';
import 'package:subdock/settings/desktop_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'uses the Flutter asset tray icon on Linux, packaged ico on Windows',
    () {
      final bundle = Directory('/opt/subdock');

      expect(
        trayIconPath(bundleDirectory: bundle, isWindows: false),
        'assets/icon/app_icon_32.png',
      );
      expect(
        trayIconPath(bundleDirectory: bundle, isWindows: true),
        '/opt/subdock/data/tray_icon.ico',
      );
    },
  );

  test('intercepts native close events before initializing the tray', () async {
    final windowCalls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const windowChannel = MethodChannel('window_manager');
    final tray = _FakeTray();
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      windowCalls.add(call);
      if (call.method != 'destroy') expect(tray.initialized, isFalse);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));
    final lifecycle = DesktopLifecycle(onExit: () async {}, tray: tray);
    addTearDown(lifecycle.exit);

    await lifecycle.initialize();
    expect(tray.initialized, isTrue);

    expect(windowCalls.map((call) => call.method), [
      'setPreventClose',
      'isMaximized',
    ]);
    expect(windowCalls.first.arguments, {'isPreventClose': true});
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

  test(
    'exits on close when requested or when the tray is unavailable',
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

      final exiting = DesktopLifecycle(
        onExit: () async => calls.add('exit'),
        closeBehavior: () async => CloseBehavior.exitApp,
      );
      exiting.onWindowClose();
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['exit', 'destroy']);

      calls.clear();
      final tray = DesktopLifecycle(
        onExit: () async => calls.add('exit'),
        closeBehavior: () async => CloseBehavior.closeToTray,
      );
      tray.onWindowClose();
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['exit', 'destroy']);
    },
  );

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
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      calls.add(call.method);
      if (call.method == 'isMaximized') return false;
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));
    var exits = 0;
    final lifecycle = DesktopLifecycle(
      onExit: () async => exits++,
      closeBehavior: () async => CloseBehavior.closeToTray,
      tray: _FakeTray(),
    );
    addTearDown(lifecycle.exit);
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
      final tray = _FakeTray();
      final lifecycle = DesktopLifecycle(
        tray: tray,
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

      await lifecycle.initialize();
      calls.clear();
      final first = tray.onExit();
      final second = tray.onExit();
      await Future.wait([first, second]);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(approvals, 1);
      expect(exits, 1);
      expect(calls, contains('destroy'));
      expect(tray.disposals, 1);
    },
  );

  test(
    'tray initialization failure warns and exits instead of hiding',
    () async {
      final methods = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('window_manager');
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      var exits = 0;
      final tray = _FakeTray()..initializationError = StateError('unavailable');
      final lifecycle = DesktopLifecycle(
        onExit: () async => exits++,
        tray: tray,
      );

      await lifecycle.initialize();
      expect(
        lifecycle.warning.value,
        isA<AppConfigError>().having(
          (error) => error.code,
          'code',
          AppConfigErrorCode.trayUnavailable,
        ),
      );
      methods.clear();
      await lifecycle.closeToTray();

      expect(exits, 1);
      expect(methods, ['destroy']);
      expect(tray.disposals, 0);
    },
  );

  test('updates localized tray labels and reports update failures', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('window_manager');
    messenger.setMockMethodCallHandler(channel, (call) async => false);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    var chinese = false;
    final tray = _FakeTray();
    final lifecycle = DesktopLifecycle(
      onExit: () async {},
      tray: tray,
      trayLabels: (item) => switch (item) {
        TrayItem.show => chinese ? '显示窗口' : 'Show window',
        TrayItem.exit => chinese ? '退出' : 'Exit',
      },
    );
    addTearDown(lifecycle.exit);
    await lifecycle.updateTray();
    expect(tray.labels, isEmpty);
    await lifecycle.initialize();
    expect(tray.labels, ['Show window', 'Exit']);

    chinese = true;
    await lifecycle.updateTray();
    expect(tray.labels, ['显示窗口', '退出']);
    tray.updateError = StateError('update failed');
    await lifecycle.updateTray();
    expect(lifecycle.warning.value, isA<AppConfigError>());
  });

  test(
    'failed window destruction does not dispose tray twice on retry',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('window_manager');
      var destroys = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'destroy' && destroys++ == 0) {
          throw PlatformException(code: 'fixture');
        }
        return false;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final tray = _FakeTray();
      final lifecycle = DesktopLifecycle(onExit: () async {}, tray: tray);
      await lifecycle.initialize();

      await expectLater(lifecycle.exit(), throwsA(isA<PlatformException>()));
      await lifecycle.exit();

      expect(destroys, 2);
      expect(tray.disposals, 1);
    },
  );

  test('tray exit rejection keeps the tray and window alive', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('window_manager');
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      return false;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final tray = _FakeTray();
    var exits = 0;
    final lifecycle = DesktopLifecycle(
      onExit: () async => exits++,
      tray: tray,
      closeRequestGuard: CloseRequestGuard(approvalHandler: () async => false),
    );
    addTearDown(lifecycle.exit);
    await lifecycle.initialize();
    methods.clear();

    await tray.onExit();

    expect(exits, 0);
    expect(methods, isEmpty);
    expect(tray.disposals, 0);
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

    final tray = _FakeTray();
    final lifecycle = DesktopLifecycle(onExit: () async {}, tray: tray);
    addTearDown(lifecycle.exit);
    await lifecycle.initialize();
    windowCalls.clear();
    await tray.onShow();
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

    final tray = _FakeTray();
    final lifecycle = DesktopLifecycle(onExit: () async {}, tray: tray);
    addTearDown(lifecycle.exit);
    await lifecycle.initialize();
    methods.clear();
    await tray.onShow();
    await Future<void>.delayed(Duration.zero);

    expect(methods.first, 'isMinimized');
    expect(methods, containsAllInOrder(['show', 'focus']));
    expect(methods, isNot(contains('restore')));
  });
}

class _FakeTray extends Fake implements DesktopTray {
  var initialized = false;
  var disposals = 0;
  Object? initializationError;
  Object? updateError;
  List<String> labels = [];
  late Future<void> Function() onShow;
  late Future<void> Function() onExit;

  @override
  void initialize({
    required Future<void> Function() onShow,
    required Future<void> Function() onExit,
    TrayLabelResolver? labels,
  }) {
    if (initializationError != null) throw initializationError!;
    initialized = true;
    this.onShow = onShow;
    this.onExit = onExit;
    updateLabels(labels);
  }

  @override
  void updateLabels(TrayLabelResolver? labels) {
    if (updateError != null) throw updateError!;
    this.labels = [
      labels?.call(TrayItem.show) ?? 'Show window',
      labels?.call(TrayItem.exit) ?? 'Exit',
    ];
  }

  @override
  void dispose() => disposals++;
}

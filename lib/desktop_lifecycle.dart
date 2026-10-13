import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'app/close_request_guard.dart';
import 'desktop_tray.dart';
import 'settings/config_error.dart';
import 'settings/desktop_preferences.dart';

class DesktopLifecycle with WindowListener {
  DesktopLifecycle({
    required this.onExit,
    this.trayLabels,
    this.closeBehavior = _defaultCloseBehavior,
    CloseRequestGuard? closeRequestGuard,
    DesktopTray? tray,
  }) : _tray = tray ?? DesktopTray(),
       closeRequestGuard = closeRequestGuard ?? CloseRequestGuard();

  final Future<void> Function() onExit;
  final TrayLabelResolver? trayLabels;
  final Future<CloseBehavior> Function() closeBehavior;
  final CloseRequestGuard closeRequestGuard;
  final DesktopTray _tray;
  final warning = ValueNotifier<Object?>(null);
  final isMaximized = ValueNotifier<bool>(false);
  var _trayReady = false;
  var _exiting = false;

  Future<void> initialize() async {
    await windowManager.setPreventClose(true);
    isMaximized.value = await windowManager.isMaximized();
    windowManager.addListener(this);
    try {
      _tray.initialize(
        onShow: _showWindow,
        onExit: _exitFromTray,
        labels: trayLabels,
      );
      _trayReady = true;
    } catch (_) {
      warning.value = const AppConfigError(AppConfigErrorCode.trayUnavailable);
    }
  }

  /// Updates menu labels in the current language once the tray is ready.
  Future<void> updateTray() async {
    if (!_trayReady) return;
    try {
      _tray.updateLabels(trayLabels);
    } catch (_) {
      warning.value = const AppConfigError(AppConfigErrorCode.trayUnavailable);
    }
  }

  Future<void> exit() async {
    if (_exiting) return;
    _exiting = true;
    try {
      await onExit();
      if (_trayReady) {
        _tray.dispose();
        _trayReady = false;
      }
      await windowManager.destroy();
    } catch (_) {
      _exiting = false;
      rethrow;
    }
    windowManager.removeListener(this);
  }

  Future<void> minimize() => windowManager.minimize();

  Future<void> toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  Future<void> closeToTray() => _closeWindow();

  @override
  void onWindowClose() => unawaited(_closeWindow());

  @override
  void onWindowMaximize() => isMaximized.value = true;

  @override
  void onWindowUnmaximize() => isMaximized.value = false;

  Future<void> _closeWindow() async {
    if (_exiting) return;
    if (!await closeRequestGuard.request()) return;
    if (_exiting) return;
    if (await closeBehavior() == CloseBehavior.exitApp) {
      await exit();
      return;
    }
    if (_trayReady) {
      await windowManager.hide();
      return;
    }
    await exit();
  }

  Future<void> _showWindow() async {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _exitFromTray() async {
    if (_exiting || !await closeRequestGuard.request()) return;
    await exit();
  }
}

Future<CloseBehavior> _defaultCloseBehavior() async =>
    CloseBehavior.closeToTray;

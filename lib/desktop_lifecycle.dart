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
  var _exitCompleted = false;
  Future<void>? _exitRequestPending;
  Future<void>? _exitPending;

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
      try {
        await _showWindow();
      } catch (_) {}
    }
  }

  /// Updates menu labels in the current language once the tray is ready.
  Future<void> updateTray() async {
    if (!_trayReady) return;
    try {
      _tray.updateLabels(trayLabels);
    } catch (_) {
      final currentWarning = warning.value;
      if (currentWarning is! AppConfigError ||
          currentWarning.code != AppConfigErrorCode.exitFailed) {
        warning.value = const AppConfigError(
          AppConfigErrorCode.trayUnavailable,
        );
      }
    }
  }

  Future<void> exit() {
    if (_exitCompleted) return Future<void>.value();
    final pending = _exitPending;
    if (pending != null) return pending;

    late final Future<void> operation;
    operation = _finishExit().whenComplete(() {
      if (identical(_exitPending, operation)) _exitPending = null;
    });
    _exitPending = operation;
    return operation;
  }

  /// Requests approval and shares the complete exit operation with other routes.
  Future<void> requestExit() => _startExitRequest(revealWindow: true);

  Future<void> _startExitRequest({required bool revealWindow}) {
    if (_exitCompleted) return Future<void>.value();
    final pending = _exitRequestPending;
    if (pending != null) return pending;

    late final Future<void> request;
    request = _requestExit(revealWindow: revealWindow).whenComplete(() {
      if (identical(_exitRequestPending, request)) _exitRequestPending = null;
    });
    _exitRequestPending = request;
    return request;
  }

  Future<void> _finishExit() async {
    try {
      await onExit();
      if (_trayReady) {
        _tray.dispose();
        _trayReady = false;
      }
      await windowManager.destroy();
      windowManager.removeListener(this);
      _exitCompleted = true;
    } catch (error) {
      await _reportExitFailure(error);
      rethrow;
    }
  }

  Future<void> _requestExit({required bool revealWindow}) async {
    try {
      if (_exitCompleted) return;
      if (revealWindow) await _showWindow();
      if (_exitCompleted || !await closeRequestGuard.request()) return;
      if (_exitCompleted) return;
      await exit();
    } catch (error) {
      await _reportExitFailure(error);
      rethrow;
    }
  }

  Future<void> _reportExitFailure(Object error) async {
    if (_exitCompleted) return;
    final detail = '$error';
    final previous = warning.value;
    if (previous is AppConfigError &&
        previous.code == AppConfigErrorCode.exitFailed &&
        previous.detail == detail) {
      return;
    }
    warning.value = AppConfigError(
      AppConfigErrorCode.exitFailed,
      detail: detail,
    );
    try {
      await _showWindow();
    } catch (_) {}
  }

  Future<void> minimize() => windowManager.minimize();

  Future<void> toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  Future<void> closeToTray() => _handleCloseRequest();

  @override
  void onWindowClose() => unawaited(_handleCloseRequest());

  @override
  void onWindowMaximize() => isMaximized.value = true;

  @override
  void onWindowUnmaximize() => isMaximized.value = false;

  Future<void> _handleCloseRequest() async {
    try {
      await _closeWindow();
    } catch (error) {
      await _reportExitFailure(error);
    }
  }

  Future<void> _closeWindow() async {
    if (_exitCompleted) return;
    final activeExit = _exitRequestPending;
    if (activeExit != null) {
      await activeExit;
      return;
    }

    final behavior = await closeBehavior();
    if (_exitCompleted) return;
    final pendingExit = _exitRequestPending;
    if (pendingExit != null) {
      await pendingExit;
      return;
    }
    if (behavior == CloseBehavior.closeToTray && _trayReady) {
      await windowManager.hide();
      return;
    }
    await _startExitRequest(revealWindow: false);
  }

  Future<void> _showWindow() async {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _exitFromTray() async {
    try {
      await requestExit();
    } catch (error) {
      await _reportExitFailure(error);
    }
  }
}

Future<CloseBehavior> _defaultCloseBehavior() async =>
    CloseBehavior.closeToTray;

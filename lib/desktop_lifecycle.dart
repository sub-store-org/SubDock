import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app/close_request_guard.dart';
import 'settings/config_error.dart';
import 'settings/desktop_preferences.dart';

/// The tray menu items whose labels depend on the UI language.
enum TrayItem { show, exit }

/// Resolves a tray menu label from its [TrayItem] in the current UI language.
/// The menu is a native OS menu with no BuildContext, so the label text is
/// produced by the caller (desktop_main) via a language callback.
typedef TrayLabelResolver = String Function(TrayItem item);

class DesktopLifecycle with WindowListener, TrayListener {
  DesktopLifecycle({
    required this.onExit,
    this.trayLabels,
    this.closeBehavior = _defaultCloseBehavior,
    CloseRequestGuard? closeRequestGuard,
    Directory? bundleDirectory,
  }) : _bundleDirectory =
           bundleDirectory ?? File(Platform.resolvedExecutable).parent,
       closeRequestGuard = closeRequestGuard ?? CloseRequestGuard();

  final Future<void> Function() onExit;
  final TrayLabelResolver? trayLabels;
  final Future<CloseBehavior> Function() closeBehavior;
  final CloseRequestGuard closeRequestGuard;
  final Directory _bundleDirectory;
  final warning = ValueNotifier<Object?>(null);
  final isMaximized = ValueNotifier<bool>(false);
  var _trayReady = false;
  var _exiting = false;

  Future<void> initialize() async {
    await windowManager.setPreventClose(true);
    isMaximized.value = await windowManager.isMaximized();
    windowManager.addListener(this);
    trayManager.addListener(this);
    try {
      await trayManager.setIcon(
        trayIconPath(
          bundleDirectory: _bundleDirectory,
          isWindows: Platform.isWindows,
        ),
      );
      if (traySupportsToolTip(isLinux: Platform.isLinux)) {
        await trayManager.setToolTip('SubDock');
      }
      await _updateContextMenu();
      _trayReady = true;
    } catch (_) {
      warning.value = const AppConfigError(AppConfigErrorCode.trayUnavailable);
    }
  }

  /// Rebuilds the tray menu in the current language (KTD3). Safe to call
  /// before the tray is ready; it simply records the pending label state.
  Future<void> updateTray() async {
    if (!_trayReady) return;
    try {
      await _updateContextMenu();
    } catch (_) {
      warning.value = const AppConfigError(AppConfigErrorCode.trayUnavailable);
    }
  }

  Future<void> _updateContextMenu() {
    final labels = trayLabels;
    return trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(
            key: TrayItem.show.name,
            label: labels?.call(TrayItem.show) ?? 'Show window',
          ),
          MenuItem.separator(),
          MenuItem(
            key: TrayItem.exit.name,
            label: labels?.call(TrayItem.exit) ?? 'Exit',
          ),
        ],
      ),
    );
  }

  Future<void> exit() async {
    if (_exiting) return;
    _exiting = true;
    try {
      await onExit();
      if (_trayReady) await trayManager.destroy();
      await windowManager.destroy();
    } catch (_) {
      _exiting = false;
      rethrow;
    }
    windowManager.removeListener(this);
    trayManager.removeListener(this);
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

  @override
  void onTrayIconMouseDown() => unawaited(_showWindow());

  @override
  void onTrayIconRightMouseDown() {
    if (traySupportsPopupContextMenu(
      isWindows: Platform.isWindows,
      isMacOS: Platform.isMacOS,
    )) {
      unawaited(trayManager.popUpContextMenu());
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(_showWindow());
      case 'exit':
        unawaited(_exitFromTray());
    }
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

String trayIconPath({
  required Directory bundleDirectory,
  required bool isWindows,
}) => File.fromUri(
  bundleDirectory.uri.resolve('data/tray_icon${isWindows ? '.ico' : '.png'}'),
).path;

bool traySupportsToolTip({required bool isLinux}) => !isLinux;

bool traySupportsPopupContextMenu({
  required bool isWindows,
  required bool isMacOS,
}) => isWindows || isMacOS;

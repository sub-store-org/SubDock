import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';

/// The tray menu items whose labels depend on the UI language.
enum TrayItem { show, exit }

/// Resolves labels for the native menu, which has no BuildContext.
typedef TrayLabelResolver = String Function(TrayItem item);

/// Owns the native tray handles independently of the window lifecycle.
class DesktopTray {
  DesktopTray({Directory? bundleDirectory})
    : _bundleDirectory =
          bundleDirectory ?? File(Platform.resolvedExecutable).parent;

  final Directory _bundleDirectory;
  TrayIcon? _icon;
  Menu? _menu;
  MenuItem? _showItem;
  MenuItem? _exitItem;

  void initialize({
    required Future<void> Function() onShow,
    required Future<void> Function() onExit,
    TrayLabelResolver? labels,
  }) {
    try {
      if (!TrayManager.instance.isSupported()) {
        throw StateError('System tray is unavailable');
      }
      final icon = _icon = TrayIcon.create();
      if (icon == null) throw StateError('Cannot create tray icon');
      final image = Platform.isWindows
          ? Image.fromFile(
              trayIconPath(bundleDirectory: _bundleDirectory, isWindows: true),
            )
          : ImageAsset.fromAsset('assets/icon/app_icon_32.png');
      if (image == null) throw StateError('Cannot load tray icon');
      try {
        icon.icon = image;
      } finally {
        image.dispose();
      }
      icon.setTooltip('SubDock');
      // Linux panels should open the exported menu on a primary click.
      icon.setContextMenuTrigger(
        Platform.isLinux
            ? ContextMenuTrigger.clicked
            : ContextMenuTrigger.rightClicked,
      );
      icon.addListener((event) {
        if (event is TrayIconClickedEvent) unawaited(onShow());
      });

      final menu = _menu = Menu.create();
      if (menu == null) throw StateError('Cannot create tray menu');
      final showItem = _showItem = MenuItem.createWithLabelAndType(
        'Show window',
        MenuItemType.normal,
      );
      final exitItem = _exitItem = MenuItem.createWithLabelAndType(
        'Exit',
        MenuItemType.normal,
      );
      if (showItem == null || exitItem == null) {
        throw StateError('Cannot create tray menu items');
      }
      showItem.addListener((event) {
        if (event is MenuItemClickedEvent) unawaited(onShow());
      });
      exitItem.addListener((event) {
        if (event is MenuItemClickedEvent) unawaited(onExit());
      });
      menu.addItem(showItem);
      menu.addSeparator();
      menu.addItem(exitItem);
      updateLabels(labels);
      if (!icon.setVisible(true)) throw StateError('Cannot show tray icon');
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  void updateLabels(TrayLabelResolver? labels) {
    _showItem?.label = labels?.call(TrayItem.show) ?? 'Show window';
    _exitItem?.label = labels?.call(TrayItem.exit) ?? 'Exit';
    // Reattach to notify Linux panels that cache the D-Bus menu layout.
    _icon?.setContextMenu(_menu);
  }

  void dispose() {
    _icon?.dispose();
    _icon = null;
    _menu?.dispose();
    _menu = null;
    _showItem?.dispose();
    _showItem = null;
    _exitItem?.dispose();
    _exitItem = null;
  }
}

/// Windows loads its packaged ICO directly; other desktops use a Flutter asset.
String trayIconPath({
  required Directory bundleDirectory,
  required bool isWindows,
}) => isWindows
    ? File.fromUri(bundleDirectory.uri.resolve('data/tray_icon.ico')).path
    : 'assets/icon/app_icon_32.png';

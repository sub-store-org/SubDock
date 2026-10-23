import 'dart:io';

/// Manages login startup through the Linux XDG autostart directory.
class AutostartManager {
  const AutostartManager({this._configHome, this._executablePath});

  final Directory? _configHome;
  final String? _executablePath;

  Directory get _autostartDirectory {
    final home =
        _configHome ??
        Directory(
          '${Platform.environment['XDG_CONFIG_HOME'] ?? '${Platform.environment['HOME'] ?? '.'}/.config'}/autostart',
        );
    return home;
  }

  bool get isSupported => Platform.isLinux;

  File get _entryFile =>
      File.fromUri(_autostartDirectory.uri.resolve('subdock.desktop'));

  String get _executable {
    final explicit = _executablePath;
    if (explicit != null) return explicit;
    return Platform.resolvedExecutable;
  }

  /// 写入/更新 XDG autostart 条目。
  Future<void> enable() async {
    if (!isSupported) {
      throw UnsupportedError('Login startup is not supported on this platform');
    }
    await _autostartDirectory.create(recursive: true);
    await _entryFile.writeAsString('''
[Desktop Entry]
Type=Application
Name=SubDock
Exec=$_executable
X-GNOME-Autostart-enabled=true
''', flush: true);
  }

  /// 移除 XDG autostart 条目。
  Future<void> disable() async {
    if (!isSupported) {
      throw UnsupportedError('Login startup is not supported on this platform');
    }
    final file = _entryFile;
    if (await file.exists()) await file.delete();
  }
}

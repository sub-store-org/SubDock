import 'dart:io';

/// 管理开机自启。本轮实现 Linux 的 XDG autostart
/// （`~/.config/autostart/subdock.desktop`）；macOS/Windows 留待后续。
class AutostartManager {
  const AutostartManager({this._configHome, this._executablePath});

  final Directory? _configHome;
  final String? _executablePath;

  Directory get _autostartDirectory {
    final home = _configHome ??
        Directory('${Platform.environment['XDG_CONFIG_HOME'] ?? '${Platform.environment['HOME'] ?? '.'}/.config'}/autostart');
    return home;
  }

  File get _entryFile =>
      File.fromUri(_autostartDirectory.uri.resolve('subdock.desktop'));

  String get _executable {
    final explicit = _executablePath;
    if (explicit != null) return explicit;
    return Platform.resolvedExecutable;
  }

  /// 写入/更新 XDG autostart 条目。
  Future<void> enable() async {
    if (!Platform.isLinux) return;
    await _autostartDirectory.create(recursive: true);
    await _entryFile.writeAsString(
      '''
[Desktop Entry]
Type=Application
Name=SubDock
Exec=$_executable
X-GNOME-Autostart-enabled=true
''',
      flush: true,
    );
  }

  /// 移除 XDG autostart 条目。
  Future<void> disable() async {
    if (!Platform.isLinux) return;
    final file = _entryFile;
    if (await file.exists()) await file.delete();
  }
}

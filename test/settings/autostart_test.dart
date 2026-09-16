import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/settings/autostart.dart';

void main() {
  test(
    'writes and removes an XDG autostart entry on Linux',
    () async {
      final temp = await Directory.systemTemp.createTemp('autostart_test_');
      addTearDown(() => temp.delete(recursive: true));
      final manager = AutostartManager(
        configHome: Directory(temp.path),
        executablePath: '/opt/subdock/SubDock',
      );

      await manager.enable();
      final entry = File('${temp.path}/subdock.desktop');
      expect(await entry.exists(), isTrue);
      final contents = await entry.readAsString();
      expect(contents, contains('[Desktop Entry]'));
      expect(contents, contains('Exec=/opt/subdock/SubDock'));
      expect(contents, contains('Name=SubDock'));

      await manager.disable();
      expect(await entry.exists(), isFalse);
    },
    skip: !Platform.isLinux,
  );
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/settings/autostart.dart';

void main() {
  test('applies login startup only on supported platforms', () async {
    final temp = await Directory.systemTemp.createTemp('autostart_test_');
    addTearDown(() => temp.delete(recursive: true));
    final manager = AutostartManager(
      configHome: Directory(temp.path),
      executablePath: '/opt/subdock/SubDock',
    );
    final entry = File('${temp.path}/subdock.desktop');

    if (!manager.isSupported) {
      await expectLater(manager.enable(), throwsA(isA<UnsupportedError>()));
      await expectLater(manager.disable(), throwsA(isA<UnsupportedError>()));
      expect(await entry.exists(), isFalse);
      return;
    }

    await manager.enable();
    expect(await entry.exists(), isTrue);
    final contents = await entry.readAsString();
    expect(contents, contains('[Desktop Entry]'));
    expect(contents, contains('Exec=/opt/subdock/SubDock'));
    expect(contents, contains('Name=SubDock'));

    await manager.disable();
    expect(await entry.exists(), isFalse);
  });
}

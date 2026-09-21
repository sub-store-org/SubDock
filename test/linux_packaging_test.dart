import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Arch package registers the SubDock icon with the desktop icon theme', () {
    final desktopEntry = File('linux/packaging/arch/subdock.desktop')
        .readAsStringSync();
    final packageBuild = File('linux/packaging/arch/PKGBUILD').readAsStringSync();

    expect(desktopEntry, contains('Icon=org.substore.subdock'));
    expect(
      packageBuild,
      contains(
        'usr/share/icons/hicolor/1024x1024/apps/org.substore.subdock.png',
      ),
    );
  });
}

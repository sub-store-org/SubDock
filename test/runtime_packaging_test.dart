import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in ['unix', 'windows', 'macos']) {
    test(
      '$platform bundle accepts a Node-only runtime and still requires Node',
      () async {
        final temp = await Directory.systemTemp.createTemp('subdock_bundle_');
        addTearDown(() => temp.delete(recursive: true));
        final bundle = Directory('${temp.path}/bundle');
        final suffix = platform == 'windows' ? '.exe' : '';
        final node = File('${bundle.path}/data/runtime/node$suffix');
        final paths = [
          'data/runtime/node$suffix',
          'data/backend/sub-store.bundle.js',
          'data/backend/runtime-manifest.json',
          'data/backend/version',
          'data/frontend/index.html',
          'data/frontend/version',
          'data/http-meta/http-meta.bundle.js',
          'data/http-meta/version',
          'data/http-meta/meta/tpl.yaml',
          'data/http-meta/meta/mihomo$suffix',
          'data/http-meta/meta/mihomo-version',
          'data/licenses/GPL-3.0-only.txt',
          'data/icon/app_icon.png',
          if (platform == 'windows')
            'data/tray_icon.ico'
          else if (platform == 'macos')
            '../Frameworks/App.framework/Resources/flutter_assets/assets/icon/app_icon_32.png'
          else
            'data/flutter_assets/assets/icon/app_icon_32.png',
        ];
        for (final path in paths) {
          final file = File('${bundle.path}/$path');
          await file.parent.create(recursive: true);
          await file.writeAsString(
            path.endsWith('runtime-manifest.json')
                ? '{"testedNode":"24.15.0","externalBinary":[]}\n'
                : 'fixture\n',
          );
        }
        if (platform != 'windows') {
          final permissions = await Process.run('chmod', [
            '+x',
            node.path,
            '${bundle.path}/data/http-meta/meta/mihomo',
          ]);
          expect(permissions.exitCode, 0, reason: '${permissions.stderr}');
        }
        final script = File('tool/verify_bundle.sh').absolute.path;
        final result = await Process.run('sh', [script, bundle.path, platform]);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');

        await node.delete();
        final missingNode = await Process.run('sh', [
          script,
          bundle.path,
          platform,
        ]);
        expect(missingNode.exitCode, isNot(0));
      },
      skip: Platform.isWindows,
    );
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/about_info.dart';

void main() {
  test('loads injected package and platform metadata', () async {
    final loader = AboutInfoLoader(
      loadPackageMetadata: () async => (version: '1.2.3', buildNumber: '45'),
      operatingSystem: () => 'linux',
      architecture: () => 'x64',
    );

    final info = await loader.load();

    expect(info.version, '1.2.3');
    expect(info.buildNumber, '45');
    expect(info.operatingSystem, 'linux');
    expect(info.architecture, 'x64');
  });

  test('passes empty build and alternate platform metadata through', () async {
    final info = await AboutInfoLoader(
      loadPackageMetadata: () async => (version: '2.0.0', buildNumber: ''),
      operatingSystem: () => 'windows',
      architecture: () => 'arm64',
    ).load();

    expect(info.version, '2.0.0');
    expect(info.buildNumber, isEmpty);
    expect(info.operatingSystem, 'windows');
    expect(info.architecture, 'arm64');
  });

  test('keeps repository metadata constants stable', () {
    expect(subDockLicenseId, 'GPL-3.0');
    expect(subDockProjectHomepage, 'https://github.com/Delusions6515/SubDock');
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_resource_resolver.dart';
import 'package:subdock/update/component_update_checker.dart';
import 'package:subdock/update/github_release_client.dart';

void main() {
  late Directory temp;
  late ComponentUpdateChecker checker;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('subdock_check_');
    final bundle = Directory.fromUri(temp.uri.resolve('bundle/'));
    final components = Directory.fromUri(temp.uri.resolve('components/'));
    await _write(bundle, 'data/backend/version', '2.38.4\n');
    await _write(bundle, 'data/backend/sub-store.bundle.js', 'backend');
    await _write(bundle, 'data/backend/runtime-manifest.json', '{}');
    await _write(bundle, 'data/frontend/version', '2.31.3\n');
    await _write(bundle, 'data/frontend/index.html', 'frontend');
    checker = ComponentUpdateChecker(
      resources: ComponentResourceResolver(
        bundleDirectory: bundle,
        componentsDirectory: components,
        metadataStore: ComponentMetadataStore(components),
      ),
      releases: _FakeReleases(),
    );
  });

  tearDown(() => temp.delete(recursive: true));

  test(
    'reports the newer stable Backend release with both required assets',
    () async {
      final update = await checker.check(ComponentKind.backend);

      expect(update.currentVersion, '2.38.4');
      expect(update.availableVersion, '2.39.0');
      expect(update.isAvailable, isTrue);
    },
  );

  test('rejects a release that lacks one required Backend asset', () async {
    checker = ComponentUpdateChecker(
      resources: checker.resources,
      releases: _FakeReleases(includeManifest: false),
    );

    await expectLater(checker.check(ComponentKind.backend), throwsStateError);
  });
}

class _FakeReleases implements GithubReleaseSource {
  _FakeReleases({this.includeManifest = true});

  final bool includeManifest;

  @override
  Future<GithubRelease> latest(String repository) async => GithubRelease(
    version: '2.39.0',
    releaseUri: Uri.parse('https://example.invalid/release'),
    assets: [
      GithubReleaseAsset(
        name: 'sub-store.bundle.js',
        downloadUri: Uri.parse('https://example.invalid/sub-store.bundle.js'),
        sha256: '0' * 64,
      ),
      if (includeManifest)
        GithubReleaseAsset(
          name: 'runtime-manifest.json',
          downloadUri: Uri.parse(
            'https://example.invalid/runtime-manifest.json',
          ),
          sha256: '1' * 64,
        ),
      GithubReleaseAsset(
        name: 'dist.zip',
        downloadUri: Uri.parse('https://example.invalid/dist.zip'),
        sha256: '2' * 64,
      ),
    ],
  );
}

Future<void> _write(Directory root, String path, String value) async {
  final file = File.fromUri(root.uri.resolve(path));
  await file.parent.create(recursive: true);
  await file.writeAsString(value);
}

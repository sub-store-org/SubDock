import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_resource_resolver.dart';

void main() {
  late Directory temp;
  late Directory bundle;
  late Directory components;
  late ComponentMetadataStore store;
  late ComponentResourceResolver resolver;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('subdock_resources_');
    bundle = Directory.fromUri(temp.uri.resolve('bundle/'));
    components = Directory.fromUri(temp.uri.resolve('components/'));
    store = ComponentMetadataStore(components);
    resolver = ComponentResourceResolver(
      bundleDirectory: bundle,
      componentsDirectory: components,
      metadataStore: store,
    );
    await _write(bundle, 'data/backend/version', '2.38.4\n');
    await _write(
      bundle,
      'data/backend/sub-store.bundle.js',
      'baseline backend',
    );
    await _write(bundle, 'data/backend/runtime-manifest.json', '{}');
    await _write(bundle, 'data/frontend/version', '2.31.3\n');
    await _write(bundle, 'data/frontend/index.html', 'baseline frontend');
  });

  tearDown(() => temp.delete(recursive: true));

  test(
    'uses packaged resources until an active component is recorded',
    () async {
      final resources = await resolver.resolve();

      expect(
        resources.backend.path,
        Directory.fromUri(bundle.uri.resolve('data/backend/')).path,
      );
      expect(
        resources.frontend.path,
        Directory.fromUri(bundle.uri.resolve('data/frontend/')).path,
      );
      expect(resources.backendVersion, '2.38.4');
      expect(resources.frontendVersion, '2.31.3');
    },
  );

  test('uses complete active component directories after activation', () async {
    await _write(components, 'backend/2.39.0/sub-store.bundle.js', 'candidate');
    await _write(components, 'backend/2.39.0/runtime-manifest.json', '{}');
    await _write(components, 'frontend/2.32.0/index.html', 'candidate');
    await store.save(
      ComponentKind.backend,
      const ComponentMetadata(baseline: '2.38.4', active: '2.39.0'),
    );
    await store.save(
      ComponentKind.frontend,
      const ComponentMetadata(baseline: '2.31.3', active: '2.32.0'),
    );

    final resources = await resolver.resolve();

    expect(
      resources.backend.path,
      Directory.fromUri(components.uri.resolve('backend/2.39.0/')).path,
    );
    expect(
      resources.frontend.path,
      Directory.fromUri(components.uri.resolve('frontend/2.32.0/')).path,
    );
    expect(resources.backendVersion, '2.39.0');
    expect(resources.frontendVersion, '2.32.0');
  });

  test(
    'rejects an active component that is missing its required resources',
    () async {
      await _write(
        components,
        'backend/2.39.0/sub-store.bundle.js',
        'candidate',
      );
      await store.save(
        ComponentKind.backend,
        const ComponentMetadata(baseline: '2.38.4', active: '2.39.0'),
      );

      await expectLater(resolver.resolve(), throwsStateError);
    },
  );

  test('refuses to resolve a component with an unresolved operation', () async {
    for (final row in <({ComponentKind kind, String baseline, String active})>[
      (kind: ComponentKind.backend, baseline: '2.38.4', active: '2.39.0'),
      (kind: ComponentKind.frontend, baseline: '2.31.3', active: '2.32.0'),
    ]) {
      // The provisional candidate is complete on disk, so only the pending
      // record distinguishes it from a confirmed component.
      if (row.kind == ComponentKind.backend) {
        await _write(
          components,
          'backend/2.39.0/sub-store.bundle.js',
          'candidate',
        );
        await _write(components, 'backend/2.39.0/runtime-manifest.json', '{}');
      } else {
        await _write(components, 'frontend/2.32.0/index.html', 'candidate');
      }
      await store.save(
        row.kind,
        ComponentMetadata(
          baseline: row.baseline,
          active: row.active,
          pending: ComponentPending(version: row.active),
        ),
      );

      await expectLater(
        resolver.resolve(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('unresolved'),
          ),
        ),
        reason: row.kind.name,
      );

      await store.save(
        row.kind,
        ComponentMetadata(baseline: row.baseline, active: row.active),
      );
    }
  });

  test('resolves packaged HTTP-META resources and version markers', () async {
    await _write(bundle, 'data/http-meta/http-meta.bundle.js', 'bundle');
    await _write(bundle, 'data/http-meta/version', '1.3.0\n');
    await _write(bundle, 'data/http-meta/meta/tpl.yaml', 'tpl');
    await _write(bundle, 'data/http-meta/meta/mihomo-version', 'v1.19.30\n');
    final mihomoPath =
        'data/http-meta/meta/${Platform.isWindows ? 'mihomo.exe' : 'mihomo'}';
    await _write(bundle, mihomoPath, 'mihomo');
    final mihomo = File.fromUri(bundle.uri.resolve(mihomoPath));
    if (!Platform.isWindows) await Process.run('chmod', ['755', mihomo.path]);

    final resources = await resolver.resolveHttpMeta();

    expect(resources.version, '1.3.0');
    expect(resources.mihomoVersion, 'v1.19.30');
    expect(resources.bundle.path, endsWith('http-meta.bundle.js'));
  });
}

Future<void> _write(Directory root, String path, String value) async {
  final file = File.fromUri(root.uri.resolve(path));
  await file.parent.create(recursive: true);
  await file.writeAsString(value);
}

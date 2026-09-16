import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/settings/backend_env.dart';
import 'package:subdock/settings/config_error.dart';
import 'package:subdock/settings/subdock_config.dart';
import 'package:subdock/settings/subdock_config_store.dart';

void main() {
  test('uses the version-one defaults when no config file exists', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_config_test_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);

    final config = await SubDockConfigStore(directories).load();

    expect(config, const SubDockConfig());
    expect(config.httpMeta.enabled, isTrue);
  });

  test('rejects unknown fields, incompatible schemas, and invalid values', () {
    expect(
      () => SubDockConfig.fromJson({
        'schemaVersion': 1,
        'backend': {'apiPort': 0},
      }),
      throwsA(isA<AppConfigError>()),
    );
    expect(
      () => SubDockConfig.fromJson({'schemaVersion': 2}),
      throwsA(isA<AppConfigError>()),
    );
    expect(
      () => SubDockConfig.fromJson({'schemaVersion': 1, 'unknown': true}),
      throwsA(isA<AppConfigError>()),
    );
  });

  test(
    'saves atomically with private permissions and resets to defaults',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'subdock_config_test_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final directories = await RuntimeDirectories.fromBaseDirectory(temp);
      final store = SubDockConfigStore(directories);
      const config = SubDockConfig(
        backend: SubDockBackendConfig(apiPort: 4321),
        httpMeta: SubDockHttpMetaConfig(enabled: false, port: 9877),
      );

      await store.save(config);

      expect(await store.load(), config);
      if (!Platform.isWindows) {
        expect((await store.file.stat()).mode & 0x1ff, 0x180);
      }
      await store.reset();
      expect(await store.load(), const SubDockConfig());
    },
  );

  test('fails closed on malformed saved JSON until reset', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_config_test_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = SubDockConfigStore(directories);
    await store.file.writeAsString('{not json');

    await expectLater(store.load(), throwsA(isA<AppConfigError>()));

    await store.reset();
    expect(await store.load(), const SubDockConfig());
  });

  test(
    'resolves system, ENV, SubDock, defaults, and reserved paths in order',
    () {
      const config = SubDockConfig(
        backend: SubDockBackendConfig(apiPort: 4000, merge: false),
        httpMeta: SubDockHttpMetaConfig(host: '127.0.0.2'),
      );
      final effective = EffectiveRuntimeConfig.resolve(
        systemEnvironment: {'SUB_STORE_BACKEND_API_HOST': '0.0.0.0'},
        backendEnvironment: BackendEnvDocument.parse(
          'SUB_STORE_BACKEND_API_PORT=3002\n'
          'SUB_STORE_BACKEND_MERGE=true\n'
          'HOST=0.0.0.0\n'
          'PORT=9000\n',
        ),
        config: config,
        dataDirectory: Directory('/private/data'),
        frontendDirectory: Directory('/bundle/frontend'),
        metaFolder: Directory('/bundle/http-meta'),
      );

      expect(effective.environment['SUB_STORE_BACKEND_API_HOST'], '0.0.0.0');
      expect(effective.environment['SUB_STORE_BACKEND_API_PORT'], '4000');
      expect(effective.environment['SUB_STORE_BACKEND_MERGE'], 'false');
      // 后端路径不再由 resolve 以 `/` 兜底：首次配置由 coordinator 生成随
      // 机路径并持久化进 config，此处未显式配置时不注入默认值。
      expect(
        effective.environment.containsKey('SUB_STORE_FRONTEND_BACKEND_PATH'),
        isFalse,
      );
      expect(
        effective.environment['SUB_STORE_CORS_ALLOWED_ORIGINS'],
        'http://0.0.0.0:4000',
      );
      expect(effective.environment['HOST'], '127.0.0.2');
      expect(effective.environment['PORT'], '9000');
      expect(
        effective.environment['META_TEMP_FOLDER'],
        '/private/data/http-meta',
      );
      expect(effective.environment['META_FOLDER'], '/bundle/http-meta');
      expect(
        effective.environment['SUB_STORE_DATA_BASE_PATH'],
        '/private/data',
      );
      expect(
        effective.environment['SUB_STORE_FRONTEND_PATH'],
        '/bundle/frontend',
      );
    },
  );

  test('removing an override follows ENV or the effective default', () {
    const config = SubDockConfig(
      backend: SubDockBackendConfig(apiPort: 4000),
      httpMeta: SubDockHttpMetaConfig(port: 9999),
    );
    final following = config.copyWith(
      backend: config.backend.copyWith(apiPort: null),
      httpMeta: config.httpMeta.copyWith(port: null),
    );

    expect(following.backend.apiPort, isNull);
    expect(following.httpMeta.port, isNull);
  });
}

import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'backend_env.dart';
import 'config_error.dart';

class SubDockConfig {
  const SubDockConfig({
    this.backend = const SubDockBackendConfig(),
    this.httpMeta = const SubDockHttpMetaConfig(),
  });

  static const schemaVersion = 1;

  final SubDockBackendConfig backend;
  final SubDockHttpMetaConfig httpMeta;

  factory SubDockConfig.fromJson(Object? json) {
    final root = _object(json, 'SubDock configuration');
    _rejectUnknownKeys(root, const {'schemaVersion', 'backend', 'httpMeta'});
    if (root['schemaVersion'] != schemaVersion) {
      throw const AppConfigError(AppConfigErrorCode.unsupportedVersion);
    }
    return SubDockConfig(
      backend: SubDockBackendConfig.fromJson(root['backend']),
      httpMeta: SubDockHttpMetaConfig.fromJson(root['httpMeta']),
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'backend': backend.toJson(),
    'httpMeta': httpMeta.toJson(),
  };

  SubDockConfig copyWith({
    SubDockBackendConfig? backend,
    SubDockHttpMetaConfig? httpMeta,
  }) => SubDockConfig(
    backend: backend ?? this.backend,
    httpMeta: httpMeta ?? this.httpMeta,
  );

  @override
  bool operator ==(Object other) =>
      other is SubDockConfig &&
      other.backend == backend &&
      other.httpMeta == httpMeta;

  @override
  int get hashCode => Object.hash(backend, httpMeta);
}

class SubDockBackendConfig {
  const SubDockBackendConfig({
    this.apiHost,
    this.apiPort,
    this.merge,
    this.frontendBackendPath,
    this.corsAllowedOrigins,
  });

  final String? apiHost;
  final int? apiPort;
  final bool? merge;
  final String? frontendBackendPath;
  final String? corsAllowedOrigins;

  factory SubDockBackendConfig.fromJson(Object? json) {
    if (json == null) return const SubDockBackendConfig();
    final object = _object(json, 'backend');
    _rejectUnknownKeys(object, const {
      'apiHost',
      'apiPort',
      'merge',
      'frontendBackendPath',
      'corsAllowedOrigins',
    });
    final config = SubDockBackendConfig(
      apiHost: _optionalString(object, 'apiHost'),
      apiPort: _optionalPort(object, 'apiPort'),
      merge: _optionalBool(object, 'merge'),
      frontendBackendPath: _optionalString(object, 'frontendBackendPath'),
      corsAllowedOrigins: _optionalString(object, 'corsAllowedOrigins'),
    );
    _validateBackend(config);
    return config;
  }

  Map<String, Object?> toJson() => {
    'apiHost': apiHost,
    'apiPort': apiPort,
    'merge': merge,
    'frontendBackendPath': frontendBackendPath,
    'corsAllowedOrigins': corsAllowedOrigins,
  };

  SubDockBackendConfig copyWith({
    Object? apiHost = _unset,
    Object? apiPort = _unset,
    Object? merge = _unset,
    Object? frontendBackendPath = _unset,
    Object? corsAllowedOrigins = _unset,
  }) => SubDockBackendConfig(
    apiHost: identical(apiHost, _unset) ? this.apiHost : apiHost as String?,
    apiPort: identical(apiPort, _unset) ? this.apiPort : apiPort as int?,
    merge: identical(merge, _unset) ? this.merge : merge as bool?,
    frontendBackendPath: identical(frontendBackendPath, _unset)
        ? this.frontendBackendPath
        : frontendBackendPath as String?,
    corsAllowedOrigins: identical(corsAllowedOrigins, _unset)
        ? this.corsAllowedOrigins
        : corsAllowedOrigins as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is SubDockBackendConfig &&
      other.apiHost == apiHost &&
      other.apiPort == apiPort &&
      other.merge == merge &&
      other.frontendBackendPath == frontendBackendPath &&
      other.corsAllowedOrigins == corsAllowedOrigins;

  @override
  int get hashCode => Object.hash(
    apiHost,
    apiPort,
    merge,
    frontendBackendPath,
    corsAllowedOrigins,
  );
}

class SubDockHttpMetaConfig {
  const SubDockHttpMetaConfig({this.enabled = true, this.host, this.port});

  final bool enabled;
  final String? host;
  final int? port;

  factory SubDockHttpMetaConfig.fromJson(Object? json) {
    if (json == null) return const SubDockHttpMetaConfig();
    final object = _object(json, 'httpMeta');
    _rejectUnknownKeys(object, const {'enabled', 'host', 'port'});
    final config = SubDockHttpMetaConfig(
      enabled: _optionalBool(object, 'enabled') ?? true,
      host: _optionalString(object, 'host'),
      port: _optionalPort(object, 'port'),
    );
    if (config.host?.isEmpty ?? false) {
      throw const AppConfigError(
        AppConfigErrorCode.emptyHost,
        key: 'httpMeta.host',
      );
    }
    return config;
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'host': host,
    'port': port,
  };

  SubDockHttpMetaConfig copyWith({
    Object? enabled = _unset,
    Object? host = _unset,
    Object? port = _unset,
  }) => SubDockHttpMetaConfig(
    enabled: identical(enabled, _unset) ? this.enabled : enabled as bool,
    host: identical(host, _unset) ? this.host : host as String?,
    port: identical(port, _unset) ? this.port : port as int?,
  );

  @override
  bool operator ==(Object other) =>
      other is SubDockHttpMetaConfig &&
      other.enabled == enabled &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(enabled, host, port);
}

/// 生成随机的 `SUB_STORE_FRONTEND_BACKEND_PATH`：`/` + 20–24 位 `[a-zA-Z0-9]`。
///
/// 对齐 Sub-Store-Module 的 `gen_backend_path`（`lib.sh`）：长度 20–24，
/// 字符集 `a-zA-Z0-9`，首字符固定 `/`。用于首次配置时给后端入口随机路径，
/// 避免默认 `/` 暴露后端 API。
String randomBackendPath([Random? random]) {
  const alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final source = random ?? Random.secure();
  final length = 20 + source.nextInt(5);
  final buffer = StringBuffer('/');
  for (var i = 0; i < length; i++) {
    buffer.write(alphabet[source.nextInt(alphabet.length)]);
  }
  return buffer.toString();
}

class EffectiveRuntimeConfig {
  const EffectiveRuntimeConfig._({
    required this.environment,
    required this.httpMetaEnabled,
  });

  final Map<String, String> environment;
  final bool httpMetaEnabled;

  factory EffectiveRuntimeConfig.resolve({
    required Map<String, String> systemEnvironment,
    required BackendEnvDocument backendEnvironment,
    required SubDockConfig config,
    Directory? dataDirectory,
    Directory? frontendDirectory,
    Directory? metaFolder,
  }) {
    final environment = Map<String, String>.of(systemEnvironment);
    environment.addAll(backendEnvironment.values);
    _applyBackendOverrides(environment, config.backend);
    environment.putIfAbsent(
      BackendEnvPolicy.host,
      () => InternetAddress.loopbackIPv4.address,
    );
    environment.putIfAbsent(BackendEnvPolicy.port, () => '3001');
    environment.putIfAbsent(BackendEnvPolicy.merge, () => 'true');
    // 后端路径不会再以 `/` 兜底：首次配置由 `randomBackendPath` 生成并
    // 持久化进 config（见 AppCoordinator._initializeBackendPath）。此处若
    // 缺失，由 `canOpenWebUi` / 校验层处理，而不是静默暴露根路径。
    environment.putIfAbsent(
      BackendEnvPolicy.corsAllowedOrigins,
      () =>
          'http://${environment[BackendEnvPolicy.host]}:'
          '${environment[BackendEnvPolicy.port]}',
    );
    if (config.httpMeta.host != null) {
      environment['HOST'] = config.httpMeta.host!;
    }
    environment.putIfAbsent('HOST', () => InternetAddress.loopbackIPv4.address);
    if (config.httpMeta.port != null) {
      environment['PORT'] = '${config.httpMeta.port}';
    }
    environment.putIfAbsent('PORT', () => '9876');
    if (dataDirectory != null &&
        frontendDirectory != null &&
        metaFolder != null) {
      environment.addAll({
        BackendEnvPolicy.dataBasePath: dataDirectory.path,
        BackendEnvPolicy.frontendPath: frontendDirectory.path,
        BackendEnvPolicy.metaFolder: metaFolder.path,
        'META_TEMP_FOLDER': Directory.fromUri(
          dataDirectory.uri.resolve('http-meta'),
        ).path,
      });
    }
    return EffectiveRuntimeConfig._(
      environment: UnmodifiableMapView(environment),
      httpMetaEnabled: config.httpMeta.enabled,
    );
  }

  static void _applyBackendOverrides(
    Map<String, String> environment,
    SubDockBackendConfig config,
  ) {
    if (config.apiHost != null) {
      environment[BackendEnvPolicy.host] = config.apiHost!;
    }
    if (config.apiPort != null) {
      environment[BackendEnvPolicy.port] = '${config.apiPort}';
    }
    if (config.merge != null) {
      environment[BackendEnvPolicy.merge] = '${config.merge}';
    }
    if (config.frontendBackendPath != null) {
      environment[BackendEnvPolicy.frontendBackendPath] =
          config.frontendBackendPath!;
    }
    if (config.corsAllowedOrigins != null) {
      environment[BackendEnvPolicy.corsAllowedOrigins] =
          config.corsAllowedOrigins!;
    }
  }
}

Map<String, Object?> _object(Object? value, String name) {
  if (value is! Map) {
    throw AppConfigError(AppConfigErrorCode.notAnObject, name: name);
  }
  final object = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw AppConfigError(AppConfigErrorCode.invalidFieldName, name: name);
    }
    object[entry.key as String] = entry.value;
  }
  return object;
}

void _rejectUnknownKeys(Map<String, Object?> object, Set<String> allowed) {
  final unknown = object.keys.where((key) => !allowed.contains(key));
  if (unknown.isNotEmpty) {
    throw AppConfigError(
      AppConfigErrorCode.unknownField,
      field: unknown.first,
    );
  }
}

String? _optionalString(Map<String, Object?> object, String key) {
  final value = object[key];
  if (value == null) return null;
  if (value is! String || value.contains('\n') || value.contains('\r')) {
    throw AppConfigError(AppConfigErrorCode.stringWithNewline, key: key);
  }
  return value;
}

bool? _optionalBool(Map<String, Object?> object, String key) {
  final value = object[key];
  if (value == null) return null;
  if (value is! bool) throw AppConfigError(AppConfigErrorCode.mustBeBoolean, key: key);
  return value;
}

int? _optionalPort(Map<String, Object?> object, String key) {
  final value = object[key];
  if (value == null) return null;
  if (value is! int || value < 1 || value > 65535) {
    throw AppConfigError(AppConfigErrorCode.portRange, key: key);
  }
  return value;
}

void _validateBackend(SubDockBackendConfig config) {
  if (config.apiHost?.isEmpty ?? false) {
    throw const AppConfigError(
      AppConfigErrorCode.emptyHost,
      key: 'backend.apiHost',
    );
  }
  if (config.frontendBackendPath != null &&
      !config.frontendBackendPath!.startsWith('/')) {
    throw const AppConfigError(
      AppConfigErrorCode.pathPrefix,
      key: 'backend.frontendBackendPath',
    );
  }
  final origins = config.corsAllowedOrigins;
  if (origins == null) return;
  final issues = BackendEnvPolicy.validate(
    BackendEnvDocument.parse('${BackendEnvPolicy.corsAllowedOrigins}=$origins'),
  );
  if (issues.isNotEmpty) {
    throw AppConfigError(
      AppConfigErrorCode.corsOrigin,
      origin: issues.first.origin,
    );
  }
}

const _unset = Object();

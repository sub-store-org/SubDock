import 'dart:collection';
import 'dart:io';

enum BackendEnvIssueCode {
  missingPair,
  invalidKey,
  duplicateKey,
  reservedKey,
  portRange,
  mergeBool,
  pathPrefix,
  corsOrigin,
}

class BackendEnvIssue {
  const BackendEnvIssue(
    this.code, {
    this.line,
    this.key,
    this.origin,
  });

  final BackendEnvIssueCode code;
  final int? line;
  final String? key;
  final String? origin;

  /// English debugging fallback; the UI renders a localized message from
  /// [code] plus its parameters instead of this raw string.
  String get message => switch (code) {
        BackendEnvIssueCode.missingPair => 'Missing KEY=VALUE',
        BackendEnvIssueCode.invalidKey => 'Invalid environment variable name: $key',
        BackendEnvIssueCode.duplicateKey => 'Duplicate environment variable: $key',
        BackendEnvIssueCode.reservedKey => 'Reserved SubDock environment variable: $key',
        BackendEnvIssueCode.portRange => 'Port must be between 1 and 65535',
        BackendEnvIssueCode.mergeBool => 'Merge mode must be true or false',
        BackendEnvIssueCode.pathPrefix => 'Frontend Backend Path must start with /',
        BackendEnvIssueCode.corsOrigin => 'Invalid CORS origin: $origin',
      };
}

class BackendEnvDocument {
  BackendEnvDocument._(this.rawText, Map<String, String> values, this.issues)
    : values = UnmodifiableMapView(values);

  static final _keyPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  final String rawText;
  final Map<String, String> values;
  final List<BackendEnvIssue> issues;

  bool get isValid => issues.isEmpty;

  factory BackendEnvDocument.parse(String rawText) {
    final values = <String, String>{};
    final issues = <BackendEnvIssue>[];
    final lines = rawText.split('\n');
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].endsWith('\r')
          ? lines[index].substring(0, lines[index].length - 1)
          : lines[index];
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
      final separator = line.indexOf('=');
      if (separator < 1) {
        issues.add(
          BackendEnvIssue(BackendEnvIssueCode.missingPair, line: index + 1),
        );
        continue;
      }
      final key = line.substring(0, separator);
      if (!_keyPattern.hasMatch(key)) {
        issues.add(
          BackendEnvIssue(
            BackendEnvIssueCode.invalidKey,
            line: index + 1,
            key: key,
          ),
        );
        continue;
      }
      if (values.containsKey(key)) {
        issues.add(
          BackendEnvIssue(
            BackendEnvIssueCode.duplicateKey,
            line: index + 1,
            key: key,
          ),
        );
        continue;
      }
      values[key] = line.substring(separator + 1);
    }
    return BackendEnvDocument._(rawText, values, issues);
  }

  BackendEnvDocument withValue(String key, String value) {
    if (!_keyPattern.hasMatch(key)) throw ArgumentError.value(key, 'key');
    if (value.contains('\n') || value.contains('\r')) {
      throw ArgumentError.value(value, 'value', 'value must not contain a newline');
    }
    final lineEnding = rawText.contains('\r\n') ? '\r\n' : '\n';
    final trailingLineEnding = rawText.endsWith('\n');
    final lines = rawText.isEmpty
        ? <String>[]
        : rawText.split(RegExp(r'\r?\n'));
    if (trailingLineEnding) lines.removeLast();

    var replaced = false;
    for (var index = 0; index < lines.length; index++) {
      final separator = lines[index].indexOf('=');
      if (separator > 0 && lines[index].substring(0, separator) == key) {
        lines[index] = '$key=$value';
        replaced = true;
      }
    }
    if (!replaced) lines.add('$key=$value');
    return BackendEnvDocument.parse(
      '${lines.join(lineEnding)}${trailingLineEnding ? lineEnding : ''}',
    );
  }
}

class BackendEnvPolicy {
  static const dataBasePath = 'SUB_STORE_DATA_BASE_PATH';
  static const frontendPath = 'SUB_STORE_FRONTEND_PATH';
  static const host = 'SUB_STORE_BACKEND_API_HOST';
  static const port = 'SUB_STORE_BACKEND_API_PORT';
  static const merge = 'SUB_STORE_BACKEND_MERGE';
  static const frontendBackendPath = 'SUB_STORE_FRONTEND_BACKEND_PATH';
  static const frontendHost = 'SUB_STORE_FRONTEND_HOST';
  static const frontendPort = 'SUB_STORE_FRONTEND_PORT';
  static const corsAllowedOrigins = 'SUB_STORE_CORS_ALLOWED_ORIGINS';
  static const metaFolder = 'META_FOLDER';
  static const metaTempFolder = 'META_TEMP_FOLDER';

  static const reservedKeys = <String>{
    dataBasePath,
    frontendPath,
    metaFolder,
    metaTempFolder,
  };

  static List<BackendEnvIssue> validate(BackendEnvDocument document) {
    final issues = [...document.issues];
    for (final key in reservedKeys) {
      if (document.values.containsKey(key)) {
        issues.add(
          BackendEnvIssue(BackendEnvIssueCode.reservedKey, key: key),
        );
      }
    }
    final configuredPort = document.values[port];
    final parsedPort = configuredPort == null
        ? null
        : int.tryParse(configuredPort);
    if (configuredPort != null &&
        (parsedPort == null || parsedPort < 1 || parsedPort > 65535)) {
      issues.add(const BackendEnvIssue(BackendEnvIssueCode.portRange));
    }
    final configuredMerge = document.values[merge];
    if (configuredMerge != null &&
        configuredMerge != 'true' &&
        configuredMerge != 'false') {
      issues.add(const BackendEnvIssue(BackendEnvIssueCode.mergeBool));
    }
    final configuredPath = document.values[frontendBackendPath];
    if (configuredPath != null && !configuredPath.startsWith('/')) {
      issues.add(const BackendEnvIssue(BackendEnvIssueCode.pathPrefix));
    }
    for (final origin in _origins(document.values[corsAllowedOrigins])) {
      if (origin == '*') continue;
      final uri = Uri.tryParse(origin);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.query.isNotEmpty ||
          uri.fragment.isNotEmpty ||
          (uri.path.isNotEmpty && uri.path != '/')) {
        issues.add(BackendEnvIssue(BackendEnvIssueCode.corsOrigin, origin: origin));
      }
    }
    return issues;
  }

  static Uri localOrigin(BackendEnvDocument document) {
    final configuredHost =
        document.values[host] ?? InternetAddress.loopbackIPv4.address;
    final parsedPort = int.tryParse(document.values[port] ?? '');
    final configuredPort =
        parsedPort != null && parsedPort >= 1 && parsedPort <= 65535
        ? parsedPort
        : 3001;
    return Uri(scheme: 'http', host: configuredHost, port: configuredPort);
  }

  static bool isMergeEnabledFor(BackendEnvDocument document) =>
      document.values[merge] != 'false';

  static bool hasNonLoopbackHost(BackendEnvDocument document) {
    final value = document.values[host] ?? InternetAddress.loopbackIPv4.address;
    return value != 'localhost' && value != '::1' && !value.startsWith('127.');
  }

  static List<String> externalOrigins(BackendEnvDocument document) {
    final local = localOrigin(document).origin;
    return _origins(document.values[corsAllowedOrigins])
        .where(
          (origin) => origin == '*' || Uri.tryParse(origin)?.origin != local,
        )
        .toList(growable: false);
  }

  static Iterable<String> _origins(String? value) =>
      value
          ?.split(',')
          .map((origin) => origin.trim())
          .where((origin) => origin.isNotEmpty) ??
      const <String>[];
}

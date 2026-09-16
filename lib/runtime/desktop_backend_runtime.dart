import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'backend_runtime.dart';
import 'runtime_directories.dart';
import 'runtime_log_store.dart';
import 'runtime_permissions.dart';
import '../settings/backend_env.dart';
import '../settings/subdock_config.dart';
import '../update/component_metadata_store.dart';
import '../update/component_resource_resolver.dart';

class DesktopRuntimeProfile {
  const DesktopRuntimeProfile._(this.executableSuffix);

  factory DesktopRuntimeProfile.current() =>
      DesktopRuntimeProfile._(Platform.isWindows ? '.exe' : '');

  final String executableSuffix;

  String get nodeFileName => 'node$executableSuffix';

  String externalBinaryFileName(String name) => '$name$executableSuffix';
}

class DesktopBackendRuntime implements BackendRuntime {
  DesktopBackendRuntime({
    required this.directories,
    required this.logStore,
    Directory? bundleDirectory,
    DesktopRuntimeProfile? profile,
    ComponentResourceResolver? componentResources,
    int port = 3001,
    Map<String, String> userEnvironment = const <String, String>{},
  }) : _bundleDirectory =
           bundleDirectory ?? File(Platform.resolvedExecutable).parent,
       _profile = profile ?? DesktopRuntimeProfile.current(),
       _componentResources =
           componentResources ??
           ComponentResourceResolver(
             bundleDirectory:
                 bundleDirectory ?? File(Platform.resolvedExecutable).parent,
             componentsDirectory: directories.components,
             metadataStore: ComponentMetadataStore(directories.components),
           ),
       _defaultPort = port,
       _userEnvironment = Map<String, String>.of(userEnvironment);

  static const _healthCheckInterval = Duration(seconds: 1);
  static const _healthCheckTimeout = Duration(seconds: 10);
  static const _httpRequestTimeout = Duration(seconds: 1);
  static const _stopTimeout = Duration(seconds: 5);
  static final _binaryName = RegExp(r'^[A-Za-z0-9._-]+$');

  final RuntimeDirectories directories;
  final RuntimeLogStore logStore;
  final Directory _bundleDirectory;
  final DesktopRuntimeProfile _profile;
  final ComponentResourceResolver _componentResources;
  final int _defaultPort;
  Map<String, String> _userEnvironment;
  final _logs = StreamController<RuntimeLog>.broadcast(sync: true);
  final _states = StreamController<RuntimeState>.broadcast(sync: true);

  RuntimeState _currentState = RuntimeState(
    status: RuntimeStatus.stopped,
    changedAt: DateTime.now(),
  );
  Future<void> _operation = Future<void>.value();
  Process? _process;
  Process? _httpMetaProcess;
  HttpClient? _httpClient;
  HttpClient? _httpMetaClient;
  Future<void> _logWrites = Future<void>.value();
  String? _activeLogRunId;
  Future<void>? _finalizeRunOperation;
  final _captureDrains = <Future<void>>[];
  Timer? _healthTimer;
  bool _stopping = false;
  bool _checkingHealth = false;
  bool _disposed = false;
  bool _httpMetaEnabled = true;
  HttpMetaStatus _httpMetaStatus = HttpMetaStatus.disabled;
  int? _httpMetaPort;
  String? _httpMetaVersion;
  String? _httpMetaMessage;
  String? _httpMetaMihomoVersion;

  @override
  RuntimeState get currentState => _currentState;

  @override
  Uri get endpoint => Uri(
    scheme: 'http',
    host:
        _environmentValue('SUB_STORE_BACKEND_API_HOST') ??
        InternetAddress.loopbackIPv4.address,
    port: port,
  );

  int get port =>
      int.tryParse(_environmentValue('SUB_STORE_BACKEND_API_PORT') ?? '') ??
      _defaultPort;

  @override
  Stream<RuntimeLog> get logs => _logs.stream;

  @override
  Stream<RuntimeState> get state => Stream<RuntimeState>.multi((controller) {
    controller.add(_currentState);
    final subscription = _states.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = subscription.cancel;
  }, isBroadcast: true);

  @override
  Future<void> start() => _serialize(() async {
    _ensureActive();
    await _start();
  });

  @override
  Future<void> stop() => _serialize(() async {
    _ensureActive();
    await _stop();
  });

  @override
  Future<void> restart() => _serialize(() async {
    _ensureActive();
    await _stop();
    await _start();
  });

  @override
  Future<void> activateUserEnvironment(Map<String, String> environment) =>
      _serialize(() async {
        _ensureActive();
        _userEnvironment = Map<String, String>.of(environment);
      });

  @override
  Future<void> activateConfiguration(EffectiveRuntimeConfig configuration) =>
      _serialize(() async {
        _ensureActive();
        _userEnvironment = Map<String, String>.of(configuration.environment);
        _httpMetaEnabled = configuration.httpMetaEnabled;
      });

  @override
  Future<bool> isHealthy() async {
    _ensureActive();
    return _process != null && await _requestInfo() != null;
  }

  @override
  Future<BackendInfo> info() async {
    _ensureActive();
    if (_process == null) throw StateError('Backend is not running');
    final info = await _requestInfo();
    if (info == null) {
      throw StateError('Backend API is unavailable at $endpoint');
    }
    return info;
  }

  @override
  Future<void> dispose() {
    if (_disposed) return Future<void>.value();
    final next = _operation.then((_) => _dispose());
    _operation = next.catchError((Object _) {});
    return next;
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operation.then((_) => operation());
    _operation = next.catchError((Object _) {});
    return next;
  }

  Future<void> _start() async {
    if (_process != null) {
      if (_currentState.status == RuntimeStatus.running) return;
      throw StateError('Backend process is already active');
    }

    _stopping = false;
    _emit(RuntimeStatus.starting);
    try {
      _activeLogRunId = await logStore.beginRun();
      await _startHttpMeta();
      await _verifyPortAvailable();
      final resources = await _componentResources.resolve();
      final manifest = await _readRuntimeManifest(resources.backend);
      final node = await _resolveNode(manifest.testedNode);
      await _verifyExternalBinaries(manifest.externalBinaries);
      final bundle = File.fromUri(
        resources.backend.uri.resolve('sub-store.bundle.js'),
      );
      if (!await bundle.exists()) {
        throw StateError('Backend bundle is missing: ${bundle.path}');
      }
      final process = await Process.start(node, [
        bundle.path,
      ], environment: _environment(resources.frontend));
      _process = process;
      _capture(process.stdout, RuntimeLogSource.stdout, _activeLogRunId!);
      _capture(process.stderr, RuntimeLogSource.stderr, _activeLogRunId!);
      unawaited(() async {
        try {
          await process.exitCode.then((code) => _handleExit(process, code));
        } on Object catch (error) {
          _emit(RuntimeStatus.crashed, '$error');
        }
      }());

      if (!await _waitForHealthy(process)) {
        if (identical(_process, process)) {
          await _terminate(process);
          _process = null;
        }
        throw StateError('Backend did not become healthy');
      }

      if (!identical(_process, process)) {
        throw StateError('Backend exited during startup');
      }
      _emit(RuntimeStatus.running);
      _startHealthMonitor();
    } catch (error, stackTrace) {
      final process = _process;
      if (process != null) {
        try {
          await _terminate(process);
        } on Object {
          // The failure below is the startup error that callers can act on.
        }
        if (identical(_process, process)) _process = null;
      }
      final metaProcess = _httpMetaProcess;
      if (metaProcess != null) {
        var terminated = false;
        try {
          await _terminate(metaProcess);
          terminated = true;
        } on Object catch (cleanupError) {
          _httpMetaStatus = HttpMetaStatus.degraded;
          _httpMetaMessage = 'Unable to stop HTTP-META: $cleanupError';
        }
        if (terminated) {
          if (identical(_httpMetaProcess, metaProcess)) {
            _httpMetaProcess = null;
          }
          _closeHttpMetaClient();
          _httpMetaStatus = HttpMetaStatus.stopped;
          _httpMetaMessage = null;
        }
      }
      _closeHttpClient();
      Object? finalizationError;
      try {
        await _finalizeActiveLogRun();
      } on Object catch (cleanupError) {
        finalizationError = cleanupError;
      }
      _emit(
        RuntimeStatus.crashed,
        finalizationError == null
            ? '$error'
            : '$error; log finalization failed: $finalizationError',
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _stop() async {
    _healthTimer?.cancel();
    _healthTimer = null;
    final process = _process;
    final metaProcess = _httpMetaProcess;
    if (process == null && metaProcess == null) {
      _closeHttpClient();
      _closeHttpMetaClient();
      await _finalizeActiveLogRun();
      if (_currentState.status != RuntimeStatus.stopped) {
        _emit(RuntimeStatus.stopped);
      }
      return;
    }

    _stopping = true;
    _emit(RuntimeStatus.stopping);
    try {
      if (metaProcess != null) {
        await _stopOwnedHttpMetaChildren();
        await _terminate(metaProcess);
      }
      if (process != null) await _terminate(process);
      _closeHttpClient();
      _closeHttpMetaClient();
      await _finalizeActiveLogRun();
      _httpMetaProcess = null;
      _httpMetaStatus = HttpMetaStatus.stopped;
      _process = null;
      _emit(RuntimeStatus.stopped);
    } catch (error, stackTrace) {
      _stopping = false;
      _emit(RuntimeStatus.crashed, 'Unable to stop backend: $error');
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _dispose() async {
    Object? failure;
    StackTrace? failureStackTrace;
    try {
      await _stop();
    } catch (error, stackTrace) {
      failure = error;
      failureStackTrace = stackTrace;
    }
    _healthTimer?.cancel();
    _healthTimer = null;
    _closeHttpClient();
    await _finalizeActiveLogRun();
    _disposed = true;
    await Future.wait(<Future<void>>[_logs.close(), _states.close()]);
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStackTrace!);
    }
  }

  Future<void> _verifyPortAvailable() async {
    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException {
      throw StateError('Backend port $port is occupied by an unknown process');
    } finally {
      await socket?.close();
    }
  }

  Future<void> _startHttpMeta() async {
    if (!_httpMetaEnabled) {
      _httpMetaStatus = HttpMetaStatus.disabled;
      _httpMetaMessage = null;
      _httpMetaVersion = null;
      _httpMetaMihomoVersion = null;
      return;
    }
    _httpMetaStatus = HttpMetaStatus.starting;
    _httpMetaPort = int.tryParse(_environmentValue('PORT') ?? '') ?? 9876;
    try {
      final resources = await _componentResources.resolveHttpMeta();
      final tempDirectory = Directory.fromUri(
        directories.data.uri.resolve('http-meta/'),
      );
      await tempDirectory.create(recursive: true);
      await restrictDirectoryToCurrentUser(tempDirectory);
      await _verifyHttpMetaPortAvailable();
      final node = _runtimeNode;
      if (!await node.exists()) {
        throw StateError('Packaged Node.js runtime is missing: ${node.path}');
      }
      final process = await Process.start(node.path, [
        resources.bundle.path,
      ], environment: _httpMetaEnvironment(resources));
      _httpMetaProcess = process;
      _capture(
        process.stdout,
        RuntimeLogSource.httpMetaStdout,
        _activeLogRunId!,
      );
      _capture(
        process.stderr,
        RuntimeLogSource.httpMetaStderr,
        _activeLogRunId!,
      );
      unawaited(
        process.exitCode.then((code) => _handleHttpMetaExit(process, code)),
      );
      if (!await _waitForHttpMetaHealthy(process)) {
        await _terminate(process);
        _httpMetaProcess = null;
        throw StateError('HTTP-META did not become healthy');
      }
      _httpMetaStatus = HttpMetaStatus.running;
      _httpMetaVersion = resources.version;
      _httpMetaMihomoVersion = resources.mihomoVersion;
      _httpMetaMessage = null;
    } catch (error) {
      _httpMetaStatus = HttpMetaStatus.unavailable;
      _httpMetaMessage = '$error';
      _httpMetaVersion = null;
      _httpMetaMihomoVersion = null;
      // HTTP-META is an optional helper; Backend startup continues.
    }
  }

  Future<void> _verifyHttpMetaPortAvailable() async {
    final port = _httpMetaPort!;
    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException {
      throw StateError(
        'HTTP-META port $port is occupied by an unknown process',
      );
    } finally {
      await socket?.close();
    }
  }

  Map<String, String> _httpMetaEnvironment(HttpMetaResources resources) {
    final environment = _environment(directories.data);
    environment['HOST'] =
        _environmentValue('HOST') ?? InternetAddress.loopbackIPv4.address;
    environment['PORT'] = '${_httpMetaPort ?? 9876}';
    environment['META_FOLDER'] = resources.metaDirectory.path;
    environment['META_TEMP_FOLDER'] = Directory.fromUri(
      directories.data.uri.resolve('http-meta/'),
    ).path;
    return environment;
  }

  Future<bool> _waitForHttpMetaHealthy(Process process) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < _healthCheckTimeout) {
      if (!identical(_httpMetaProcess, process)) return false;
      if (await _requestHttpMetaHealthy()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  Future<bool> _requestHttpMetaHealthy() async {
    final client = _httpMetaClient ??= HttpClient()
      ..connectionTimeout = _httpRequestTimeout;
    try {
      final request = await client.postUrl(
        Uri(
          scheme: 'http',
          host:
              _environmentValue('HOST') ?? InternetAddress.loopbackIPv4.address,
          port: _httpMetaPort ?? 9876,
          path: '/stats',
        ),
      );
      request.headers.contentType = ContentType.json;
      request.write('{}');
      final response = await request.close().timeout(_httpRequestTimeout);
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } on Object {
      _httpMetaClient?.close(force: true);
      _httpMetaClient = null;
      return false;
    }
  }

  Future<void> _stopOwnedHttpMetaChildren() async {
    final file = File.fromUri(
      directories.data.uri.resolve('http-meta/http-meta.json'),
    );
    if (!await file.exists()) return;
    List<int> pids;
    try {
      final decoded = jsonDecode(await file.readAsString());
      final processes = decoded is Map<String, dynamic>
          ? decoded['processes']
          : null;
      if (processes is! Map<String, dynamic>) return;
      pids = processes.keys.map(int.tryParse).whereType<int>().toList();
    } on Object {
      return;
    }
    if (pids.isEmpty) return;
    final client = _httpMetaClient ??= HttpClient()
      ..connectionTimeout = _httpRequestTimeout;
    try {
      final request = await client.postUrl(
        Uri(
          scheme: 'http',
          host:
              _environmentValue('HOST') ?? InternetAddress.loopbackIPv4.address,
          port: _httpMetaPort ?? 9876,
          path: '/stop',
        ),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'pid': pids}));
      final response = await request.close().timeout(_httpRequestTimeout);
      await response.drain<void>();
    } on Object {
      // The helper may already be unavailable; process cleanup remains targeted.
    }
  }

  Future<void> _terminate(Process process) async {
    if (!process.kill()) {
      throw StateError('Backend process could not be terminated');
    }
    try {
      await process.exitCode.timeout(_stopTimeout);
    } on TimeoutException {
      final killed = Platform.isWindows
          ? process.kill()
          : process.kill(ProcessSignal.sigkill);
      if (!killed) {
        throw StateError('Backend process could not be force-terminated');
      }
      await process.exitCode.timeout(_stopTimeout);
    }
  }

  Future<_RuntimeManifest> _readRuntimeManifest(
    Directory backendDirectory,
  ) async {
    final manifest = File.fromUri(
      backendDirectory.uri.resolve('runtime-manifest.json'),
    );
    if (!await manifest.exists()) {
      throw StateError('Runtime manifest is missing: ${manifest.path}');
    }
    final decoded = jsonDecode(await manifest.readAsString());
    if (decoded is! Map<String, dynamic> || decoded['testedNode'] is! String) {
      throw StateError('Runtime manifest has no testedNode version');
    }
    final binaries = decoded['externalBinary'] ?? const <Object>[];
    if (binaries is! List || binaries.any((item) => item is! String)) {
      throw StateError('Runtime manifest has invalid external binaries');
    }
    return _RuntimeManifest(
      testedNode: decoded['testedNode'] as String,
      externalBinaries: binaries.cast<String>(),
    );
  }

  Future<String> _resolveNode(String testedNode) async {
    final expectedMajor = _majorVersion(testedNode);
    if (expectedMajor == null) {
      throw StateError('Runtime manifest has an invalid testedNode version');
    }
    final node = _runtimeNode;
    if (!await node.exists()) {
      throw StateError('Packaged Node.js runtime is missing: ${node.path}');
    }
    if (!await _hasMajorVersion(node.path, expectedMajor)) {
      throw StateError('Packaged Node.js is not major version $expectedMajor');
    }
    return node.path;
  }

  Future<void> _verifyExternalBinaries(List<String> binaries) async {
    for (final binary in binaries) {
      if (!_binaryName.hasMatch(binary)) {
        throw StateError(
          'Runtime manifest has an invalid binary name: $binary',
        );
      }
      final file = File.fromUri(
        _bundleDirectory.uri.resolve(
          'data/runtime/bin/${_profile.externalBinaryFileName(binary)}',
        ),
      );
      if (!await file.exists()) {
        throw StateError('Packaged external binary is missing: ${file.path}');
      }
      if (!Platform.isWindows && ((await file.stat()).mode & 0x49) == 0) {
        throw StateError(
          'Packaged external binary is not executable: ${file.path}',
        );
      }
    }
  }

  Future<bool> _hasMajorVersion(String executable, int expectedMajor) async {
    try {
      final result = await Process.run(executable, ['--version']);
      if (result.exitCode != 0) return false;
      return _majorVersion(result.stdout.toString().trim()) == expectedMajor;
    } on ProcessException {
      return false;
    }
  }

  int? _majorVersion(String version) {
    final match = RegExp(r'^v?(\d+)\.').firstMatch(version);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  Future<bool> _waitForHealthy(Process process) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < _healthCheckTimeout) {
      if (!identical(_process, process)) return false;
      if (await isHealthy()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  void _startHealthMonitor() {
    _healthTimer = Timer.periodic(_healthCheckInterval, (_) async {
      if (_checkingHealth || _process == null) return;
      _checkingHealth = true;
      try {
        final healthy = await isHealthy();
        if (!healthy && _currentState.status == RuntimeStatus.running) {
          _emit(RuntimeStatus.unhealthy, 'Backend API is unavailable');
        } else if (healthy && _currentState.status == RuntimeStatus.unhealthy) {
          _emit(RuntimeStatus.running);
        }
      } finally {
        _checkingHealth = false;
      }
    });
  }

  Future<BackendInfo?> _requestInfo() async {
    final client = _httpClient ??= HttpClient()
      ..connectionTimeout = _httpRequestTimeout;
    try {
      return await _requestInfoFrom(client).timeout(_httpRequestTimeout);
    } on TimeoutException {
      _closeHttpClient();
      return null;
    } on HttpException {
      return null;
    } on SocketException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<BackendInfo?> _requestInfoFrom(HttpClient client) async {
    final request = await client.getUrl(_apiUrl());
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) return null;
    final body = await utf8.decoder.bind(response).join();
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    final data = decoded['data'];
    if (data is! Map<String, dynamic>) return null;
    final meta = data['meta'];
    if (meta is! Map<String, dynamic>) return null;
    final node = meta['node'];
    if (node is! Map<String, dynamic> ||
        node['version'] is! String ||
        data['version'] is! String) {
      return null;
    }
    return BackendInfo(
      nodeVersion: node['version'] as String,
      backendVersion: data['version'] as String,
      port: port,
    );
  }

  void _capture(
    Stream<List<int>> stream,
    RuntimeLogSource source,
    String runId,
  ) {
    final drain = stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final log = RuntimeLog(
            timestamp: DateTime.now(),
            source: source,
            message: line,
          );
          if (!_logs.isClosed) _logs.add(log);
          final next = _logWrites.then((_) async {
            if (_activeLogRunId == runId) await logStore.append(log);
          });
          _logWrites = next.catchError((Object _) {});
        })
        .asFuture<void>();
    _captureDrains.add(drain);
  }

  Future<void> _finalizeActiveLogRun() {
    final id = _activeLogRunId;
    if (id == null) return Future<void>.value();
    final existing = _finalizeRunOperation;
    if (existing != null) return existing;
    final operation = () async {
      try {
        await Future.wait(List<Future<void>>.of(_captureDrains));
      } on Object {
        // Capture errors are irrelevant after the stream has been closed.
      }
      await _logWrites;
      if (_activeLogRunId == id) {
        await logStore.finalize(end: DateTime.now());
        _activeLogRunId = null;
        _captureDrains.clear();
      }
    }();
    late final Future<void> completed;
    completed = operation.whenComplete(() {
      if (identical(_finalizeRunOperation, completed)) {
        _finalizeRunOperation = null;
      }
    });
    _finalizeRunOperation = completed;
    return completed;
  }

  Future<void> _handleExit(Process process, int exitCode) async {
    if (!identical(_process, process)) return;
    _healthTimer?.cancel();
    _healthTimer = null;
    _closeHttpClient();
    _process = null;
    if (_stopping || _currentState.status == RuntimeStatus.starting) return;
    final metaProcess = _httpMetaProcess;
    if (metaProcess != null) {
      await _stopOwnedHttpMetaChildren();
      await _terminate(metaProcess);
      _httpMetaProcess = null;
    }
    await _finalizeActiveLogRun();
    _emit(RuntimeStatus.crashed, 'Backend exited with code $exitCode');
  }

  void _handleHttpMetaExit(Process process, int exitCode) {
    if (!identical(_httpMetaProcess, process)) return;
    _httpMetaProcess = null;
    _closeHttpMetaClient();
    if (_stopping) {
      _httpMetaStatus = HttpMetaStatus.stopped;
      _httpMetaMessage = null;
    } else {
      _httpMetaStatus = HttpMetaStatus.degraded;
      _httpMetaMessage = 'HTTP-META exited with code $exitCode';
    }
    _emit(_currentState.status, _currentState.message);
  }

  void _emit(RuntimeStatus status, [String? message]) {
    _currentState = RuntimeState(
      status: status,
      changedAt: DateTime.now(),
      message: message,
      httpMetaStatus: _httpMetaStatus,
      httpMetaPort: _httpMetaPort,
      httpMetaVersion: _httpMetaVersion,
      httpMetaMihomoVersion: _httpMetaMihomoVersion,
      httpMetaMessage: _httpMetaMessage,
    );
    if (!_states.isClosed) _states.add(_currentState);
  }

  Map<String, String> _environment(Directory frontendDirectory) {
    final environment = Map<String, String>.of(Platform.environment);
    final pathKey = environment.keys.firstWhere(
      (key) => key.toLowerCase() == 'path',
      orElse: () => 'PATH',
    );
    final originalPath = environment[pathKey] ?? '';
    final binaryPath = _runtimeBin.path;
    environment[pathKey] = originalPath.isEmpty
        ? binaryPath
        : '$binaryPath${Platform.pathSeparator}$originalPath';
    environment.addAll(_userEnvironment);
    environment.putIfAbsent(
      'SUB_STORE_BACKEND_API_HOST',
      () => InternetAddress.loopbackIPv4.address,
    );
    environment['SUB_STORE_BACKEND_API_PORT'] = '$port';
    environment.putIfAbsent('SUB_STORE_BACKEND_MERGE', () => 'true');
    environment.putIfAbsent(
      'SUB_STORE_CORS_ALLOWED_ORIGINS',
      () => endpoint.origin,
    );
    environment.addAll(<String, String>{
      'SUB_STORE_DATA_BASE_PATH': directories.data.path,
      'SUB_STORE_FRONTEND_PATH': frontendDirectory.path,
      BackendEnvPolicy.metaFolder: Directory.fromUri(
        _bundleDirectory.uri.resolve('data/http-meta/meta/'),
      ).path,
      BackendEnvPolicy.metaTempFolder: Directory.fromUri(
        directories.data.uri.resolve('http-meta/'),
      ).path,
    });
    return environment;
  }

  String? _environmentValue(String key) =>
      _userEnvironment[key] ?? Platform.environment[key];

  Uri _apiUrl() {
    final backendPrefixEnabled =
        _environmentValue('SUB_STORE_BACKEND_PREFIX')?.isNotEmpty ?? false;
    final pathAppliesToBackend =
        _environmentValue(BackendEnvPolicy.merge) != 'false' ||
        backendPrefixEnabled;
    final configuredPath = pathAppliesToBackend
        ? _environmentValue(BackendEnvPolicy.frontendBackendPath) ?? '/'
        : '/';
    final prefix = configuredPath == '/' ? '' : configuredPath;
    return endpoint.replace(path: '$prefix/api/utils/env');
  }

  File get _runtimeNode => File.fromUri(
    _bundleDirectory.uri.resolve('data/runtime/${_profile.nodeFileName}'),
  );

  Directory get _runtimeBin =>
      Directory.fromUri(_bundleDirectory.uri.resolve('data/runtime/bin/'));

  void _ensureActive() {
    if (_disposed) throw StateError('Backend runtime has been disposed');
  }

  void _closeHttpClient() {
    _httpClient?.close(force: true);
    _httpClient = null;
  }

  void _closeHttpMetaClient() {
    _httpMetaClient?.close(force: true);
    _httpMetaClient = null;
  }
}

class _RuntimeManifest {
  const _RuntimeManifest({
    required this.testedNode,
    required this.externalBinaries,
  });

  final String testedNode;
  final List<String> externalBinaries;
}

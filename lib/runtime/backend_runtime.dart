import 'dart:async';

import '../settings/subdock_config.dart';

abstract class BackendRuntime {
  RuntimeState get currentState;

  Uri get endpoint;

  Future<void> start();

  Future<void> stop();

  Future<void> restart();

  Future<void> activateUserEnvironment(Map<String, String> environment);

  Future<void> activateConfiguration(EffectiveRuntimeConfig configuration) =>
      activateUserEnvironment(configuration.environment);

  Future<bool> isHealthy();

  Future<BackendInfo> info();

  Future<void> dispose();

  Stream<RuntimeLog> get logs;

  Stream<RuntimeState> get state;
}

enum RuntimeStatus { stopped, starting, running, stopping, unhealthy, crashed }

class RuntimeState {
  const RuntimeState({
    required this.status,
    required this.changedAt,
    this.message,
    this.httpMetaStatus = HttpMetaStatus.disabled,
    this.httpMetaPort,
    this.httpMetaVersion,
    this.httpMetaMessage,
    this.httpMetaMihomoVersion,
  });

  final RuntimeStatus status;
  final DateTime changedAt;
  final String? message;
  final HttpMetaStatus httpMetaStatus;
  final int? httpMetaPort;
  final String? httpMetaVersion;
  final String? httpMetaMessage;
  final String? httpMetaMihomoVersion;
}

enum HttpMetaStatus {
  disabled,
  unavailable,
  starting,
  running,
  degraded,
  stopped,
}

enum RuntimeLogSource { stdout, stderr, httpMetaStdout, httpMetaStderr }

class RuntimeLog {
  const RuntimeLog({
    required this.timestamp,
    required this.source,
    required this.message,
  });

  final DateTime timestamp;
  final RuntimeLogSource source;
  final String message;
}

class BackendInfo {
  const BackendInfo({
    required this.nodeVersion,
    required this.backendVersion,
    required this.port,
  });

  final String nodeVersion;
  final String backendVersion;
  final int port;
}

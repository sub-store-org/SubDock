import 'dart:async';

import '../settings/subdock_config.dart';

abstract class BackendRuntime {
  RuntimeState get currentState;

  Uri get endpoint;

  /// The configuration the running process was started with.
  ///
  /// Null while nothing is running, so a saved or pending configuration never
  /// reads as applied before a successful start. Runtimes that own no process
  /// keep the null default.
  EffectiveRuntimeConfig? get appliedConfiguration => null;

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

  /// Identifies each run created by the runtime's real log store.
  Stream<RuntimeLogRunStarted> get logRunStarted =>
      const Stream<RuntimeLogRunStarted>.empty();

  Stream<RuntimeLogRunUpdate> get logRunUpdates =>
      const Stream<RuntimeLogRunUpdate>.empty();

  Future<void> retryLogFinalization(String runId) => Future<void>.error(
    UnsupportedError('This runtime cannot retry log finalization'),
  );

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

enum RuntimeLogIntegrity { unknown, complete, incomplete, recovered }

class RuntimeLogRunUpdate {
  const RuntimeLogRunUpdate({
    required this.runId,
    required this.integrity,
    required this.finalized,
    required this.persistenceConfirmed,
    this.retryAvailable = false,
  });

  final String runId;
  final RuntimeLogIntegrity integrity;
  final bool finalized;
  final bool persistenceConfirmed;
  final bool retryAvailable;
}

class RuntimeLogRunStarted {
  const RuntimeLogRunStarted(this.runId);

  final String runId;
}

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

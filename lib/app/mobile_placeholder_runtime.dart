import '../runtime/backend_runtime.dart';

class MobilePlaceholderRuntime extends BackendRuntime {
  MobilePlaceholderRuntime()
    : _state = RuntimeState(
        status: RuntimeStatus.stopped,
        changedAt: DateTime.now(),
      );

  final RuntimeState _state;

  @override
  RuntimeState get currentState => _state;

  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:3001/');

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> restart() async {}

  @override
  Future<void> activateUserEnvironment(Map<String, String> environment) async {}

  @override
  Future<bool> isHealthy() async => false;

  @override
  Future<BackendInfo> info() => Future<BackendInfo>.error(
    StateError('Mobile placeholder runtime has no Backend info'),
  );

  @override
  Future<void> dispose() async {}

  @override
  Stream<RuntimeLog> get logs => const Stream<RuntimeLog>.empty();

  @override
  Stream<RuntimeState> get state => const Stream<RuntimeState>.empty();
}

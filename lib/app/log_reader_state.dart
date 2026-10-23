import '../runtime/backend_runtime.dart';

/// Keeps the live tail bounded while a paused view retains its own snapshot.
class LogReaderState {
  LogReaderState({required this._limit});

  int _limit;
  final List<RuntimeLog> _liveLogs = [];
  List<RuntimeLog>? _frozenLogs;
  String? _runId;
  String? _frozenRunId;
  var _following = true;
  var _newLogCount = 0;

  List<RuntimeLog> get visibleLogs => List.unmodifiable(
    _following ? _liveLogs : _frozenLogs ?? const <RuntimeLog>[],
  );

  String? get visibleRunId => _following ? _runId : _frozenRunId;
  String? get currentRunId => _runId;
  String? get frozenRunId => _frozenRunId;
  bool get isFollowing => _following;
  int get newLogCount => _newLogCount;

  void beginRun(String runId) {
    if (_runId == runId) return;
    _runId = runId;
    _liveLogs.clear();
    if (_following) _newLogCount = 0;
  }

  void append(RuntimeLog log) {
    _liveLogs.add(log);
    if (_liveLogs.length > _limit) {
      _liveLogs.removeRange(0, _liveLogs.length - _limit);
    }
    if (!_following) _newLogCount++;
  }

  void updateLimit(int limit) {
    _limit = limit;
    if (_liveLogs.length > limit) {
      _liveLogs.removeRange(0, _liveLogs.length - limit);
    }
  }

  void pause() {
    if (!_following) return;
    _following = false;
    _frozenLogs = List<RuntimeLog>.of(_liveLogs);
    _frozenRunId = _runId;
    _newLogCount = 0;
  }

  void resume() {
    if (_following) return;
    _following = true;
    _frozenLogs = null;
    _frozenRunId = null;
    _newLogCount = 0;
  }
}

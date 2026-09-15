import '../runtime/backend_runtime.dart';

class RuntimeObservationSnapshot {
  const RuntimeObservationSnapshot({
    required this.startedAt,
    required this.anomalyCount,
    required this.currentSessionLogCount,
  });

  final DateTime? startedAt;
  final int anomalyCount;
  final int currentSessionLogCount;
}

class RuntimeObservations {
  RuntimeStatus? _status;
  DateTime? _startedAt;
  final _anomalies = <DateTime>[];
  var _currentSessionLogCount = 0;

  void observeState(RuntimeState state) {
    final wasAnomalous = _isAnomalous(_status);
    if (state.status == RuntimeStatus.starting &&
        _status != RuntimeStatus.starting) {
      _startedAt = state.changedAt;
      _currentSessionLogCount = 0;
    }
    if (_isAnomalous(state.status) && !wasAnomalous) {
      _anomalies.add(state.changedAt);
    }
    _status = state.status;
  }

  void observeLog(RuntimeLog log) {
    _currentSessionLogCount++;
  }

  RuntimeObservationSnapshot snapshot({DateTime? now}) {
    final evaluatedAt = now ?? DateTime.now();
    final cutoff = evaluatedAt.subtract(const Duration(hours: 24));
    final anomalyCount = _anomalies.where((timestamp) {
      return !timestamp.isBefore(cutoff) && !timestamp.isAfter(evaluatedAt);
    }).length;

    return RuntimeObservationSnapshot(
      startedAt: _startedAt,
      anomalyCount: anomalyCount,
      currentSessionLogCount: _currentSessionLogCount,
    );
  }

  bool _isAnomalous(RuntimeStatus? status) {
    return status == RuntimeStatus.unhealthy || status == RuntimeStatus.crashed;
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/runtime_observations.dart';
import 'package:subdock/runtime/backend_runtime.dart';

void main() {
  test('captures the first start and keeps it during repeated starting', () {
    final observations = RuntimeObservations();
    final first = DateTime(2026, 9, 15, 10);

    observations.observeState(_state(RuntimeStatus.starting, first));
    observations.observeState(
      _state(RuntimeStatus.starting, first.add(const Duration(minutes: 1))),
    );

    expect(observations.snapshot(now: first).startedAt, first);
  });

  test('a later start replaces the timestamp and resets its log count', () {
    final observations = RuntimeObservations();
    final first = DateTime(2026, 9, 15, 10);
    final second = first.add(const Duration(hours: 1));

    observations.observeState(_state(RuntimeStatus.starting, first));
    observations.observeLog(_log(first));
    observations.observeState(_state(RuntimeStatus.stopped, second));
    observations.observeLog(_log(second));
    observations.observeState(
      _state(RuntimeStatus.starting, second.add(const Duration(minutes: 1))),
    );

    final snapshot = observations.snapshot(now: second);
    expect(snapshot.startedAt, second.add(const Duration(minutes: 1)));
    expect(snapshot.currentSessionLogCount, 0);
  });

  test('keeps one anomaly incident across unhealthy and crashed states', () {
    final observations = RuntimeObservations();
    final start = DateTime(2026, 9, 15, 10);

    observations.observeState(_state(RuntimeStatus.unhealthy, start));
    observations.observeState(
      _state(RuntimeStatus.crashed, start.add(const Duration(minutes: 1))),
    );
    observations.observeState(
      _state(RuntimeStatus.unhealthy, start.add(const Duration(minutes: 2))),
    );

    expect(observations.snapshot(now: start).anomalyCount, 1);
  });

  test('counts a new anomaly after recovery', () {
    final observations = RuntimeObservations();
    final start = DateTime(2026, 9, 15, 10);

    observations.observeState(_state(RuntimeStatus.unhealthy, start));
    observations.observeState(
      _state(RuntimeStatus.running, start.add(const Duration(minutes: 1))),
    );
    observations.observeState(
      _state(RuntimeStatus.crashed, start.add(const Duration(minutes: 2))),
    );

    expect(
      observations
          .snapshot(now: start.add(const Duration(minutes: 3)))
          .anomalyCount,
      2,
    );
  });

  test(
    'counts only recent anomalies, including the exact 24 hour boundary',
    () {
      final observations = RuntimeObservations();
      final now = DateTime(2026, 9, 15, 10);

      observations.observeState(
        _state(RuntimeStatus.crashed, now.subtract(const Duration(hours: 25))),
      );
      observations.observeState(
        _state(RuntimeStatus.running, now.subtract(const Duration(hours: 24))),
      );
      observations.observeState(
        _state(RuntimeStatus.crashed, now.subtract(const Duration(hours: 24))),
      );
      observations.observeState(_state(RuntimeStatus.running, now));
      observations.observeState(
        _state(RuntimeStatus.crashed, now.subtract(const Duration(hours: 1))),
      );

      expect(observations.snapshot(now: now).anomalyCount, 2);
    },
  );

  test('counts every observed log independently of the visible log list', () {
    final observations = RuntimeObservations();
    final now = DateTime(2026, 9, 15, 10);

    observations.observeState(_state(RuntimeStatus.starting, now));
    for (var index = 0; index < 3; index++) {
      observations.observeLog(_log(now.add(Duration(minutes: index))));
    }

    expect(observations.snapshot(now: now).currentSessionLogCount, 3);
  });
}

RuntimeState _state(RuntimeStatus status, DateTime changedAt) =>
    RuntimeState(status: status, changedAt: changedAt);

RuntimeLog _log(DateTime timestamp) => RuntimeLog(
  timestamp: timestamp,
  source: RuntimeLogSource.stdout,
  message: 'message',
);

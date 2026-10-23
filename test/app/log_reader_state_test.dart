import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/log_reader_state.dart';
import 'package:subdock/runtime/backend_runtime.dart';

void main() {
  test('saved live limit does not trim a paused snapshot', () {
    final reader = LogReaderState(limit: 4);
    reader.beginRun('run-1');
    for (var index = 0; index < 4; index++) {
      reader.append(_log('first-$index'));
    }
    reader.pause();

    reader.updateLimit(2);
    reader.beginRun('run-2');
    for (var index = 0; index < 3; index++) {
      reader.append(_log('second-$index'));
    }
    reader.updateLimit(1);

    expect(reader.visibleLogs.map((log) => log.message), [
      'first-0',
      'first-1',
      'first-2',
      'first-3',
    ]);
    expect(reader.visibleRunId, 'run-1');
    expect(reader.newLogCount, 3);

    reader.resume();
    expect(reader.visibleLogs.map((log) => log.message), ['second-2']);
    expect(reader.visibleRunId, 'run-2');
    expect(reader.newLogCount, 0);
  });
}

RuntimeLog _log(String message) => RuntimeLog(
  timestamp: DateTime.utc(2026, 1, 1),
  source: RuntimeLogSource.stdout,
  message: message,
);

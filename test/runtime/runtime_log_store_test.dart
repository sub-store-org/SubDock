import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/runtime/runtime_log_store.dart';

void main() {
  late Directory temp;
  late RuntimeDirectories directories;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('subdock_log_store_');
    directories = await RuntimeDirectories.fromBaseDirectory(temp);
  });
  tearDown(() => temp.delete(recursive: true));

  test('round trips a completed run and supports reverse traversal', () async {
    final store = RuntimeLogStore(directories, segmentBytes: 1);
    await store.initialize();
    final start = await store.beginRun();
    final entries = [
      RuntimeLog(
        timestamp: DateTime.utc(2026, 9, 13, 4, 0),
        source: RuntimeLogSource.stdout,
        message: 'one',
      ),
      RuntimeLog(
        timestamp: DateTime.utc(2026, 9, 13, 4, 1),
        source: RuntimeLogSource.stderr,
        message: 'two',
      ),
      RuntimeLog(
        timestamp: DateTime.utc(2026, 9, 13, 4, 2),
        source: RuntimeLogSource.httpMetaStdout,
        message: 'three',
      ),
    ];
    for (final entry in entries) {
      await store.append(entry);
    }
    await store.finalize();

    final runs = await store.listRuns();
    expect(runs.single.id, start);
    expect(runs.single.eventCount, 3);
    final actual = await store.readRun(start);
    expect(
      actual.map((entry) => entry.message),
      entries.map((entry) => entry.message),
    );
    expect(
      (await store.readRun(start, reverse: true)).map((entry) => entry.message),
      entries.reversed.map((entry) => entry.message),
    );
  });

  test(
    'uses the supplied lifecycle end time and rejects active deletion',
    () async {
      final store = RuntimeLogStore(directories);
      await store.initialize();
      final id = await store.beginRun();
      await store.append(
        RuntimeLog(
          timestamp: DateTime.utc(2026, 9, 13),
          source: RuntimeLogSource.stdout,
          message: 'entry',
        ),
      );
      expect(() => store.deleteRun(id), throwsStateError);
      final end = DateTime.utc(2026, 9, 13, 1);
      await store.finalize(end: end);
      expect((await store.listRuns()).single.end, end);
    },
  );

  test('streams reverse events across forced-small segments', () async {
    final store = RuntimeLogStore(directories, segmentBytes: 1);
    await store.initialize();
    final id = await store.beginRun();
    for (var index = 0; index < 5; index++) {
      await store.append(
        RuntimeLog(
          timestamp: DateTime.utc(2026, 9, 13, 0, index),
          source: RuntimeLogSource.stdout,
          message: '$index',
        ),
      );
    }
    await store.finalize();
    expect(
      await store
          .readRunStream(id, reverse: true)
          .map((entry) => entry.message)
          .toList(),
      ['4', '3', '2', '1', '0'],
    );
  });

  test(
    'uses UTF-8 bytes for segment rollover and prunes legacy logs',
    () async {
      final store = RuntimeLogStore(directories, segmentBytes: 40);
      await store.initialize();
      final id = await store.beginRun();
      await store.append(
        RuntimeLog(
          timestamp: DateTime.utc(2026, 9, 13),
          source: RuntimeLogSource.stdout,
          message: '中文日志',
        ),
      );
      await store.append(
        RuntimeLog(
          timestamp: DateTime.utc(2026, 9, 13, 0, 1),
          source: RuntimeLogSource.stdout,
          message: 'second',
        ),
      );
      await store.finalize();
      expect(await store.readRunStream(id).length, 2);

      final legacy = File.fromUri(directories.logs.uri.resolve('backend.log'));
      await legacy.writeAsString('old');
      final old = DateTime.now().subtract(const Duration(days: 8));
      await legacy.setLastModified(old);
      await store.pruneExpired();
      expect(await legacy.exists(), isFalse);
    },
  );

  test('deletes one run and undoes the latest deletion', () async {
    final store = RuntimeLogStore(directories);
    await store.initialize();
    final id = await store.beginRun();
    await store.append(
      RuntimeLog(
        timestamp: DateTime.utc(2026, 9, 13),
        source: RuntimeLogSource.stdout,
        message: 'entry',
      ),
    );
    await store.finalize();
    await store.deleteRun(id);
    expect(await store.listRuns(), isEmpty);
    await store.clearHistory();
    await store.undoLastDeletion();
    expect((await store.readRun(id)).single.message, 'entry');
  });

  test('reconciles an orphan run and retains the seven-day boundary', () async {
    final now = DateTime.utc(2026, 9, 13);
    final store = RuntimeLogStore(directories, now: () => now);
    await store.initialize();
    final id = await store.beginRun();
    await store.append(
      RuntimeLog(
        timestamp: DateTime.utc(2026, 9, 13),
        source: RuntimeLogSource.stdout,
        message: 'durable',
      ),
    );
    final restarted = RuntimeLogStore(directories, now: () => now);
    await restarted.initialize();
    expect((await restarted.listRuns()).single.id, id);
    expect((await restarted.listRuns()).single.eventCount, 1);
  });

  test('rejects unsafe and inactive operations', () async {
    final store = RuntimeLogStore(directories);
    await store.initialize();
    expect(
      () => store.append(
        RuntimeLog(
          timestamp: DateTime.utc(2026, 9, 13),
          source: RuntimeLogSource.stdout,
          message: 'no run',
        ),
      ),
      throwsStateError,
    );
    expect(() => store.readRun('../escape'), throwsArgumentError);
  });

  test('only ignores a physically truncated orphan tail', () async {
    final now = DateTime.utc(2026, 9, 13);
    Future<Directory> orphan(String tail, {int segmentBytes = 1 << 20}) async {
      final store = RuntimeLogStore(
        directories,
        now: () => now,
        segmentBytes: segmentBytes,
      );
      await store.initialize();
      final id = await store.beginRun();
      await store.append(
        RuntimeLog(
          timestamp: DateTime.utc(2026, 9, 13),
          source: RuntimeLogSource.stdout,
          message: 'durable',
        ),
      );
      final file = File.fromUri(
        directories.logs.uri.resolve('runs/$id/000000.jsonl'),
      );
      await file.writeAsString('${await file.readAsString()}$tail');
      return Directory.fromUri(directories.logs.uri.resolve('runs/$id/'));
    }

    final truncated = await orphan('{"timestamp":"2026-09-13T00:00:00');
    final recovered = RuntimeLogStore(directories, now: () => now);
    await recovered.initialize();
    expect((await recovered.listRuns()).single.eventCount, 1);
    expect(truncated.existsSync(), isTrue);

    await orphan(
      jsonEncode({
        'timestamp': 'not-a-date',
        'source': 'stdout',
        'message': 'corrupt',
      }),
    );
    expect(
      () => RuntimeLogStore(directories, now: () => now).initialize(),
      throwsFormatException,
    );
  });

  test('does not hide earlier-segment corruption', () async {
    final store = RuntimeLogStore(directories, segmentBytes: 1);
    await store.initialize();
    final id = await store.beginRun();
    await store.append(
      RuntimeLog(
        timestamp: DateTime.utc(2026, 9, 13),
        source: RuntimeLogSource.stdout,
        message: 'one',
      ),
    );
    await store.append(
      RuntimeLog(
        timestamp: DateTime.utc(2026, 9, 13, 0, 1),
        source: RuntimeLogSource.stdout,
        message: 'two',
      ),
    );
    final first = File.fromUri(
      directories.logs.uri.resolve('runs/$id/000000.jsonl'),
    );
    await first.writeAsString('{');
    expect(
      () => RuntimeLogStore(directories).initialize(),
      throwsFormatException,
    );
  });

  test('history reads reject newline-terminated malformed records', () async {
    final store = RuntimeLogStore(directories);
    await store.initialize();
    final completed = await store.beginRun();
    await store.finalize();
    final last = File.fromUri(
      directories.logs.uri.resolve('runs/$completed/000000.jsonl'),
    );
    await last.writeAsString('{\n');
    expect(() => store.readRun(completed), throwsFormatException);
  });

  test('resets stale undo state and keeps exact retention boundary', () async {
    final now = DateTime.utc(2026, 9, 13);
    final store = RuntimeLogStore(directories, now: () => now);
    await store.initialize();
    final deleted = await store.beginRun();
    await store.finalize();
    await store.deleteRun(deleted);
    await store.initialize();
    await store.undoLastDeletion();
    expect(await store.listRuns(), isEmpty);

    final boundary = await store.beginRun();
    await store.finalize(end: now.subtract(const Duration(days: 7)));
    final expired = await store.beginRun();
    await store.finalize(
      end: now.subtract(const Duration(days: 7, seconds: 1)),
    );
    await store.pruneExpired();
    expect((await store.listRuns()).map((run) => run.id), contains(boundary));
    expect(
      (await store.listRuns()).map((run) => run.id),
      isNot(contains(expired)),
    );
  });
}

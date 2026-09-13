import 'dart:io';

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
}

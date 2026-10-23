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

  Future<String> completedRun(RuntimeLogStore store, String message) async {
    final id = await store.beginRun();
    await store.append(
      RuntimeLog(
        timestamp: DateTime.utc(2026, 9, 13),
        source: RuntimeLogSource.stdout,
        message: message,
      ),
    );
    await store.finalize();
    return id;
  }

  Future<Directory> deletionBatch() async {
    final trash = Directory.fromUri(directories.logs.uri.resolve('trash/'));
    final batches = <Directory>[];
    await for (final entry in trash.list()) {
      if (entry is Directory &&
          await File.fromUri(entry.uri.resolve('operation.json')).exists()) {
        batches.add(entry);
      }
    }
    expect(batches, hasLength(1));
    return batches.single;
  }

  Future<void> arrangeInterruptedState(Directory batch, String state) async {
    // Production created this record and its moved run directories; changing
    // the phase models interruption between real filesystem moves.
    final marker = File.fromUri(batch.uri.resolve('operation.json'));
    final operation = jsonDecode(await marker.readAsString()) as Map;
    operation['state'] = state;
    await marker.writeAsString(jsonEncode(operation), flush: true);
  }

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
    expect(runs.single.integrity, RuntimeLogIntegrity.complete);
    final actual = await store.readRun(start);
    expect(actual.map((entry) => entry.message), ['one', 'two', 'three']);
    expect(
      (await store.readRun(start, reverse: true)).map((entry) => entry.message),
      ['three', 'two', 'one'],
    );
    expect(
      await store
          .readRunStream(start, reverse: true)
          .map((entry) => entry.message)
          .toList(),
      ['three', 'two', 'one'],
    );
  });

  test(
    'keeps incomplete runs readable and preserves status through undo',
    () async {
      final store = RuntimeLogStore(directories);
      await store.initialize();
      final id = await store.beginRun();
      await store.append(
        RuntimeLog(
          timestamp: DateTime.utc(2026, 9, 13),
          source: RuntimeLogSource.stdout,
          message: 'durable prefix',
        ),
      );
      await store.finalize(integrity: RuntimeLogIntegrity.incomplete);

      final run = (await store.listRuns()).single;
      expect(run.id, id);
      expect(run.integrity, RuntimeLogIntegrity.incomplete);
      expect((await store.readRun(id)).single.message, 'durable prefix');

      await store.deleteRun(id);
      await store.undoLastDeletion();
      expect(
        (await store.listRuns()).single.integrity,
        RuntimeLogIntegrity.incomplete,
      );
      expect((await store.readRun(id)).single.message, 'durable prefix');
    },
  );

  test(
    'keeps legacy run metadata unverified and rejects invalid statuses',
    () async {
      final store = RuntimeLogStore(directories);
      await store.initialize();
      final id = await completedRun(store, 'legacy data');
      final metadataFile = File.fromUri(
        directories.logs.uri.resolve('runs/$id/meta.json'),
      );
      final metadata =
          jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
      metadata.remove('integrity');
      await metadataFile.writeAsString(jsonEncode(metadata), flush: true);

      final legacy = (await store.listRuns()).single;
      expect(legacy.integrity, RuntimeLogIntegrity.unknown);
      expect((await store.readRun(id)).single.message, 'legacy data');

      for (final invalidStatus in [7, 'not-a-status']) {
        metadata['integrity'] = invalidStatus;
        await metadataFile.writeAsString(jsonEncode(metadata), flush: true);
        await expectLater(store.listRuns(), throwsFormatException);
      }
    },
  );

  test(
    'retries startup recovery while preserving incomplete metadata',
    () async {
      final now = DateTime.utc(2026, 10, 16);
      final writer = RuntimeLogStore(directories, now: () => now);
      await writer.initialize();
      final id = await writer.beginRun();
      await writer.append(
        RuntimeLog(
          timestamp: now,
          source: RuntimeLogSource.stdout,
          message: 'recoverable prefix',
        ),
      );
      final metadataFile = File.fromUri(
        directories.logs.uri.resolve('runs/$id/meta.json'),
      );
      final metadata =
          jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
      metadata['integrity'] = 'invalid-status';
      await metadataFile.writeAsString(jsonEncode(metadata), flush: true);

      final recoveredStore = RuntimeLogStore(directories, now: () => now);
      await expectLater(recoveredStore.initialize(), throwsFormatException);
      metadata['integrity'] = 'incomplete';
      await metadataFile.writeAsString(jsonEncode(metadata), flush: true);

      await recoveredStore.initialize();
      expect(
        (await recoveredStore.listRuns()).single.integrity,
        RuntimeLogIntegrity.incomplete,
      );
      expect(
        (await recoveredStore.readRun(id)).single.message,
        'recoverable prefix',
      );
    },
  );

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

  test(
    'uses UTF-8 bytes for segment rollover and prunes legacy logs',
    () async {
      // Character counting fits these records; UTF-8 byte counting rolls over.
      final store = RuntimeLogStore(directories, segmentBytes: 165);
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
          message: '第二条日志',
        ),
      );
      await store.finalize();
      expect(
        await store.readRunStream(id).map((entry) => entry.message).toList(),
        ['中文日志', '第二条日志'],
      );
      final segments = await Directory.fromUri(
        directories.logs.uri.resolve('runs/$id/'),
      ).list().where((entry) => entry.path.endsWith('.jsonl')).toList();
      expect(segments, hasLength(2));

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

  test('recovers a partial deletion before startup cleanup', () async {
    final now = DateTime.utc(2026, 9, 13);
    final store = RuntimeLogStore(directories, now: () => now);
    await store.initialize();
    final expected = <String, String>{
      await completedRun(store, 'first'): 'first',
      await completedRun(store, 'second'): 'second',
    };
    await store.clearHistory();

    final batch = await deletionBatch();
    await arrangeInterruptedState(batch, 'deleting');
    final ids = expected.keys.toList()..sort();
    final staged = Directory.fromUri(batch.uri.resolve('${ids.last}/'));
    final runDirectory = Directory.fromUri(
      directories.logs.uri.resolve('runs/${ids.first}/'),
    );
    await Directory.fromUri(batch.uri.resolve('${ids.first}/'))
        .rename(runDirectory.path);
    final conflict = Directory.fromUri(
      directories.logs.uri.resolve('runs/${ids.last}/'),
    );
    await conflict.create();
    final externalFile = File.fromUri(conflict.uri.resolve('external-data'));
    await externalFile.writeAsString('keep this conflicting data');

    final restarted = RuntimeLogStore(directories, now: () => now);
    await expectLater(restarted.initialize(), throwsStateError);
    expect(await staged.exists(), isTrue);
    expect(await externalFile.readAsString(), 'keep this conflicting data');
    expect(
      await File.fromUri(batch.uri.resolve('operation.json')).exists(),
      isTrue,
    );

    await conflict.delete(recursive: true);
    await restarted.initialize();
    await restarted.initialize();
    expect(
      (await restarted.listRuns()).map((run) => run.id).toSet(),
      expected.keys.toSet(),
    );
    for (final entry in expected.entries) {
      expect((await restarted.readRun(entry.key)).map((log) => log.message), [
        entry.value,
      ]);
    }
  });

  test('recovers an interrupted undo into readable history', () async {
    final now = DateTime.utc(2026, 9, 13);
    final store = RuntimeLogStore(directories, now: () => now);
    await store.initialize();
    final expected = <String, String>{
      await completedRun(store, 'first'): 'first',
      await completedRun(store, 'second'): 'second',
    };
    await store.clearHistory();

    final batch = await deletionBatch();
    await arrangeInterruptedState(batch, 'undoing');
    final id = expected.keys.first;
    await Directory.fromUri(
      batch.uri.resolve('$id/'),
    ).rename(Directory.fromUri(directories.logs.uri.resolve('runs/$id/')).path);

    final restarted = RuntimeLogStore(directories, now: () => now);
    await restarted.initialize();
    expect(
      (await restarted.listRuns()).map((run) => run.id).toSet(),
      expected.keys.toSet(),
    );
    for (final entry in expected.entries) {
      expect((await restarted.readRun(entry.key)).map((log) => log.message), [
        entry.value,
      ]);
    }
  });

  test('a later deletion preserves an interrupted undo batch', () async {
    final now = DateTime.utc(2026, 9, 13);
    final store = RuntimeLogStore(directories, now: () => now);
    await store.initialize();
    final expected = <String, String>{
      await completedRun(store, 'first'): 'first',
      await completedRun(store, 'second'): 'second',
    };
    await store.clearHistory();

    final batch = await deletionBatch();
    await arrangeInterruptedState(batch, 'undoing');
    final restoredId = expected.keys.first;
    await Directory.fromUri(batch.uri.resolve('$restoredId/')).rename(
      Directory.fromUri(directories.logs.uri.resolve('runs/$restoredId/')).path,
    );
    final nextId = await completedRun(store, 'next deletion');

    await store.deleteRun(nextId);
    for (final entry in expected.entries) {
      expect((await store.readRun(entry.key)).single.message, entry.value);
    }
    await store.undoLastDeletion();
    expect((await store.readRun(nextId)).single.message, 'next deletion');
  });

  test(
    'a committed deletion survives obsolete undo cleanup failure',
    () async {
      final now = DateTime.utc(2026, 9, 13);
      final store = RuntimeLogStore(directories, now: () => now);
      await store.initialize();
      final obsoleteUndoId = await completedRun(store, 'older deletion');
      final deletedId = await completedRun(store, 'current deletion');
      final retainedId = await completedRun(store, 'retained history');
      await store.deleteRun(obsoleteUndoId);
      final obsoleteBatch = await deletionBatch();

      final restricted = await Process.run('chmod', [
        '500',
        obsoleteBatch.path,
      ]);
      expect(restricted.exitCode, 0, reason: '${restricted.stderr}');
      try {
        await store.deleteRun(deletedId);
      } finally {
        final restored = await Process.run('chmod', [
          '700',
          obsoleteBatch.path,
        ]);
        expect(restored.exitCode, 0, reason: '${restored.stderr}');
      }

      expect(await obsoleteBatch.exists(), isTrue);
      expect(await store.listRuns(), hasLength(1));
      expect((await store.listRuns()).single.id, retainedId);
      await store.undoLastDeletion();
      expect(
        (await store.readRun(deletedId)).single.message,
        'current deletion',
      );
      expect(
        (await store.readRun(retainedId)).single.message,
        'retained history',
      );

      final purgedId = await completedRun(store, 'completed deletion');
      await store.deleteRun(purgedId);
      final restarted = RuntimeLogStore(directories, now: () => now);
      await restarted.initialize();
      await restarted.undoLastDeletion();
      await expectLater(restarted.readRun(purgedId), throwsStateError);
      expect(
        (await restarted.readRun(retainedId)).single.message,
        'retained history',
      );
    },
    skip: Platform.isWindows
        ? 'Directory permissions differ on Windows'
        : false,
  );

  test(
    'a failed later deletion keeps the previous undo readable',
    () async {
      final now = DateTime.utc(2026, 9, 13);
      final store = RuntimeLogStore(directories, now: () => now);
      await store.initialize();
      final deletedId = await completedRun(store, 'undo me');
      final retainedId = await completedRun(store, 'keep me');
      await store.deleteRun(deletedId);

      final trash = Directory.fromUri(directories.logs.uri.resolve('trash/'));
      final restricted = await Process.run('chmod', ['500', trash.path]);
      expect(restricted.exitCode, 0, reason: '${restricted.stderr}');
      try {
        await expectLater(
          store.deleteRun(retainedId),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        final restored = await Process.run('chmod', ['700', trash.path]);
        expect(restored.exitCode, 0, reason: '${restored.stderr}');
      }

      await store.undoLastDeletion();
      expect((await store.readRun(deletedId)).map((log) => log.message), [
        'undo me',
      ]);
      expect((await store.readRun(retainedId)).map((log) => log.message), [
        'keep me',
      ]);
    },
    skip: Platform.isWindows
        ? 'Directory permissions differ on Windows'
        : false,
  );

  test('reconciles an orphan run with its durable event count', () async {
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
    final metadataFile = File.fromUri(
      directories.logs.uri.resolve('runs/$id/meta.json'),
    );
    final metadata =
        jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
    metadata.remove('integrity');
    await metadataFile.writeAsString(jsonEncode(metadata), flush: true);

    final restarted = RuntimeLogStore(directories, now: () => now);
    await restarted.initialize();
    final recovered = (await restarted.listRuns()).single;
    expect(recovered.id, id);
    expect(recovered.eventCount, 1);
    expect(recovered.integrity, RuntimeLogIntegrity.recovered);
    expect((await restarted.readRun(id)).single.message, 'durable');

    final nextId = await restarted.beginRun();
    await restarted.append(
      RuntimeLog(
        timestamp: DateTime.utc(2026, 9, 13, 0, 1),
        source: RuntimeLogSource.stdout,
        message: 'next run',
      ),
    );
    await restarted.finalize();
    final runs = await restarted.listRuns();
    expect(
      runs.singleWhere((run) => run.id == id).integrity,
      RuntimeLogIntegrity.recovered,
    );
    expect(
      runs.singleWhere((run) => run.id == nextId).integrity,
      RuntimeLogIntegrity.complete,
    );
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

  test('repairs only a physically truncated orphan tail on disk', () async {
    final now = DateTime.utc(2026, 9, 13);
    Future<({Directory directory, String validSegment})> orphan(
      List<int> tail,
    ) async {
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
      final file = File.fromUri(
        directories.logs.uri.resolve('runs/$id/000000.jsonl'),
      );
      final validSegment = await file.readAsString();
      await file.writeAsBytes([...await file.readAsBytes(), ...tail]);
      return (
        directory: Directory.fromUri(directories.logs.uri.resolve('runs/$id/')),
        validSegment: validSegment,
      );
    }

    final truncated = await orphan(
      utf8.encode('{"timestamp":"2026-09-13T00:00:00'),
    );
    final recovered = RuntimeLogStore(directories, now: () => now);
    await recovered.initialize();
    final run = (await recovered.listRuns()).single;
    expect(run.eventCount, 1);
    final segment = File.fromUri(
      truncated.directory.uri.resolve('000000.jsonl'),
    );
    expect(await segment.readAsString(), truncated.validSegment);
    expect((await recovered.readRun(run.id)).map((entry) => entry.message), [
      'durable',
    ]);
    expect(
      await recovered
          .readRunStream(run.id)
          .map((entry) => entry.message)
          .toList(),
      ['durable'],
    );
    await recovered.deleteRun(run.id);
    await recovered.initialize();

    final utf8Truncated = await orphan([
      ...utf8.encode(
        '{"timestamp":"2026-09-13T00:00:00.000Z","source":"stdout",'
        '"message":"truncated ',
      ),
      0xe4,
    ]);
    final utf8Recovered = RuntimeLogStore(directories, now: () => now);
    final utf8Segment = File.fromUri(
      utf8Truncated.directory.uri.resolve('000000.jsonl'),
    );
    final bytesBeforeRepair = await utf8Segment.readAsBytes();
    if (!Platform.isWindows) {
      final restricted = await Process.run('chmod', ['400', utf8Segment.path]);
      expect(restricted.exitCode, 0, reason: '${restricted.stderr}');
      try {
        await expectLater(
          utf8Recovered.initialize(),
          throwsA(isA<FileSystemException>()),
        );
        expect(await utf8Segment.readAsBytes(), bytesBeforeRepair);
      } finally {
        final restored = await Process.run('chmod', ['600', utf8Segment.path]);
        expect(restored.exitCode, 0, reason: '${restored.stderr}');
      }
    }
    await utf8Recovered.initialize();
    final utf8Run = (await utf8Recovered.listRuns()).single;
    expect(await utf8Segment.readAsString(), utf8Truncated.validSegment);
    expect(
      await utf8Recovered
          .readRunStream(utf8Run.id)
          .map((entry) => entry.message)
          .toList(),
      ['durable'],
    );

    final invalidUtf8 = await orphan([0xff, 0xe4]);
    final invalidSegment = File.fromUri(
      invalidUtf8.directory.uri.resolve('000000.jsonl'),
    );
    expect(await invalidSegment.readAsBytes(), [
      ...utf8.encode(invalidUtf8.validSegment),
      0xff,
      0xe4,
    ]);
    final invalidId = invalidUtf8.directory.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .last;
    final invalidStore = RuntimeLogStore(directories, now: () => now);
    expect(
      (await invalidStore.listRuns()).map((run) => run.id),
      isNot(contains(invalidId)),
    );
    await expectLater(invalidStore.initialize(), throwsFormatException);
    await invalidUtf8.directory.delete(recursive: true);

    await orphan(
      utf8.encode(
        jsonEncode({
          'timestamp': 'not-a-date',
          'source': 'stdout',
          'message': 'corrupt',
        }),
      ),
    );
    await expectLater(
      RuntimeLogStore(directories, now: () => now).initialize(),
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
    await expectLater(
      RuntimeLogStore(directories).initialize(),
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
    await expectLater(store.readRun(completed), throwsFormatException);
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

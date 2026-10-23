import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'backend_runtime.dart';
import 'runtime_directories.dart';
import 'runtime_permissions.dart';

class RuntimeLogRun {
  const RuntimeLogRun({
    required this.id,
    required this.start,
    required this.end,
    required this.eventCount,
    this.integrity = RuntimeLogIntegrity.unknown,
  });

  final String id;
  final DateTime start;
  final DateTime? end;
  final int eventCount;
  final RuntimeLogIntegrity integrity;
}

class RuntimeLogStore {
  RuntimeLogStore(
    RuntimeDirectories directories, {
    DateTime Function()? now,
    this.segmentBytes = 10 * 1024 * 1024,
  }) : _logs = directories.logs,
       _now = now ?? DateTime.now;

  final Directory _logs;
  final DateTime Function() _now;
  final int segmentBytes;
  Future<void> _operation = Future<void>.value();
  String? _activeId;
  String? _lastTrash;

  Directory get _runs => Directory.fromUri(_logs.uri.resolve('runs/'));
  Directory get _trash => Directory.fromUri(_logs.uri.resolve('trash/'));

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _operation.then((_) => action());
    _operation = result.then<void>((_) {}, onError: (error, stack) {});
    return result;
  }

  Future<void> initialize() => _serial(() async {
    await _runs.create(recursive: true);
    await _trash.create(recursive: true);
    await restrictDirectoryToCurrentUser(_runs);
    await restrictDirectoryToCurrentUser(_trash);
    await _recoverInterruptedBatches();
    for (final entry in await _trash.list().toList()) {
      await entry.delete(recursive: true);
    }
    _lastTrash = null;
    final cutoff = _now().subtract(const Duration(days: 7));
    for (final entry in await _runs.list().toList()) {
      if (entry is! Directory || !_safeId(_id(entry))) continue;
      final meta = await _readMeta(entry);
      if (meta == null) continue;
      if (meta.end == null) {
        final scan = await _scanEvents(entry);
        final end = scan.last ?? meta.start;
        final integrity = meta.integrity == RuntimeLogIntegrity.incomplete
            ? RuntimeLogIntegrity.incomplete
            : RuntimeLogIntegrity.recovered;
        await _writeMeta(
          entry,
          _Meta(meta.id, meta.start, end, scan.count, integrity: integrity),
        );
      }
      final refreshed = await _readMeta(entry);
      if (refreshed != null && refreshed.end!.isBefore(cutoff)) {
        await entry.delete(recursive: true);
      }
    }
    for (final entry in await _logs.list().toList()) {
      if (entry is File &&
          RegExp(r'^backend\.log(?:\.\d+)?$').hasMatch(_id(entry)) &&
          (await entry.stat()).modified.isBefore(cutoff)) {
        await entry.delete();
      }
    }
  });

  Future<String> beginRun() => _serial(() async {
    if (_activeId != null) throw StateError('A log run is already active');
    final id = '${_now().toUtc().microsecondsSinceEpoch}-${_randomPart()}';
    final directory = _runDirectory(id);
    await directory.create(recursive: true);
    await restrictDirectoryToCurrentUser(directory);
    await _writeMeta(
      directory,
      _Meta(
        id,
        _now().toUtc(),
        null,
        0,
        integrity: RuntimeLogIntegrity.incomplete,
      ),
    );
    _activeId = id;
    return id;
  });

  Future<void> append(RuntimeLog log) => _serial(() async {
    final id = _activeId;
    if (id == null) throw StateError('No active log run');
    final directory = _runDirectory(id);
    final line = '${jsonEncode(_eventJson(log))}\n';
    final segment = await _segmentForAppend(
      directory,
      utf8.encode(line).length,
    );
    final file = File.fromUri(segment.uri);
    await file.writeAsString(line, mode: FileMode.append, flush: true);
    await restrictFileToCurrentUser(file);
    final meta = await _readMeta(directory);
    if (meta != null) {
      await _writeMeta(
        directory,
        _Meta(id, meta.start, null, meta.count + 1, integrity: meta.integrity),
      );
    }
  });

  Future<void> finalize({
    DateTime? end,
    RuntimeLogIntegrity integrity = RuntimeLogIntegrity.complete,
  }) => _serial(() async {
    final id = _activeId;
    if (id == null) throw StateError('No active log run');
    final directory = _runDirectory(id);
    final meta = await _readMeta(directory);
    if (meta == null) throw StateError('Unknown active log run');
    final count = integrity == RuntimeLogIntegrity.incomplete
        ? (await _scanEvents(directory)).count
        : meta.count;
    await _writeMeta(
      directory,
      _Meta(
        id,
        meta.start,
        (end ?? _now()).toUtc(),
        count,
        integrity: integrity,
      ),
    );
    _activeId = null;
  });

  Future<List<RuntimeLogRun>> listRuns() => _serial(() async {
    final result = <RuntimeLogRun>[];
    for (final entry in await _runs.list().toList()) {
      if (entry is Directory) {
        final meta = await _readMeta(entry);
        if (meta?.end != null) result.add(meta!.summary);
      }
    }
    result.sort((a, b) => b.start.compareTo(a.start));
    return result;
  });

  Future<List<RuntimeLog>> readRun(String id, {bool reverse = false}) =>
      _serial(() async {
        _requireSafeId(id);
        return readRunStream(id, reverse: reverse).toList();
      });

  Stream<RuntimeLog> readRunStream(String id, {bool reverse = false}) async* {
    _requireSafeId(id);
    final directory = _runDirectory(id);
    if (!await directory.exists()) {
      throw StateError('Unknown log run: $id');
    }
    final meta = await _readMeta(directory);
    if (meta?.end == null) {
      throw StateError('Log run is not finalized: $id');
    }
    var files =
        (await directory.list().toList())
            .whereType<File>()
            .where((file) => _id(file).endsWith('.jsonl'))
            .toList()
          ..sort((a, b) => _id(a).compareTo(_id(b)));
    if (reverse) {
      files = files.reversed.toList();
    }
    for (final file in files) {
      final events = await _readSegment(file);
      for (final event in reverse ? events.reversed : events) {
        yield event;
      }
    }
  }

  Future<void> deleteRun(String id) => _serial(() async {
    _requireSafeId(id);
    await _recoverInterruptedBatches();
    final source = _runDirectory(id);
    if (!await source.exists()) {
      return;
    }
    if (_activeId == id) {
      throw StateError('Cannot delete the active log run');
    }
    final meta = await _readMeta(source);
    if (meta?.end == null) {
      throw StateError('Cannot delete an unfinished log run');
    }
    await _deleteRuns([source]);
  });

  Future<void> clearHistory() => _serial(() async {
    await _recoverInterruptedBatches();
    final completed = <Directory>[];
    for (final entry in await _runs.list().toList()) {
      if (entry is Directory && (await _readMeta(entry))?.end != null) {
        completed.add(entry);
      }
    }
    await _deleteRuns(completed);
  });

  Future<void> undoLastDeletion() => _serial(() async {
    await _recoverInterruptedBatches();
    final path = _lastTrash;
    if (path == null) return;
    final batch = Directory(path);
    if (!await batch.exists()) {
      _lastTrash = null;
      return;
    }
    final operation = await _readOperation(batch);
    if (operation == null || operation.state == _BatchState.deleting) {
      throw StateError('The deletion batch cannot be undone');
    }
    if (operation.state == _BatchState.complete) {
      await _validateRestoration(batch, operation);
      await _writeOperation(
        batch,
        _BatchOperation(_BatchState.undoing, operation.ids),
      );
    }
    await _restoreBatch(batch, operation);
    _lastTrash = null;
  });

  Future<void> pruneExpired() => _serial(() async {
    final cutoff = _now().subtract(const Duration(days: 7));
    for (final entry in await _runs.list().toList()) {
      if (entry is Directory) {
        final meta = await _readMeta(entry);
        if (meta?.end != null && meta!.end!.isBefore(cutoff)) {
          await entry.delete(recursive: true);
        }
      }
    }
    await _pruneLegacy(cutoff);
  });

  Directory _runDirectory(String id) =>
      Directory.fromUri(_runs.uri.resolve('$id/'));

  Directory _batchRunDirectory(Directory batch, String id) =>
      Directory.fromUri(batch.uri.resolve('$id/'));

  Future<void> _deleteRuns(List<Directory> runs) async {
    if (runs.isEmpty) return;
    final ids = runs.map(_id).toList()..sort();
    if (ids.any((id) => !_safeId(id)) || ids.toSet().length != ids.length) {
      throw StateError('Invalid log run identity');
    }
    for (final id in ids) {
      if (_activeId == id) {
        throw StateError('Cannot delete the active log run');
      }
      final meta = await _readMeta(_runDirectory(id));
      if (meta?.end == null) {
        throw StateError('Cannot delete an unfinished log run');
      }
    }

    final batch = await _createBatchDirectory();
    final operation = _BatchOperation(_BatchState.deleting, ids);
    await _writeOperation(batch, operation);
    for (final id in ids) {
      await _runDirectory(id).rename(_batchRunDirectory(batch, id).path);
    }
    await _writeOperation(batch, _BatchOperation(_BatchState.complete, ids));

    final previous = _lastTrash;
    _lastTrash = batch.path;
    if (previous != null && previous != batch.path) {
      try {
        final previousBatch = Directory(previous);
        if (await previousBatch.exists() &&
            (await _readOperation(previousBatch))?.state ==
                _BatchState.complete) {
          await previousBatch.delete(recursive: true);
        }
      } on FileSystemException {
        // The new deletion is committed; startup cleanup can remove leftovers.
      } on FormatException {
        // Preserve a batch whose completion record cannot be validated.
      }
    }
  }

  Future<Directory> _createBatchDirectory() async {
    final batch = await _trash.createTemp('batch-');
    await restrictDirectoryToCurrentUser(batch);
    return batch;
  }

  Future<void> _recoverInterruptedBatches() async {
    for (final entry in await _trash.list().toList()) {
      if (entry is! Directory) continue;
      final record = File.fromUri(entry.uri.resolve('operation.json'));
      if (!await record.exists()) continue;
      final operation = await _readOperation(entry);
      if (operation == null) {
        throw FormatException('Invalid log deletion operation');
      }
      if (operation.state != _BatchState.complete) {
        await _restoreBatch(entry, operation);
      }
    }
  }

  Future<_BatchOperation?> _readOperation(Directory batch) async {
    final file = File.fromUri(batch.uri.resolve('operation.json'));
    if (!await file.exists()) return null;
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic> ||
        value['schema'] != 1 ||
        value['state'] is! String ||
        value['runs'] is! List) {
      throw FormatException('Invalid log deletion operation');
    }
    final state = switch (value['state']) {
      'deleting' => _BatchState.deleting,
      'undoing' => _BatchState.undoing,
      'complete' => _BatchState.complete,
      _ => throw FormatException('Invalid log deletion operation state'),
    };
    final rawIds = value['runs'] as List;
    if (rawIds.isEmpty || rawIds.any((id) => id is! String)) {
      throw FormatException('Invalid log deletion run identities');
    }
    final ids = rawIds.cast<String>();
    if (ids.any((id) => !_safeId(id)) || ids.toSet().length != ids.length) {
      throw FormatException('Invalid log deletion run identities');
    }
    return _BatchOperation(state, ids);
  }

  Future<void> _writeOperation(
    Directory batch,
    _BatchOperation operation,
  ) async {
    final temporary = File.fromUri(batch.uri.resolve('operation.json.tmp'));
    await temporary.writeAsString(
      jsonEncode({
        'schema': 1,
        'state': operation.state.name,
        'runs': operation.ids,
      }),
      flush: true,
    );
    await restrictFileToCurrentUser(temporary);
    await temporary.rename(
      File.fromUri(batch.uri.resolve('operation.json')).path,
    );
  }

  Future<void> _validateRestoration(
    Directory batch,
    _BatchOperation operation,
  ) async {
    final allowedEntries = {
      'operation.json',
      'operation.json.tmp',
      ...operation.ids,
    };
    for (final entry in await batch.list().toList()) {
      if (!allowedEntries.contains(_id(entry))) {
        throw StateError('Unexpected data in a log deletion batch');
      }
    }
    for (final id in operation.ids) {
      final staged = _batchRunDirectory(batch, id);
      final destination = _runDirectory(id);
      final stagedType = await FileSystemEntity.type(
        staged.path,
        followLinks: false,
      );
      final destinationType = await FileSystemEntity.type(
        destination.path,
        followLinks: false,
      );
      if (stagedType != FileSystemEntityType.notFound &&
          stagedType != FileSystemEntityType.directory) {
        throw StateError('Conflicting data in a log deletion batch');
      }
      if (destinationType != FileSystemEntityType.notFound &&
          destinationType != FileSystemEntityType.directory) {
        throw StateError('Conflicting log run data');
      }
      if (stagedType == FileSystemEntityType.directory &&
          destinationType == FileSystemEntityType.directory) {
        throw StateError('Conflicting log run data');
      }
      if (stagedType == FileSystemEntityType.notFound &&
          destinationType == FileSystemEntityType.notFound) {
        throw StateError('Missing log run data');
      }
    }
  }

  Future<void> _restoreBatch(Directory batch, _BatchOperation operation) async {
    await _validateRestoration(batch, operation);
    for (final id in operation.ids) {
      final staged = _batchRunDirectory(batch, id);
      if (await staged.exists()) {
        await staged.rename(_runDirectory(id).path);
      }
    }
    await batch.delete(recursive: true);
  }

  Future<File> _segmentForAppend(Directory directory, int lineBytes) async {
    final segments =
        (await directory.list().toList())
            .whereType<File>()
            .where((file) => RegExp(r'^\d{6}\.jsonl$').hasMatch(_id(file)))
            .toList()
          ..sort((a, b) => _id(a).compareTo(_id(b)));
    if (segments.isEmpty ||
        (await segments.last.length()) > 0 &&
            await segments.last.length() + lineBytes > segmentBytes) {
      final name = '${segments.length.toString().padLeft(6, '0')}.jsonl';
      final file = File.fromUri(directory.uri.resolve(name));
      await file.create();
      await restrictFileToCurrentUser(file);
      return file;
    }
    return segments.last;
  }

  Future<_EventScan> _scanEvents(Directory directory) async {
    var count = 0;
    DateTime? last;
    final files =
        (await directory.list().toList())
            .whereType<File>()
            .where((file) => _id(file).endsWith('.jsonl'))
            .toList()
          ..sort((a, b) => _id(a).compareTo(_id(b)));
    for (final file in files) {
      for (final event in await _readSegment(
        file,
        allowTrailingTruncation: file == files.last,
      )) {
        count++;
        last = event.timestamp;
      }
    }
    return _EventScan(count, last);
  }

  Future<void> _pruneLegacy(DateTime cutoff) async {
    for (final entry in await _logs.list().toList()) {
      if (entry is File &&
          RegExp(r'^backend\.log(?:\.\d+)?$').hasMatch(_id(entry)) &&
          (await entry.stat()).modified.isBefore(cutoff)) {
        await entry.delete();
      }
    }
  }

  Future<List<RuntimeLog>> _readSegment(
    File file, {
    bool allowTrailingTruncation = false,
  }) async {
    final bytes = await file.readAsBytes();
    if (!allowTrailingTruncation || bytes.isEmpty || bytes.last == 0x0a) {
      return _eventsFromText(utf8.decode(bytes));
    }

    final lastNewline = bytes.lastIndexOf(0x0a);
    final completeBytes = bytes.sublist(0, lastNewline + 1);
    final tailBytes = bytes.sublist(lastNewline + 1);
    final completeEvents = _eventsFromText(utf8.decode(completeBytes));
    if (!_isValidUtf8Prefix(tailBytes, tailBytes.length) &&
        !_hasIncompleteUtf8Suffix(tailBytes)) {
      throw FormatException('Invalid UTF-8 in log event');
    }
    String tail;
    try {
      tail = utf8.decode(tailBytes);
    } on FormatException {
      if (!_hasIncompleteUtf8Suffix(tailBytes)) rethrow;
      await _truncateSegment(file, completeBytes.length);
      return completeEvents;
    }

    try {
      return [...completeEvents, _eventFromLine(tail)];
    } on FormatException catch (error) {
      if (!_isIncompleteJson(tail, error)) {
        Error.throwWithStackTrace(error, StackTrace.current);
      }
      await _truncateSegment(file, completeBytes.length);
      return completeEvents;
    }
  }

  Future<void> _truncateSegment(File file, int length) async {
    final segment = await file.open(mode: FileMode.append);
    try {
      await segment.truncate(length);
      await segment.flush();
    } finally {
      await segment.close();
    }
  }

  static List<RuntimeLog> _eventsFromText(String text) {
    final lines = text.split('\n');
    if (text.endsWith('\n')) lines.removeLast();
    return [
      for (final line in lines)
        if (line.trim().isNotEmpty) _eventFromLine(line),
    ];
  }

  static RuntimeLog _eventFromLine(String line) {
    final value = jsonDecode(line);
    if (value is! Map<String, dynamic>) {
      throw FormatException('Invalid log event');
    }
    return _eventFromJson(value);
  }

  static bool _isIncompleteJson(String line, FormatException error) {
    if (line.trim().isEmpty) return false;
    final message = error.message.toString();
    return message.contains('Unexpected end of input') ||
        message.contains('Unterminated string');
  }

  static bool _hasIncompleteUtf8Suffix(List<int> bytes) {
    if (bytes.isEmpty) return false;
    var start = bytes.length - 1;
    while (start >= 0 && (bytes[start] & 0xc0) == 0x80) {
      start--;
    }
    if (start < 0 || !_isValidUtf8Prefix(bytes, start)) return false;
    final first = bytes[start];
    final length = _utf8SequenceLength(first);
    final available = bytes.length - start;
    if (length == 0 || available >= length) return false;
    return _hasValidUtf8Continuations(bytes, start, bytes.length, first);
  }

  static bool _isValidUtf8Prefix(List<int> bytes, int end) {
    var index = 0;
    while (index < end) {
      final first = bytes[index];
      if (first <= 0x7f) {
        index++;
        continue;
      }
      final length = _utf8SequenceLength(first);
      if (length == 0 || index + length > end) return false;
      if (!_hasValidUtf8Continuations(bytes, index, index + length, first)) {
        return false;
      }
      index += length;
    }
    return true;
  }

  static int _utf8SequenceLength(int first) => switch (first) {
    >= 0xc2 && <= 0xdf => 2,
    >= 0xe0 && <= 0xef => 3,
    >= 0xf0 && <= 0xf4 => 4,
    _ => 0,
  };

  static bool _hasValidUtf8Continuations(
    List<int> bytes,
    int start,
    int end,
    int first,
  ) {
    for (var index = start + 1; index < end; index++) {
      if ((bytes[index] & 0xc0) != 0x80) return false;
      if (index == start + 1 &&
          (first == 0xe0 && bytes[index] < 0xa0 ||
              first == 0xed && bytes[index] > 0x9f ||
              first == 0xf0 && bytes[index] < 0x90 ||
              first == 0xf4 && bytes[index] > 0x8f)) {
        return false;
      }
    }
    return true;
  }

  static RuntimeLog _eventFromJson(Map<String, dynamic> json) {
    return RuntimeLog(
      timestamp: DateTime.parse(json['timestamp'] as String),
      source: RuntimeLogSource.values.byName(json['source'] as String),
      message: json['message'] as String,
    );
  }

  Future<_Meta?> _readMeta(Directory directory) async {
    final file = File.fromUri(directory.uri.resolve('meta.json'));
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (json['schema'] != 1 || json['id'] != _id(directory)) {
      throw FormatException('Invalid log metadata');
    }
    final rawIntegrity = json['integrity'];
    final integrity = rawIntegrity == null && !json.containsKey('integrity')
        ? RuntimeLogIntegrity.unknown
        : RuntimeLogIntegrity.values.firstWhere(
            (value) => value.name == rawIntegrity,
            orElse: () =>
                throw const FormatException('Invalid log run integrity status'),
          );
    return _Meta(
      json['id'] as String,
      DateTime.parse(json['start'] as String),
      json['end'] == null ? null : DateTime.parse(json['end'] as String),
      json['count'] as int,
      integrity: integrity,
    );
  }

  Future<void> _writeMeta(Directory directory, _Meta meta) async {
    final temporary = File.fromUri(directory.uri.resolve('meta.json.tmp'));
    await temporary.writeAsString(
      jsonEncode({
        'schema': 1,
        'id': meta.id,
        'start': meta.start.toIso8601String(),
        'end': meta.end?.toIso8601String(),
        'count': meta.count,
        if (meta.integrity != RuntimeLogIntegrity.unknown)
          'integrity': meta.integrity.name,
      }),
      flush: true,
    );
    await restrictFileToCurrentUser(temporary);
    await temporary.rename(
      File.fromUri(directory.uri.resolve('meta.json')).path,
    );
    await restrictFileToCurrentUser(
      File.fromUri(directory.uri.resolve('meta.json')),
    );
  }

  static Map<String, String> _eventJson(RuntimeLog log) => {
    'timestamp': log.timestamp.toUtc().toIso8601String(),
    'source': log.source.name,
    'message': log.message,
  };

  static String _id(FileSystemEntity entity) =>
      entity.uri.pathSegments.where((part) => part.isNotEmpty).last;
  static bool _safeId(String id) => RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id);
  static void _requireSafeId(String id) {
    if (!_safeId(id)) throw ArgumentError.value(id, 'id');
  }

  static String _randomPart() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
}

class _Meta {
  const _Meta(
    this.id,
    this.start,
    this.end,
    this.count, {
    this.integrity = RuntimeLogIntegrity.unknown,
  });
  final String id;
  final DateTime start;
  final DateTime? end;
  final int count;
  final RuntimeLogIntegrity integrity;
  RuntimeLogRun get summary => RuntimeLogRun(
    id: id,
    start: start,
    end: end,
    eventCount: count,
    integrity: integrity,
  );
}

class _EventScan {
  const _EventScan(this.count, this.last);
  final int count;
  final DateTime? last;
}

enum _BatchState { deleting, undoing, complete }

class _BatchOperation {
  const _BatchOperation(this.state, this.ids);

  final _BatchState state;
  final List<String> ids;
}

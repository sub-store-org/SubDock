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
  });

  final String id;
  final DateTime start;
  final DateTime? end;
  final int eventCount;
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
        await _writeMeta(entry, _Meta(meta.id, meta.start, end, scan.count));
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
    await _writeMeta(directory, _Meta(id, _now().toUtc(), null, 0));
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
      await _writeMeta(directory, _Meta(id, meta.start, null, meta.count + 1));
    }
  });

  Future<void> finalize({DateTime? end}) => _serial(() async {
    final id = _activeId;
    if (id == null) throw StateError('No active log run');
    final directory = _runDirectory(id);
    final meta = await _readMeta(directory);
    if (meta == null) throw StateError('Unknown active log run');
    await _writeMeta(
      directory,
      _Meta(id, meta.start, (end ?? _now()).toUtc(), meta.count),
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
    await _discardTrash();
    final batch = Directory.fromUri(
      _trash.uri.resolve('${_now().microsecondsSinceEpoch}/'),
    );
    await batch.create(recursive: true);
    await restrictDirectoryToCurrentUser(batch);
    await source.rename(Directory.fromUri(batch.uri.resolve('$id/')).path);
    _lastTrash = batch.path;
  });

  Future<void> clearHistory() => _serial(() async {
    final completed = <Directory>[];
    for (final entry in await _runs.list().toList()) {
      if (entry is Directory && (await _readMeta(entry))?.end != null) {
        completed.add(entry);
      }
    }
    if (completed.isEmpty) return;
    await _discardTrash();
    final batch = Directory.fromUri(
      _trash.uri.resolve('${_now().microsecondsSinceEpoch}/'),
    );
    await batch.create(recursive: true);
    await restrictDirectoryToCurrentUser(batch);
    for (final entry in completed) {
      await entry.rename(
        Directory.fromUri(batch.uri.resolve('${_id(entry)}/')).path,
      );
    }
    _lastTrash = batch.path;
  });

  Future<void> undoLastDeletion() => _serial(() async {
    final path = _lastTrash;
    if (path == null) return;
    final batch = Directory(path);
    if (!await batch.exists()) {
      _lastTrash = null;
      return;
    }
    for (final entry in await batch.list().toList()) {
      if (entry is Directory && _safeId(_id(entry))) {
        await entry.rename(_runDirectory(_id(entry)).path);
      }
    }
    await batch.delete(recursive: true);
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
    final result = <RuntimeLog>[];
    final text = utf8.decode(await file.readAsBytes());
    final hasFinalNewline = text.endsWith('\n');
    final lines = text.split('\n');
    if (hasFinalNewline) lines.removeLast();
    for (var index = 0; index < lines.length; index++) {
      if (lines[index].trim().isEmpty) continue;
      try {
        final json = jsonDecode(lines[index]);
        if (json is! Map<String, dynamic>) {
          throw FormatException('Invalid log event');
        }
        result.add(_eventFromJson(json));
      } on FormatException catch (error) {
        if (allowTrailingTruncation &&
            !hasFinalNewline &&
            index == lines.length - 1 &&
            _isJsonSyntaxError(lines[index])) {
          break;
        }
        Error.throwWithStackTrace(error, StackTrace.current);
      }
    }
    return result;
  }

  static RuntimeLog _eventFromJson(Map<String, dynamic> json) {
    return RuntimeLog(
      timestamp: DateTime.parse(json['timestamp'] as String),
      source: RuntimeLogSource.values.byName(json['source'] as String),
      message: json['message'] as String,
    );
  }

  static bool _isJsonSyntaxError(String line) {
    try {
      jsonDecode(line);
      return false;
    } on FormatException {
      return true;
    }
  }

  Future<_Meta?> _readMeta(Directory directory) async {
    final file = File.fromUri(directory.uri.resolve('meta.json'));
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (json['schema'] != 1 || json['id'] != _id(directory)) {
      throw FormatException('Invalid log metadata');
    }
    return _Meta(
      json['id'] as String,
      DateTime.parse(json['start'] as String),
      json['end'] == null ? null : DateTime.parse(json['end'] as String),
      json['count'] as int,
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

  Future<void> _discardTrash() async {
    final path = _lastTrash;
    if (path != null) {
      final directory = Directory(path);
      if (await directory.exists()) await directory.delete(recursive: true);
    }
    _lastTrash = null;
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
  const _Meta(this.id, this.start, this.end, this.count);
  final String id;
  final DateTime start;
  final DateTime? end;
  final int count;
  RuntimeLogRun get summary =>
      RuntimeLogRun(id: id, start: start, end: end, eventCount: count);
}

class _EventScan {
  const _EventScan(this.count, this.last);
  final int count;
  final DateTime? last;
}

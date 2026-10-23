import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../runtime/runtime_directories.dart';
import '../runtime/runtime_permissions.dart';
import 'backend_env.dart';
import 'backend_env_store.dart';
import 'config_error.dart';
import 'subdock_config.dart';
import 'subdock_config_store.dart';

/// The connection configuration and the raw ENV saved as one recoverable pair.
class RuntimeConfiguration {
  const RuntimeConfiguration({
    required this.environment,
    required this.configuration,
  });

  final BackendEnvDocument environment;
  final SubDockConfig configuration;

  @override
  bool operator ==(Object other) =>
      other is RuntimeConfiguration &&
      other.environment.rawText == environment.rawText &&
      other.configuration == configuration;

  @override
  int get hashCode => Object.hash(environment.rawText, configuration);
}

/// Outcome of a paired save.
class RuntimeConfigurationCommit {
  const RuntimeConfigurationCommit({required this.cleanupPending});

  /// True when the commit receipt persisted but clearing the recovery record
  /// failed. The pair is saved; the next load resolves the leftover record.
  final bool cleanupPending;
}

/// Outcome of a recovery-aware read.
class RuntimeConfigurationLoad {
  const RuntimeConfigurationLoad({
    required this.configuration,
    required this.recovered,
  });

  final RuntimeConfiguration configuration;

  /// True when a recovery record existed and was resolved by this load.
  final bool recovered;
}

/// Saves and restores `backend.env` and `subdock.json` as one pair.
///
/// A save writes a private recovery record that carries the previous bytes and
/// the candidate digests, replaces both files, then persists a committed
/// receipt. A pre-commit failure restores the previous bytes, including the
/// previous absence of a file. A committed pair is only consumed once the
/// files still match the receipt; suspected external edits block instead of
/// being overwritten. Recovery only ever touches the two fixed file names.
class RuntimeConfigurationStore {
  RuntimeConfigurationStore({
    required this.directories,
    required this.environmentStore,
    required this.configurationStore,
  });

  static const _recordVersion = 1;

  final RuntimeDirectories directories;
  final BackendEnvStore environmentStore;
  final SubDockConfigStore configurationStore;

  File get environmentFile => environmentStore.file;

  File get configurationFile => configurationStore.file;

  File get recoveryFile => File.fromUri(
    directories.config.uri.resolve('runtime-configuration.recovery.json'),
  );

  Future<RuntimeConfigurationLoad> load() async {
    final raw = await _readRecoveryRecord();
    if (raw == null) {
      return RuntimeConfigurationLoad(
        configuration: await _readPair(),
        recovered: false,
      );
    }
    final record = _RecoveryRecord.decode(raw);
    if (record.committed) {
      await _verifyCommitted(record);
    } else {
      await _restoreUncommitted(record);
    }
    try {
      await clearRecoveryRecord();
    } on Object {
      // The resolved record is re-checked and re-cleared on the next load.
    }
    return RuntimeConfigurationLoad(
      configuration: await _readPair(),
      recovered: true,
    );
  }

  Future<RuntimeConfigurationCommit> save(
    RuntimeConfiguration candidate,
  ) async {
    _validate(candidate);
    // Resolve or reject an earlier save before replacing its only recovery record.
    if (await recoveryFile.exists()) await load();
    final record = _RecoveryRecord(
      committed: false,
      environment: _FileRecord.from(await environmentStore.readRaw()),
      configuration: _FileRecord.from(await configurationStore.readRaw()),
      candidateEnvironment: _digest(candidate.environment.rawText),
      candidateConfiguration: _digest(
        SubDockConfigStore.encode(candidate.configuration),
      ),
    );
    await _writeRecoveryRecord(record);
    try {
      await environmentStore.replaceRaw(candidate.environment.rawText);
      await configurationStore.replaceRaw(
        SubDockConfigStore.encode(candidate.configuration),
      );
      await _writeRecoveryRecord(record.asCommitted());
    } catch (_) {
      await _restore(
        record.environment,
        environmentStore.file,
        environmentStore.replaceRaw,
      );
      await _restore(
        record.configuration,
        configurationStore.file,
        configurationStore.replaceRaw,
      );
      try {
        await clearRecoveryRecord();
      } on Object {
        // An unresolved record is re-resolved by the next load.
      }
      rethrow;
    }
    var cleanupPending = false;
    try {
      await clearRecoveryRecord();
    } on Object {
      cleanupPending = true;
    }
    return RuntimeConfigurationCommit(cleanupPending: cleanupPending);
  }

  /// Removes the recovery record once the pair is resolved or committed.
  ///
  /// Called by [load] and by [save] after the receipt is durable; a failure
  /// leaves the record for the next load to resolve.
  Future<void> clearRecoveryRecord() async {
    if (await recoveryFile.exists()) await recoveryFile.delete();
  }

  Future<RuntimeConfiguration> _readPair() async => RuntimeConfiguration(
    environment: await environmentStore.load(),
    configuration: await configurationStore.load(),
  );

  void _validate(RuntimeConfiguration candidate) {
    final issues = BackendEnvPolicy.validate(candidate.environment);
    if (issues.isNotEmpty) {
      throw AppConfigError(
        AppConfigErrorCode.environmentInvalid,
        issue: issues.first,
      );
    }
    SubDockConfig.fromJson(candidate.configuration.toJson());
  }

  Future<void> _verifyCommitted(_RecoveryRecord record) async {
    final environment = await environmentStore.readRaw();
    final configuration = await configurationStore.readRaw();
    if (environment == null ||
        _digest(environment) != record.candidateEnvironment ||
        configuration == null ||
        _digest(configuration) != record.candidateConfiguration) {
      throw _blocked(
        'The saved runtime configuration no longer matches its receipt',
      );
    }
  }

  Future<void> _restoreUncommitted(_RecoveryRecord record) async {
    final environment = await environmentStore.readRaw();
    final configuration = await configurationStore.readRaw();
    if (!record.environment.accepts(environment, record.candidateEnvironment) ||
        !record.configuration.accepts(
          configuration,
          record.candidateConfiguration,
        )) {
      throw _blocked('The runtime configuration files changed outside SubDock');
    }
    await _restore(
      record.environment,
      environmentStore.file,
      environmentStore.replaceRaw,
    );
    await _restore(
      record.configuration,
      configurationStore.file,
      configurationStore.replaceRaw,
    );
  }

  Future<void> _restore(
    _FileRecord before,
    File file,
    Future<void> Function(String rawText) replaceRaw,
  ) async {
    if (before.exists) {
      await replaceRaw(before.raw!);
      return;
    }
    if (await file.exists()) await file.delete();
  }

  Future<void> _writeRecoveryRecord(_RecoveryRecord record) async {
    final temporary = File(
      '${recoveryFile.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsString(
        jsonEncode(record.toJson()),
        encoding: utf8,
        flush: true,
      );
      await restrictFileToCurrentUser(temporary);
      // Rename preserves the private mode; publication is the last fallible step.
      await temporary.rename(recoveryFile.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<String?> _readRecoveryRecord() async {
    if (!await recoveryFile.exists()) return null;
    return recoveryFile.readAsString(encoding: utf8);
  }

  static AppConfigError _blocked(String detail) =>
      AppConfigError(AppConfigErrorCode.readFailed, detail: detail);
}

String _digest(String raw) => sha256.convert(utf8.encode(raw)).toString();

/// The previous bytes of one file, plus the digest of the candidate.
class _FileRecord {
  const _FileRecord({required this.exists, this.raw, this.digest});

  factory _FileRecord.from(String? raw) => raw == null
      ? const _FileRecord(exists: false)
      : _FileRecord(exists: true, raw: raw, digest: _digest(raw));

  final bool exists;
  final String? raw;
  final String? digest;

  /// Whether [current] still matches either the previous bytes or [candidate].
  bool accepts(String? current, String candidate) {
    if (current == null) return !exists;
    final observed = _digest(current);
    return (exists && observed == digest) || observed == candidate;
  }

  Map<String, Object?> toJson() => {
    'exists': exists,
    'raw': ?raw,
    'digest': ?digest,
  };

  factory _FileRecord.decode(Object? value) {
    if (value is! Map || value['exists'] is! bool) {
      throw const FormatException('invalid file record');
    }
    final exists = value['exists'] as bool;
    final raw = value['raw'];
    final digest = value['digest'];
    if (exists &&
        (raw is! String || digest is! String || _digest(raw) != digest)) {
      throw const FormatException('invalid file record');
    }
    return _FileRecord(
      exists: exists,
      raw: raw as String?,
      digest: digest as String?,
    );
  }
}

class _RecoveryRecord {
  const _RecoveryRecord({
    required this.committed,
    required this.environment,
    required this.configuration,
    required this.candidateEnvironment,
    required this.candidateConfiguration,
  });

  final bool committed;
  final _FileRecord environment;
  final _FileRecord configuration;
  final String candidateEnvironment;
  final String candidateConfiguration;

  _RecoveryRecord asCommitted() => _RecoveryRecord(
    committed: true,
    environment: environment,
    configuration: configuration,
    candidateEnvironment: candidateEnvironment,
    candidateConfiguration: candidateConfiguration,
  );

  Map<String, Object?> toJson() => {
    'version': RuntimeConfigurationStore._recordVersion,
    'committed': committed,
    'environment': environment.toJson(),
    'configuration': configuration.toJson(),
    'candidate': {
      'environment': candidateEnvironment,
      'configuration': candidateConfiguration,
    },
  };

  factory _RecoveryRecord.decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('not an object');
      if (decoded['version'] != RuntimeConfigurationStore._recordVersion ||
          decoded['committed'] is! bool) {
        throw const FormatException('unknown record version');
      }
      final candidate = decoded['candidate'];
      if (candidate is! Map ||
          candidate['environment'] is! String ||
          candidate['configuration'] is! String) {
        throw const FormatException('invalid candidate digests');
      }
      return _RecoveryRecord(
        committed: decoded['committed'] as bool,
        environment: _FileRecord.decode(decoded['environment']),
        configuration: _FileRecord.decode(decoded['configuration']),
        candidateEnvironment: candidate['environment'] as String,
        candidateConfiguration: candidate['configuration'] as String,
      );
    } on Object {
      throw RuntimeConfigurationStore._blocked(
        'The runtime configuration recovery record is unreadable',
      );
    }
  }
}

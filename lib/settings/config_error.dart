import 'backend_env.dart';

/// Machine-readable configuration errors raised by the parse/validate layers.
///
/// UI render points map [code] plus the carried parameters to a localized
/// message via `AppLocalizations`, so the non-UI layers never hold display
/// text. The English [message] stays as a debugging fallback.
enum AppConfigErrorCode {
  unsupportedVersion,
  emptyHost,
  notAnObject,
  invalidFieldName,
  unknownField,
  stringWithNewline,
  mustBeBoolean,
  portRange,
  pathPrefix,
  corsOrigin,
  readFailed,
  pendingMetadataInvalid,
  metadataInvalid,
  configStoreDisabled,
  updaterDisabled,
  componentRecoveryFailed,
  environmentInvalid,
  trayUnavailable,
  exitFailed,
}

class AppConfigError implements Exception {
  const AppConfigError(
    this.code, {
    this.name,
    this.key,
    this.field,
    this.origin,
    this.detail,
    this.issue,
  });

  final AppConfigErrorCode code;
  final String? name;
  final String? key;
  final String? field;
  final String? origin;
  final String? detail;

  /// The first environment issue behind an [AppConfigErrorCode.environmentInvalid].
  final BackendEnvIssue? issue;

  @override
  String toString() => switch (code) {
    AppConfigErrorCode.unsupportedVersion =>
      'Unsupported SubDock configuration version',
    AppConfigErrorCode.emptyHost => '$key must not be empty',
    AppConfigErrorCode.notAnObject => '$name must be an object',
    AppConfigErrorCode.invalidFieldName => '$name has an invalid field name',
    AppConfigErrorCode.unknownField => 'Unsupported config field: $field',
    AppConfigErrorCode.stringWithNewline => '$key must be a string without newlines',
    AppConfigErrorCode.mustBeBoolean => '$key must be a boolean',
    AppConfigErrorCode.portRange => '$key must be between 1 and 65535',
    AppConfigErrorCode.pathPrefix => '$key must start with /',
    AppConfigErrorCode.corsOrigin => 'Invalid CORS origin: $origin',
    AppConfigErrorCode.readFailed => 'Failed to read configuration: $detail',
    AppConfigErrorCode.pendingMetadataInvalid => 'Invalid pending component metadata',
    AppConfigErrorCode.metadataInvalid => 'Invalid component metadata',
    AppConfigErrorCode.configStoreDisabled =>
      'The SubDock configuration store is not enabled',
    AppConfigErrorCode.updaterDisabled =>
      'The component updater is not enabled on this platform',
    AppConfigErrorCode.componentRecoveryFailed =>
      'Component update recovery failed: $detail',
    AppConfigErrorCode.environmentInvalid => issue?.message ?? 'Invalid environment',
    AppConfigErrorCode.trayUnavailable =>
      'System tray unavailable; closing the window exits SubDock.',
    AppConfigErrorCode.exitFailed => 'SubDock exit failed: $detail',
  };
}

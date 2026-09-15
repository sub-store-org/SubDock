// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'SubDock';

  @override
  String get manage => 'Manage';

  @override
  String get overview => 'Overview';

  @override
  String get logs => 'Logs';

  @override
  String get updates => 'Updates';

  @override
  String get settings => 'Settings';

  @override
  String get frontendUpdate => 'Frontend Update';

  @override
  String get frontendUpdateSubtitle =>
      'Check and manage the installed Frontend component';

  @override
  String get backendUpdate => 'Backend Update';

  @override
  String get backendUpdateSubtitle =>
      'Check and manage the installed Backend component';

  @override
  String get recheck => 'Recheck';

  @override
  String get currentVersion => 'Current version';

  @override
  String get previousVersion => 'Previous version';

  @override
  String get availableVersion => 'Available version';

  @override
  String get componentStatusUnavailable => 'Installed version unavailable';

  @override
  String get backendMustBeStopped =>
      'Stop Backend before updating or rolling back components.';

  @override
  String confirmComponentRollback(Object current, Object previous) {
    return 'Roll back from $current to $previous?';
  }

  @override
  String get backendRestartRequired => 'Backend restart required';

  @override
  String get backendTransitioning =>
      'Waiting for Backend to reach a stable state.';

  @override
  String get backendStoppedForUpdates =>
      'Backend is stopped. Component changes are available.';

  @override
  String get stopBackend => 'Stop Backend';

  @override
  String get start => 'Start';

  @override
  String get stop => 'Stop';

  @override
  String get restart => 'Restart';

  @override
  String get save => 'Save';

  @override
  String get saved => 'Saved';

  @override
  String get ready => 'Ready';

  @override
  String get unavailable => 'Unavailable';

  @override
  String get processing => 'Processing';

  @override
  String get stopped => 'Stopped';

  @override
  String get starting => 'Starting';

  @override
  String get running => 'Running';

  @override
  String get stopping => 'Stopping';

  @override
  String get unhealthy => 'Unhealthy';

  @override
  String get crashed => 'Crashed';

  @override
  String get themeFollowSystem => 'Follow system';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get operationInProgress => 'An operation is already in progress';

  @override
  String get minimizeTooltip => 'Minimize';

  @override
  String get maximizeTooltip => 'Maximize';

  @override
  String get restoreTooltip => 'Restore';

  @override
  String get closeTooltip => 'Close';

  @override
  String get webView2Missing =>
      'Microsoft Edge WebView2 Runtime was not detected. Install it and try again.';

  @override
  String openSystemBrowserFailed(Object uri) {
    return 'The system browser could not open $uri';
  }

  @override
  String downloadFailedHttp(Object statusCode) {
    return 'Download failed: HTTP $statusCode';
  }

  @override
  String get blobExportInvalid => 'Blob export data is invalid';

  @override
  String get blobExportTooLarge => 'Blob export exceeds the 16 MiB limit';

  @override
  String get openWebView2DownloadFailed =>
      'The system browser could not open the WebView2 download page';

  @override
  String get backendNotRunning => 'Backend is not running';

  @override
  String get viewOverview => 'View overview';

  @override
  String get componentStatusHeading => 'Component Status';

  @override
  String componentCurrent(Object version) {
    return 'Current $version';
  }

  @override
  String componentPrevious(Object version) {
    return 'Previous $version';
  }

  @override
  String get rollbackAvailable => 'Rollback available';

  @override
  String get rollbackUnavailable => 'Rollback unavailable';

  @override
  String get refresh => 'Refresh';

  @override
  String get openInSystemBrowser => 'Open in system browser';

  @override
  String get webViewCurrentUrlUnavailable =>
      'The current WebView URL is unavailable or invalid';

  @override
  String get fixConfiguration => 'Fix configuration';

  @override
  String get openWebView2DownloadPage =>
      'Open the official WebView2 download page';

  @override
  String get httpMetaDisabled => 'Disabled';

  @override
  String get httpMetaUnavailable => 'Unavailable';

  @override
  String httpMetaUnavailableDetail(Object message) {
    return 'Unavailable: $message';
  }

  @override
  String get httpMetaStarting => 'Starting';

  @override
  String httpMetaRunning(Object port, Object version) {
    return 'Running on port $port, version $version';
  }

  @override
  String get httpMetaDegraded => 'Degraded';

  @override
  String httpMetaDegradedDetail(Object message) {
    return 'Degraded: $message';
  }

  @override
  String get httpMetaStopped => 'Stopped';

  @override
  String get noLogs => 'No logs yet';

  @override
  String get logSearch => 'Search log messages';

  @override
  String get logNewest => 'Newest first';

  @override
  String get logOldest => 'Newest last';

  @override
  String get copyLog => 'Copy log';

  @override
  String get copyFilteredLogs => 'Copy filtered logs';

  @override
  String get noFilteredLogs => 'No matching logs';

  @override
  String get logLevelDebug => 'Debug';

  @override
  String get logLevelInfo => 'Info';

  @override
  String get logLevelWarning => 'Warning';

  @override
  String get logLevelError => 'Error';

  @override
  String get current => 'Current';

  @override
  String get history => 'History';

  @override
  String get noHistory => 'No history';

  @override
  String get historyLoadError => 'Unable to load history';

  @override
  String get logEvents => 'events';

  @override
  String get back => 'Back';

  @override
  String get deleteRun => 'Delete run';

  @override
  String get clearHistory => 'Clear history';

  @override
  String get undo => 'Undo';

  @override
  String get unsavedChanges => 'You have unsaved changes. Continue?';

  @override
  String get recentlyDeleted => 'Recently deleted';

  @override
  String get previousPage => 'Previous';

  @override
  String get nextPage => 'Next';

  @override
  String get confirmExternalCors =>
      'Allowing an external origin lets it reach the Backend API. Save anyway?';

  @override
  String get confirmNonLoopback =>
      'The Backend has no authentication; a non-loopback address lets other devices on the network reach every API. Save anyway?';

  @override
  String get configSavedNoRestart =>
      'SubDock configuration saved; the service will not restart automatically.';

  @override
  String get savedRestartToApply =>
      'Saved; takes effect after the Backend restarts.';

  @override
  String get restartNow => 'Restart now';

  @override
  String get cancel => 'Cancel';

  @override
  String get continueAction => 'Continue';

  @override
  String componentUpdatedTo(Object version) {
    return 'Updated to $version';
  }

  @override
  String get componentPackageVersion => 'Package version';

  @override
  String get componentRolledBack => 'Rolled back to the previous version';

  @override
  String get componentReadingVersion => 'Reading the installed version…';

  @override
  String componentCurrentWithPrevious(Object current, Object previous) {
    return 'Current $current, previous $previous';
  }

  @override
  String componentUpdateAvailable(
    Object available,
    Object current,
    Object previous,
  ) {
    return 'Current $current, can update to $available, previous $previous';
  }

  @override
  String componentUpToDate(Object current, Object previous) {
    return 'Current $current is the latest version, previous $previous';
  }

  @override
  String get subdockConfigHeading => 'SubDock Configuration';

  @override
  String configurationInvalid(Object error) {
    return 'Invalid configuration file: $error';
  }

  @override
  String get resetSubdockConfig => 'Reset SubDock configuration';

  @override
  String get enableHttpMeta => 'Enable HTTP-META';

  @override
  String get enableHttpMetaSubtitle =>
      'The Backend keeps running even if the auxiliary start fails';

  @override
  String get saveSubdockConfig => 'Save SubDock configuration';

  @override
  String get backendConfigHeading => 'Backend Configuration';

  @override
  String get mergeMode => 'Merge mode';

  @override
  String get apiFieldsSummary => 'Host, Port, Merge, Path, CORS';

  @override
  String get apiHost => 'API Host';

  @override
  String get apiPort => 'API Port';

  @override
  String get frontendBackendPath => 'Frontend Backend Path';

  @override
  String get corsAllowedOrigins => 'CORS Allowed Origins';

  @override
  String get unsaved => 'Unsaved';

  @override
  String get inherit => 'Inherit';

  @override
  String get enabled => 'On';

  @override
  String get disabled => 'Off';

  @override
  String get advancedRawEnv => 'Advanced raw ENV';

  @override
  String get advancedRawEnvSubtitle =>
      'Edit the full Backend environment variables directly';

  @override
  String lineNumber(Object line) {
    return 'Line $line:';
  }

  @override
  String get appearanceHeading => 'Appearance';

  @override
  String get themeHeading => 'Theme';

  @override
  String get languageHeading => 'Language';

  @override
  String get themeSubtitle =>
      'Preview theme changes immediately and use Save to keep this setting.';

  @override
  String get languageSubtitle =>
      'Preview interface language changes immediately and use Save to keep this setting.';

  @override
  String get closeBehaviorHeading => 'Close behavior';

  @override
  String get closeBehaviorSubtitle =>
      'Controls what happens when the window close button is pressed.';

  @override
  String get recentLogsSubtitle =>
      'Controls how many recent logs are retained before older entries are removed.';

  @override
  String get saveAll => 'Save All';

  @override
  String get discard => 'Discard';

  @override
  String get exitApp => 'Exit app';

  @override
  String get closeToTray => 'Close to tray';

  @override
  String get recentLogs => 'Recent logs';

  @override
  String get recentLogPresets => 'Preset limit';

  @override
  String get structuredEnvPrecedenceWarning =>
      'Backend Configuration overrides matching Advanced ENV values.';

  @override
  String get languageFollowSystem => 'Follow system';

  @override
  String get componentUpdatesHeading => 'Component Updates';

  @override
  String get checkForUpdates => 'Check for updates';

  @override
  String get update => 'Update';

  @override
  String get rollback => 'Rollback';

  @override
  String get viewReleaseNotes => 'View release notes';

  @override
  String get aboutSubDock => 'About SubDock';

  @override
  String get aboutSubDockSubtitle =>
      'Version, license, and platform information';

  @override
  String get aboutVersion => 'SubDock version';

  @override
  String get aboutBuildNumber => 'Build number';

  @override
  String get aboutLicense => 'License';

  @override
  String get aboutProjectHomepage => 'Project homepage';

  @override
  String get aboutOperatingSystem => 'Operating system';

  @override
  String get aboutArchitecture => 'Architecture';

  @override
  String get aboutMetadataLoading => 'Loading application information…';

  @override
  String get aboutMetadataUnavailable => 'Application information unavailable';

  @override
  String get envIssueMissingPair => 'Missing KEY=VALUE';

  @override
  String envIssueInvalidKey(Object key) {
    return 'Invalid environment variable name: $key';
  }

  @override
  String envIssueDuplicateKey(Object key) {
    return 'Duplicate environment variable: $key';
  }

  @override
  String envIssueReservedKey(Object key) {
    return 'Reserved SubDock environment variable: $key';
  }

  @override
  String get envIssuePortRange => 'Port must be between 1 and 65535';

  @override
  String get envIssueMergeBool => 'Merge mode must be true or false';

  @override
  String get envIssuePathPrefix => 'Frontend Backend Path must start with /';

  @override
  String envIssueCorsOrigin(Object origin) {
    return 'Invalid CORS origin: $origin';
  }

  @override
  String get configErrorUnsupportedVersion =>
      'Unsupported SubDock configuration version';

  @override
  String configErrorNotAnObject(Object name) {
    return '$name must be an object';
  }

  @override
  String configErrorInvalidFieldName(Object name) {
    return '$name has an invalid field name';
  }

  @override
  String configErrorUnknownField(Object field) {
    return 'Unsupported SubDock configuration field: $field';
  }

  @override
  String configErrorStringWithNewline(Object key) {
    return '$key must be a string without newlines';
  }

  @override
  String configErrorNotBoolean(Object key) {
    return '$key must be a boolean';
  }

  @override
  String configErrorPortRange(Object key) {
    return '$key must be between 1 and 65535';
  }

  @override
  String configErrorNotEmpty(Object key) {
    return '$key must not be empty';
  }

  @override
  String configErrorPathPrefix(Object key) {
    return '$key must start with /';
  }

  @override
  String configErrorCorsOrigin(Object origin) {
    return 'Invalid CORS origin: $origin';
  }

  @override
  String configErrorReadFailed(Object detail) {
    return 'Failed to read SubDock configuration: $detail';
  }

  @override
  String get configErrorPendingMetadataInvalid =>
      'Invalid pending component metadata';

  @override
  String get configErrorMetadataInvalid => 'Invalid component metadata';

  @override
  String get configErrorStoreDisabled =>
      'The SubDock configuration store is not enabled';

  @override
  String get configErrorUpdaterDisabled =>
      'The component updater is not enabled on this platform';

  @override
  String configErrorRecoveryFailed(Object detail) {
    return 'Component update recovery failed: $detail';
  }

  @override
  String get configErrorTrayUnavailable =>
      'System tray unavailable; closing the window exits SubDock.';

  @override
  String get trayShowWindow => 'Show window';

  @override
  String get trayExit => 'Exit';
}

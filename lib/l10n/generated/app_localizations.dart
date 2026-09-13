import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In zh, this message translates to:
  /// **'SubDock'**
  String get appTitle;

  /// No description provided for @manage.
  ///
  /// In zh, this message translates to:
  /// **'管理'**
  String get manage;

  /// No description provided for @overview.
  ///
  /// In zh, this message translates to:
  /// **'概览'**
  String get overview;

  /// No description provided for @logs.
  ///
  /// In zh, this message translates to:
  /// **'日志'**
  String get logs;

  /// No description provided for @settings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settings;

  /// No description provided for @start.
  ///
  /// In zh, this message translates to:
  /// **'启动'**
  String get start;

  /// No description provided for @stop.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get stop;

  /// No description provided for @restart.
  ///
  /// In zh, this message translates to:
  /// **'重启'**
  String get restart;

  /// No description provided for @save.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get save;

  /// No description provided for @ready.
  ///
  /// In zh, this message translates to:
  /// **'就绪'**
  String get ready;

  /// No description provided for @unavailable.
  ///
  /// In zh, this message translates to:
  /// **'不可用'**
  String get unavailable;

  /// No description provided for @processing.
  ///
  /// In zh, this message translates to:
  /// **'处理中'**
  String get processing;

  /// No description provided for @stopped.
  ///
  /// In zh, this message translates to:
  /// **'已停止'**
  String get stopped;

  /// No description provided for @starting.
  ///
  /// In zh, this message translates to:
  /// **'正在启动'**
  String get starting;

  /// No description provided for @running.
  ///
  /// In zh, this message translates to:
  /// **'运行中'**
  String get running;

  /// No description provided for @stopping.
  ///
  /// In zh, this message translates to:
  /// **'正在停止'**
  String get stopping;

  /// No description provided for @unhealthy.
  ///
  /// In zh, this message translates to:
  /// **'不健康'**
  String get unhealthy;

  /// No description provided for @crashed.
  ///
  /// In zh, this message translates to:
  /// **'已崩溃'**
  String get crashed;

  /// No description provided for @themeFollowSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get themeFollowSystem;

  /// No description provided for @themeLight.
  ///
  /// In zh, this message translates to:
  /// **'浅色'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get themeDark;

  /// No description provided for @operationInProgress.
  ///
  /// In zh, this message translates to:
  /// **'已有操作正在进行'**
  String get operationInProgress;

  /// No description provided for @minimizeTooltip.
  ///
  /// In zh, this message translates to:
  /// **'最小化'**
  String get minimizeTooltip;

  /// No description provided for @toggleFullscreenTooltip.
  ///
  /// In zh, this message translates to:
  /// **'切换全屏'**
  String get toggleFullscreenTooltip;

  /// No description provided for @closeToTrayTooltip.
  ///
  /// In zh, this message translates to:
  /// **'关闭到托盘'**
  String get closeToTrayTooltip;

  /// No description provided for @webView2Missing.
  ///
  /// In zh, this message translates to:
  /// **'未检测到 Microsoft Edge WebView2 Runtime。请安装后重试。'**
  String get webView2Missing;

  /// No description provided for @openSystemBrowserFailed.
  ///
  /// In zh, this message translates to:
  /// **'系统浏览器无法打开 {uri}'**
  String openSystemBrowserFailed(Object uri);

  /// No description provided for @downloadFailedHttp.
  ///
  /// In zh, this message translates to:
  /// **'下载失败：HTTP {statusCode}'**
  String downloadFailedHttp(Object statusCode);

  /// No description provided for @blobExportInvalid.
  ///
  /// In zh, this message translates to:
  /// **'Blob 导出数据格式无效'**
  String get blobExportInvalid;

  /// No description provided for @blobExportTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'Blob 导出超过 16 MiB 限制'**
  String get blobExportTooLarge;

  /// No description provided for @openWebView2DownloadFailed.
  ///
  /// In zh, this message translates to:
  /// **'系统浏览器无法打开 WebView2 下载页面'**
  String get openWebView2DownloadFailed;

  /// No description provided for @backendNotRunning.
  ///
  /// In zh, this message translates to:
  /// **'Backend 未运行'**
  String get backendNotRunning;

  /// No description provided for @viewOverview.
  ///
  /// In zh, this message translates to:
  /// **'查看概览'**
  String get viewOverview;

  /// No description provided for @recentLogsHeading.
  ///
  /// In zh, this message translates to:
  /// **'最近日志'**
  String get recentLogsHeading;

  /// No description provided for @componentStatusHeading.
  ///
  /// In zh, this message translates to:
  /// **'组件状态'**
  String get componentStatusHeading;

  /// No description provided for @fixConfiguration.
  ///
  /// In zh, this message translates to:
  /// **'修复配置'**
  String get fixConfiguration;

  /// No description provided for @openWebView2DownloadPage.
  ///
  /// In zh, this message translates to:
  /// **'打开 WebView2 官方下载页'**
  String get openWebView2DownloadPage;

  /// No description provided for @httpMetaDisabled.
  ///
  /// In zh, this message translates to:
  /// **'已禁用'**
  String get httpMetaDisabled;

  /// No description provided for @httpMetaUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'不可用'**
  String get httpMetaUnavailable;

  /// No description provided for @httpMetaUnavailableDetail.
  ///
  /// In zh, this message translates to:
  /// **'不可用：{message}'**
  String httpMetaUnavailableDetail(Object message);

  /// No description provided for @httpMetaStarting.
  ///
  /// In zh, this message translates to:
  /// **'启动中'**
  String get httpMetaStarting;

  /// No description provided for @httpMetaRunning.
  ///
  /// In zh, this message translates to:
  /// **'运行中，端口 {port}，版本 {version}'**
  String httpMetaRunning(Object port, Object version);

  /// No description provided for @httpMetaDegraded.
  ///
  /// In zh, this message translates to:
  /// **'已降级'**
  String get httpMetaDegraded;

  /// No description provided for @httpMetaDegradedDetail.
  ///
  /// In zh, this message translates to:
  /// **'已降级：{message}'**
  String httpMetaDegradedDetail(Object message);

  /// No description provided for @httpMetaStopped.
  ///
  /// In zh, this message translates to:
  /// **'已停止'**
  String get httpMetaStopped;

  /// No description provided for @noLogs.
  ///
  /// In zh, this message translates to:
  /// **'暂无日志'**
  String get noLogs;

  /// No description provided for @confirmExternalCors.
  ///
  /// In zh, this message translates to:
  /// **'允许外部 origin 会使其能够访问 Backend API。是否继续保存？'**
  String get confirmExternalCors;

  /// No description provided for @confirmNonLoopback.
  ///
  /// In zh, this message translates to:
  /// **'Backend 没有鉴权；非回环地址会让同一网络中的设备访问全部 API。是否继续保存？'**
  String get confirmNonLoopback;

  /// No description provided for @configSavedNoRestart.
  ///
  /// In zh, this message translates to:
  /// **'SubDock 配置已保存；不会自动重启服务。'**
  String get configSavedNoRestart;

  /// No description provided for @savedRestartToApply.
  ///
  /// In zh, this message translates to:
  /// **'已保存；重启 Backend 后生效。'**
  String get savedRestartToApply;

  /// No description provided for @restartNow.
  ///
  /// In zh, this message translates to:
  /// **'立即重启'**
  String get restartNow;

  /// No description provided for @cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get cancel;

  /// No description provided for @continueAction.
  ///
  /// In zh, this message translates to:
  /// **'继续'**
  String get continueAction;

  /// No description provided for @componentUpdatedTo.
  ///
  /// In zh, this message translates to:
  /// **'已更新到 {version}'**
  String componentUpdatedTo(Object version);

  /// No description provided for @componentPackageVersion.
  ///
  /// In zh, this message translates to:
  /// **'安装包版本'**
  String get componentPackageVersion;

  /// No description provided for @componentRolledBack.
  ///
  /// In zh, this message translates to:
  /// **'已回滚到上一版本'**
  String get componentRolledBack;

  /// No description provided for @componentReadingVersion.
  ///
  /// In zh, this message translates to:
  /// **'正在读取已安装版本…'**
  String get componentReadingVersion;

  /// No description provided for @componentCurrentWithPrevious.
  ///
  /// In zh, this message translates to:
  /// **'当前 {current}，上一版 {previous}'**
  String componentCurrentWithPrevious(Object current, Object previous);

  /// No description provided for @componentUpdateAvailable.
  ///
  /// In zh, this message translates to:
  /// **'当前 {current}，可更新到 {available}，上一版 {previous}'**
  String componentUpdateAvailable(
    Object available,
    Object current,
    Object previous,
  );

  /// No description provided for @componentUpToDate.
  ///
  /// In zh, this message translates to:
  /// **'当前 {current} 已是最新版本，上一版 {previous}'**
  String componentUpToDate(Object current, Object previous);

  /// No description provided for @subdockConfigHeading.
  ///
  /// In zh, this message translates to:
  /// **'SubDock 配置'**
  String get subdockConfigHeading;

  /// No description provided for @configurationInvalid.
  ///
  /// In zh, this message translates to:
  /// **'配置文件无效：{error}'**
  String configurationInvalid(Object error);

  /// No description provided for @resetSubdockConfig.
  ///
  /// In zh, this message translates to:
  /// **'重置 SubDock 配置'**
  String get resetSubdockConfig;

  /// No description provided for @enableHttpMeta.
  ///
  /// In zh, this message translates to:
  /// **'启用 HTTP-META'**
  String get enableHttpMeta;

  /// No description provided for @enableHttpMetaSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'辅助启动失败时 Backend 仍会继续运行'**
  String get enableHttpMetaSubtitle;

  /// No description provided for @saveSubdockConfig.
  ///
  /// In zh, this message translates to:
  /// **'保存 SubDock 配置'**
  String get saveSubdockConfig;

  /// No description provided for @backendConfigHeading.
  ///
  /// In zh, this message translates to:
  /// **'Backend 配置'**
  String get backendConfigHeading;

  /// No description provided for @mergeMode.
  ///
  /// In zh, this message translates to:
  /// **'合并模式'**
  String get mergeMode;

  /// No description provided for @advancedRawEnv.
  ///
  /// In zh, this message translates to:
  /// **'高级原始 ENV'**
  String get advancedRawEnv;

  /// No description provided for @advancedRawEnvSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'直接编辑完整 Backend 环境变量'**
  String get advancedRawEnvSubtitle;

  /// No description provided for @lineNumber.
  ///
  /// In zh, this message translates to:
  /// **'第 {line} 行：'**
  String lineNumber(Object line);

  /// No description provided for @appearanceHeading.
  ///
  /// In zh, this message translates to:
  /// **'外观'**
  String get appearanceHeading;

  /// No description provided for @languageFollowSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get languageFollowSystem;

  /// No description provided for @componentUpdatesHeading.
  ///
  /// In zh, this message translates to:
  /// **'组件更新'**
  String get componentUpdatesHeading;

  /// No description provided for @checkForUpdates.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get checkForUpdates;

  /// No description provided for @update.
  ///
  /// In zh, this message translates to:
  /// **'更新'**
  String get update;

  /// No description provided for @rollback.
  ///
  /// In zh, this message translates to:
  /// **'回滚'**
  String get rollback;

  /// No description provided for @envIssueMissingPair.
  ///
  /// In zh, this message translates to:
  /// **'缺少 KEY=VALUE'**
  String get envIssueMissingPair;

  /// No description provided for @envIssueInvalidKey.
  ///
  /// In zh, this message translates to:
  /// **'环境变量名无效：{key}'**
  String envIssueInvalidKey(Object key);

  /// No description provided for @envIssueDuplicateKey.
  ///
  /// In zh, this message translates to:
  /// **'环境变量重复：{key}'**
  String envIssueDuplicateKey(Object key);

  /// No description provided for @envIssueReservedKey.
  ///
  /// In zh, this message translates to:
  /// **'SubDock 保留环境变量：{key}'**
  String envIssueReservedKey(Object key);

  /// No description provided for @envIssuePortRange.
  ///
  /// In zh, this message translates to:
  /// **'端口必须在 1 到 65535 之间'**
  String get envIssuePortRange;

  /// No description provided for @envIssueMergeBool.
  ///
  /// In zh, this message translates to:
  /// **'合并模式必须为 true 或 false'**
  String get envIssueMergeBool;

  /// No description provided for @envIssuePathPrefix.
  ///
  /// In zh, this message translates to:
  /// **'Frontend Backend Path 必须以 / 开头'**
  String get envIssuePathPrefix;

  /// No description provided for @envIssueCorsOrigin.
  ///
  /// In zh, this message translates to:
  /// **'CORS origin 无效：{origin}'**
  String envIssueCorsOrigin(Object origin);

  /// No description provided for @configErrorUnsupportedVersion.
  ///
  /// In zh, this message translates to:
  /// **'不支持的 SubDock 配置版本'**
  String get configErrorUnsupportedVersion;

  /// No description provided for @configErrorNotAnObject.
  ///
  /// In zh, this message translates to:
  /// **'{name} 必须是对象'**
  String configErrorNotAnObject(Object name);

  /// No description provided for @configErrorInvalidFieldName.
  ///
  /// In zh, this message translates to:
  /// **'{name} 的字段名无效'**
  String configErrorInvalidFieldName(Object name);

  /// No description provided for @configErrorUnknownField.
  ///
  /// In zh, this message translates to:
  /// **'不支持的 SubDock 配置字段：{field}'**
  String configErrorUnknownField(Object field);

  /// No description provided for @configErrorStringWithNewline.
  ///
  /// In zh, this message translates to:
  /// **'{key} 必须是不含换行的字符串'**
  String configErrorStringWithNewline(Object key);

  /// No description provided for @configErrorNotBoolean.
  ///
  /// In zh, this message translates to:
  /// **'{key} 必须是布尔值'**
  String configErrorNotBoolean(Object key);

  /// No description provided for @configErrorPortRange.
  ///
  /// In zh, this message translates to:
  /// **'{key} 必须在 1 到 65535 之间'**
  String configErrorPortRange(Object key);

  /// No description provided for @configErrorNotEmpty.
  ///
  /// In zh, this message translates to:
  /// **'{key} 不能为空'**
  String configErrorNotEmpty(Object key);

  /// No description provided for @configErrorPathPrefix.
  ///
  /// In zh, this message translates to:
  /// **'{key} 必须以 / 开头'**
  String configErrorPathPrefix(Object key);

  /// No description provided for @configErrorCorsOrigin.
  ///
  /// In zh, this message translates to:
  /// **'CORS origin 无效：{origin}'**
  String configErrorCorsOrigin(Object origin);

  /// No description provided for @configErrorReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法读取 SubDock 配置：{detail}'**
  String configErrorReadFailed(Object detail);

  /// No description provided for @configErrorPendingMetadataInvalid.
  ///
  /// In zh, this message translates to:
  /// **'组件 pending 元数据无效'**
  String get configErrorPendingMetadataInvalid;

  /// No description provided for @configErrorMetadataInvalid.
  ///
  /// In zh, this message translates to:
  /// **'组件元数据无效'**
  String get configErrorMetadataInvalid;

  /// No description provided for @configErrorStoreDisabled.
  ///
  /// In zh, this message translates to:
  /// **'SubDock 配置存储尚未启用'**
  String get configErrorStoreDisabled;

  /// No description provided for @configErrorUpdaterDisabled.
  ///
  /// In zh, this message translates to:
  /// **'组件更新器尚未在当前平台启用'**
  String get configErrorUpdaterDisabled;

  /// No description provided for @configErrorRecoveryFailed.
  ///
  /// In zh, this message translates to:
  /// **'组件更新恢复失败：{detail}'**
  String configErrorRecoveryFailed(Object detail);

  /// No description provided for @configErrorTrayUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'系统托盘不可用；关闭窗口会退出 SubDock。'**
  String get configErrorTrayUnavailable;

  /// No description provided for @trayShowWindow.
  ///
  /// In zh, this message translates to:
  /// **'显示窗口'**
  String get trayShowWindow;

  /// No description provided for @trayExit.
  ///
  /// In zh, this message translates to:
  /// **'退出'**
  String get trayExit;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}

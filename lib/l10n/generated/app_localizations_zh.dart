// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'SubDock';

  @override
  String get manage => '管理';

  @override
  String get overview => '概览';

  @override
  String get logs => '日志';

  @override
  String get settings => '设置';

  @override
  String get start => '启动';

  @override
  String get stop => '停止';

  @override
  String get restart => '重启';

  @override
  String get save => '保存';

  @override
  String get ready => '就绪';

  @override
  String get unavailable => '不可用';

  @override
  String get processing => '处理中';

  @override
  String get stopped => '已停止';

  @override
  String get starting => '正在启动';

  @override
  String get running => '运行中';

  @override
  String get stopping => '正在停止';

  @override
  String get unhealthy => '不健康';

  @override
  String get crashed => '已崩溃';

  @override
  String get themeFollowSystem => '跟随系统';

  @override
  String get themeLight => '浅色';

  @override
  String get themeDark => '深色';

  @override
  String get operationInProgress => '已有操作正在进行';

  @override
  String get minimizeTooltip => '最小化';

  @override
  String get toggleFullscreenTooltip => '切换全屏';

  @override
  String get closeToTrayTooltip => '关闭到托盘';

  @override
  String get webView2Missing => '未检测到 Microsoft Edge WebView2 Runtime。请安装后重试。';

  @override
  String openSystemBrowserFailed(Object uri) {
    return '系统浏览器无法打开 $uri';
  }

  @override
  String downloadFailedHttp(Object statusCode) {
    return '下载失败：HTTP $statusCode';
  }

  @override
  String get blobExportInvalid => 'Blob 导出数据格式无效';

  @override
  String get blobExportTooLarge => 'Blob 导出超过 16 MiB 限制';

  @override
  String get openWebView2DownloadFailed => '系统浏览器无法打开 WebView2 下载页面';

  @override
  String get backendNotRunning => 'Backend 未运行';

  @override
  String get viewOverview => '查看概览';

  @override
  String get recentLogsHeading => '最近日志';

  @override
  String get componentStatusHeading => '组件状态';

  @override
  String get fixConfiguration => '修复配置';

  @override
  String get openWebView2DownloadPage => '打开 WebView2 官方下载页';

  @override
  String get httpMetaDisabled => '已禁用';

  @override
  String get httpMetaUnavailable => '不可用';

  @override
  String httpMetaUnavailableDetail(Object message) {
    return '不可用：$message';
  }

  @override
  String get httpMetaStarting => '启动中';

  @override
  String httpMetaRunning(Object port, Object version) {
    return '运行中，端口 $port，版本 $version';
  }

  @override
  String get httpMetaDegraded => '已降级';

  @override
  String httpMetaDegradedDetail(Object message) {
    return '已降级：$message';
  }

  @override
  String get httpMetaStopped => '已停止';

  @override
  String get noLogs => '暂无日志';

  @override
  String get confirmExternalCors => '允许外部 origin 会使其能够访问 Backend API。是否继续保存？';

  @override
  String get confirmNonLoopback =>
      'Backend 没有鉴权；非回环地址会让同一网络中的设备访问全部 API。是否继续保存？';

  @override
  String get configSavedNoRestart => 'SubDock 配置已保存；不会自动重启服务。';

  @override
  String get savedRestartToApply => '已保存；重启 Backend 后生效。';

  @override
  String get restartNow => '立即重启';

  @override
  String get cancel => '取消';

  @override
  String get continueAction => '继续';

  @override
  String componentUpdatedTo(Object version) {
    return '已更新到 $version';
  }

  @override
  String get componentPackageVersion => '安装包版本';

  @override
  String get componentRolledBack => '已回滚到上一版本';

  @override
  String get componentReadingVersion => '正在读取已安装版本…';

  @override
  String componentCurrentWithPrevious(Object current, Object previous) {
    return '当前 $current，上一版 $previous';
  }

  @override
  String componentUpdateAvailable(
    Object available,
    Object current,
    Object previous,
  ) {
    return '当前 $current，可更新到 $available，上一版 $previous';
  }

  @override
  String componentUpToDate(Object current, Object previous) {
    return '当前 $current 已是最新版本，上一版 $previous';
  }

  @override
  String get subdockConfigHeading => 'SubDock 配置';

  @override
  String configurationInvalid(Object error) {
    return '配置文件无效：$error';
  }

  @override
  String get resetSubdockConfig => '重置 SubDock 配置';

  @override
  String get enableHttpMeta => '启用 HTTP-META';

  @override
  String get enableHttpMetaSubtitle => '辅助启动失败时 Backend 仍会继续运行';

  @override
  String get saveSubdockConfig => '保存 SubDock 配置';

  @override
  String get backendConfigHeading => 'Backend 配置';

  @override
  String get mergeMode => '合并模式';

  @override
  String get advancedRawEnv => '高级原始 ENV';

  @override
  String get advancedRawEnvSubtitle => '直接编辑完整 Backend 环境变量';

  @override
  String lineNumber(Object line) {
    return '第 $line 行：';
  }

  @override
  String get appearanceHeading => '外观';

  @override
  String get languageFollowSystem => '跟随系统';

  @override
  String get componentUpdatesHeading => '组件更新';

  @override
  String get checkForUpdates => '检查更新';

  @override
  String get update => '更新';

  @override
  String get rollback => '回滚';

  @override
  String get envIssueMissingPair => '缺少 KEY=VALUE';

  @override
  String envIssueInvalidKey(Object key) {
    return '环境变量名无效：$key';
  }

  @override
  String envIssueDuplicateKey(Object key) {
    return '环境变量重复：$key';
  }

  @override
  String envIssueReservedKey(Object key) {
    return 'SubDock 保留环境变量：$key';
  }

  @override
  String get envIssuePortRange => '端口必须在 1 到 65535 之间';

  @override
  String get envIssueMergeBool => '合并模式必须为 true 或 false';

  @override
  String get envIssuePathPrefix => 'Frontend Backend Path 必须以 / 开头';

  @override
  String envIssueCorsOrigin(Object origin) {
    return 'CORS origin 无效：$origin';
  }

  @override
  String get configErrorUnsupportedVersion => '不支持的 SubDock 配置版本';

  @override
  String configErrorNotAnObject(Object name) {
    return '$name 必须是对象';
  }

  @override
  String configErrorInvalidFieldName(Object name) {
    return '$name 的字段名无效';
  }

  @override
  String configErrorUnknownField(Object field) {
    return '不支持的 SubDock 配置字段：$field';
  }

  @override
  String configErrorStringWithNewline(Object key) {
    return '$key 必须是不含换行的字符串';
  }

  @override
  String configErrorNotBoolean(Object key) {
    return '$key 必须是布尔值';
  }

  @override
  String configErrorPortRange(Object key) {
    return '$key 必须在 1 到 65535 之间';
  }

  @override
  String configErrorNotEmpty(Object key) {
    return '$key 不能为空';
  }

  @override
  String configErrorPathPrefix(Object key) {
    return '$key 必须以 / 开头';
  }

  @override
  String configErrorCorsOrigin(Object origin) {
    return 'CORS origin 无效：$origin';
  }

  @override
  String configErrorReadFailed(Object detail) {
    return '无法读取 SubDock 配置：$detail';
  }

  @override
  String get configErrorPendingMetadataInvalid => '组件 pending 元数据无效';

  @override
  String get configErrorMetadataInvalid => '组件元数据无效';

  @override
  String get configErrorStoreDisabled => 'SubDock 配置存储尚未启用';

  @override
  String get configErrorUpdaterDisabled => '组件更新器尚未在当前平台启用';

  @override
  String configErrorRecoveryFailed(Object detail) {
    return '组件更新恢复失败：$detail';
  }

  @override
  String get configErrorTrayUnavailable => '系统托盘不可用；关闭窗口会退出 SubDock。';

  @override
  String get trayShowWindow => '显示窗口';

  @override
  String get trayExit => '退出';
}

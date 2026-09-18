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
  String get updates => '更新';

  @override
  String get settings => '设置';

  @override
  String get backendRuntime => 'Backend';

  @override
  String get node => 'Node';

  @override
  String get port => '端口';

  @override
  String get status => '状态';

  @override
  String get healthy => '健康';

  @override
  String get httpMetaBundled => '随 SubDock 提供';

  @override
  String get httpMetaBundledDescription =>
      '独立运行状态；资源随 SubDock 安装包提供，不属于独立更新组件。';

  @override
  String get components => '组件';

  @override
  String get latest => '最新';

  @override
  String get recentStart => '最近启动';

  @override
  String get anomalies24h => '运行异常（24 小时）';

  @override
  String get sessionLogs => '日志（当前会话）';

  @override
  String get backendComponent => 'Backend';

  @override
  String get frontendComponent => 'Frontend';

  @override
  String get backendComponentDescription => 'Sub-Store Backend';

  @override
  String get frontendComponentDescription => 'Sub-Store WebUI';

  @override
  String get independentlyUpdatable => '可独立更新';

  @override
  String get packagedWithSubDock => '随 SubDock 提供';

  @override
  String get packagedResourcesDescription =>
      '这些运行资源属于应用安装包，不通过 Frontend / Backend 的在线更新器单独替换。';

  @override
  String get nodeJsRuntime => 'Node.js Runtime';

  @override
  String get mihomo => 'Mihomo';

  @override
  String get httpMetaResource => 'HTTP-META 资源';

  @override
  String get recheck => '重新检查';

  @override
  String get currentVersion => '当前版本';

  @override
  String get previousVersion => '上一版本';

  @override
  String get availableVersion => '可用版本';

  @override
  String get componentStatusUnavailable => '无法读取已安装版本';

  @override
  String get backendMustBeStopped => '更新或回滚组件前，请先停止 Backend。';

  @override
  String confirmComponentRollback(Object current, Object previous) {
    return '确认从 $current 回滚到 $previous？';
  }

  @override
  String get backendUpdatedStart => 'Backend 已更新，点击「启动 Backend」恢复运行。';

  @override
  String get backendTransitioning => '正在等待 Backend 进入稳定状态。';

  @override
  String get backendStoppedForUpdates => 'Backend 已停止，可以更改组件。';

  @override
  String get stopBackend => '停止 Backend';

  @override
  String get start => '启动';

  @override
  String get stop => '停止';

  @override
  String get restart => '重启';

  @override
  String get save => '保存';

  @override
  String get saved => '已保存';

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
  String get maximizeTooltip => '最大化';

  @override
  String get restoreTooltip => '还原';

  @override
  String get closeTooltip => '关闭';

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
  String get componentStatusHeading => '组件状态';

  @override
  String componentCurrent(Object version) {
    return '当前 $version';
  }

  @override
  String componentPrevious(Object version) {
    return '上一版 $version';
  }

  @override
  String get rollbackAvailable => '可回滚';

  @override
  String get rollbackUnavailable => '不可回滚';

  @override
  String get refresh => '刷新';

  @override
  String get openInSystemBrowser => '在系统浏览器中打开';

  @override
  String get webViewCurrentUrlUnavailable => '当前 WebView 地址不可用或无效';

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
  String get logSearch => '搜索日志消息';

  @override
  String get logFilters => '筛选';

  @override
  String get logSources => '来源';

  @override
  String get logAllSources => '全部';

  @override
  String get logLevels => '级别';

  @override
  String get logSort => '排序';

  @override
  String get logNewest => '最新在前';

  @override
  String get logOldest => '最早在前';

  @override
  String get copyLog => '复制日志';

  @override
  String get copyFilteredLogs => '复制筛选结果';

  @override
  String get noFilteredLogs => '没有匹配的日志';

  @override
  String get logLevelDebug => '调试';

  @override
  String get logLevelInfo => '信息';

  @override
  String get logLevelWarning => '警告';

  @override
  String get logLevelError => '错误';

  @override
  String get current => '当前';

  @override
  String get history => '历史';

  @override
  String get noHistory => '暂无历史记录';

  @override
  String get historyLoadError => '无法加载历史记录';

  @override
  String get logEvents => '条日志';

  @override
  String get back => '返回';

  @override
  String get forward => '前进';

  @override
  String get deleteRun => '删除运行记录';

  @override
  String get clearHistory => '清空历史';

  @override
  String get undo => '撤销';

  @override
  String get unsavedChanges => '有未保存的更改，是否继续？';

  @override
  String get recentlyDeleted => '已删除';

  @override
  String get previousPage => '上一页';

  @override
  String get nextPage => '下一页';

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
  String get startBackend => '启动 Backend';

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
  String get apiFieldsSummary => '主机、端口、合并、路径、CORS';

  @override
  String get apiHost => 'API 主机';

  @override
  String get apiPort => 'API 端口';

  @override
  String get frontendBackendPath => '前端 Backend 路径';

  @override
  String get regenerateBackendPath => '重新生成';

  @override
  String get corsAllowedOrigins => '允许的 CORS 来源';

  @override
  String get unsaved => '未保存';

  @override
  String get inherit => '继承';

  @override
  String get enabled => '开启';

  @override
  String get disabled => '关闭';

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
  String get appearanceLanguageHeading => '外观与语言';

  @override
  String get runtimeHeading => '运行';

  @override
  String get desktopBehaviorHeading => '桌面行为';

  @override
  String get open => '打开';

  @override
  String get themeHeading => '主题';

  @override
  String get languageHeading => '语言';

  @override
  String get themeSubtitle => '即时预览主题变化，使用保存按钮保留当前设置。';

  @override
  String get languageSubtitle => '即时预览界面语言变化，使用保存按钮保留当前设置。';

  @override
  String get closeBehaviorHeading => '关闭行为';

  @override
  String get closeBehaviorSubtitle => '控制点击窗口关闭按钮后的处理方式。';

  @override
  String get recentLogsSubtitle => '设置保留的最近日志数量，超出后自动清理旧日志。';

  @override
  String get saveAll => '全部保存';

  @override
  String get discard => '放弃更改';

  @override
  String get exitApp => '退出应用';

  @override
  String get closeToTray => '关闭到托盘';

  @override
  String get launchAtLoginHeading => '开机自启';

  @override
  String get launchAtLoginSubtitle => '登录系统后自动启动 SubDock。';

  @override
  String get startHiddenToTrayHeading => '启动时隐藏到托盘';

  @override
  String get startHiddenToTraySubtitle => '启动后不显示窗口，仅驻留系统托盘。';

  @override
  String get recentLogs => '最近日志条数';

  @override
  String get recentLogPresets => '选择预设条数';

  @override
  String get structuredEnvPrecedenceWarning => 'Backend 配置会覆盖高级 ENV 中同名的值。';

  @override
  String get languageFollowSystem => '跟随系统';

  @override
  String get checkForUpdates => '检查更新';

  @override
  String get update => '更新';

  @override
  String get rollback => '回滚';

  @override
  String get viewReleaseNotes => '查看发行说明';

  @override
  String get aboutSubDock => '关于 SubDock';

  @override
  String get aboutSubDockSubtitle => '版本、许可证和平台信息';

  @override
  String get aboutVersion => 'SubDock 版本';

  @override
  String get aboutBuildNumber => '构建号';

  @override
  String get aboutLicense => '许可证';

  @override
  String get aboutProjectHomepage => '项目主页';

  @override
  String get aboutOperatingSystem => '操作系统';

  @override
  String get aboutArchitecture => '架构';

  @override
  String get aboutMetadataLoading => '正在加载应用信息…';

  @override
  String get aboutMetadataUnavailable => '无法获取应用信息';

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

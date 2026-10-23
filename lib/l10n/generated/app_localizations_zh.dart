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
  String get manage => 'Sub-Store';

  @override
  String get manageStartAndEnter => '启动并进入';

  @override
  String get manageLoadingSubStore => '正在加载 Sub-Store…';

  @override
  String get manageAuxiliaryUnavailable => '辅助服务不可用；订阅管理仍可使用。';

  @override
  String get manageBackendStillRunning =>
      '本地服务仍在运行；可以重试加载 Sub-Store，或在系统浏览器中打开。';

  @override
  String get manageServiceDetails => '服务详情';

  @override
  String get manageUnavailableTitle => '嵌入式 Sub-Store 暂不可用';

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
  String get componentInstalled => '已安装';

  @override
  String get serviceComponentsHeading => '组件与辅助服务';

  @override
  String get serviceOperationCompleted => '服务操作已完成。';

  @override
  String get serviceTitle => '服务';

  @override
  String get serviceOpenSubStore => '进入 Sub-Store';

  @override
  String get serviceStoppedTitle => '本地服务尚未启动';

  @override
  String get serviceStartingTitle => '正在启动本地服务';

  @override
  String get serviceRunningTitle => '本地服务正在运行';

  @override
  String get serviceStoppingTitle => '正在停止本地服务';

  @override
  String get serviceUnhealthyTitle => '服务响应异常';

  @override
  String get serviceCrashedTitle => '服务意外退出';

  @override
  String get serviceStoppedDescription => '启动后可使用订阅管理；已有配置与订阅数据仍保留。';

  @override
  String get serviceRunningDescription => '可以进入 Sub-Store 管理订阅。';

  @override
  String get serviceTransitionDescription => '正在处理，请稍候；切换页面不会重复执行操作。';

  @override
  String get serviceUnhealthyDescription =>
      '进程仍存在，但健康检查没有通过；不要重复启动。可以重启或先查看日志。';

  @override
  String get serviceCrashedDescription => '进程已退出，订阅处理暂不可用；查看原因后可重新启动。';

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
  String get availableVersionUnconfirmed => '尚未确认';

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
  String get updateAll => '全部更新';

  @override
  String get maintenanceDescription =>
      'SubDock 会协调停止服务、变更组件和恢复运行。后续步骤失败时，已成功变更的组件会保留。';

  @override
  String get maintenanceHeading => '组件维护';

  @override
  String get maintenancePreparing => '正在准备组件变更…';

  @override
  String get maintenanceStopping => '正在停止 Backend…';

  @override
  String get maintenanceUpdating => '正在变更组件…';

  @override
  String get maintenanceStarting => '正在使用已保存配置启动 Backend…';

  @override
  String get maintenanceCompleted => '组件维护已完成。';

  @override
  String get maintenanceFailed => '组件维护已停止，所选变更尚未全部完成。';

  @override
  String get maintenanceStartFailed => '组件文件已就绪，但 Backend 未能启动。';

  @override
  String get maintenanceInterrupted => '先前的组件操作意外中断。请检查剩余工作后再继续。';

  @override
  String get maintenanceAwaitingStart => '组件文件已就绪。准备好后可启动 Backend 以应用变更。';

  @override
  String get maintenanceBlocked => '组件维护恢复需要处理；Backend 启动已阻止。';

  @override
  String get maintenanceRetry => '重试剩余操作';

  @override
  String get maintenanceRetryStart => '重试启动 Backend';

  @override
  String get maintenanceTargetPending => '待处理';

  @override
  String get maintenanceTargetCompleted => '已完成';

  @override
  String get maintenanceTargetFailed => '失败';

  @override
  String get maintenanceRefreshFailed => '组件文件已变更，但无法刷新已安装版本。';

  @override
  String get maintenanceConfirmTitle => '确认组件变更';

  @override
  String maintenanceConfirmDescription(Object targets) {
    return '所选版本：$targets。SubDock 会按需停止 Backend；后续步骤失败时会保留已成功的变更。';
  }

  @override
  String get maintenanceRollbackDataWarning =>
      '回滚 Backend 时也会恢复关联的数据快照，可能覆盖该快照之后新增或修改的订阅。';

  @override
  String get maintenanceRecoveryBlocked =>
      '维护记录无效或与已安装组件文件不匹配。记录已保留以便恢复，不会自动更新组件或启动服务。';

  @override
  String get maintenanceRecoveryRevalidate => '重新验证恢复';

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
  String get confirmStopServiceTitle => '停止本地服务？';

  @override
  String get confirmStopServiceMessage => '订阅管理和前端访问将暂时中断；已保存的配置与订阅数据不会改变。';

  @override
  String get confirmRestartServiceTitle => '重启本地服务？';

  @override
  String get confirmRestartServiceMessage => '订阅管理和前端访问将短暂中断；服务会使用最新已保存配置重新启动。';

  @override
  String get viewLogs => '查看日志';

  @override
  String get minimizeTooltip => '最小化';

  @override
  String get maximizeTooltip => '最大化';

  @override
  String get restoreTooltip => '还原';

  @override
  String get closeTooltip => '关闭';

  @override
  String get exitConfirmationTitle => '退出 SubDock？';

  @override
  String get exitConfirmationMessage =>
      'SubDock 会先停止 Backend 再退出。你可以取消并继续当前工作。';

  @override
  String get retryExit => '重试退出';

  @override
  String get webView2Missing => '未检测到 Microsoft Edge WebView2 Runtime。请安装后重试。';

  @override
  String get webViewUnavailable => '此平台无法使用嵌入式浏览器，可改用系统浏览器打开 Sub-Store。';

  @override
  String get webViewMainFrameFailure => 'Sub-Store 页面加载失败。后端仍在运行；请重试或改用系统浏览器。';

  @override
  String get webViewLoadFailure => 'Sub-Store 页面无法加载。请重试或改用系统浏览器打开。';

  @override
  String get browserLaunchFailure => '无法打开系统浏览器。';

  @override
  String openSystemBrowserFailed(Object uri) {
    return '系统浏览器无法打开 $uri';
  }

  @override
  String get webViewActionFailure => '嵌入式浏览器无法完成此操作。';

  @override
  String get downloadFailed => '无法完成下载。';

  @override
  String downloadFailedHttp(Object statusCode) {
    return '下载失败：HTTP $statusCode';
  }

  @override
  String get blobExportInvalid => 'Blob 导出数据格式无效';

  @override
  String get blobExportFailed => '无法完成 Blob 导出';

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
  String get rollbackDataSnapshotMissing => '缺少此版本关联的数据快照；使用其他快照可能覆盖订阅数据。';

  @override
  String get rollbackComponentFilesMissing => '缺少此版本的组件文件。';

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
  String get logResetFilters => '重置筛选';

  @override
  String get logClearFilters => '清空全部筛选';

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
  String get logLoading => '正在读取日志…';

  @override
  String logVisibleCount(int count) {
    return '显示 $count 条日志';
  }

  @override
  String logRecordedCount(int count) {
    return '本次运行共记录 $count 条日志';
  }

  @override
  String logRangeLabel(int start, int end, int total) {
    return '第 $start–$end 条 / 共 $total 条匹配';
  }

  @override
  String logPageLabel(int page) {
    return '第 $page 页';
  }

  @override
  String get copyLog => '复制日志';

  @override
  String get copyFilteredLogs => '复制筛选结果';

  @override
  String get logCopySucceeded => '日志已复制到剪贴板。';

  @override
  String get logCopyFailed => '无法将日志复制到剪贴板。';

  @override
  String get logReadingPaused => '已暂停跟随，日志仍在记录；正在查看的列表暂不变动。';

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
  String historyCompletedCount(int count) {
    return '已结束的运行 · $count 次';
  }

  @override
  String get historyLoadError => '无法加载历史记录';

  @override
  String get historyActionError => '历史记录操作失败。重试以再次尝试。';

  @override
  String get retry => '重试';

  @override
  String get retrying => '正在重试…';

  @override
  String get logRecoveryFailed => '日志历史恢复失败。Backend 启动和自动清理已暂停。';

  @override
  String get logPersistenceFailed => '日志未能完整保存。本次运行的状态是否保存成功尚未确认。';

  @override
  String get logIntegrityUnknown => '日志完整性未验证';

  @override
  String get logIntegrityComplete => '日志捕获完整';

  @override
  String get logIntegrityIncomplete => '日志捕获不完整';

  @override
  String get logIntegrityRecovered => '已从中断状态恢复';

  @override
  String get logEvents => '条日志';

  @override
  String get pauseLogReading => '暂停阅读';

  @override
  String get resumeLogReading => '查看最新日志';

  @override
  String newLogCount(int count) {
    return '新增日志：$count';
  }

  @override
  String get confirmDeleteRun => '删除这次运行记录？';

  @override
  String get confirmDeleteRunMessage => '仅删除这次已结束的运行。最近一次删除可以撤销。';

  @override
  String get confirmClearHistory => '清空已结束的运行记录？';

  @override
  String get confirmClearHistoryMessage => '将删除所有已结束的运行记录。最近一次删除可以撤销。';

  @override
  String get deleteHistoryAction => '删除';

  @override
  String get componentMaintenanceActivity => '组件维护活动';

  @override
  String get maintenanceActivityPreparing => '正在准备组件';

  @override
  String get maintenanceActivityStopping => '正在停止 Backend';

  @override
  String get maintenanceActivityUpdating => '正在更新组件';

  @override
  String get maintenanceActivityStarting => '正在启动 Backend';

  @override
  String get maintenanceActivityCompleted => '维护已完成';

  @override
  String get maintenanceActivityFailed => '维护失败';

  @override
  String get maintenanceActivityStartFailed => 'Backend 启动失败';

  @override
  String get maintenanceActivityInterrupted => '维护已中断';

  @override
  String get maintenanceActivityAwaitingStart => '等待启动 Backend';

  @override
  String get maintenanceActivityBlocked => '维护已阻止';

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
  String logRunIdentity(Object runId) {
    return '运行 $runId';
  }

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
  String get themeSubtitleAutomatic => '选择后立即预览并自动记住，无需整页保存。';

  @override
  String get languageSubtitleAutomatic => '选择后立即切换并自动记住，无需整页保存。';

  @override
  String get closeBehaviorHeading => '关闭行为';

  @override
  String get closeBehaviorSubtitle => '控制点击窗口关闭按钮后的处理方式。';

  @override
  String get recentLogsSubtitle => '设置保留的最近日志数量，超出后自动清理旧日志。';

  @override
  String get saveAll => '全部保存';

  @override
  String get settingsLocalServiceHeading => '本地服务';

  @override
  String get settingsRuntimeConfigurationEntry => '编辑运行配置';

  @override
  String get settingsQuickAppearanceHeading => '界面与记录';

  @override
  String get settingsQuickDesktopHeading => '窗口与启动';

  @override
  String get settingsConfirmChangesTitle => '确认设置更改';

  @override
  String get autoSavePreferencesHeading => '自动保存本页设置';

  @override
  String get autoSavePreferencesEnabledSubtitle =>
      '外观、语言、最近日志和桌面行为会自动保存；运行配置需要单独保存。';

  @override
  String get autoSavePreferencesManualSubtitle => '在下方保存或撤销偏好更改；运行配置需要单独保存。';

  @override
  String get autoSavePreferencesSaving => '正在保存偏好设置…';

  @override
  String get preferenceSaveFailed => '设置保存失败；你的修改仍保留在此处。';

  @override
  String get retryPreferencesSave => '重试保存';

  @override
  String get recentLogRangeError => '请输入 50 到 2000 之间的整数。';

  @override
  String get runtimeSaveFailed => '运行配置保存失败；草稿仍保留在此处。';

  @override
  String get retrySave => '重试';

  @override
  String get saveRuntimeConfiguration => '保存运行配置';

  @override
  String get runtimeDraftPending => '运行配置有未保存的更改。';

  @override
  String get runtimeConfigurationStatus => '运行配置状态';

  @override
  String get runtimeConfigDraftStatus => '运行配置草稿尚未保存。';

  @override
  String get runtimeConfigSavedPending => '已保存的运行配置尚待应用。';

  @override
  String get runtimeConfigApplied => '已保存的运行配置正在使用。';

  @override
  String get runtimeConfigSavedForNextStart => '下次启动 Backend 时将使用已保存的运行配置。';

  @override
  String get runtimeCurrentConfiguration => '当前已应用';

  @override
  String get runtimeProposedConfiguration => '本次配置';

  @override
  String get runtimeNoAppliedConfiguration => '当前没有已应用的运行配置。';

  @override
  String get runtimePreviewUnavailable => '修正配置错误后即可预览本次运行配置。';

  @override
  String get runtimeSharedDraftScope =>
      '连接配置、HTTP-META 与高级 ENV 共用同一份草稿，并由同一组保存和撤销操作管理。';

  @override
  String get revertRuntimeDraft => '撤销运行草稿';

  @override
  String get confirmRevertRuntimeDraft =>
      '要将连接配置、HTTP-META 与高级 ENV 的修改全部恢复为上次保存的配置吗？';

  @override
  String get saveAndStartBackend => '保存并启动 Backend';

  @override
  String get saveAndRestartBackend => '保存并重启 Backend';

  @override
  String get confirmSaveAndStartBackend =>
      '保存连接配置、HTTP-META 与 ENV 草稿，然后使用该配置启动 Backend？';

  @override
  String get confirmSaveAndRestartBackend =>
      '保存连接配置、HTTP-META 与 ENV 草稿，然后使用该配置重启 Backend？';

  @override
  String get applySavedConfiguration => '应用已保存配置';

  @override
  String get runtimeApplyFailed => '运行配置未能应用；已保存的设置仍保留，可重试。';

  @override
  String get retryApplyRuntime => '重试应用';

  @override
  String get autostartApplyFailed => '已保存的登录启动偏好未能应用。';

  @override
  String get autostartUnsupported => '当前平台不支持登录时启动。';

  @override
  String get retryAutostart => '重试登录启动设置';

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
  String get aboutRetryMetadata => '重试加载信息';

  @override
  String get aboutProjectSourceTitle => '项目与组件来源';

  @override
  String get aboutSubStoreSource => 'Sub-Store 源码';

  @override
  String get aboutNodeSource => 'Node.js 源码';

  @override
  String get aboutHttpMetaSource => 'HTTP-META 源码';

  @override
  String get aboutMihomoSource => 'mihomo 源码';

  @override
  String get aboutViewLicenses => '查看许可证';

  @override
  String get aboutCopyDiagnostics => '复制诊断摘要';

  @override
  String get aboutDiagnosticsTitle => '诊断摘要';

  @override
  String get aboutDiagnosticsPrivacy =>
      '摘要仅包含允许公开的版本、平台、运行、维护和组件状态；不包含原始 ENV、订阅内容、入口密钥或原始异常。';

  @override
  String get aboutDiagnosticsCopied => '已复制诊断摘要';

  @override
  String get aboutClipboardFailed => '无法复制诊断摘要。';

  @override
  String get aboutProjectLinkOpened => '已请求打开项目页面。';

  @override
  String get aboutLicensesLoading => '正在加载许可证信息…';

  @override
  String get aboutLicensesUnavailable => '无法获取许可证信息。';

  @override
  String get aboutRetryLicenses => '重试加载许可证';

  @override
  String get aboutLicenseBack => '返回关于';

  @override
  String get runtimeValueCopied => '已复制运行信息';

  @override
  String get runtimeValueCopyFailed => '无法复制运行信息。';

  @override
  String get expand => '展开';

  @override
  String get collapse => '收起';

  @override
  String get aboutOpenLinkFailed => '无法打开项目页面。';

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
  String configErrorExitFailed(Object detail) {
    return 'SubDock 未能完成退出。窗口仍保持打开，可以重试。$detail';
  }

  @override
  String get trayShowWindow => '显示窗口';

  @override
  String get trayExit => '退出';
}

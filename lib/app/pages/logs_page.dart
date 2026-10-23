part of '../app.dart';

class _LogToolbarDropdown<T> extends StatelessWidget {
  const _LogToolbarDropdown({
    super.key,
    required this.hint,
    required this.options,
    required this.value,
    required this.itemLabel,
    required this.onChanged,
    this.includeAll = false,
    this.allLabel,
  });

  final String hint;
  final List<T> options;
  final T? value;
  final String Function(T item) itemLabel;
  final ValueChanged<T?> onChanged;
  final bool includeAll;
  final String? allLabel;

  @override
  Widget build(BuildContext context) {
    final selected = value == null ? null : value as T;
    return Semantics(
      label: hint,
      child: ShadSelect<T?>(
        initialValue: selected,
        minWidth: 160,
        maxWidth: 280,
        placeholder: Text(allLabel ?? hint),
        selectedOptionBuilder: (_, item) => Text(
          item == null ? (allLabel ?? hint) : itemLabel(item),
          overflow: TextOverflow.ellipsis,
        ),
        options: [
          if (includeAll)
            ShadOption<T?>(value: null, child: Text(allLabel ?? hint)),
          for (final option in options)
            ShadOption<T?>(value: option, child: Text(itemLabel(option))),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

enum _LogLevel { debug, info, warning, error }

enum _LogsMode { current, history }

class _ClassifiedLog {
  const _ClassifiedLog(this.log, this.source, this.level);

  final RuntimeLog log;
  final String source;
  final _LogLevel level;
}

_ClassifiedLog _classifyLog(RuntimeLog log) {
  final source = switch (log.source) {
    RuntimeLogSource.stdout || RuntimeLogSource.stderr => 'Backend',
    RuntimeLogSource.httpMetaStdout ||
    RuntimeLogSource.httpMetaStderr => 'HTTP-META',
  };
  final token = RegExp(
    r'(?<![A-Za-z0-9_])(trace|debug|info|warn|warning|error|fatal|panic)(?![A-Za-z0-9_])',
    caseSensitive: false,
  ).firstMatch(log.message)?.group(1)?.toLowerCase();
  final level = switch (token) {
    'trace' || 'debug' => _LogLevel.debug,
    'info' => _LogLevel.info,
    'warn' || 'warning' => _LogLevel.warning,
    'error' || 'fatal' || 'panic' => _LogLevel.error,
    _
        when log.source == RuntimeLogSource.stderr ||
            log.source == RuntimeLogSource.httpMetaStderr =>
      _LogLevel.error,
    _ => _LogLevel.info,
  };
  return _ClassifiedLog(log, source, level);
}

String _formatLog(_ClassifiedLog item, AppLocalizations l10n) {
  final now = DateTime.now();
  final local = item.log.timestamp.toLocal();
  final sameDay =
      now.year == local.year &&
      now.month == local.month &&
      now.day == local.day;
  final time = sameDay
      ? '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}'
      : '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  final level = switch (item.level) {
    _LogLevel.debug => l10n.logLevelDebug,
    _LogLevel.info => l10n.logLevelInfo,
    _LogLevel.warning => l10n.logLevelWarning,
    _LogLevel.error => l10n.logLevelError,
  };
  return '$time [${item.source}] [$level] ${item.log.message}';
}

class _LogsPage extends StatefulWidget {
  const _LogsPage({
    super.key,
    required this.reader,
    required this.historyRefreshGeneration,
    required this.historyMutationsEnabled,
    required this.logStore,
    required this.sort,
    required this.maintenanceActivity,
    required this.logRunUpdates,
    required this.retryingLogFinalizations,
    required this.onRetryLogFinalization,
    required this.onSortChanged,
  });

  final LogReaderState reader;
  final int historyRefreshGeneration;
  final bool historyMutationsEnabled;
  final RuntimeLogStore? logStore;
  final LogSort sort;
  final List<MaintenanceActivity> maintenanceActivity;
  final Map<String, RuntimeLogRunUpdate> logRunUpdates;
  final Set<String> retryingLogFinalizations;
  final Future<void> Function(String runId) onRetryLogFinalization;
  final Future<void> Function(LogSort) onSortChanged;

  @override
  State<_LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<_LogsPage> {
  final _query = TextEditingController();
  final _historyScroll = ScrollController();
  final _detailScroll = ScrollController();
  final _currentScroll = ScrollController();
  final _workspaceViewportKey = GlobalKey();
  final _latestLogKey = GlobalKey();
  // 来源/级别用单一选择(null = 全部),配合桌面三个独立下拉框。
  String? _source;
  _LogLevel? _level;
  var _mode = _LogsMode.current;
  var _historyListLoading = false;
  Object? _historyListError;
  Object? _historyActionError;
  var _historyDetailLoading = false;
  Object? _historyDetailError;
  List<RuntimeLogRun> _historyRuns = const [];
  RuntimeLogRun? _selectedRun;
  List<RuntimeLog> _historyLogs = const [];
  var _historyPage = 0;
  int? _historyMatchingCount;
  var _historyRetryPage = 0;
  var _historyHasNext = false;
  Future<void> Function()? _retryHistoryAction;
  var _historyListGeneration = 0;
  var _historyGeneration = 0;
  var _hasRecentDeletion = false;
  RuntimeLog? _lastCurrentLog;
  String? _lastCurrentRunId;
  var _feedbackGeneration = 0;
  Object? _copyError;

  @override
  void initState() {
    super.initState();
    _lastCurrentLog = widget.reader.visibleLogs.lastOrNull;
    _lastCurrentRunId = widget.reader.visibleRunId;
    _currentScroll.addListener(_pauseWhenAwayFromLatest);
  }

  @override
  void didUpdateWidget(covariant _LogsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sort != widget.sort && _selectedRun != null) {
      unawaited(_loadHistoryPage(_selectedRun!, page: 0));
    }
    if (oldWidget.historyRefreshGeneration != widget.historyRefreshGeneration &&
        _mode == _LogsMode.history) {
      unawaited(_loadHistoryRuns());
    }
    final currentLogs = widget.reader.visibleLogs;
    final currentRunId = widget.reader.visibleRunId;
    if (widget.reader.isFollowing &&
        (currentLogs.lastOrNull != _lastCurrentLog ||
            currentRunId != _lastCurrentRunId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToLatest();
      });
    }
    _lastCurrentLog = currentLogs.lastOrNull;
    _lastCurrentRunId = currentRunId;
  }

  @override
  void dispose() {
    _query.dispose();
    _currentScroll.removeListener(_pauseWhenAwayFromLatest);
    _currentScroll.dispose();
    _detailScroll.dispose();
    _historyScroll.dispose();
    super.dispose();
  }

  Future<void> _loadHistoryRuns() async {
    final store = widget.logStore;
    if (store == null) return;
    final generation = ++_historyListGeneration;
    setState(() => _historyListLoading = true);
    try {
      final runs = await store.listRuns();
      if (!mounted || generation != _historyListGeneration) return;
      setState(() {
        _historyRuns = runs;
        _historyListError = null;
      });
    } catch (error) {
      if (mounted && generation == _historyListGeneration) {
        setState(() => _historyListError = error);
      }
    } finally {
      if (mounted && generation == _historyListGeneration) {
        setState(() => _historyListLoading = false);
      }
    }
  }

  Future<void> _loadHistoryPage(RuntimeLogRun run, {required int page}) async {
    final store = widget.logStore;
    if (store == null) return;
    final generation = ++_historyGeneration;
    final previousPage = _historyPage;
    final newRun = _selectedRun?.id != run.id;
    final query = _query.text.toLowerCase();
    final source = _source;
    final level = _level;
    final sort = widget.sort;
    setState(() {
      _selectedRun = run;
      _historyDetailLoading = true;
      _historyDetailError = null;
      _historyMatchingCount = null;
      _historyRetryPage = page;
      if (newRun) {
        _historyLogs = const [];
        _historyHasNext = false;
        _historyPage = page;
      }
    });
    try {
      final pageLogs = <RuntimeLog>[];
      var matchingIndex = 0;
      await for (final log in store.readRunStream(
        run.id,
        reverse: sort == LogSort.newestFirst,
      )) {
        if (!mounted || generation != _historyGeneration) return;
        final classified = _classifyLog(log);
        final matches =
            (source == null || classified.source == source) &&
            (level == null || classified.level == level) &&
            log.message.toLowerCase().contains(query);
        if (!matches) continue;
        if (matchingIndex++ < page * 200) continue;
        if (pageLogs.length < 201) pageLogs.add(log);
      }
      if (!mounted || generation != _historyGeneration) return;
      setState(() {
        _historyPage = page;
        _historyMatchingCount = matchingIndex;
        _historyHasNext = pageLogs.length > 200;
        _historyLogs = pageLogs.take(200).toList();
      });
      if (newRun || page != previousPage) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_detailScroll.hasClients) _detailScroll.jumpTo(0);
        });
      }
    } catch (error) {
      if (mounted && generation == _historyGeneration) {
        setState(() => _historyDetailError = error);
      }
    } finally {
      if (mounted && generation == _historyGeneration) {
        setState(() => _historyDetailLoading = false);
      }
    }
  }

  Widget _buildHistoryList(AppLocalizations l10n) {
    if (_historyListLoading &&
        _historyListError == null &&
        _historyRuns.isEmpty &&
        !_hasRecentDeletion &&
        _historyActionError == null) {
      return Center(
        child: SizedBox(
          width: 240,
          child: ShadProgress(minHeight: 5, semanticsLabel: l10n.logLoading),
        ),
      );
    }
    if (_historyListError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_historyActionError != null) _buildHistoryActionError(l10n),
            Text(l10n.historyLoadError),
            ShadButton.ghost(
              key: const ValueKey('history-list-retry'),
              enabled: !_historyListLoading,
              onPressed: _historyListLoading
                  ? null
                  : () => unawaited(_loadHistoryRuns()),
              child: Text(l10n.retry),
            ),
          ],
        ),
      );
    }
    if (_historyRuns.isEmpty &&
        !_hasRecentDeletion &&
        _historyActionError == null) {
      return Center(child: Text(l10n.noHistory));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_historyActionError != null) _buildHistoryActionError(l10n),
        if (_historyListLoading)
          ShadProgress(minHeight: 4, semanticsLabel: l10n.logLoading),
        Padding(
          padding: EdgeInsets.all(
            Theme.of(context).extension<AppTypography>()!.spacingSm,
          ),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(l10n.historyCompletedCount(_historyRuns.length)),
              Wrap(
                spacing: Theme.of(context)
                    .extension<AppTypography>()!
                    .spacingXs,
                children: [
                  ShadButton.ghost(
                    enabled: !_historyListLoading,
                    onPressed: _historyListLoading
                        ? null
                        : () => unawaited(_loadHistoryRuns()),
                    child: Text(l10n.refresh),
                  ),
                  ShadButton.ghost(
                    enabled:
                        widget.historyMutationsEnabled &&
                        _historyRuns.isNotEmpty,
                    onPressed:
                        widget.historyMutationsEnabled &&
                            _historyRuns.isNotEmpty
                        ? () => unawaited(_clearHistory(l10n))
                        : null,
                    child: Text(l10n.clearHistory),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _historyScroll,
            itemCount: _historyRuns.length + (_hasRecentDeletion ? 1 : 0),
            itemBuilder: (context, index) {
              if (_hasRecentDeletion && index == 0) {
                return Padding(
                  key: const ValueKey('recently-deleted'),
                  padding: EdgeInsets.only(
                    bottom: Theme.of(context)
                        .extension<AppTypography>()!
                        .spacingSm,
                  ),
                  child: ShadCard(
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(l10n.recentlyDeleted),
                        ShadButton.outline(
                          enabled: widget.historyMutationsEnabled,
                          onPressed: widget.historyMutationsEnabled
                              ? () => unawaited(_undoDeletion())
                              : null,
                          child: Text(l10n.undo),
                        ),
                      ],
                    ),
                  ),
                );
              }
              final run = _historyRuns[index - (_hasRecentDeletion ? 1 : 0)];
              final typography = Theme.of(context).extension<AppTypography>()!;
              return Column(
                key: ValueKey('history-run-${run.id}'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.all(typography.spacingMd),
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      runSpacing: typography.spacingSm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _formatRunDate(run.start),
                              style: typography.titleSmall,
                            ),
                            Text(
                              '${_integrityLabel(run.integrity, l10n)} · ${_formatDuration(run)} · ${run.eventCount} ${l10n.logEvents}',
                              style: typography.bodySmall,
                            ),
                            Text(
                              l10n.logRunIdentity(run.id),
                              style: typography.bodySmall,
                            ),
                          ],
                        ),
                        Wrap(
                          spacing: typography.spacingXs,
                          children: [
                            ShadButton.ghost(
                              key: ValueKey('history-view-${run.id}'),
                              onPressed: () =>
                                  unawaited(_loadHistoryPage(run, page: 0)),
                              child: Semantics(
                                button: true,
                                enabled: true,
                                child: Text(l10n.open),
                              ),
                            ),
                            ShadTooltip(
                              builder: (_) => Text(l10n.deleteRun),
                              child: ShadIconButton.destructive(
                                key: ValueKey('history-delete-${run.id}'),
                                icon: Semantics(
                                  label: l10n.deleteRun,
                                  button: true,
                                  enabled: widget.historyMutationsEnabled,
                                  child: const Icon(Icons.delete_outline),
                                ),
                                enabled: widget.historyMutationsEnabled,
                                onPressed: widget.historyMutationsEnabled
                                    ? () => unawaited(_deleteRun(run, l10n))
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const ShadSeparator.horizontal(),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _logsPanel({
    required Widget child,
    required AppTypography typography,
  }) => ShadCard(
    key: const ValueKey('logs-surface'),
    padding: EdgeInsets.zero,
    radius: BorderRadius.circular(typography.radiusLg),
    backgroundColor: Theme.of(context).extension<AppColors>()!.surfaceLow,
    border: ShadBorder.all(
      color: Theme.of(context).extension<AppColors>()!.divider,
      width: 1,
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  Widget _buildHistoryActionError(AppLocalizations l10n) => Padding(
    key: const ValueKey('history-action-error'),
    padding: const EdgeInsets.all(12),
    child: Row(
      children: [
        Expanded(child: Text(l10n.historyActionError)),
        ShadButton.ghost(
          key: const ValueKey('history-action-retry'),
          enabled:
              widget.historyMutationsEnabled && _retryHistoryAction != null,
          onPressed:
              widget.historyMutationsEnabled && _retryHistoryAction != null
              ? () => unawaited(_retryHistoryAction!.call())
              : null,
          child: Text(l10n.retry),
        ),
      ],
    ),
  );

  Future<bool> _confirmHistoryAction(
    AppLocalizations l10n, {
    required String title,
    required String message,
  }) async =>
      await showShadDialog<bool>(
        context: context,
        builder: (context) => ShadDialog(
          title: Text(title),
          description: Text(message),
          actions: [
            ShadButton.ghost(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            ShadButton(
              key: const ValueKey('history-delete-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.deleteHistoryAction),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _deleteRun(RuntimeLogRun run, AppLocalizations l10n) async {
    final feedbackGeneration = _feedbackGeneration;
    final store = widget.logStore;
    if (store == null || !widget.historyMutationsEnabled) return;
    if (!await _confirmHistoryAction(
      l10n,
      title: l10n.confirmDeleteRun,
      message: l10n.confirmDeleteRunMessage,
    )) {
      return;
    }
    if (!mounted || !widget.historyMutationsEnabled) return;
    try {
      await store.deleteRun(run.id);
      _historyActionError = null;
      _retryHistoryAction = null;
      if (mounted) {
        setState(() {
          _hasRecentDeletion = true;
          if (_selectedRun?.id == run.id) {
            _historyGeneration++;
            _selectedRun = null;
            _historyLogs = const [];
            _historyDetailLoading = false;
            _historyDetailError = null;
          }
        });
      }
      await _loadHistoryRuns();
      if (mounted && feedbackGeneration == _feedbackGeneration) {
        _showDeletionSuccess(l10n);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _historyActionError = error;
          _retryHistoryAction = () => _deleteRun(run, l10n);
        });
      }
    }
  }

  Future<void> _clearHistory(AppLocalizations l10n) async {
    final feedbackGeneration = _feedbackGeneration;
    final store = widget.logStore;
    if (store == null ||
        !widget.historyMutationsEnabled ||
        _historyRuns.isEmpty ||
        !await _confirmHistoryAction(
          l10n,
          title: l10n.confirmClearHistory,
          message: l10n.confirmClearHistoryMessage,
        )) {
      return;
    }
    try {
      if (!mounted || !widget.historyMutationsEnabled) return;
      await store.clearHistory();
      _historyActionError = null;
      _retryHistoryAction = null;
      if (mounted) setState(() => _hasRecentDeletion = true);
      await _loadHistoryRuns();
      if (mounted && feedbackGeneration == _feedbackGeneration) {
        _showDeletionSuccess(l10n);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _historyActionError = error;
          _retryHistoryAction = () => _clearHistory(l10n);
        });
      }
    }
  }

  void _showDeletionSuccess(AppLocalizations l10n) {
    ShadToaster.of(context).show(
      ShadToast(
        alignment: Alignment.bottomRight,
        duration: const Duration(seconds: 4),
        showCloseIconOnlyWhenHovered: false,
        title: Semantics(
          container: true,
          liveRegion: true,
          child: Text(l10n.recentlyDeleted),
        ),
      ),
    );
  }

  Future<void> _undoDeletion() async {
    final store = widget.logStore;
    if (store == null || !widget.historyMutationsEnabled) return;
    try {
      await store.undoLastDeletion();
      _historyActionError = null;
      _retryHistoryAction = null;
      if (mounted) setState(() => _hasRecentDeletion = false);
      await _loadHistoryRuns();
    } catch (error) {
      if (mounted) {
        setState(() {
          _historyActionError = error;
          _retryHistoryAction = _undoDeletion;
        });
      }
    }
  }

  List<_ClassifiedLog> get _visible {
    final source = _selectedRun == null
        ? widget.reader.visibleLogs
        : _historyLogs;
    final result = source.map(_classifyLog).where(_matchesLog).toList();
    if (_selectedRun == null && widget.sort == LogSort.newestFirst) {
      return result.reversed.toList();
    }
    return result;
  }

  bool _matchesLog(_ClassifiedLog item) =>
      (_source == null || item.source == _source) &&
      (_level == null || item.level == _level) &&
      item.log.message.toLowerCase().contains(_query.text.toLowerCase());

  void _pauseWhenAwayFromLatest() {
    if (_programmaticScroll ||
        !widget.reader.isFollowing ||
        _mode != _LogsMode.current ||
        _selectedRun != null ||
        !_currentScroll.hasClients ||
        !_currentScroll.position.hasContentDimensions) {
      return;
    }
    final awayFromLatest = widget.sort == LogSort.newestFirst
        ? _currentScroll.offset > 24
        : _currentScroll.position.extentAfter > 24;
    if (awayFromLatest) setState(widget.reader.pause);
  }

  var _workspaceUserScrollActive = false;

  bool _handleWorkspaceScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is UserScrollNotification) {
      _workspaceUserScrollActive = notification.direction.name != 'idle';
      return false;
    }
    if (notification is! ScrollUpdateNotification) return false;
    final scrollDelta = notification.scrollDelta;
    if (_programmaticScroll ||
        !widget.reader.isFollowing ||
        _mode != _LogsMode.current ||
        _selectedRun != null ||
        (notification.dragDetails == null && !_workspaceUserScrollActive) ||
        scrollDelta == null ||
        scrollDelta == 0) {
      return false;
    }
    final movingAway = widget.sort == LogSort.newestFirst
        ? scrollDelta > 0
        : scrollDelta < 0;
    if (movingAway && !_isLatestEdgePhysicallyVisible()) {
      setState(widget.reader.pause);
    }
    return false;
  }

  bool _isLatestEdgePhysicallyVisible() {
    final latestContext = _latestLogKey.currentContext;
    final viewportContext = _workspaceViewportKey.currentContext;
    if (latestContext == null || viewportContext == null) return true;
    final latestObject = latestContext.findRenderObject();
    final viewportObject = viewportContext.findRenderObject();
    if (latestObject is! RenderBox ||
        viewportObject is! RenderBox ||
        !latestObject.hasSize ||
        !viewportObject.hasSize) {
      return true;
    }
    final latestRect =
        latestObject.localToGlobal(Offset.zero) & latestObject.size;
    final viewportRect =
        viewportObject.localToGlobal(Offset.zero) & viewportObject.size;
    final latestEdge = widget.sort == LogSort.newestFirst
        ? latestRect.top
        : latestRect.bottom;
    final edgeIsInsideViewport = widget.sort == LogSort.newestFirst
        ? latestEdge >= viewportRect.top && latestEdge < viewportRect.bottom
        : latestEdge > viewportRect.top && latestEdge <= viewportRect.bottom;
    return viewportRect.overlaps(latestRect) && edgeIsInsideViewport;
  }

  var _programmaticScroll = false;

  void _scrollToLatest() {
    if (!mounted ||
        !widget.reader.isFollowing ||
        _mode != _LogsMode.current ||
        _selectedRun != null ||
        !_currentScroll.hasClients) {
      return;
    }
    _programmaticScroll = true;
    try {
      final position = _currentScroll.position;
      final offset = widget.sort == LogSort.newestFirst
          ? 0.0
          : position.maxScrollExtent;
      _currentScroll.jumpTo(offset);
    } finally {
      _programmaticScroll = false;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !widget.reader.isFollowing ||
          _mode != _LogsMode.current ||
          _selectedRun != null) {
        return;
      }
      final latestContext = _latestLogKey.currentContext;
      if (latestContext == null) return;
      _programmaticScroll = true;
      try {
        unawaited(
          Scrollable.ensureVisible(
            latestContext,
            alignment: widget.sort == LogSort.newestFirst ? 0 : 1,
            duration: Duration.zero,
          ),
        );
      } finally {
        _programmaticScroll = false;
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _toggleFollowing() {
    setState(() {
      if (widget.reader.isFollowing) {
        widget.reader.pause();
      } else {
        widget.reader.resume();
      }
    });
    if (widget.reader.isFollowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToLatest();
      });
    }
  }

  void _setSource(String? source) {
    setState(() => _source = source);
    if (_selectedRun != null) {
      unawaited(_loadHistoryPage(_selectedRun!, page: 0));
    }
  }

  void _setLevel(_LogLevel? level) {
    setState(() => _level = level);
    if (_selectedRun != null) {
      unawaited(_loadHistoryPage(_selectedRun!, page: 0));
    }
  }

  void _resetFilters() {
    setState(() {
      _query.clear();
      _source = null;
      _level = null;
      if (_selectedRun == null) _historyPage = 0;
    });
    if (_selectedRun case final run?) {
      unawaited(_loadHistoryPage(run, page: 0));
    }
  }

  void _dismissFeedback() {
    _feedbackGeneration++;
    unawaited(ShadToaster.of(context).hide(animate: false));
  }

  void _showCopySuccess(AppLocalizations l10n) {
    ShadToaster.of(context).show(
      ShadToast(
        alignment: Alignment.bottomRight,
        duration: const Duration(seconds: 4),
        showCloseIconOnlyWhenHovered: false,
        title: Semantics(
          container: true,
          liveRegion: true,
          child: Text(l10n.logCopySucceeded),
        ),
      ),
    );
  }

  Future<void> _copy(
    AppLocalizations l10n,
    Iterable<_ClassifiedLog> logs,
  ) async {
    final generation = _feedbackGeneration;
    try {
      await Clipboard.setData(
        ClipboardData(
          text: logs.map((log) => _formatLog(log, l10n)).join('\n'),
        ),
      );
      if (!mounted) return;
      setState(() => _copyError = null);
      if (generation != _feedbackGeneration) return;
      _showCopySuccess(l10n);
    } on Object {
      if (mounted) setState(() => _copyError = l10n.logCopyFailed);
    }
  }

  Future<void> _copyFilteredHistory(AppLocalizations l10n) async {
    final store = widget.logStore;
    final run = _selectedRun;
    if (store == null || run == null) return;
    final generation = _historyGeneration;
    final feedbackGeneration = _feedbackGeneration;
    final query = _query.text.toLowerCase();
    final source = _source;
    final level = _level;
    final sort = widget.sort;
    bool matchesSnapshot(_ClassifiedLog item) =>
        (source == null || item.source == source) &&
        (level == null || item.level == level) &&
        item.log.message.toLowerCase().contains(query);
    final buffer = StringBuffer();
    try {
      var first = true;
      await for (final log in store.readRunStream(
        run.id,
        reverse: sort == LogSort.newestFirst,
      )) {
        final classified = _classifyLog(log);
        if (!matchesSnapshot(classified)) continue;
        if (!first) buffer.writeln();
        first = false;
        buffer.write(_formatLog(classified, l10n));
      }
    } on Object catch (error) {
      if (mounted && generation == _historyGeneration) {
        setState(() => _historyDetailError = error);
      }
      return;
    }
    if (!mounted || generation != _historyGeneration) return;
    try {
      await Clipboard.setData(ClipboardData(text: buffer.toString()));
      if (!mounted) return;
      setState(() => _copyError = null);
      if (feedbackGeneration == _feedbackGeneration) _showCopySuccess(l10n);
    } on Object {
      if (mounted) setState(() => _copyError = l10n.logCopyFailed);
    }
  }

  Future<void> _showFilters(AppLocalizations l10n) async {
    await showShadDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => ShadDialog(
          title: Text(l10n.logFilters),
          actions: [
            ShadButton.outline(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.back),
            ),
          ],
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.logSources),
                Wrap(
                  spacing: 8,
                  children: [
                    Semantics(
                      selected: _source == null,
                      inMutuallyExclusiveGroup: true,
                      child: ShadButton.raw(
                        key: const ValueKey('logs-source-all'),
                        variant: ShadButtonVariant.outline,
                        backgroundColor: _source == null
                            ? Theme.of(context)
                                  .extension<AppColors>()!
                                  .surfaceHigh
                            : null,
                        onPressed: () {
                          _setSource(null);
                          setDialogState(() {});
                        },
                        child: Text(l10n.logAllSources),
                      ),
                    ),
                    for (final source in const ['Backend', 'HTTP-META'])
                      Semantics(
                        selected: _source == source,
                        inMutuallyExclusiveGroup: true,
                        child: ShadButton.raw(
                          key: ValueKey('logs-source-$source'),
                          variant: ShadButtonVariant.outline,
                          backgroundColor: _source == source
                              ? Theme.of(context)
                                    .extension<AppColors>()!
                                    .surfaceHigh
                              : null,
                          onPressed: () {
                            _setSource(source);
                            setDialogState(() {});
                          },
                          child: Text(source),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(l10n.logLevels),
                Wrap(
                  spacing: 8,
                  children: [
                    Semantics(
                      selected: _level == null,
                      inMutuallyExclusiveGroup: true,
                      child: ShadButton.raw(
                        key: const ValueKey('logs-level-all'),
                        variant: ShadButtonVariant.outline,
                        backgroundColor: _level == null
                            ? Theme.of(context)
                                  .extension<AppColors>()!
                                  .surfaceHigh
                            : null,
                        onPressed: () {
                          _setLevel(null);
                          setDialogState(() {});
                        },
                        child: Text(l10n.logAllSources),
                      ),
                    ),
                    for (final level in _LogLevel.values)
                      Semantics(
                        selected: _level == level,
                        inMutuallyExclusiveGroup: true,
                        child: ShadButton.raw(
                          key: ValueKey('logs-level-${level.name}'),
                          variant: ShadButtonVariant.outline,
                          backgroundColor: _level == level
                              ? Theme.of(context)
                                    .extension<AppColors>()!
                                    .surfaceHigh
                              : null,
                          onPressed: () {
                            _setLevel(level);
                            setDialogState(() {});
                          },
                          child: Text(_levelLabel(l10n, level)),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                ShadSelect<LogSort>(
                  key: const ValueKey('logs-mobile-sort'),
                  initialValue: widget.sort,
                  placeholder: Text(l10n.logSort),
                  selectedOptionBuilder: (_, value) => Text(
                    value == LogSort.newestFirst
                        ? l10n.logNewest
                        : l10n.logOldest,
                  ),
                  options: [
                    ShadOption(
                      value: LogSort.newestFirst,
                      child: Text(l10n.logNewest),
                    ),
                    ShadOption(
                      value: LogSort.newestLast,
                      child: Text(l10n.logOldest),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) unawaited(widget.onSortChanged(value));
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _logTime(RuntimeLog log) {
    final local = log.timestamp.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
  }

  String _integrityLabel(
    RuntimeLogIntegrity integrity,
    AppLocalizations l10n,
  ) => switch (integrity) {
    RuntimeLogIntegrity.unknown => l10n.logIntegrityUnknown,
    RuntimeLogIntegrity.complete => l10n.logIntegrityComplete,
    RuntimeLogIntegrity.incomplete => l10n.logIntegrityIncomplete,
    RuntimeLogIntegrity.recovered => l10n.logIntegrityRecovered,
  };

  Widget _buildIntegrityNotice(
    RuntimeLogIntegrity integrity,
    AppLocalizations l10n, {
    RuntimeLogRunUpdate? update,
  }) {
    final retryAvailable = update?.retryAvailable ?? false;
    final retrying =
        update != null &&
        widget.retryingLogFinalizations.contains(update.runId);
    final message = update != null && !update.persistenceConfirmed
        ? l10n.logPersistenceFailed
        : _integrityLabel(integrity, l10n);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(message)),
          if (retryAvailable && update != null)
            ShadButton.ghost(
              key: const ValueKey('logs-retry-finalization'),
              enabled: !retrying,
              onPressed: retrying
                  ? null
                  : () =>
                        unawaited(widget.onRetryLogFinalization(update.runId)),
              child: Text(retrying ? l10n.retrying : l10n.retry),
            ),
        ],
      ),
    );
  }

  Widget _buildMaintenanceActivity(AppLocalizations l10n) {
    final activity = widget.maintenanceActivity.reversed.take(3).toList();
    final typography = Theme.of(context).extension<AppTypography>()!;
    final colors = Theme.of(context).extension<AppColors>()!;
    return Container(
      key: const ValueKey('logs-maintenance-activity'),
      margin: EdgeInsets.only(bottom: typography.spacingSm),
      padding: EdgeInsets.all(typography.spacingS),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(typography.radiusMd),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.componentMaintenanceActivity, style: typography.titleSmall),
          for (final item in activity)
            Padding(
              padding: EdgeInsets.only(top: typography.spacingXs),
              child: Text(
                '${_maintenancePhaseLabel(item.phase, l10n)}'
                '${item.kind == null ? '' : ' · ${item.kind == ComponentKind.backend ? l10n.backendComponent : l10n.frontendComponent}'}'
                ' · ${_formatClock(item.timestamp)}',
                style: typography.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchField(AppLocalizations l10n) => ShadInput(
    controller: _query,
    key: const ValueKey('logs-search'),
    placeholder: Text(l10n.logSearch),
    leading: const Icon(Icons.search, size: 18),
    onChanged: (_) {
      setState(() {});
      if (_selectedRun != null) {
        unawaited(_loadHistoryPage(_selectedRun!, page: 0));
      }
    },
  );

  Widget _logRow(
    BuildContext context,
    _ClassifiedLog item,
    AppLocalizations l10n,
    AppTypography typography,
    bool compact,
  ) {
    final level = _levelLabel(l10n, item.level);
    final colors = Theme.of(context).extension<AppColors>()!;
    final levelStyle = typography.codeSmall.copyWith(
      color: switch (item.level) {
        _LogLevel.debug => colors.onSurface,
        _LogLevel.info => colors.accent,
        _LogLevel.warning => colors.warning,
        _LogLevel.error => colors.error,
      },
    );
    final copy = ShadTooltip(
      builder: (_) => Text(l10n.copyLog),
      child: ShadIconButton.ghost(
        key: const ValueKey('logs-row-copy'),
        icon: Semantics(
          label: l10n.copyLog,
          button: true,
          enabled: true,
          child: const Icon(Icons.copy),
        ),
        iconSize: 18,
        width: 40,
        height: 40,
        onPressed: () => unawaited(_copy(l10n, [item])),
      ),
    );
    final message = SelectableText(
      item.log.message,
      key: const ValueKey('log-row-message'),
      style: typography.codeSmall,
    );
    if (compact) {
      return Container(
        key: const ValueKey('logs-mobile-row'),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
              child: Column(
                key: const ValueKey('logs-mobile-meta'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_logTime(item.log), style: typography.codeSmall),
                  SizedBox(height: typography.spacingXs),
                  Text(level, style: levelStyle),
                ],
              ),
            ),
            SizedBox(width: typography.spacingSm),
            Expanded(
              child: Column(
                key: const ValueKey('logs-mobile-content'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(item.source, style: typography.codeSmall),
                      ),
                      copy,
                    ],
                  ),
                  SizedBox(height: typography.spacingXs),
                  message,
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      key: const ValueKey('logs-desktop-row'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(_logTime(item.log), style: typography.codeSmall),
          ),
          SizedBox(
            width: 96,
            child: Text(item.source, style: typography.codeSmall),
          ),
          SizedBox(width: 72, child: Text(level, style: levelStyle)),
          Expanded(child: message),
          copy,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _buildWorkspace(context, constraints),
  );

  Widget _buildWorkspace(BuildContext context, BoxConstraints constraints) {
    final l10n = AppLocalizations.of(context)!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final visible = _visible;
    final visibleRunId = widget.reader.visibleRunId;
    final visibleRunUpdate = visibleRunId == null
        ? null
        : widget.logRunUpdates[visibleRunId];
    final compact = constraints.maxWidth < navigationBreakpoint;
    final bodyPadding = compact
        ? EdgeInsets.only(
            top: typography.spacingSm,
            left: typography.spacingSm,
            right: typography.spacingSm,
            bottom: typography.spacingLg,
          )
        : EdgeInsets.all(typography.spacingLg);
    final filterCount = (_source == null ? 0 : 1) + (_level == null ? 0 : 1);
    final hasFilters = _query.text.isNotEmpty || filterCount > 0;
    final workspaceHeight = constraints.maxHeight < 640
        ? 640.0
        : constraints.maxHeight;
    final workspace = Padding(
      key: const ValueKey('logs-body'),
      padding: bodyPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: typography.spacingS),
            child: Column(
              key: ValueKey(
                compact ? 'logs-mobile-toolbar' : 'logs-desktop-toolbar',
              ),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: typography.spacingXs,
                    children: [
                      for (final mode in _LogsMode.values)
                        ShadButton.raw(
                          variant: ShadButtonVariant.ghost,
                          backgroundColor: _mode == mode
                              ? Theme.of(context)
                                    .extension<AppColors>()!
                                    .surfaceHigh
                              : null,
                          onPressed: () {
                            if (mode == _mode) return;
                            setState(() {
                              _mode = mode;
                              _historyGeneration++;
                              _selectedRun = null;
                              _historyLogs = const [];
                              _historyDetailLoading = false;
                              _historyDetailError = null;
                            });
                            if (mode == _LogsMode.history) {
                              unawaited(_loadHistoryRuns());
                            }
                          },
                          child: Semantics(
                            button: true,
                            enabled: true,
                            selected: _mode == mode,
                            inMutuallyExclusiveGroup: true,
                            child: Text(
                              mode == _LogsMode.current
                                  ? l10n.current
                                  : l10n.history,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: typography.spacingSm),
                if (compact)
                  Row(
                    children: [
                      Expanded(child: _buildSearchField(l10n)),
                      SizedBox(width: typography.spacingSm),
                      ShadButton.outline(
                        key: const ValueKey('logs-mobile-filter'),
                        onPressed: () => unawaited(_showFilters(l10n)),
                        child: Text('${l10n.logFilters} · $filterCount'),
                      ),
                      if (hasFilters)
                        ShadTooltip(
                          builder: (_) => Text(l10n.logResetFilters),
                          child: ShadIconButton.ghost(
                            key: const ValueKey('logs-reset-filters'),
                            icon: Semantics(
                              label: l10n.logResetFilters,
                              button: true,
                              enabled: true,
                              child: const Icon(Icons.clear),
                            ),
                            onPressed: _resetFilters,
                          ),
                        ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(flex: 2, child: _buildSearchField(l10n)),
                      SizedBox(width: typography.spacingSm),
                      Expanded(
                        child: _LogToolbarDropdown<String>(
                          key: const ValueKey('logs-source-filter'),
                          hint: l10n.logSources,
                          options: const ['Backend', 'HTTP-META'],
                          value: _source,
                          includeAll: true,
                          allLabel: l10n.logAllSources,
                          itemLabel: (source) => source,
                          onChanged: _setSource,
                        ),
                      ),
                      SizedBox(width: typography.spacingSm),
                      Expanded(
                        child: _LogToolbarDropdown<String>(
                          key: const ValueKey('logs-level-filter'),
                          hint: l10n.logLevels,
                          options: [
                            for (final level in _LogLevel.values) level.name,
                          ],
                          value: _level?.name,
                          includeAll: true,
                          allLabel: l10n.logLevels,
                          itemLabel: (name) =>
                              _levelLabel(l10n, _LogLevel.values.byName(name)),
                          onChanged: (name) => _setLevel(
                            name == null ? null : _LogLevel.values.byName(name),
                          ),
                        ),
                      ),
                      SizedBox(width: typography.spacingSm),
                      Expanded(
                        child: _LogToolbarDropdown<LogSort>(
                          key: const ValueKey('logs-sort-selector'),
                          hint: l10n.logSort,
                          options: [LogSort.newestFirst, LogSort.newestLast],
                          value: widget.sort,
                          itemLabel: (value) => value == LogSort.newestFirst
                              ? l10n.logNewest
                              : l10n.logOldest,
                          onChanged: (value) {
                            if (value != null) {
                              unawaited(widget.onSortChanged(value));
                            }
                          },
                        ),
                      ),
                      if (hasFilters)
                        ShadButton.ghost(
                          key: const ValueKey('logs-reset-filters'),
                          onPressed: _resetFilters,
                          child: Text(l10n.logResetFilters),
                        ),
                    ],
                  ),
                if (_copyError != null)
                  Semantics(
                    liveRegion: true,
                    child: Padding(
                      padding: EdgeInsets.only(top: typography.spacingXs),
                      child: Text(l10n.logCopyFailed),
                    ),
                  ),
              ],
            ),
          ),
          if (widget.maintenanceActivity.isNotEmpty)
            _buildMaintenanceActivity(l10n),
          if (_mode == _LogsMode.history && _selectedRun == null)
            Expanded(
              child: _logsPanel(
                child: _buildHistoryList(l10n),
                typography: typography,
              ),
            )
          else
            Expanded(
              child: _logsPanel(
                typography: typography,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_selectedRun != null && _historyActionError != null)
                      _buildHistoryActionError(l10n),
                    Padding(
                      key: const ValueKey('logs-panel-header'),
                      padding: EdgeInsets.all(typography.spacingSm),
                      child: Wrap(
                        spacing: typography.spacingSm,
                        runSpacing: typography.spacingXs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          ShadTooltip(
                            builder: (_) => Text(
                              _selectedRun != null
                                  ? l10n.logRunIdentity(_selectedRun!.id)
                                  : visibleRunId != null
                                  ? l10n.logRunIdentity(visibleRunId)
                                  : l10n.current,
                            ),
                            child: Text(
                              _selectedRun == null
                                  ? l10n.current
                                  : _formatRunDate(_selectedRun!.start),
                              style: typography.titleSmall,
                            ),
                          ),
                          if (_selectedRun == null)
                            Text(
                              '${visible.length} / ${widget.reader.visibleLogs.length} ${l10n.logEvents}',
                              style: typography.bodySmall,
                            )
                          else ...[
                            ShadTooltip(
                              builder: (_) => Text(
                                l10n.logRecordedCount(_selectedRun!.eventCount),
                              ),
                              child: Text(
                                l10n.logVisibleCount(visible.length),
                                style: typography.bodySmall,
                              ),
                            ),
                            Text(
                              _formatDuration(_selectedRun!),
                              style: typography.bodySmall,
                            ),
                          ],
                          if (_selectedRun != null)
                            ShadButton.ghost(
                              key: const ValueKey('history-back'),
                              onPressed: () => setState(() {
                                _historyGeneration++;
                                _selectedRun = null;
                                _historyLogs = const [];
                                _historyDetailLoading = false;
                                _historyDetailError = null;
                              }),
                              child: Text(l10n.back),
                            ),
                          if (_selectedRun != null)
                            ShadButton.ghost(
                              key: const ValueKey('history-delete-detail'),
                              enabled: widget.historyMutationsEnabled,
                              onPressed: widget.historyMutationsEnabled
                                  ? () => unawaited(
                                      _deleteRun(_selectedRun!, l10n),
                                    )
                                  : null,
                              child: Text(l10n.deleteRun),
                            ),
                          if (_selectedRun == null &&
                              _mode == _LogsMode.current)
                            ShadButton.ghost(
                              key: const ValueKey('logs-follow-toggle'),
                              onPressed: _toggleFollowing,
                              child: Text(
                                widget.reader.isFollowing
                                    ? l10n.pauseLogReading
                                    : widget.reader.newLogCount == 0
                                    ? l10n.resumeLogReading
                                    : l10n.newLogCount(
                                        widget.reader.newLogCount,
                                      ),
                              ),
                            ),
                          ShadButton.outline(
                            key: const ValueKey('logs-copy-filtered'),
                            enabled: visible.isNotEmpty,
                            onPressed: visible.isEmpty
                                ? null
                                : () => unawaited(
                                    _selectedRun == null
                                        ? _copy(l10n, visible)
                                        : _copyFilteredHistory(l10n),
                                  ),
                            child: Text(l10n.copyFilteredLogs),
                          ),
                        ],
                      ),
                    ),
                    if (_selectedRun == null &&
                        !widget.reader.isFollowing &&
                        _mode == _LogsMode.current)
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          typography.spacingSm,
                          0,
                          typography.spacingSm,
                          typography.spacingSm,
                        ),
                        child: Text(l10n.logReadingPaused),
                      ),
                    if (_selectedRun != null)
                      _buildIntegrityNotice(_selectedRun!.integrity, l10n),
                    if (_selectedRun == null &&
                        _mode == _LogsMode.current &&
                        visibleRunUpdate != null)
                      _buildIntegrityNotice(
                        visibleRunUpdate.integrity,
                        l10n,
                        update: visibleRunUpdate,
                      ),
                    if (_selectedRun != null && _historyDetailError != null)
                      Padding(
                        padding: EdgeInsets.all(typography.spacingS),
                        child: Row(
                          children: [
                            Expanded(child: Text(l10n.historyLoadError)),
                            ShadButton.ghost(
                              enabled: !_historyDetailLoading,
                              onPressed: _historyDetailLoading
                                  ? null
                                  : () => unawaited(
                                      _loadHistoryPage(
                                        _selectedRun!,
                                        page: _historyRetryPage,
                                      ),
                                    ),
                              child: Text(l10n.retry),
                            ),
                          ],
                        ),
                      ),
                    const ShadSeparator.horizontal(),
                    Expanded(
                      child: _historyDetailLoading && _historyLogs.isEmpty
                          ? Center(
                              child: SizedBox(
                                width: 240,
                                child: ShadProgress(
                                  minHeight: 5,
                                  semanticsLabel: l10n.logLoading,
                                ),
                              ),
                            )
                          : visible.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _selectedRun == null
                                        ? (widget.reader.visibleLogs.isEmpty
                                              ? l10n.noLogs
                                              : l10n.noFilteredLogs)
                                        : (_selectedRun!.eventCount == 0
                                              ? l10n.noLogs
                                              : l10n.noFilteredLogs),
                                  ),
                                  if (hasFilters)
                                    ShadButton.ghost(
                                      key: const ValueKey('logs-clear-filters'),
                                      onPressed: _resetFilters,
                                      child: Text(l10n.logClearFilters),
                                    ),
                                ],
                              ),
                            )
                          : ListView.separated(
                              controller: _selectedRun == null
                                  ? _currentScroll
                                  : _detailScroll,
                              itemCount: visible.length,
                              separatorBuilder: (_, _) =>
                                  const ShadSeparator.horizontal(),
                              itemBuilder: (context, index) {
                                final item = visible[index];
                                final isLatestCurrentRow =
                                    _selectedRun == null &&
                                    index ==
                                        (widget.sort == LogSort.newestFirst
                                            ? 0
                                            : visible.length - 1);
                                return Padding(
                                  key: isLatestCurrentRow
                                      ? _latestLogKey
                                      : null,
                                  padding: EdgeInsets.symmetric(
                                    horizontal: typography.spacingSm,
                                    vertical: typography.spacingS,
                                  ),
                                  child: _logRow(
                                    context,
                                    item,
                                    l10n,
                                    typography,
                                    compact,
                                  ),
                                );
                              },
                            ),
                    ),
                    if (_selectedRun != null)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ShadButton.ghost(
                            enabled: _historyPage > 0,
                            onPressed: _historyPage > 0
                                ? () => unawaited(
                                    _loadHistoryPage(
                                      _selectedRun!,
                                      page: _historyPage - 1,
                                    ),
                                  )
                                : null,
                            child: Text(l10n.previousPage),
                          ),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(l10n.logPageLabel(_historyPage + 1)),
                                if (_historyMatchingCount case final count?)
                                  Text(
                                    l10n.logRangeLabel(
                                      _historyLogs.isEmpty
                                          ? 0
                                          : _historyPage * 200 + 1,
                                      _historyLogs.isEmpty
                                          ? 0
                                          : _historyPage * 200 +
                                                _historyLogs.length,
                                      count,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                              ],
                            ),
                          ),
                          ShadButton.ghost(
                            enabled: _historyHasNext,
                            onPressed: _historyHasNext
                                ? () => unawaited(
                                    _loadHistoryPage(
                                      _selectedRun!,
                                      page: _historyPage + 1,
                                    ),
                                  )
                                : null,
                            child: Text(l10n.nextPage),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    return NotificationListener<ScrollNotification>(
      onNotification: _handleWorkspaceScroll,
      child: SingleChildScrollView(
        key: _workspaceViewportKey,
        child: SizedBox(height: workspaceHeight, child: workspace),
      ),
    );
  }
}

String _maintenancePhaseLabel(MaintenancePhase phase, AppLocalizations l10n) =>
    switch (phase) {
      MaintenancePhase.preparing => l10n.maintenanceActivityPreparing,
      MaintenancePhase.stopping => l10n.maintenanceActivityStopping,
      MaintenancePhase.updating => l10n.maintenanceActivityUpdating,
      MaintenancePhase.starting => l10n.maintenanceActivityStarting,
      MaintenancePhase.completed => l10n.maintenanceActivityCompleted,
      MaintenancePhase.failed => l10n.maintenanceActivityFailed,
      MaintenancePhase.startFailed => l10n.maintenanceActivityStartFailed,
      MaintenancePhase.interrupted => l10n.maintenanceActivityInterrupted,
      MaintenancePhase.awaitingStart => l10n.maintenanceActivityAwaitingStart,
      MaintenancePhase.blocked => l10n.maintenanceActivityBlocked,
    };

String _formatClock(DateTime value) {
  final local = value.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
}

String _levelLabel(AppLocalizations l10n, _LogLevel level) => switch (level) {
  _LogLevel.debug => l10n.logLevelDebug,
  _LogLevel.info => l10n.logLevelInfo,
  _LogLevel.warning => l10n.logLevelWarning,
  _LogLevel.error => l10n.logLevelError,
};

String _formatRunDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

String _formatDuration(RuntimeLogRun run) {
  final duration = (run.end ?? run.start).difference(run.start);
  final seconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  return '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${((seconds % 3600) ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

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
    final typography = Theme.of(context).extension<AppTypography>()!;
    final items = <DropdownMenuItem<T?>>[];
    if (includeAll) {
      items.add(
        DropdownMenuItem<T?>(
          value: null,
          child: Text(allLabel ?? hint),
        ),
      );
    }
    for (final option in options) {
      items.add(
        DropdownMenuItem<T?>(
          value: option,
          child: Text(itemLabel(option), overflow: TextOverflow.ellipsis),
        ),
      );
    }
    return InputDecorator(
          decoration: InputDecoration(
            // 与搜索框(48px)等高:下拉框内部采用稍高的垂直内边距,触控高度不再局促。
            contentPadding: EdgeInsets.symmetric(vertical: typography.spacingSm),
          ),
          child: DropdownButtonHideUnderline(
            child: Semantics(
              label: hint,
              button: true,
              child: DropdownButton<T?>(
                value: value,
                isExpanded: true,
                isDense: true,
                hint: Text(
                  value == null
                      ? (allLabel ?? hint)
                      : itemLabel(value as T),
                  overflow: TextOverflow.ellipsis,
                ),
                items: items,
                onChanged: (v) {
                  if (v != null || includeAll) onChanged(v);
                },
              ),
            ),
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
    required this.logs,
    required this.historyRefreshGeneration,
    required this.logStore,
    required this.sort,
    required this.entryGeneration,
    required this.onSortChanged,
  });

  final List<RuntimeLog> logs;
  final int historyRefreshGeneration;
  final RuntimeLogStore? logStore;
  final LogSort sort;
  final int entryGeneration;
  final Future<void> Function(LogSort) onSortChanged;

  @override
  State<_LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<_LogsPage> {
  final _query = TextEditingController();
  final _historyScroll = ScrollController();
  // 来源/级别用单一选择(null = 全部),配合桌面三个独立下拉框。
  String? _source;
  _LogLevel? _level;
  var _mode = _LogsMode.current;
  var _historyListLoading = false;
  Object? _historyListError;
  var _historyDetailLoading = false;
  Object? _historyDetailError;
  List<RuntimeLogRun> _historyRuns = const [];
  RuntimeLogRun? _selectedRun;
  List<RuntimeLog> _historyLogs = const [];
  var _historyPage = 0;
  var _historyHasNext = false;
  var _historyListGeneration = 0;
  var _historyGeneration = 0;
  var _hasRecentDeletion = false;

  @override
  void didUpdateWidget(covariant _LogsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entryGeneration != widget.entryGeneration) {
      _query.clear();
      _source = null;
      _level = null;
      _mode = _LogsMode.current;
      _selectedRun = null;
      _historyGeneration++;
      _historyDetailLoading = false;
      _historyLogs = const [];
      _historyDetailError = null;
    }
    if (oldWidget.sort != widget.sort && _selectedRun != null) {
      unawaited(_loadHistoryPage(_selectedRun!, page: 0));
    }
    if (oldWidget.historyRefreshGeneration != widget.historyRefreshGeneration &&
        _mode == _LogsMode.history) {
      unawaited(_loadHistoryRuns());
    }
  }

  @override
  void dispose() {
    _query.dispose();
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
    setState(() {
      _selectedRun = run;
      _historyDetailLoading = true;
      _historyDetailError = null;
      _historyLogs = const [];
      _historyPage = page;
      _historyHasNext = false;
    });
    try {
      final pageLogs = <RuntimeLog>[];
      var matchingIndex = 0;
      await for (final log in store.readRunStream(
        run.id,
        reverse: widget.sort == LogSort.newestFirst,
      )) {
        final classified = _classifyLog(log);
        if (!_matchesLog(classified)) continue;
        if (matchingIndex++ < page * 200) continue;
        if (pageLogs.length < 201) pageLogs.add(log);
        if (pageLogs.length == 201) break;
      }
      if (!mounted || generation != _historyGeneration) return;
      setState(() {
        _historyPage = page;
        _historyHasNext = pageLogs.length > 200;
        _historyLogs = pageLogs.take(200).toList();
      });
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
    if (_historyListLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_historyListError != null) {
      return Center(child: Text(l10n.historyLoadError));
    }
    if (_historyRuns.isEmpty && !_hasRecentDeletion) {
      return Center(child: Text(l10n.noHistory));
    }
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => unawaited(_clearHistory(l10n)),
            child: Text(l10n.clearHistory),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _historyScroll,
            itemCount: _historyRuns.length + (_hasRecentDeletion ? 1 : 0),
            itemBuilder: (context, index) {
              if (_hasRecentDeletion && index == 0) {
                return ListTile(
                  key: const ValueKey('recently-deleted'),
                  title: Text(l10n.recentlyDeleted),
                  trailing: TextButton(
                    onPressed: () => unawaited(_undoDeletion()),
                    child: Text(l10n.undo),
                  ),
                );
              }
              final run = _historyRuns[index - (_hasRecentDeletion ? 1 : 0)];
              return ListTile(
                key: ValueKey('history-run-${run.id}'),
                title: Text(_formatRunDate(run.start)),
                subtitle: Text(
                  '${_formatDuration(run)} · ${run.eventCount} ${l10n.logEvents}',
                ),
                trailing: IconButton(
                  tooltip: l10n.deleteRun,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => unawaited(_deleteRun(run, l10n)),
                ),
                onTap: () => unawaited(_loadHistoryPage(run, page: 0)),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _deleteRun(RuntimeLogRun run, AppLocalizations l10n) async {
    final store = widget.logStore;
    if (store == null) return;
    try {
      await store.deleteRun(run.id);
      if (mounted) setState(() => _hasRecentDeletion = true);
      await _loadHistoryRuns();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.recentlyDeleted),
            action: SnackBarAction(
              label: l10n.undo,
              onPressed: () => unawaited(_undoDeletion()),
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _historyListError = error);
    }
  }

  Future<void> _clearHistory(AppLocalizations l10n) async {
    final store = widget.logStore;
    if (store == null || _historyRuns.isEmpty) return;
    try {
      await store.clearHistory();
      if (mounted) setState(() => _hasRecentDeletion = true);
      await _loadHistoryRuns();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.recentlyDeleted),
            action: SnackBarAction(
              label: l10n.undo,
              onPressed: () => unawaited(_undoDeletion()),
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _historyListError = error);
    }
  }

  Future<void> _undoDeletion() async {
    final store = widget.logStore;
    if (store == null) return;
    try {
      await store.undoLastDeletion();
      if (mounted) setState(() => _hasRecentDeletion = false);
      await _loadHistoryRuns();
    } catch (error) {
      if (mounted) setState(() => _historyListError = error);
    }
  }

  List<_ClassifiedLog> get _visible {
    final source = _selectedRun == null ? widget.logs : _historyLogs;
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

  Future<void> _copy(
    AppLocalizations l10n,
    Iterable<_ClassifiedLog> logs,
  ) async {
    await Clipboard.setData(
      ClipboardData(text: logs.map((log) => _formatLog(log, l10n)).join('\n')),
    );
  }

  Future<void> _copyFilteredHistory(AppLocalizations l10n) async {
    final store = widget.logStore;
    final run = _selectedRun;
    if (store == null || run == null) return;
    final query = _query.text.toLowerCase();
    final source = _source;
    final level = _level;
    bool matchesSnapshot(_ClassifiedLog item) =>
        (source == null || item.source == source) &&
        (level == null || item.level == level) &&
        item.log.message.toLowerCase().contains(query);
    final buffer = StringBuffer();
    var first = true;
    await for (final log in store.readRunStream(
      run.id,
      reverse: widget.sort == LogSort.newestFirst,
    )) {
      final classified = _classifyLog(log);
      if (!matchesSnapshot(classified)) continue;
      if (!first) buffer.writeln();
      first = false;
      buffer.write(_formatLog(classified, l10n));
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
  }

  Future<void> _showFilters(AppLocalizations l10n) async {
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l10n.logFilters),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.logSources),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      key: const ValueKey('logs-source-all'),
                      label: Text(l10n.logAllSources),
                      selected: _source == null,
                      onSelected: (_) {
                        _setSource(null);
                        setDialogState(() {});
                      },
                    ),
                    for (final source in const ['Backend', 'HTTP-META'])
                      ChoiceChip(
                        key: ValueKey('logs-source-$source'),
                        label: Text(source),
                        selected: _source == source,
                        onSelected: (_) {
                          _setSource(source);
                          setDialogState(() {});
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(l10n.logLevels),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      key: const ValueKey('logs-level-all'),
                      label: Text(l10n.logAllSources),
                      selected: _level == null,
                      onSelected: (_) {
                        _setLevel(null);
                        setDialogState(() {});
                      },
                    ),
                    for (final level in _LogLevel.values)
                      ChoiceChip(
                        key: ValueKey('logs-level-${level.name}'),
                        label: Text(_levelLabel(l10n, level)),
                        selected: _level == level,
                        onSelected: (_) {
                          _setLevel(level);
                          setDialogState(() {});
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<LogSort>(
                  key: const ValueKey('logs-mobile-sort'),
                  initialValue: widget.sort,
                  decoration: InputDecoration(labelText: l10n.logSort),
                  items: [
                    DropdownMenuItem(
                      value: LogSort.newestFirst,
                      child: Text(l10n.logNewest),
                    ),
                    DropdownMenuItem(
                      value: LogSort.newestLast,
                      child: Text(l10n.logOldest),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      unawaited(widget.onSortChanged(value));
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.back),
            ),
          ],
        ),
      ),
    );
  }

  String _logTime(RuntimeLog log) {
    final local = log.timestamp.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
  }

  Widget _buildSearchField(AppLocalizations l10n) => TextField(
    controller: _query,
    key: const ValueKey('logs-search'),
    onChanged: (_) {
      setState(() {});
      if (_selectedRun != null) {
        unawaited(_loadHistoryPage(_selectedRun!, page: 0));
      }
    },
    decoration: InputDecoration(
      hintText: l10n.logSearch,
      prefixIcon: const Icon(Icons.search),
    ),
  );

  Widget _logRow(
    BuildContext context,
    _ClassifiedLog item,
    AppLocalizations l10n,
    AppTypography typography,
  ) {
    final compact = MediaQuery.sizeOf(context).width < navigationBreakpoint;
    final level = _levelLabel(l10n, item.level);
    final copy = IconButton(
      tooltip: l10n.copyLog,
      icon: const Icon(Icons.copy, size: 18),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      onPressed: () => unawaited(_copy(l10n, [item])),
    );
    final message = SelectableText(
      item.log.message,
      key: const ValueKey('log-row-message'),
      style: typography.bodySmall.copyWith(fontFamily: 'monospace'),
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
                  Text(
                    _logTime(item.log),
                    style: typography.bodySmall.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                  SizedBox(height: typography.spacingXs),
                  Text(
                    level,
                    style: typography.bodySmall.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
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
                        child: Text(
                          item.source,
                          style: typography.bodySmall.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
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
            child: Text(
              _logTime(item.log),
              style: typography.bodySmall.copyWith(fontFamily: 'monospace'),
            ),
          ),
          SizedBox(
            width: 96,
            child: Text(
              item.source,
              style: typography.bodySmall.copyWith(fontFamily: 'monospace'),
            ),
          ),
          SizedBox(
            width: 72,
            child: Text(
              level,
              style: typography.bodySmall.copyWith(fontFamily: 'monospace'),
            ),
          ),
          Expanded(child: message),
          copy,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final typography = Theme.of(context).extension<AppTypography>()!;
    final visible = _visible;
    final compact = MediaQuery.sizeOf(context).width < navigationBreakpoint;
    final bodyPadding = compact
        ? EdgeInsets.only(
            top: typography.spacingSm,
            left: typography.spacingSm,
            right: typography.spacingSm,
            bottom: typography.spacingLg,
          )
        : EdgeInsets.all(typography.spacingLg);
    final filterCount = (_source == null ? 0 : 1) + (_level == null ? 0 : 1);
    return Padding(
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
                  child: SegmentedButton<_LogsMode>(
                    segments: [
                      ButtonSegment(
                        value: _LogsMode.current,
                        label: Text(l10n.current),
                      ),
                      ButtonSegment(
                        value: _LogsMode.history,
                        label: Text(l10n.history),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (value) {
                      final next = value.first;
                      if (next == _mode) return;
                      setState(() {
                        _mode = next;
                        _historyGeneration++;
                        _selectedRun = null;
                        _historyLogs = const [];
                        _historyDetailLoading = false;
                        _historyDetailError = null;
                      });
                      if (next == _LogsMode.history) {
                        unawaited(_loadHistoryRuns());
                      }
                    },
                  ),
                ),
                SizedBox(height: typography.spacingSm),
                if (compact)
                  Row(
                    children: [
                      Expanded(child: _buildSearchField(l10n)),
                      SizedBox(width: typography.spacingSm),
                      OutlinedButton(
                        key: const ValueKey('logs-mobile-filter'),
                        onPressed: () => unawaited(_showFilters(l10n)),
                        child: Text('${l10n.logFilters} · $filterCount'),
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
                          itemLabel: (name) => _levelLabel(l10n, _LogLevel.values.byName(name)),
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
                          itemLabel: (value) =>
                              value == LogSort.newestFirst
                                  ? l10n.logNewest
                                  : l10n.logOldest,
                          onChanged: (value) {
                            if (value != null) {
                              unawaited(widget.onSortChanged(value));
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const ValueKey('logs-copy-filtered'),
                    onPressed: visible.isEmpty
                        ? null
                        : () => unawaited(
                            _selectedRun == null
                                ? _copy(l10n, visible)
                                : _copyFilteredHistory(l10n),
                          ),
                    child: Text(l10n.copyFilteredLogs),
                  ),
                ),
              ],
            ),
          ),
          if (_mode == _LogsMode.history && _selectedRun == null)
            Expanded(
              child: _SurfacePanel(
                key: const ValueKey('logs-surface'),
                padding: EdgeInsets.zero,
                radius: typography.radiusLg,
                clipBehavior: Clip.antiAlias,
                child: _buildHistoryList(l10n),
              ),
            )
          else
            Expanded(
              child: _SurfacePanel(
                key: const ValueKey('logs-surface'),
                padding: EdgeInsets.zero,
                radius: typography.radiusLg,
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_selectedRun != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
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
                      ),
                    const Divider(height: 1),
                    Expanded(
                      child: _historyDetailLoading
                          ? const Center(child: CircularProgressIndicator())
                          : _selectedRun != null && _historyDetailError != null
                          ? Center(child: Text(l10n.historyLoadError))
                          : visible.isEmpty
                          ? Center(
                              child: Text(
                                _selectedRun == null
                                    ? (widget.logs.isEmpty
                                          ? l10n.noLogs
                                          : l10n.noFilteredLogs)
                                    : (_selectedRun!.eventCount == 0
                                          ? l10n.noLogs
                                          : l10n.noFilteredLogs),
                              ),
                            )
                          : ListView.separated(
                              itemCount: visible.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final item = visible[index];
                                return Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: typography.spacingSm,
                                    vertical: typography.spacingS,
                                  ),
                                  child: _logRow(
                                    context,
                                    item,
                                    l10n,
                                    typography,
                                  ),
                                );
                              },
                            ),
                    ),
                    if (_selectedRun != null)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton(
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
                          TextButton(
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
  }
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

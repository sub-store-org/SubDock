import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart'
    show
        Brightness,
        DropdownButton,
        FilterChip,
        FilledButton,
        Locale,
        ListTile,
        ListView,
        NavigationBar,
        OutlinedButton,
        SelectableText,
        SegmentedButton,
        SwitchListTile,
        Theme,
        ThemeMode,
        TextField,
        ValueNotifier;
import 'package:flutter/scheduler.dart' show AppLifecycleState;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show GestureDetector, Offstage, Scrollable, SizedBox, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/app.dart';
import 'package:subdock/app/app_coordinator.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/runtime/runtime_log_store.dart';
import 'package:subdock/settings/backend_env_store.dart';
import 'package:subdock/settings/config_error.dart';
import 'package:subdock/settings/desktop_preferences.dart';
import 'package:subdock/settings/desktop_preferences_store.dart';
import 'package:subdock/settings/subdock_config_store.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_update_checker.dart';
import 'package:subdock/update/component_update_service.dart';

void main() {
  testWidgets('runtime controls the backend through its abstraction', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final runtime = _FakeBackendRuntime();
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories!),
    );
    await tester.binding.setSurfaceSize(const Size(600, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );

    expect(find.byKey(const ValueKey('desktop-chrome')), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-sidebar')), findsOneWidget);
    expect(find.byKey(const ValueKey('page-title')), findsOneWidget);

    final managementPage = find.byKey(const ValueKey('page-manage'));
    expect(managementPage, findsOneWidget);
    expect(tester.widget<Offstage>(managementPage).offstage, isTrue);
    expect(find.text('已停止'), findsOneWidget);
    expect(find.text('Node'), findsOneWidget);
    expect(find.text('Backend'), findsOneWidget);
    expect(find.text('Port'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '启动'))
          .onPressed,
      isNotNull,
    );

    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '启动'))
        .onPressed!();
    await tester.pump(const Duration(milliseconds: 1));

    expect(runtime.starts, 1);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('v24.20.0'), findsOneWidget);
    expect(find.text('fixture-backend'), findsOneWidget);
    expect(find.text('3001'), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '停止'))
        .onPressed!();
    await tester.pump(const Duration(milliseconds: 1));

    expect(runtime.stops, 1);
    expect(find.text('已停止'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('app stops the runtime when it detaches', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final runtime = _FakeBackendRuntime();
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories!),
    );

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pump();

    expect(runtime.stops, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manage recovery uses the shell surface', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories!),
    );

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    await tester.pump();
    expect(find.byKey(const ValueKey('manage-recovery')), findsOneWidget);
    expect(find.text('Backend 未运行'), findsOneWidget);
    expect(find.text('查看概览'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '查看概览'));
    await tester.pump();
    expect(
      tester
          .widget<Offstage>(find.byKey(const ValueKey('page-manage')))
          .offstage,
      isTrue,
    );
    expect(
      tester
          .widget<Offstage>(find.byKey(const ValueKey('page-overview')))
          .offstage,
      isFalse,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('saving SubDock configuration does not restart the runtime', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final runtime = _FakeBackendRuntime();
    final store = SubDockConfigStore(directories!);
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      configurationStore: store,
    );

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, '启用 HTTP-META'));
    await tester.pump();

    final save = find.widgetWithText(FilledButton, '保存 SubDock 配置');
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.pump();
    await _pumpRealIo(tester);

    final saved = await tester.runAsync(store.load);
    expect(saved!.httpMeta.enabled, isFalse);
    expect(find.text('SubDock 配置已保存；不会自动重启服务。'), findsOneWidget);
    expect(runtime.restarts, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('logs surface renders empty and live log states', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final runtime = _FakeBackendRuntime();
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories!),
    );

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();

    expect(find.byKey(const ValueKey('overview-recent-logs')), findsNothing);
    expect(find.byKey(const ValueKey('logs-surface')), findsOneWidget);
    expect(find.text('暂无日志'), findsOneWidget);
    runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.utc(2026, 9, 13, 4, 30),
        source: RuntimeLogSource.stdout,
        message: 'fixture log line',
      ),
    );
    await tester.pump();

    expect(find.text('暂无日志'), findsNothing);
    expect(find.byKey(const ValueKey('overview-recent-logs')), findsNothing);
    final log = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(log.data, contains('[Backend]'));
    expect(log.data, contains('[信息] fixture log line'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('current logs capture the run limit and classify levels', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final runtime = _FakeBackendRuntime();
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories!),
    );
    await tester.binding.setSurfaceSize(const Size(600, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(
      () =>
          File.fromUri(directories.logs.uri.resolve('backend.log'))
              .writeAsString('legacy entry'),
    );
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
        preferences: DesktopPreferences.defaults.copyWith(recentLogLimit: 50),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();

    expect(find.text('legacy entry'), findsNothing);

    runtime.emitState(RuntimeStatus.starting);
    for (var index = 0; index < 60; index++) {
      runtime.emitLog(
        RuntimeLog(
          timestamp: DateTime.now(),
          source: RuntimeLogSource.stdout,
          message: 'log-$index',
        ),
      );
    }
    await tester.pump();
    expect(find.textContaining('log-59'), findsOneWidget);
    expect(find.textContaining('log-0'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText && widget.data?.contains('log-9') == true,
      ),
      findsNothing,
    );

    runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.now(),
        source: RuntimeLogSource.stdout,
        message: 'non-prefix trace panic',
      ),
    );
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data?.contains('[调试] non-prefix trace panic') == true,
      ),
      findsOneWidget,
    );
    runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.now(),
        source: RuntimeLogSource.stdout,
        message: 'debug1 error404 panic_mode',
      ),
    );
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data?.contains('[信息] debug1 error404 panic_mode') == true,
      ),
      findsOneWidget,
    );
    runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.now(),
        source: RuntimeLogSource.stdout,
        message: 'non-prefix panic',
      ),
    );
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data?.contains('[错误] non-prefix panic') == true,
      ),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), 'Backend');
    await tester.pump();
    expect(find.byType(SelectableText), findsNothing);
    await tester.enterText(find.byType(TextField), 'log-59');
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText && widget.data?.contains('log-59') == true,
      ),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilterChip, 'Backend'));
    await tester.pump();
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, 'Backend'));
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText && widget.data?.contains('log-59') == true,
      ),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('最早在前'));
    await tester.pump();
    expect(
      tester
          .widget<SegmentedButton<LogSort>>(
            find.byType(SegmentedButton<LogSort>),
          )
          .selected,
      {LogSort.newestLast},
    );
    await tester.tap(find.text('最新在前'));
    await tester.pump();
    expect(
      tester
          .widget<SegmentedButton<LogSort>>(
            find.byType(SegmentedButton<LogSort>),
          )
          .selected,
      {LogSort.newestFirst},
    );

    await tester.enterText(find.byType(TextField), 'panic');
    await tester.tap(find.byKey(const ValueKey('nav-item-overview')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(find.textContaining('panic'), findsWidgets);

    runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.now(),
        source: RuntimeLogSource.httpMetaStdout,
        message: 'HTTP-META info line',
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.widgetWithText(FilterChip, 'Backend'));
    await tester.pump();
    expect(find.textContaining('HTTP-META info line'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'HTTP-META'));
    await tester.pump();
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, 'HTTP-META'));
    await tester.tap(find.widgetWithText(FilterChip, 'Backend'));
    await tester.pump();

    final platform =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? copied;
    platform.setMockMethodCallHandler(SystemChannels.platform, (call) {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => platform.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final displayed = tester
        .widget<SelectableText>(find.byType(SelectableText).first)
        .data;
    await tester.tap(find.byTooltip('复制日志').first);
    await tester.pump();
    expect(copied, displayed);

    runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.now(),
        source: RuntimeLogSource.stdout,
        message: 'x' * 2000,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    runtime.emitState(RuntimeStatus.stopping);
    await tester.pump();
    expect(find.byType(SelectableText), findsWidgets);
    runtime.emitState(RuntimeStatus.stopped);
    await tester.pump();
    expect(find.byType(SelectableText), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('history lists and opens completed log runs', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final store = RuntimeLogStore(directories!);
    await tester.runAsync(() async {
      await store.initialize();
      await store.beginRun();
      await store.append(
        RuntimeLog(
          timestamp: DateTime.now(),
          source: RuntimeLogSource.stdout,
          message: 'historical entry',
        ),
      );
      for (var index = 0; index < 405; index++) {
        await store.append(
          RuntimeLog(
            timestamp: DateTime.now(),
            source: RuntimeLogSource.stdout,
            message: 'history-${index.toString().padLeft(3, '0')}',
          ),
        );
      }
      await store.finalize();
    });
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories),
      logStore: store,
    );
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();
    await tester.tap(find.text('历史'));
    await tester.pump();
    await _pumpRealIo(tester);
    expect(find.byType(ListTile), findsOneWidget);
    await tester.tap(find.byType(ListTile));
    await _pumpRealIo(tester);
    expect(find.textContaining('history-404'), findsOneWidget);
    expect(find.textContaining('historical entry'), findsNothing);
    await tester.tap(find.text('下一页'));
    await _pumpRealIo(tester);
    expect(find.textContaining('history-204'), findsOneWidget);
    expect(find.textContaining('history-404'), findsNothing);
    await tester.tap(find.text('下一页'));
    await _pumpRealIo(tester);
    expect(find.textContaining('history-004'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -10000));
    await tester.pump();
    expect(find.textContaining('historical entry'), findsOneWidget);
    expect(find.textContaining('history-204'), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'no-such-log');
    await _pumpRealIo(tester);
    expect(find.text('没有匹配的日志'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '');
    await _pumpRealIo(tester);
    await tester.tap(find.byKey(const ValueKey('history-back')));
    await tester.pump();
    expect(find.byType(ListTile), findsOneWidget);
    await tester.tap(find.byTooltip('删除运行记录'));
    await _pumpRealIo(tester);
    expect(find.text('已删除'), findsWidgets);
    await tester.tap(find.text('撤销').last);
    await _pumpRealIo(tester);
    expect(find.byType(ListTile), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('overview uses local component status without remote checks', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final updates = _FakeComponentUpdateOperations();
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories!),
      componentUpdates: updates,
    );

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );
    await _pumpRealIo(tester);

    expect(
      find.text('backend: 当前 backend-current; 上一版 backend-previous; 可回滚'),
      findsOneWidget,
    );
    expect(find.text('frontend: 当前 frontend-current; 不可回滚'), findsOneWidget);
    expect(updates.statusCalls[ComponentKind.backend], greaterThanOrEqualTo(1));
    expect(
      updates.statusCalls[ComponentKind.frontend],
      greaterThanOrEqualTo(1),
    );
    expect(updates.checkCalls, isEmpty);

    final backendStatusCalls = updates.statusCalls[ComponentKind.backend]!;
    final frontendStatusCalls = updates.statusCalls[ComponentKind.frontend]!;
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-item-overview')));
    await _pumpRealIo(tester);
    expect(updates.statusCalls[ComponentKind.backend], backendStatusCalls + 1);
    expect(
      updates.statusCalls[ComponentKind.frontend],
      frontendStatusCalls + 1,
    );
    expect(updates.checkCalls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manage toolbar stays hidden before WebView is ready', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final runtime = _FakeBackendRuntime();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories!),
    );

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    await tester.pump();
    expect(find.byTooltip('刷新'), findsNothing);
    expect(find.byTooltip('在系统浏览器中打开'), findsNothing);

    runtime.emitState(RuntimeStatus.starting);
    await tester.pump();
    expect(find.byKey(const ValueKey('manage-transition')), findsOneWidget);
    expect(find.byTooltip('刷新'), findsNothing);
    expect(find.byTooltip('在系统浏览器中打开'), findsNothing);

    runtime.emitState(RuntimeStatus.stopping);
    await tester.pump();
    expect(find.byKey(const ValueKey('manage-transition')), findsOneWidget);
    expect(find.byTooltip('刷新'), findsNothing);
    expect(find.byTooltip('在系统浏览器中打开'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('desktop controls minimize, maximize, and close', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories!),
    );
    var minimizes = 0;
    var maximizeToggles = 0;
    var closes = 0;
    var drags = 0;

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
        onMinimize: () async => minimizes++,
        onToggleMaximize: () async => maximizeToggles++,
        onClose: () async => closes++,
        onStartDragging: () async => drags++,
      ),
    );

    await tester.tap(find.byTooltip('最小化'));
    await tester.tap(find.byTooltip('最大化'));
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.drag(find.text('SubDock'), const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 50));

    expect(minimizes, 1);
    expect(maximizeToggles, 1);
    expect(closes, 1);
    expect(drags, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('double-clicking the Linux title area toggles maximize', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories!),
    );
    var toggles = 0;
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
        onToggleMaximize: () async => toggles++,
      ),
    );

    final titleArea = tester.widget<GestureDetector>(
      find.byKey(const ValueKey('titlebar-drag-area')),
    );
    titleArea.onDoubleTap!();

    expect(toggles, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('uses responsive navigation at the 600 pixel breakpoint', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final runtime = _FakeBackendRuntime();
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories!),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.binding.setSurfaceSize(const Size(599, 800));
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(600, 800));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('desktop-sidebar')),
      findsOneWidget,
    );
    expect(find.byType(NavigationBar), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'shell renders the four pages and the warning banner in dark mode',
    (WidgetTester tester) async {
      late Directory temp;
      addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
      final directories = await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('subdock_widget_');
        return RuntimeDirectories.fromBaseDirectory(temp);
      });
      final coordinator = AppCoordinator(
        runtime: _FakeBackendRuntime(),
        environmentStore: BackendEnvStore(directories!),
      );
      addTearDown(
        () => tester.binding.platformDispatcher.platformBrightnessTestValue =
            Brightness.light,
      );

      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.dark;
      await tester.pumpWidget(
        SubDockApp(
          coordinator: coordinator,
          autoStart: false,
          enableWebView: false,
          desktopWarning: ValueNotifier<AppConfigError>(
            const AppConfigError(AppConfigErrorCode.trayUnavailable),
          ),
          locale: const Locale('zh'),
        ),
      );

      // Following the system brightness, the shell applies the dark theme.
      expect(
        Theme.of(tester.element(find.text('SubDock'))).brightness,
        Brightness.dark,
      );

      for (final key in [
        'nav-item-overview',
        'nav-item-logs',
        'nav-item-settings',
        'nav-item-manage',
      ]) {
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: key);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'theme follows the system brightness when no preference is stored',
    (WidgetTester tester) async {
      late Directory temp;
      addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
      final directories = await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('subdock_widget_');
        return RuntimeDirectories.fromBaseDirectory(temp);
      });
      final coordinator = AppCoordinator(
        runtime: _FakeBackendRuntime(),
        environmentStore: BackendEnvStore(directories!),
      );
      addTearDown(
        () => tester.binding.platformDispatcher.platformBrightnessTestValue =
            Brightness.light,
      );

      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.dark;
      await tester.pumpWidget(
        SubDockApp(
          coordinator: coordinator,
          autoStart: false,
          enableWebView: false,
          locale: const Locale('zh'),
        ),
      );
      expect(
        Theme.of(tester.element(find.text('SubDock'))).brightness,
        Brightness.dark,
      );

      // Tear down and rebuild fresh so MediaQuery reflects the new value.
      await tester.pumpWidget(const SizedBox());
      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.light;
      await tester.pumpWidget(
        SubDockApp(
          coordinator: coordinator,
          autoStart: false,
          enableWebView: false,
          locale: const Locale('zh'),
        ),
      );
      expect(
        Theme.of(tester.element(find.text('SubDock'))).brightness,
        Brightness.light,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'selecting dark from the settings appearance section applies it',
    (WidgetTester tester) async {
      late Directory temp;
      addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
      final directories = await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('subdock_widget_');
        return RuntimeDirectories.fromBaseDirectory(temp);
      });
      final coordinator = AppCoordinator(
        runtime: _FakeBackendRuntime(),
        environmentStore: BackendEnvStore(directories!),
      );

      await tester.pumpWidget(
        SubDockApp(
          coordinator: coordinator,
          autoStart: false,
          enableWebView: false,
          locale: const Locale('zh'),
        ),
      );

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedButton<ThemeMode>),
          matching: find.text('深色'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        Theme.of(tester.element(find.text('SubDock'))).brightness,
        Brightness.dark,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('restores a persisted dark preference on startup', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final store = DesktopPreferencesStore(directories!);
    await tester.runAsync(
      () => store.save(
        DesktopPreferences.defaults.copyWith(themeMode: ThemeMode.dark),
      ),
    );
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories),
    );

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        preferences: await tester.runAsync(() => store.load()),
        locale: const Locale('zh'),
      ),
    );
    await _pumpRealIo(tester);

    expect(
      Theme.of(tester.element(find.text('SubDock'))).brightness,
      Brightness.dark,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('settings surfaces fit the minimum desktop window', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories!),
    );

    await tester.binding.setSurfaceSize(const Size(600, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
    await tester.pumpAndSettle();

    final settingsList = find.byKey(const ValueKey('settings-list'));
    final scrollable = find
        .descendant(of: settingsList, matching: find.byType(Scrollable))
        .first;
    expect(find.byKey(const ValueKey('settings-appearance')), findsOneWidget);
    expect(tester.takeException(), isNull);
    for (final key in [
      'settings-subdock-config',
      'settings-backend-config',
      'settings-raw-env',
      'settings-component-updates',
    ]) {
      final section = find.byKey(ValueKey(key));
      await tester.scrollUntilVisible(section, 180, scrollable: scrollable);
      expect(section, findsOneWidget);
      expect(tester.takeException(), isNull);
    }

    final expansion = find.byKey(const ValueKey('settings-raw-env-expansion'));
    await tester.ensureVisible(expansion);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-raw-env-editor')), findsNothing);
    await tester.tap(expansion);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-raw-env-editor')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('changing the theme previews without saving to the store', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final store = DesktopPreferencesStore(directories!);
    await tester.runAsync(
      () => store.save(DesktopPreferences.defaults.copyWith(locale: 'zh')),
    );
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories),
    );

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        preferences: await tester.runAsync(() => store.load()),
        locale: const Locale('zh'),
      ),
    );

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(SegmentedButton<ThemeMode>),
        matching: find.text('浅色'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      Theme.of(tester.element(find.text('SubDock'))).brightness,
      Brightness.light,
    );

    await _pumpRealIo(tester);
    expect(
      (await tester.runAsync(() => store.load()))!.themeMode,
      ThemeMode.system,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'without a themeModeStore the settings selector applies but does not persist',
    (WidgetTester tester) async {
      late Directory temp;
      addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
      final directories = await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('subdock_widget_');
        return RuntimeDirectories.fromBaseDirectory(temp);
      });
      final coordinator = AppCoordinator(
        runtime: _FakeBackendRuntime(),
        environmentStore: BackendEnvStore(directories!),
      );

      await tester.pumpWidget(
        SubDockApp(
          coordinator: coordinator,
          autoStart: false,
          enableWebView: false,
          locale: const Locale('zh'),
        ),
      );

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedButton<ThemeMode>),
          matching: find.text('深色'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        Theme.of(tester.element(find.text('SubDock'))).brightness,
        Brightness.dark,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a corrupt theme store file degrades to following the system', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final store = DesktopPreferencesStore(directories!);
    await tester.runAsync(() => store.file.writeAsString('{not json'));
    final preferences = await tester.runAsync(() => store.load());
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories),
    );
    addTearDown(
      () => tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.light,
    );

    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.dark;
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        preferences: preferences,
        locale: const Locale('zh'),
      ),
    );
    await _pumpRealIo(tester);

    expect(tester.takeException(), isNull);
    expect(
      Theme.of(tester.element(find.text('SubDock'))).brightness,
      Brightness.dark,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders the shell in English when en is selected', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories!),
    );

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
      ),
    );

    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Overview'), findsWidgets);
    expect(find.text('Logs'), findsWidgets);
    expect(find.text('Manage'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('switching the language previews without saving it', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final preferencesStore = DesktopPreferencesStore(directories!);
    await tester.runAsync(
      () => preferencesStore.save(
        DesktopPreferences.defaults.copyWith(locale: 'zh'),
      ),
    );
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories),
    );

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
        preferences: await tester.runAsync(() => preferencesStore.load()),
      ),
    );
    expect(find.text('设置'), findsWidgets);

    // Open settings and switch the language dropdown to English.
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Appearance'), findsWidgets);
    await _pumpRealIo(tester);
    expect(
      (await tester.runAsync(() => preferencesStore.load()))!.locale,
      'zh',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('restores a persisted English preference on startup', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final preferencesStore = DesktopPreferencesStore(directories!);
    await tester.runAsync(
      () => preferencesStore.save(
        DesktopPreferences.defaults.copyWith(locale: 'en'),
      ),
    );
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories),
    );

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        preferences: await tester.runAsync(() => preferencesStore.load()),
      ),
    );
    await _pumpRealIo(tester);

    expect(find.text('Settings'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a corrupt locale store degrades to the system language', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final preferencesStore = DesktopPreferencesStore(directories!);
    await tester.runAsync(
      () => preferencesStore.file.writeAsString('{not json'),
    );
    final preferences = await tester.runAsync(() => preferencesStore.load());
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories),
    );
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    addTearDown(
      () => tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.light,
    );

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        preferences: preferences,
      ),
    );
    await _pumpRealIo(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Settings'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('theme selector round-trips through all three modes', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories!),
    );
    addTearDown(
      () => tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.light,
    );
    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.dark;

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    Future<void> selectTheme(String label, Brightness expected) async {
      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedButton<ThemeMode>),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
      await _pumpRealIo(tester);
      expect(
        Theme.of(tester.element(find.text('SubDock'))).brightness,
        expected,
      );
    }

    await selectTheme('浅色', Brightness.light);
    await selectTheme('深色', Brightness.dark);
    // Following the system (which is dark in this test) after manual picks.
    await selectTheme('跟随系统', Brightness.dark);

    await tester.pumpWidget(const SizedBox());
  });
}

/// Interleaves real-async turns (letting dart:io completions arrive) with
/// pumps (flushing the fake-async continuations those completions queue), so
/// file I/O initiated inside the widget tree can finish under `testWidgets`.
Future<void> _pumpRealIo(WidgetTester tester, {int turns = 40}) async {
  for (var turn = 0; turn < turns; turn++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

class _FakeBackendRuntime extends BackendRuntime {
  final _logs = StreamController<RuntimeLog>.broadcast(sync: true);
  final _states = StreamController<RuntimeState>.broadcast(sync: true);
  var starts = 0;
  var stops = 0;
  var restarts = 0;

  void emitLog(RuntimeLog log) => _logs.add(log);

  void emitState(RuntimeStatus status) =>
      _states.add(RuntimeState(status: status, changedAt: DateTime.now()));

  @override
  RuntimeState get currentState => RuntimeState(
    status: starts > stops ? RuntimeStatus.running : RuntimeStatus.stopped,
    changedAt: DateTime.now(),
  );

  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:3001');

  @override
  Stream<RuntimeLog> get logs => _logs.stream;

  @override
  Stream<RuntimeState> get state => _states.stream;

  @override
  Future<BackendInfo> info() async => const BackendInfo(
    nodeVersion: 'v24.20.0',
    backendVersion: 'fixture-backend',
    port: 3001,
  );

  @override
  Future<bool> isHealthy() async => true;

  @override
  Future<void> restart() async {
    restarts++;
  }

  @override
  Future<void> activateUserEnvironment(Map<String, String> environment) async {}

  @override
  Future<void> start() async {
    starts++;
    _states.add(
      RuntimeState(status: RuntimeStatus.running, changedAt: DateTime.now()),
    );
  }

  @override
  Future<void> stop() async {
    stops++;
    _states.add(
      RuntimeState(status: RuntimeStatus.stopped, changedAt: DateTime.now()),
    );
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _logs.close();
    await _states.close();
  }
}

class _FakeComponentUpdateOperations implements ComponentUpdateOperations {
  final statusCalls = <ComponentKind, int>{};
  final checkCalls = <ComponentKind, int>{};

  @override
  Future<ComponentVersionStatus> status(ComponentKind kind) async {
    statusCalls[kind] = (statusCalls[kind] ?? 0) + 1;
    return ComponentVersionStatus(
      current: '${kind.name}-current',
      previous: kind == ComponentKind.backend ? '${kind.name}-previous' : null,
    );
  }

  @override
  Future<ComponentUpdate> check(ComponentKind kind) async {
    checkCalls[kind] = (checkCalls[kind] ?? 0) + 1;
    throw StateError('check should not be called');
  }

  @override
  Future<void> rollback(ComponentKind kind) async {}

  @override
  Future<void> update(ComponentUpdate update) async {}
}

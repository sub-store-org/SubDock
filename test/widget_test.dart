import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart'
    show
        Brightness,
        Axis,
        BorderRadius,
        BoxDecoration,
        Container,
        DropdownButton,
        Flex,
        FilterChip,
        FilledButton,
        IconButton,
        Locale,
        ListTile,
        ListView,
        OutlinedButton,
        Expanded,
        SelectableText,
        Scrollable,
        SingleChildScrollView,
        SegmentedButton,
        Switch,
        Theme,
        ThemeMode,
        TextButton,
        Text,
        TextField,
        ValueNotifier;
import 'package:flutter/scheduler.dart' show AppLifecycleState;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show EdgeInsets, GestureDetector, Offstage, Padding, SizedBox, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/app.dart';
import 'package:subdock/app/about_info.dart';
import 'package:subdock/app/app_coordinator.dart';
import 'package:subdock/app/embedded_webview.dart';
import 'package:subdock/app/mobile_placeholder_runtime.dart';
import 'package:subdock/l10n/generated/app_localizations.dart';
import 'package:subdock/mobile_main.dart';
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
import 'package:subdock/update/github_release_client.dart';
import 'package:subdock/update/component_update_service.dart';

void main() {
  test('mobile placeholder runtime stays stopped and silent', () async {
    final runtime = MobilePlaceholderRuntime();

    expect(runtime.currentState.status, RuntimeStatus.stopped);
    expect(await runtime.logs.isEmpty, isTrue);
    expect(await runtime.state.isEmpty, isTrue);
    expect(await runtime.isHealthy(), isFalse);

    await runtime.start();
    await runtime.stop();
    await runtime.restart();
    await runtime.activateUserEnvironment(const {});
    await runtime.dispose();

    expect(runtime.currentState.status, RuntimeStatus.stopped);
    await expectLater(runtime.info(), throwsStateError);
  });

  testWidgets('mobile entry renders the shared shell with placeholder data', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_mobile_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final app = (await tester.runAsync(
      () => createMobileApp(directories: directories!),
    ))!;
    expect(app.coordinator.runtime, isA<MobilePlaceholderRuntime>());
    expect(app.autoStart, isFalse);
    expect(app.enableWebView, isFalse);
    expect(app.showCustomDesktopChrome, isFalse);
    expect(app.onMinimize, isNull);
    expect(app.onToggleMaximize, isNull);
    expect(app.onClose, isNull);
    expect(app.isMaximized, isNull);
    expect(app.closeRequestGuard, isNull);
    expect(app.onStartDragging, isNull);

    await tester.pumpWidget(app);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('mobile-navigation')), findsOneWidget);
    for (final page in const [
      'overview',
      'manage',
      'logs',
      'updates',
      'settings',
    ]) {
      expect(find.byKey(ValueKey('nav-item-$page')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('desktop-sidebar')), findsNothing);
    expect(find.byKey(const ValueKey('desktop-chrome')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('overview-backend-hero')),
        matching: find.text('-'),
      ),
      findsWidgets,
    );
    final overviewScrollable = find.descendant(
      of: find.byKey(const ValueKey('page-overview')),
      matching: find.byType(Scrollable),
    );
    await tester.drag(overviewScrollable, const Offset(0, -600));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('overview-stat-start')),
        matching: find.text('-'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('overview-stat-anomalies')),
        matching: find.text('0'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('overview-stat-logs')),
        matching: find.text('0'),
      ),
      findsOneWidget,
    );

    for (final page in const [
      'overview',
      'manage',
      'logs',
      'updates',
      'settings',
    ]) {
      await tester.tap(find.byKey(ValueKey('nav-item-$page')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<Offstage>(find.byKey(ValueKey('page-$page'))).offstage,
        isFalse,
      );
      switch (page) {
        case 'manage':
          expect(find.byKey(const ValueKey('manage-recovery')), findsOneWidget);
        case 'logs':
          expect(find.byKey(const ValueKey('logs-surface')), findsOneWidget);
        case 'updates':
          expect(find.byKey(const ValueKey('updates-list')), findsOneWidget);
        case 'settings':
          expect(find.byKey(const ValueKey('settings-list')), findsOneWidget);
        case 'overview':
          break;
      }
    }
    await tester.pumpWidget(const SizedBox());
  });

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
    expect(find.textContaining('Node'), findsOneWidget);
    expect(find.textContaining('Backend'), findsWidgets);
    expect(find.textContaining('端口'), findsWidgets);
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
    expect(find.textContaining('运行中'), findsWidgets);
    expect(find.textContaining('v24.20.0'), findsWidgets);
    expect(find.text('fixture-backend'), findsOneWidget);
    expect(find.textContaining('3001'), findsWidgets);
    expect(tester.takeException(), isNull);

    tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '停止'))
        .onPressed!();
    await tester.pump(const Duration(milliseconds: 1));

    expect(runtime.stops, 1);
    expect(find.text('已停止'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('native host mode omits the custom desktop chrome', (
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
        showCustomDesktopChrome: false,
      ),
    );

    expect(find.byKey(const ValueKey('desktop-chrome')), findsNothing);
    expect(find.byKey(const ValueKey('desktop-sidebar')), findsOneWidget);
    expect(find.byKey(const ValueKey('page-title')), findsOneWidget);
    expect(tester.takeException(), isNull);

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
    final runtime = _FakeBackendRuntime();
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
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
    final httpMetaSwitch = find.byType(Switch);
    expect(httpMetaSwitch, findsOneWidget);
    await tester.tap(httpMetaSwitch);
    await tester.pump();

    final save = find.byKey(const ValueKey('settings-save-all'));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.pump();
    await _pumpRealIo(tester);

    final saved = await tester.runAsync(store.load);
    expect(saved!.httpMeta.enabled, isFalse);
    expect(find.text('已保存'), findsOneWidget);
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
    expect(find.text('Backend'), findsOneWidget);
    expect(find.text('信息'), findsOneWidget);
    expect(find.text('fixture log line'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('logs toolbar switches to the compact filter at 599px', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final runtime = _FakeBackendRuntime();
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    await tester.binding.setSurfaceSize(const Size(599, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      SubDockApp(
        coordinator: AppCoordinator(
          runtime: runtime,
          environmentStore: BackendEnvStore(directories!),
        ),
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();

    runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.utc(2026, 9, 13, 4, 30),
        source: RuntimeLogSource.stdout,
        message: 'backend fixture',
      ),
    );
    runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.utc(2026, 9, 13, 4, 31),
        source: RuntimeLogSource.httpMetaStdout,
        message: 'http meta fixture',
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('logs-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('logs-mobile-filter')), findsOneWidget);
    expect(find.byKey(const ValueKey('logs-source-filter')), findsNothing);
    expect(find.byKey(const ValueKey('logs-sort-selector')), findsNothing);
    expect(
      tester.widget<Padding>(find.byKey(const ValueKey('logs-body'))).padding,
      const EdgeInsets.only(top: 12, left: 12, right: 12, bottom: 24),
    );
    expect(find.byKey(const ValueKey('logs-mobile-row')), findsNWidgets(2));
    expect(find.byKey(const ValueKey('logs-mobile-meta')), findsNWidgets(2));
    expect(find.byKey(const ValueKey('logs-mobile-content')), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('logs-mobile-filter')));
    await tester.pumpAndSettle();
    final httpMeta = find.byKey(const ValueKey('logs-source-HTTP-META'));
    final warning = find.byKey(const ValueKey('logs-level-warning'));
    expect(tester.widget<FilterChip>(httpMeta).selected, isTrue);
    expect(tester.widget<FilterChip>(warning).selected, isTrue);
    await tester.tap(httpMeta);
    await tester.tap(warning);
    await tester.tap(find.byKey(const ValueKey('logs-mobile-sort')));
    await tester.pump();
    await tester.tap(find.text('Newest last').last);
    await tester.pump();
    await tester.tap(find.text('Back').last);
    await tester.pump();
    expect(find.text('http meta fixture'), findsNothing);
    expect(find.text('backend fixture'), findsOneWidget);
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
            widget.data?.contains('non-prefix trace panic') == true,
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
            widget.data?.contains('debug1 error404 panic_mode') == true,
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
            widget.data?.contains('non-prefix panic') == true,
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
    await tester.tap(find.byKey(const ValueKey('logs-source-filter')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.widgetWithText(FilterChip, 'Backend'));
    await tester.tap(find.text('返回').last);
    await tester.pump();
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.byKey(const ValueKey('logs-source-filter')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.widgetWithText(FilterChip, 'Backend'));
    await tester.tap(find.text('返回').last);
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText && widget.data?.contains('log-59') == true,
      ),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.byKey(const ValueKey('logs-sort-selector')));
    await tester.pump();
    await tester.tap(find.text('最早在前').last);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('logs-sort-selector')));
    await tester.pump();
    await tester.tap(find.text('最新在前').last);
    await tester.pump();

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
    await tester.tap(find.byKey(const ValueKey('logs-source-filter')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.widgetWithText(FilterChip, 'Backend'));
    await tester.tap(find.text('返回').last);
    await tester.pump();
    expect(find.textContaining('HTTP-META info line'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('logs-source-filter')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.widgetWithText(FilterChip, 'HTTP-META'));
    await tester.tap(find.text('返回').last);
    await tester.pump();
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.byKey(const ValueKey('logs-source-filter')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.widgetWithText(FilterChip, 'HTTP-META'));
    await tester.tap(find.widgetWithText(FilterChip, 'Backend'));
    await tester.tap(find.text('返回').last);
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
    final copy = find.byTooltip('复制日志').first;
    await tester.ensureVisible(copy);
    await tester.pump();
    expect(tester.getSize(copy), const Size(40, 40));
    await tester.tap(copy);
    await tester.pump();
    expect(copied, contains(displayed));

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

  testWidgets('Logs history delete and undo expose semantics', (tester) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final store = RuntimeLogStore(directories!);
    late String runId;
    await tester.runAsync(() async {
      await store.initialize();
      runId = await store.beginRun();
      await store.append(
        RuntimeLog(
          timestamp: DateTime.now(),
          source: RuntimeLogSource.stdout,
          message: 'semantic history entry',
        ),
      );
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
    await _pumpRealIo(tester);

    final runTile = find.byKey(ValueKey('history-run-$runId'));
    expect(runTile, findsOneWidget);
    final semantics = tester.ensureSemantics();
    expect(
      tester.getSemantics(runTile),
      matchesSemantics(
        hasTapAction: true,
        hasFocusAction: true,
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasSelectedState: true,
      ),
    );
    final delete = find.byTooltip('删除运行记录');
    expect(delete, findsOneWidget);
    expect(
      tester.getSemantics(delete),
      matchesSemantics(
        tooltip: '删除运行记录',
        hasTapAction: true,
        hasFocusAction: true,
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
      ),
    );
    semantics.dispose();

    await tester.tap(delete);
    await _pumpRealIo(tester);
    expect(find.byKey(const ValueKey('recently-deleted')), findsOneWidget);
    expect(find.text('撤销'), findsWidgets);
    await tester.tap(find.text('撤销').last);
    await _pumpRealIo(tester);
    expect(find.byKey(ValueKey('history-run-$runId')), findsOneWidget);
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
      find.text('当前 backend-current，上一版 backend-previous'),
      findsOneWidget,
    );
    expect(find.text('当前 frontend-current'), findsOneWidget);
    final frontend = find.byKey(const ValueKey('overview-component-frontend'));
    final backend = find.byKey(const ValueKey('overview-component-backend'));
    final componentDivider = find.byKey(
      const ValueKey('overview-component-divider'),
    );
    expect(
      tester.getTopLeft(frontend).dy,
      lessThan(tester.getTopLeft(backend).dy),
    );
    expect(componentDivider, findsOneWidget);
    expect(
      tester.getTopLeft(frontend).dy,
      lessThan(tester.getTopLeft(componentDivider).dy),
    );
    expect(
      tester.getTopLeft(componentDivider).dy,
      lessThan(tester.getTopLeft(backend).dy),
    );
    expect(
      tester
          .widget<Padding>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('overview-component-card')),
                  matching: find.byType(Padding),
                )
                .first,
          )
          .padding,
      EdgeInsets.zero,
    );
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
    updates.statusErrors[ComponentKind.frontend] = StateError('status failed');
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-item-overview')));
    await _pumpRealIo(tester);
    expect(
      find.descendant(of: frontend, matching: find.text('最新')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('overview follows v5 hierarchy and displays runtime statistics', (
    tester,
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
    await tester.binding.setSurfaceSize(const Size(599, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

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
      tester
          .widget<Flex>(find.byKey(const ValueKey('overview-hero-grid')))
          .direction,
      Axis.vertical,
    );
    expect(
      tester
          .widget<Flex>(find.byKey(const ValueKey('overview-backend-hero-top')))
          .direction,
      Axis.vertical,
    );
    expect(
      tester
          .widget<Flex>(
            find.byKey(const ValueKey('overview-http-meta-hero-top')),
          )
          .direction,
      Axis.vertical,
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('overview-stats')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widget<Flex>(find.byKey(const ValueKey('overview-stats')))
          .direction,
      Axis.vertical,
    );

    await tester.binding.setSurfaceSize(const Size(600, 800));
    await tester.pump();
    expect(
      tester
          .widget<Flex>(find.byKey(const ValueKey('overview-stats')))
          .direction,
      Axis.horizontal,
    );

    await tester.fling(
      find.byType(Scrollable).first,
      const Offset(0, 1000),
      1000,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Flex>(find.byKey(const ValueKey('overview-hero-grid')))
          .direction,
      Axis.horizontal,
    );
    expect(
      tester
          .widget<Flex>(find.byKey(const ValueKey('overview-backend-hero-top')))
          .direction,
      Axis.horizontal,
    );
    expect(
      tester
          .widget<Flex>(
            find.byKey(const ValueKey('overview-http-meta-hero-top')),
          )
          .direction,
      Axis.horizontal,
    );
    final heroGrid = tester.widget<Flex>(
      find.byKey(const ValueKey('overview-hero-grid')),
    );
    expect(
      (heroGrid.children[0] as Expanded).flex,
      greaterThan((heroGrid.children[2] as Expanded).flex),
    );
    expect(find.text('独立运行状态；资源随 SubDock 安装包提供，不属于独立更新组件。'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('overview-component-status')),
        matching: find.byKey(const ValueKey('overview-component-divider')),
      ),
      findsOneWidget,
    );

    runtime.emitState(RuntimeStatus.starting);
    runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.now(),
        source: RuntimeLogSource.stdout,
        message: 'overview log',
      ),
    );
    runtime.emitState(
      RuntimeStatus.running,
      httpMetaStatus: HttpMetaStatus.running,
      httpMetaPort: 9876,
      httpMetaVersion: '1.3.0',
    );
    await _pumpRealIo(tester);

    expect(find.byKey(const ValueKey('overview-backend-hero')), findsOneWidget);
    expect(find.text('fixture-backend'), findsOneWidget);
    expect(find.text('1.3.0'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('overview-http-meta-hero')),
        matching: find.textContaining('9876'),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('overview-stat-logs')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );

    runtime.emitState(RuntimeStatus.unhealthy);
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('overview-stat-anomalies')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('component update pages check independently', (tester) async {
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
        locale: const Locale('en'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
    await _pumpRealIo(tester);
    expect(updates.checkCalls[ComponentKind.frontend], 1);
    expect(updates.checkCalls[ComponentKind.backend], 1);
    expect(
      find.byKey(const ValueKey('component-update-local-status-frontend')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('updates-check-all')),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      find.byKey(const ValueKey('component-release-notes-frontend')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('component-update-action-frontend')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('settings-child-save')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('updates-check-all')));
    await _pumpRealIo(tester);
    expect(updates.checkCalls[ComponentKind.frontend], 2);
    expect(updates.checkCalls[ComponentKind.backend], 2);
    await tester.tap(
      find.byKey(const ValueKey('component-update-recheck-frontend')),
    );
    await _pumpRealIo(tester);
    expect(updates.checkCalls[ComponentKind.frontend], 3);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('updates page separates packaged resources', (tester) async {
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
      componentUpdates: _FakeComponentUpdateOperations(),
    );
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
      ),
    );
    runtime.emitState(
      RuntimeStatus.running,
      httpMetaStatus: HttpMetaStatus.running,
      httpMetaPort: 9876,
      httpMetaVersion: '1.3.0',
    );
    await _pumpRealIo(tester);
    await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
    await _pumpRealIo(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('updates-packaged-http-meta')),
        matching: find.text('1.3.0'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('updates-packaged-node')),
        matching: find.text('v24.20.0'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('updates-packaged-mihomo')),
        matching: find.text('-'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('updates-packaged-grid')),
        matching: find.byType(FilledButton),
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('backend update page stops a running backend', (tester) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    await tester.binding.setSurfaceSize(const Size(600, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final runtime = _FakeBackendRuntime();
    await runtime.start();
    final updates = _FakeComponentUpdateOperations();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories!),
      componentUpdates: updates,
    );
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
    await _pumpRealIo(tester);
    expect(updates.checkCalls[ComponentKind.backend], 1);
    expect(updates.checkCalls[ComponentKind.frontend], 1);
    expect(find.byKey(const ValueKey('settings-child-save')), findsNothing);
    expect(
      find.byKey(const ValueKey('component-update-local-status-backend')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('component-update-recheck-backend')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('component-update-action-backend')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('component-rollback-action-backend')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('component-release-notes-backend')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    for (final state in [RuntimeStatus.starting, RuntimeStatus.stopping]) {
      runtime.emitState(state);
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('updates-backend-stop')),
            )
            .onPressed,
        isNull,
      );
    }
    runtime.emitState(RuntimeStatus.running);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('component-update-action-backend')),
      findsNothing,
    );
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('component-rollback-action-backend')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('updates-backend-stop')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('updates-backend-stop')));
    await _pumpRealIo(tester);
    expect(runtime.stops, 1);
    expect(
      find.text('Backend is stopped. Component changes are available.'),
      findsNothing,
    );
    expect(updates.updateCalls, isEmpty);
    expect(updates.rollbackCalls, isEmpty);
    await _pumpRealIo(tester);
    expect(updates.checkCalls[ComponentKind.backend], 1);
    expect(updates.checkCalls[ComponentKind.frontend], 1);
    await tester.ensureVisible(
      find.byKey(const ValueKey('component-update-recheck-backend')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('component-update-recheck-backend')),
    );
    await _pumpRealIo(tester);
    expect(updates.checkCalls[ComponentKind.backend], 2);
    expect(updates.checkCalls[ComponentKind.frontend], 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('component check failure keeps local status', (tester) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final updates = _FakeComponentUpdateOperations()
      ..checkErrors[ComponentKind.frontend] = StateError('network failed');
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
        locale: const Locale('en'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
    await _pumpRealIo(tester);
    expect(updates.checkCalls[ComponentKind.frontend], 1);
    expect(updates.checkCalls[ComponentKind.backend], 1);
    final local = tester.widget<Text>(
      find.byKey(const ValueKey('component-update-local-status-frontend')),
    );
    expect(local.data, contains('frontend-current'));
    expect(find.textContaining('network failed'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('component-update-recheck-frontend')),
          )
          .onPressed,
      isNotNull,
    );
    expect(find.byKey(const ValueKey('settings-child-save')), findsNothing);
    expect(updates.updateCalls, isEmpty);
    expect(updates.rollbackCalls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stopped component update reloads status and requires restart', (
    tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    await tester.binding.setSurfaceSize(const Size(600, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final updates = _FakeComponentUpdateOperations()
      ..statuses[ComponentKind.frontend] = const ComponentVersionStatus(
        current: '1.0.0',
        previous: '0.9.0',
      )
      ..checkResults[ComponentKind.frontend] = ComponentUpdate(
        kind: ComponentKind.frontend,
        currentVersion: '1.0.0',
        availableVersion: '1.1.0',
        release: GithubRelease(
          version: '1.1.0',
          releaseUri: Uri.parse('https://example.invalid/frontend'),
          assets: const [],
        ),
      );
    final runtime = _FakeBackendRuntime();
    final opened = <Uri>[];
    var openResult = true;
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories!),
      componentUpdates: updates,
    );
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
        onOpenExternalUri: (uri) async {
          opened.add(uri);
          return openResult;
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
    await tester.pumpAndSettle();
    await _pumpRealIo(tester);
    expect(
      find.byKey(const ValueKey('component-release-notes-frontend')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('component-release-notes-frontend')),
    );
    expect(opened, [Uri.parse('https://example.invalid/frontend')]);
    await tester.tap(
      find.byKey(const ValueKey('component-update-action-frontend')),
    );
    await _pumpRealIo(tester);
    expect(updates.updateCalls, hasLength(1));
    expect(updates.rollbackCalls, isEmpty);
    expect(runtime.restarts, 0);
    expect(find.textContaining('Current version: 1.1.0'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('component-restart-now-frontend')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('component-release-notes-frontend')),
      findsNothing,
    );
    final restart = find.byKey(
      const ValueKey('component-restart-now-frontend'),
    );
    await tester.ensureVisible(restart);
    await tester.tap(restart);
    await _pumpRealIo(tester);
    expect(runtime.restarts, 1);
    expect(
      find.byKey(const ValueKey('component-restart-now-frontend')),
      findsNothing,
    );
    expect(updates.updateCalls, hasLength(1));
    expect(updates.rollbackCalls, isEmpty);
    openResult = false;
    updates.checkErrors[ComponentKind.frontend] = StateError('network failed');
    final recheck = find.byKey(
      const ValueKey('component-update-recheck-frontend'),
    );
    await tester.ensureVisible(recheck);
    await tester.tap(recheck);
    await _pumpRealIo(tester);
    final updateCount = updates.updateCalls.length;
    final rollbackCount = updates.rollbackCalls.length;
    final restartCount = runtime.restarts;
    final openedCount = opened.length;
    expect(
      find.byKey(const ValueKey('component-release-notes-frontend')),
      findsNothing,
    );
    expect(opened, hasLength(openedCount));
    expect(
      find.byKey(const ValueKey('component-update-local-status-frontend')),
      findsOneWidget,
    );
    expect(find.textContaining('Current version: 1.1.0'), findsOneWidget);
    expect(updates.updateCalls.length, updateCount);
    expect(updates.rollbackCalls.length, rollbackCount);
    expect(runtime.restarts, restartCount);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rollback requires confirmation and reloads swapped status', (
    tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    await tester.binding.setSurfaceSize(const Size(600, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final updates = _FakeComponentUpdateOperations()
      ..statuses[ComponentKind.backend] = const ComponentVersionStatus(
        current: '2.0.0',
        previous: '1.0.0',
      );
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
        locale: const Locale('en'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
    await tester.pumpAndSettle();
    await _pumpRealIo(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('component-rollback-action-backend')),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(
      find.byKey(const ValueKey('component-rollback-action-backend')),
    );
    await tester.pump();
    expect(find.text('Roll back from 2.0.0 to 1.0.0?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(updates.rollbackCalls, isEmpty);
    final rollback = find.byKey(
      const ValueKey('component-rollback-action-backend'),
    );
    await tester.ensureVisible(rollback);
    await tester.tap(rollback);
    await tester.pump();
    await tester.ensureVisible(find.text('Rollback').last);
    await tester.tap(find.text('Rollback').last);
    await _pumpRealIo(tester);
    expect(updates.rollbackCalls, [ComponentKind.backend]);
    expect(find.textContaining('Current version: 1.0.0'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('component-restart-now-backend')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('restart failure keeps restart-required action', (tester) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final runtime = _FakeBackendRuntime()
      ..restartError = StateError('restart failed');
    final updates = _FakeComponentUpdateOperations()
      ..statuses[ComponentKind.frontend] = const ComponentVersionStatus(
        current: '1.0.0',
        previous: null,
      )
      ..checkResults[ComponentKind.frontend] = ComponentUpdate(
        kind: ComponentKind.frontend,
        currentVersion: '1.0.0',
        availableVersion: '1.1.0',
        release: GithubRelease(
          version: '1.1.0',
          releaseUri: Uri.parse('https://example.invalid/frontend'),
          assets: const [],
        ),
      );
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories!),
      componentUpdates: updates,
    );
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
    await tester.pumpAndSettle();
    await _pumpRealIo(tester);
    await tester.tap(
      find.byKey(const ValueKey('component-update-action-frontend')),
    );
    await _pumpRealIo(tester);
    await tester.tap(
      find.byKey(const ValueKey('component-restart-now-frontend')),
    );
    await _pumpRealIo(tester);
    expect(runtime.restarts, 0);
    expect(
      find.byKey(const ValueKey('component-restart-now-frontend')),
      findsOneWidget,
    );
    expect(find.textContaining('restart failed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('update failure preserves local status and unlocks update', (
    tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final updates = _FakeComponentUpdateOperations()
      ..statuses[ComponentKind.frontend] = const ComponentVersionStatus(
        current: '1.0.0',
        previous: '0.9.0',
      )
      ..checkResults[ComponentKind.frontend] = ComponentUpdate(
        kind: ComponentKind.frontend,
        currentVersion: '1.0.0',
        availableVersion: '1.1.0',
        release: GithubRelease(
          version: '1.1.0',
          releaseUri: Uri.parse('https://example.invalid/frontend'),
          assets: const [],
        ),
      )
      ..updateErrors[ComponentKind.frontend] = StateError('update failed');
    final runtime = _FakeBackendRuntime();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories!),
      componentUpdates: updates,
    );
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
    await tester.pumpAndSettle();
    await _pumpRealIo(tester);
    await tester.tap(
      find.byKey(const ValueKey('component-update-action-frontend')),
    );
    await _pumpRealIo(tester);
    expect(updates.updateCalls, hasLength(1));
    expect(updates.rollbackCalls, isEmpty);
    expect(find.textContaining('Current version: 1.0.0'), findsOneWidget);
    expect(find.textContaining('update failed'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('component-restart-now-frontend')),
      findsNothing,
    );
    expect(runtime.restarts, 0);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('component-update-action-frontend')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rollback failure preserves local status', (tester) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final updates = _FakeComponentUpdateOperations()
      ..statuses[ComponentKind.backend] = const ComponentVersionStatus(
        current: '2.0.0',
        previous: '1.0.0',
      )
      ..rollbackErrors[ComponentKind.backend] = StateError('rollback failed');
    final runtime = _FakeBackendRuntime();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories!),
      componentUpdates: updates,
    );
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
    await tester.pumpAndSettle();
    await _pumpRealIo(tester);
    final rollback = find.byKey(
      const ValueKey('component-rollback-action-backend'),
    );
    await tester.ensureVisible(rollback);
    await tester.tap(rollback);
    await tester.pump();
    await tester.ensureVisible(find.text('Rollback').last);
    await tester.tap(find.text('Rollback').last);
    await _pumpRealIo(tester);
    expect(updates.rollbackCalls, [ComponentKind.backend]);
    expect(find.textContaining('Current version: 2.0.0'), findsOneWidget);
    expect(find.textContaining('Previous version: 1.0.0'), findsOneWidget);
    expect(find.textContaining('rollback failed'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('component-restart-now-backend')),
      findsNothing,
    );
    expect(runtime.restarts, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('settings about page renders injected application metadata', (
    tester,
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
    final loader = AboutInfoLoader(
      loadPackageMetadata: () async => (version: '1.2.3', buildNumber: ''),
      operatingSystem: () => 'linux',
      architecture: () => 'x64',
    );
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
        aboutInfoLoader: loader,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-card-about')),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -160),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-about')));
    await _pumpRealIo(tester);
    expect(find.byKey(const ValueKey('settings-about-page')), findsOneWidget);
    expect(find.text('SubDock version: 1.2.3'), findsOneWidget);
    expect(find.text('Build number: -'), findsOneWidget);
    expect(find.text('License: GPL-3.0'), findsOneWidget);
    expect(
      find.text('Project homepage: https://github.com/Delusions6515/SubDock'),
      findsOneWidget,
    );
    expect(find.text('Operating system: linux'), findsOneWidget);
    expect(find.text('Architecture: x64'), findsOneWidget);
    for (final key in [
      'about-version',
      'about-build-number',
      'about-license',
      'about-homepage',
      'about-os',
      'about-architecture',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
    expect(
      find.byKey(const ValueKey('component-update-local-status-backend')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('component-update-local-status-frontend')),
      findsNothing,
    );
    expect(find.text('Current version'), findsNothing);
    expect(find.text('Previous version'), findsNothing);
    expect(find.byKey(const ValueKey('settings-child-save')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-appearance')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-about-page')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('settings about page shows metadata failure', (tester) async {
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
    final loader = AboutInfoLoader(
      loadPackageMetadata: () async => throw StateError('metadata failed'),
    );
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
        aboutInfoLoader: loader,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-card-about')),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -160),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-about')));
    await _pumpRealIo(tester);
    expect(
      find.textContaining('Application information unavailable'),
      findsOneWidget,
    );
    expect(find.textContaining('metadata failed'), findsOneWidget);
    expect(find.byKey(const ValueKey('about-version')), findsNothing);
    expect(find.byKey(const ValueKey('settings-about-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-child-save')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('settings about page renders localized metadata labels', (
    tester,
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
    final loader = AboutInfoLoader(
      loadPackageMetadata: () async => (version: '1.2.3', buildNumber: '42'),
      operatingSystem: () => 'linux',
      architecture: () => 'x64',
    );
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
        aboutInfoLoader: loader,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-card-about')),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -160),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-about')));
    await _pumpRealIo(tester);

    expect(find.text('SubDock 版本: 1.2.3'), findsOneWidget);
    expect(find.text('构建号: 42'), findsOneWidget);
    expect(find.text('许可证: GPL-3.0'), findsOneWidget);
    expect(
      find.text('项目主页: https://github.com/Delusions6515/SubDock'),
      findsOneWidget,
    );
    expect(find.text('操作系统: linux'), findsOneWidget);
    expect(find.text('架构: x64'), findsOneWidget);
    expect(find.text('Current version'), findsNothing);
    expect(find.text('Previous version'), findsNothing);
    expect(find.byKey(const ValueKey('settings-child-save')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('desktop navigation exposes semantic tap actions and selection', (
    tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final semantics = tester.ensureSemantics();
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
    final overview = tester.getSemantics(
      find.byKey(const ValueKey('nav-item-overview')),
    );
    expect(
      overview,
      matchesSemantics(
        label: 'Overview',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('nav-item-manage'))),
      matchesSemantics(
        label: 'Manage',
        isButton: true,
        isSelected: false,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.byKey(const ValueKey('nav-item-overview'))),
      matchesSemantics(
        label: 'Overview',
        isButton: true,
        isSelected: false,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('nav-item-manage'))),
      matchesSemantics(
        label: 'Manage',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('desktop navigation localizes semantic labels', (tester) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      SubDockApp(
        coordinator: AppCoordinator(
          runtime: _FakeBackendRuntime(),
          environmentStore: BackendEnvStore(directories!),
        ),
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('nav-item-settings'))),
      matchesSemantics(
        label: '设置',
        isButton: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('logs controls expose localized semantics and state', (
    tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
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
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();

    expect(
      tester.getSemantics(find.text('Current')),
      matchesSemantics(
        label: 'Current',
        isSelected: true,
        hasSelectedState: true,
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        isInMutuallyExclusiveGroup: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.text('History')),
      matchesSemantics(
        label: 'History',
        isSelected: false,
        hasSelectedState: true,
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        isInMutuallyExclusiveGroup: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    final filter = find.byKey(const ValueKey('logs-source-filter'));
    expect(
      tester.getSemantics(filter),
      matchesSemantics(
        label: 'Filters',
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    await tester.tap(filter);
    await tester.pumpAndSettle();
    final warning = find.byKey(const ValueKey('logs-level-warning'));
    expect(
      tester.getSemantics(warning),
      matchesSemantics(
        label: 'Warning',
        isSelected: true,
        hasSelectedState: true,
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    await tester.tap(warning);
    await tester.pump();
    expect(
      tester.getSemantics(warning),
      matchesSemantics(
        label: 'Warning',
        isSelected: false,
        hasSelectedState: true,
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('logs-mobile-sort')));
    await tester.pump();
    await tester.tap(find.text('Newest last').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back').last);
    await tester.pump(const Duration(milliseconds: 500));
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('logs controls localize Chinese semantics', (tester) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      SubDockApp(
        coordinator: AppCoordinator(
          runtime: _FakeBackendRuntime(),
          environmentStore: BackendEnvStore(directories!),
        ),
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();
    expect(
      tester.getSemantics(find.text('当前')),
      matchesSemantics(
        label: '当前',
        isSelected: true,
        hasSelectedState: true,
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        isInMutuallyExclusiveGroup: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('logs-source-filter'))),
      matchesSemantics(
        label: '筛选',
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('settings about page localizes Chinese labels', (tester) async {
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
        aboutInfoLoader: AboutInfoLoader(
          loadPackageMetadata: () async => (version: '1.0.0', buildNumber: '1'),
          operatingSystem: () => 'linux',
          architecture: () => 'x64',
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-card-about')),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -160),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-about')));
    await _pumpRealIo(tester);
    expect(find.text('SubDock 版本: 1.0.0'), findsOneWidget);
    expect(find.text('构建号: 1'), findsOneWidget);
    expect(find.text('许可证: GPL-3.0'), findsOneWidget);
    expect(
      find.text('项目主页: https://github.com/Delusions6515/SubDock'),
      findsOneWidget,
    );
    expect(find.text('操作系统: linux'), findsOneWidget);
    expect(find.text('架构: x64'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-child-save')), findsNothing);
    expect(
      find.byKey(const ValueKey('component-update-local-status-backend')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('component-update-local-status-frontend')),
      findsNothing,
    );
    expect(find.text('当前版本'), findsNothing);
    expect(find.text('上一版本'), findsNothing);
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

  testWidgets('manage reports WebView initialization failures', (
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
        locale: const Locale('zh'),
        webViewControllerFactory:
            ({
              required onNavigationRequest,
              required onBlobMessage,
              required bridgeScript,
              onPageChanged,
            }) => _testWebViewController(
              initialize: () async {
                throw StateError('initialization failed');
              },
              loadRequest: (_) async {},
            ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    await tester.pump();
    runtime.emitState(RuntimeStatus.running);
    await _pumpRealIo(tester);

    expect(
      find.byKey(const ValueKey('manage-browser-toolbar')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('manage-webview-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('manage-webview-loading')), findsNothing);
    expect(find.text('Bad state: initialization failed'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-manage-webview')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manage reports WebView load failures', (
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
        locale: const Locale('zh'),
        webViewControllerFactory:
            ({
              required onNavigationRequest,
              required onBlobMessage,
              required bridgeScript,
              onPageChanged,
            }) => _testWebViewController(
              initialize: () async {},
              loadRequest: (_) async {
                throw StateError('load failed');
              },
            ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    await tester.pump();
    runtime.emitState(RuntimeStatus.running);
    await _pumpRealIo(tester);

    expect(find.byKey(const ValueKey('manage-webview-error')), findsOneWidget);
    expect(find.text('Bad state: load failed'), findsOneWidget);
    expect(find.byKey(const ValueKey('manage-webview-loading')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manage shows loading until the first WebView page finishes', (
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
    final initialized = Completer<void>();

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        locale: const Locale('zh'),
        webViewControllerFactory:
            ({
              required onNavigationRequest,
              required onBlobMessage,
              required bridgeScript,
              onPageChanged,
            }) => _testWebViewController(
              initialize: () => initialized.future,
              loadRequest: (_) async {},
            ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    await tester.pump();
    runtime.emitState(RuntimeStatus.running);
    await _pumpRealIo(tester);

    expect(
      find.byKey(const ValueKey('manage-browser-toolbar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('manage-webview-loading')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('fake-manage-webview')), findsNothing);

    initialized.complete();
    await _pumpRealIo(tester);
    expect(
      find.byKey(const ValueKey('manage-webview-loading')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('fake-manage-webview')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ready manage toolbar follows v5 browser hierarchy', (
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
    Uri? openedUri;
    late EmbeddedPageChangeHandler? pageChanged;
    late EmbeddedNavigationHandler navigationRequest;
    var canGoBack = false;
    var canGoForward = false;
    var wentBack = false;
    var wentForward = false;

    await tester.binding.setSurfaceSize(const Size(600, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        locale: const Locale('zh'),
        onOpenExternalUri: (uri) async {
          openedUri = uri;
          return true;
        },
        webViewControllerFactory:
            ({
              required onNavigationRequest,
              required onBlobMessage,
              required bridgeScript,
              onPageChanged,
            }) {
              pageChanged = onPageChanged;
              navigationRequest = onNavigationRequest;
              return EmbeddedWebViewController.testing(
                initialize: () async {},
                buildWidget: () =>
                    const SizedBox(key: ValueKey('fake-manage-webview')),
                loadRequest: (uri) async => onPageChanged?.call(uri),
                reload: () async {},
                currentUrl: () async => coordinator.webUiUri,
                canGoBack: () async => canGoBack,
                goBack: () async {
                  wentBack = true;
                },
                canGoForward: () async => canGoForward,
                goForward: () async {
                  wentForward = true;
                },
              );
            },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    await tester.pump();
    runtime.emitState(RuntimeStatus.running);
    await _pumpRealIo(tester);

    expect(
      find.byKey(const ValueKey('manage-browser-toolbar')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('manage-url')), findsOneWidget);
    expect(find.text(coordinator.webUiUri.toString()), findsOneWidget);
    final urlDecoration =
        tester
                .widget<Container>(find.byKey(const ValueKey('manage-url')))
                .decoration!
            as BoxDecoration;
    expect(urlDecoration.borderRadius, BorderRadius.circular(8));
    for (final key in [
      'manage-back',
      'manage-forward',
      'manage-reload',
      'manage-open-external',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('manage-back')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('manage-forward')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('manage-open-external')));
    await _pumpRealIo(tester);
    expect(openedUri, coordinator.webUiUri);

    canGoBack = true;
    canGoForward = true;
    pageChanged!.call(Uri.parse('${coordinator.webUiUri}/settings'));
    await _pumpRealIo(tester);
    expect(find.text('${coordinator.webUiUri}/settings'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('manage-back')))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('manage-forward')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('manage-back')));
    await tester.tap(find.byKey(const ValueKey('manage-forward')));
    await _pumpRealIo(tester);
    expect(wentBack, isTrue);
    expect(wentForward, isTrue);
    await tester.tap(find.byKey(const ValueKey('manage-open-external')));
    await _pumpRealIo(tester);
    expect(openedUri, Uri.parse('${coordinator.webUiUri}/settings'));

    final sameOrigin = await navigationRequest(
      EmbeddedNavigationRequest(Uri.parse('${coordinator.webUiUri}/other')),
    );
    expect(sameOrigin, EmbeddedNavigationDecision.navigate);
    final external = Uri.parse('https://example.com/outside');
    expect(
      await navigationRequest(EmbeddedNavigationRequest(external)),
      EmbeddedNavigationDecision.prevent,
    );
    expect(openedUri, external);
    final nonHttp = Uri.parse('mailto:test@example.com');
    expect(
      await navigationRequest(EmbeddedNavigationRequest(nonHttp)),
      EmbeddedNavigationDecision.prevent,
    );
    expect(openedUri, external);

    await tester.binding.setSurfaceSize(const Size(599, 480));
    await tester.pump();
    expect(find.byKey(const ValueKey('manage-url')), findsNothing);
    for (final key in [
      'manage-back',
      'manage-forward',
      'manage-reload',
      'manage-open-external',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
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
    expect(find.byKey(const ValueKey('mobile-navigation')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('mobile-navigation'))).height,
      68,
    );
    expect(tester.getSize(find.byKey(const ValueKey('page-title'))).height, 56);
    await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
    await tester.pump();
    expect(
      tester
          .widget<Offstage>(find.byKey(const ValueKey('page-updates')))
          .offstage,
      isFalse,
    );

    await tester.binding.setSurfaceSize(const Size(600, 800));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('desktop-sidebar')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('mobile-navigation')), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('desktop-chrome'))).height,
      44,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('desktop-sidebar'))).width,
      140,
    );
    expect(tester.getSize(find.byKey(const ValueKey('page-title'))).height, 64);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'shell renders the five pages and the warning banner in dark mode',
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
        'nav-item-updates',
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

    expect(find.byKey(const ValueKey('settings-appearance')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-save-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-subdock-config')), findsNothing);
    expect(
      find.byKey(const ValueKey('settings-card-backend-config')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('settings-raw-env')), findsNothing);
    final l10n = AppLocalizations.of(
      tester.element(find.byKey(const ValueKey('settings-appearance'))),
    )!;
    expect(find.text(l10n.themeHeading), findsOneWidget);
    expect(find.text(l10n.languageHeading), findsOneWidget);
    expect(find.text(l10n.themeSubtitle), findsOneWidget);
    expect(find.text(l10n.languageSubtitle), findsOneWidget);
    expect(find.text(l10n.closeBehaviorSubtitle), findsOneWidget);
    expect(find.text(l10n.recentLogsSubtitle), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(599, 700));
    await tester.pumpAndSettle();
    final mobileTheme = tester.getRect(
      find.byKey(const ValueKey('settings-theme-mode')),
    );
    final mobileLanguage = tester.getRect(
      find.byKey(const ValueKey('settings-language')),
    );
    expect(
      tester
          .widget<Flex>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('settings-theme-row')),
                  matching: find.byType(Flex),
                )
                .first,
          )
          .direction,
      Axis.vertical,
    );
    expect(mobileLanguage.top, greaterThan(mobileTheme.bottom));

    await tester.binding.setSurfaceSize(const Size(600, 700));
    await tester.pumpAndSettle();
    final desktopTheme = tester.getRect(
      find.byKey(const ValueKey('settings-theme-mode')),
    );
    final desktopLanguage = tester.getRect(
      find.byKey(const ValueKey('settings-language')),
    );
    expect(
      tester
          .widget<Flex>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('settings-theme-row')),
                  matching: find.byType(Flex),
                )
                .first,
          )
          .direction,
      Axis.horizontal,
    );
    expect((desktopLanguage.left - desktopTheme.left).abs(), lessThan(1));
    expect(desktopLanguage.top, greaterThan(desktopTheme.bottom));
    expect(find.byKey(const ValueKey('settings-save-all')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    '600x480 Settings backend subpage keeps back and save reachable',
    (tester) async {
      late Directory temp;
      addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
      final directories = await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('subdock_widget_');
        return RuntimeDirectories.fromBaseDirectory(temp);
      });

      await tester.binding.setSurfaceSize(const Size(600, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        SubDockApp(
          coordinator: AppCoordinator(
            runtime: _FakeBackendRuntime(),
            environmentStore: BackendEnvStore(directories!),
          ),
          autoStart: false,
          enableWebView: false,
          locale: const Locale('en'),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
      await tester.pumpAndSettle();
      final backendConfig = find.byKey(
        const ValueKey('settings-card-backend-config'),
      );
      expect(backendConfig, findsOneWidget);
      await tester.ensureVisible(backendConfig);
      await tester.pumpAndSettle();
      await tester.tap(backendConfig);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('settings-back')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-child-save')), findsOneWidget);

      final settingsBack = find.byKey(const ValueKey('settings-back'));
      expect(settingsBack, findsOneWidget);
      await tester.ensureVisible(settingsBack);
      await tester.pumpAndSettle();
      await tester.tap(settingsBack);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-appearance')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('599x480 updates page uses mobile hierarchy', (tester) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });

    final updates = _FakeComponentUpdateOperations();
    final runtime = _FakeBackendRuntime();

    await tester.binding.setSurfaceSize(const Size(599, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      SubDockApp(
        coordinator: AppCoordinator(
          runtime: runtime,
          environmentStore: BackendEnvStore(directories!),
          componentUpdates: updates,
        ),
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
    await _pumpRealIo(tester);
    runtime.emitState(RuntimeStatus.running);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('updates-list')),
          )
          .padding,
      const EdgeInsets.only(top: 12, left: 12, right: 12, bottom: 24),
    );
    expect(
      tester
          .widget<Flex>(find.byKey(const ValueKey('component-layout-frontend')))
          .direction,
      Axis.vertical,
    );
    expect(
      tester
          .widget<Flex>(find.byKey(const ValueKey('component-layout-backend')))
          .direction,
      Axis.vertical,
    );
    expect(
      tester
          .widget<Flex>(
            find.byKey(const ValueKey('updates-backend-notice-layout')),
          )
          .direction,
      Axis.vertical,
    );
    expect(
      find.byKey(const ValueKey('updates-independent-section')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('updates-packaged-grid')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('component-release-notes-frontend')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('component-update-action-frontend')),
      findsNothing,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('updates-packaged-node'))).width,
      greaterThan(500),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('600x480 updates page uses desktop hierarchy', (tester) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });

    final updates = _FakeComponentUpdateOperations()
      ..statuses[ComponentKind.backend] = const ComponentVersionStatus(
        current: '2.0.0',
        previous: '1.0.0',
      );
    final runtime = _FakeBackendRuntime();

    await tester.binding.setSurfaceSize(const Size(600, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      SubDockApp(
        coordinator: AppCoordinator(
          runtime: runtime,
          environmentStore: BackendEnvStore(directories!),
          componentUpdates: updates,
        ),
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
    await _pumpRealIo(tester);
    runtime.emitState(RuntimeStatus.running);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('updates-list')),
          )
          .padding,
      const EdgeInsets.all(24),
    );
    expect(
      tester
          .widget<Flex>(find.byKey(const ValueKey('component-layout-frontend')))
          .direction,
      Axis.horizontal,
    );
    expect(
      tester
          .widget<Flex>(find.byKey(const ValueKey('component-layout-backend')))
          .direction,
      Axis.horizontal,
    );
    expect(
      tester
          .widget<Flex>(
            find.byKey(const ValueKey('updates-backend-notice-layout')),
          )
          .direction,
      Axis.horizontal,
    );
    expect(
      find.byKey(const ValueKey('updates-independent-section')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('updates-packaged-http-meta')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('updates-packaged-mihomo')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('updates-packaged-node')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('updates-packaged-node'))).width,
      lessThan(300),
    );
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

  testWidgets('a delayed preference save does not clear newer general edits', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final store = _DelayedDesktopPreferencesStore(directories!);
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
        preferences: DesktopPreferences.defaults,
        preferencesStore: store,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('settings-close-behavior')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-close-behavior')));
    await tester.pump();
    await tester.tap(find.text('关闭到托盘'));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('settings-save-all')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('settings-save-all')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    await tester.ensureVisible(find.text('深色'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(SegmentedButton<ThemeMode>),
        matching: find.text('深色'),
      ),
    );
    await tester.pump();

    store.releaseNext();
    await _pumpRealIo(tester);
    expect(store.saved.single.closeBehavior, CloseBehavior.closeToTray);
    expect(store.saved.single.themeMode, ThemeMode.system);

    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('settings-save-all')))
          .onPressed,
      isNotNull,
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
    expect(find.text('Appearance & Language'), findsWidgets);
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

EmbeddedWebViewController _testWebViewController({
  required Future<void> Function() initialize,
  required Future<void> Function(Uri uri) loadRequest,
}) => EmbeddedWebViewController.testing(
  initialize: initialize,
  buildWidget: () => const SizedBox(key: ValueKey('fake-manage-webview')),
  loadRequest: loadRequest,
  reload: () async {},
  currentUrl: () async => Uri.parse('http://127.0.0.1:3001/'),
  canGoBack: () async => false,
  goBack: () async {},
  canGoForward: () async => false,
  goForward: () async {},
);

class _DelayedDesktopPreferencesStore extends DesktopPreferencesStore {
  _DelayedDesktopPreferencesStore(super.directories);

  final saved = <DesktopPreferences>[];
  final _pending = <Completer<void>>[];

  @override
  Future<void> save(DesktopPreferences preferences) async {
    saved.add(preferences);
    final completer = Completer<void>();
    _pending.add(completer);
    await completer.future;
  }

  void releaseNext() => _pending.removeAt(0).complete();
}

class _FakeBackendRuntime extends BackendRuntime {
  final _logs = StreamController<RuntimeLog>.broadcast(sync: true);
  final _states = StreamController<RuntimeState>.broadcast(sync: true);
  var starts = 0;
  var stops = 0;
  var restarts = 0;
  Object? restartError;

  void emitLog(RuntimeLog log) => _logs.add(log);

  void emitState(
    RuntimeStatus status, {
    HttpMetaStatus httpMetaStatus = HttpMetaStatus.disabled,
    int? httpMetaPort,
    String? httpMetaVersion,
  }) => _states.add(
    RuntimeState(
      status: status,
      changedAt: DateTime.now(),
      httpMetaStatus: httpMetaStatus,
      httpMetaPort: httpMetaPort,
      httpMetaVersion: httpMetaVersion,
    ),
  );

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
    if (restartError != null) throw restartError!;
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
  final statusErrors = <ComponentKind, Object>{};
  final statuses = <ComponentKind, ComponentVersionStatus>{};
  final checkCalls = <ComponentKind, int>{};
  final checkResults = <ComponentKind, ComponentUpdate>{};
  final checkErrors = <ComponentKind, Object>{};
  final updateErrors = <ComponentKind, Object>{};
  final rollbackErrors = <ComponentKind, Object>{};
  final updateCalls = <ComponentUpdate>[];
  final rollbackCalls = <ComponentKind>[];

  @override
  Future<ComponentVersionStatus> status(ComponentKind kind) async {
    statusCalls[kind] = (statusCalls[kind] ?? 0) + 1;
    final error = statusErrors[kind];
    if (error != null) throw error;
    final configured = statuses[kind];
    if (configured != null) return configured;
    return ComponentVersionStatus(
      current: '${kind.name}-current',
      previous: kind == ComponentKind.backend ? '${kind.name}-previous' : null,
    );
  }

  @override
  Future<ComponentUpdate> check(ComponentKind kind) async {
    checkCalls[kind] = (checkCalls[kind] ?? 0) + 1;
    final error = checkErrors[kind];
    if (error != null) throw error;
    return checkResults[kind] ??
        ComponentUpdate(
          kind: kind,
          currentVersion: '1.0.0',
          availableVersion: '1.0.0',
          release: GithubRelease(
            version: '1.0.0',
            releaseUri: Uri.parse('https://example.invalid/${kind.name}'),
            assets: const [],
          ),
        );
  }

  @override
  Future<void> rollback(ComponentKind kind) async {
    rollbackCalls.add(kind);
    final error = rollbackErrors[kind];
    if (error != null) throw error;
    final status = statuses[kind];
    if (status != null && status.previous != null) {
      statuses[kind] = ComponentVersionStatus(
        current: status.previous!,
        previous: status.current,
      );
    }
  }

  @override
  Future<void> update(ComponentUpdate update) async {
    updateCalls.add(update);
    final error = updateErrors[update.kind];
    if (error != null) throw error;
    final status = statuses[update.kind];
    statuses[update.kind] = ComponentVersionStatus(
      current: update.availableVersion,
      previous: status?.current ?? update.currentVersion,
    );
  }
}

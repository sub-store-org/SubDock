import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart'
    show
        Brightness,
        Axis,
        BorderRadius,
        BoxDecoration,
        ClipRRect,
        Container,
        ChoiceChip,
        DropdownButton,
        FilledButton,
        Flex,
        IconButton,
        InputDecorator,
        Locale,
        Material,
        ListTile,
        ListView,
        OutlinedButton,
        OutlineInputBorder,
        Expanded,
        RoundedRectangleBorder,
        SelectableText,
        Scrollable,
        SegmentedButton,
        Switch,
        Theme,
        ThemeMode,
        Text,
        TextButton,
        TextField,
        ValueNotifier;
import 'package:flutter/scheduler.dart' show AppLifecycleState;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show EdgeInsets, GestureDetector, Offstage, Padding, SizedBox, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show ShadLocalizations, ShadTheme;
import 'package:subdock/app/app.dart';
import 'package:subdock/app/about_info.dart';
import 'package:subdock/app/app_coordinator.dart';
import 'package:subdock/app/app_typography.dart'
    show uiMonoFontFamily, uiTextFontFamily;
import 'package:subdock/app/embedded_webview.dart';
import 'package:subdock/app/mobile_placeholder_runtime.dart';
import 'package:subdock/app/maintenance_operation.dart';
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
import 'package:subdock/update/maintenance_attempt_store.dart';

import 'support/pump_app.dart';

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
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));

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

    await pumpApp(
      tester,
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

    await pumpApp(
      tester,
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

    await pumpApp(
      tester,
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

    await pumpApp(
      tester,
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
    await tester.pumpAndSettle();
    final httpMetaSwitch = find.byKey(
      const ValueKey('settings-http-meta-toggle'),
    );
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
    await pumpApp(
      tester,
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
    // 来源/级别是单一选择(ChoiceChip),默认都是「全部」即未选中具体项。
    final httpMeta = find.byKey(const ValueKey('logs-source-HTTP-META'));
    final back = find.byKey(const ValueKey('logs-source-Backend'));
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('logs-source-all')))
          .selected,
      isTrue,
    );
    expect(tester.widget<ChoiceChip>(httpMeta).selected, isFalse);
    expect(tester.widget<ChoiceChip>(back).selected, isFalse);
    await tester.tap(back);
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

  testWidgets('logs layout aligns toolbar and card at 599 and 600 pixels', (
    WidgetTester tester,
  ) async {
    final fixture = await _widgetRuntime(tester);
    await tester.binding.setSurfaceSize(const Size(600, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: fixture.coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );
    for (final message in const [
      'mobile fixture',
      'http meta fixture',
      'desktop fixture',
    ]) {
      fixture.runtime.emitLog(
        RuntimeLog(
          timestamp: DateTime.utc(2026, 9, 13, 4, 30),
          source: RuntimeLogSource.stdout,
          message: message,
        ),
      );
    }
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();

    for (final width in const [600.0, 599.0]) {
      await tester.binding.setSurfaceSize(Size(width, 700));
      await tester.pump();
      final compact = width < 600;
      final toolbar = find.byKey(
        ValueKey(compact ? 'logs-mobile-toolbar' : 'logs-desktop-toolbar'),
      );
      final surface = find.byKey(const ValueKey('logs-surface'));
      final row = find.byKey(
        ValueKey(compact ? 'logs-mobile-row' : 'logs-desktop-row'),
      );
      expect(toolbar, findsOneWidget);
      expect(row, findsNWidgets(3));
      expect(find.descendant(of: surface, matching: toolbar), findsNothing);

      final toolbarRect = tester.getRect(toolbar);
      final surfaceRect = tester.getRect(surface);
      final searchRect = tester.getRect(
        find.byKey(const ValueKey('logs-search')),
      );
      expect((toolbarRect.left - surfaceRect.left).abs(), lessThan(0.5));
      expect((toolbarRect.right - surfaceRect.right).abs(), lessThan(0.5));
      expect((searchRect.left - surfaceRect.left).abs(), lessThan(0.5));
      expect(toolbarRect.bottom, lessThanOrEqualTo(surfaceRect.top));

      if (!compact) {
        final card = tester.widget<Material>(
          find.descendant(of: surface, matching: find.byType(Material)).first,
        );
        expect(
          (card.shape! as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(12),
        );
        final searchBorder =
            tester
                    .widget<InputDecorator>(
                      find.descendant(
                        of: find.byKey(const ValueKey('logs-search')),
                        matching: find.byType(InputDecorator),
                      ),
                    )
                    .decoration
                    .enabledBorder
                as OutlineInputBorder;
        expect(searchBorder.borderRadius, BorderRadius.circular(8));
      }
      expect(tester.takeException(), isNull);
    }

    await tester.enterText(
      find.byKey(const ValueKey('logs-search')),
      'no-match',
    );
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('logs-surface')),
        matching: find.text('没有匹配的日志'),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('current logs capture the run limit and classify levels', (
    WidgetTester tester,
  ) async {
    final fixture = await _widgetRuntime(tester);
    final runtime = fixture.runtime;
    final directories = fixture.directories;
    final coordinator = fixture.coordinator;
    await tester.binding.setSurfaceSize(const Size(600, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(
      () =>
          File.fromUri(directories.logs.uri.resolve('backend.log'))
              .writeAsString('legacy entry'),
    );
    await pumpApp(
      tester,
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

    expect(find.byKey(const ValueKey('logs-surface')), findsOneWidget);
    expect(find.byKey(const ValueKey('overview-recent-logs')), findsNothing);
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
    expect(find.text('legacy entry'), findsNothing);

    runtime.emitState(RuntimeStatus.starting);
    runtime.emitRunStarted('fixture-run-1');
    runtime.emitState(
      RuntimeStatus.running,
      httpMetaStatus: HttpMetaStatus.running,
    );
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

    const classifications = {
      'non-prefix trace panic': '调试',
      'debug1 error404 panic_mode': '信息',
      'non-prefix panic': '错误',
    };
    for (final entry in classifications.entries) {
      runtime.emitLog(
        RuntimeLog(
          timestamp: DateTime.now(),
          source: RuntimeLogSource.stdout,
          message: entry.key,
        ),
      );
      await tester.pump();
      final message = find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.data == entry.key,
      );
      expect(message, findsOneWidget);
      final row = find.ancestor(
        of: message,
        matching: find.byKey(const ValueKey('logs-desktop-row')),
      );
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text(entry.value)),
        findsOneWidget,
      );
    }

    await tester.enterText(find.byType(TextField), 'Backend');
    await tester.pump();
    expect(find.byType(SelectableText), findsNothing);
    await tester.enterText(find.byType(TextField), 'log-0');
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
    await tester.tap(find.text('HTTP-META').last);
    await tester.pump();
    // 单一审(HTTP-META)下,后端日志 log-59 被过滤掉。
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.byKey(const ValueKey('logs-source-filter')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Backend').last);
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText && widget.data?.contains('log-59') == true,
      ),
      findsOneWidget,
    );

    for (final entry in [
      (message: 'sort-oldest', timestamp: DateTime.utc(2020)),
      (message: 'sort-newest', timestamp: DateTime.utc(2025)),
    ]) {
      runtime.emitLog(
        RuntimeLog(
          timestamp: entry.timestamp,
          source: RuntimeLogSource.stdout,
          message: entry.message,
        ),
      );
    }
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'sort-');
    await tester.tap(find.byKey(const ValueKey('logs-sort-selector')));
    await tester.pump();
    await tester.tap(find.text('最早在前').last);
    await tester.pump();
    List<String?> sortedMessages() => tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.data)
        .toList();
    var sortedRows = sortedMessages();
    expect(sortedRows, ['sort-oldest', 'sort-newest']);
    await tester.tap(find.byKey(const ValueKey('logs-sort-selector')));
    await tester.pump();
    await tester.tap(find.text('最新在前').last);
    await tester.pump();
    sortedRows = sortedMessages();
    expect(sortedRows, ['sort-newest', 'sort-oldest']);
    await tester.enterText(find.byType(TextField), '');

    await tester.enterText(find.byType(TextField), 'panic');
    await tester.tap(find.byKey(const ValueKey('nav-item-overview')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'panic',
    );
    final retainedSearchResults = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.data ?? '');
    expect(retainedSearchResults, isNotEmpty);
    expect(
      retainedSearchResults.every((message) => message.contains('panic')),
      isTrue,
    );

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
    await tester.tap(find.text('HTTP-META').last);
    await tester.pump();
    expect(find.textContaining('HTTP-META info line'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('logs-source-filter')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Backend').last);
    await tester.pump();
    expect(find.textContaining('HTTP-META info line'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('logs-source-filter')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('全部').last);
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

    final follow = find.byKey(const ValueKey('logs-follow-toggle'));
    await tester.ensureVisible(follow);
    await tester.tap(follow);
    for (var index = 0; index < 55; index++) {
      runtime.emitLog(
        RuntimeLog(
          timestamp: DateTime.now(),
          source: RuntimeLogSource.stdout,
          message: 'paused-$index',
        ),
      );
    }
    await tester.pump();
    expect(find.text('新增日志：55'), findsOneWidget);

    runtime.emitRunStarted('fixture-run-2');
    runtime.emitState(
      RuntimeStatus.running,
      httpMetaStatus: HttpMetaStatus.degraded,
    );
    for (var index = 0; index < 60; index++) {
      runtime.emitLog(
        RuntimeLog(
          timestamp: DateTime.now(),
          source: RuntimeLogSource.stdout,
          message: 'new-run-$index',
        ),
      );
    }
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('logs-search')), 'log-59');
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText && widget.data?.contains('log-59') == true,
      ),
      findsOneWidget,
    );
    expect(find.text('新增日志：115'), findsOneWidget);

    runtime.emitState(RuntimeStatus.stopping);
    await tester.pump();
    expect(find.byType(SelectableText), findsWidgets);
    runtime.emitState(RuntimeStatus.stopped);
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText && widget.data?.contains('log-59') == true,
      ),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('logs-search')),
      'new-run-59',
    );
    await tester.pump();
    await tester.tap(follow);
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data?.contains('new-run-59') == true,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText && widget.data?.contains('log-59') == true,
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('log recovery retries without autostart or clearing blockers', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final writer = RuntimeLogStore(directories!);
    late String healthyRunId;
    late String runId;
    await tester.runAsync(() async {
      await writer.initialize();
      healthyRunId = await writer.beginRun();
      await writer.append(
        RuntimeLog(
          timestamp: DateTime.utc(2026, 10, 16),
          source: RuntimeLogSource.stdout,
          message: 'healthy history remains readable',
        ),
      );
      await writer.finalize();
      runId = await writer.beginRun();
      await writer.append(
        RuntimeLog(
          timestamp: DateTime.utc(2026, 10, 16),
          source: RuntimeLogSource.stdout,
          message: 'recoverable prefix',
        ),
      );
    });
    final eventFile = File.fromUri(
      directories.logs.uri.resolve('runs/$runId/000000.jsonl'),
    );
    final originalEvents = await tester.runAsync(() => eventFile.readAsBytes());
    await tester.runAsync(
      () => eventFile.writeAsString(
        '{malformed}\n',
        mode: FileMode.append,
        flush: true,
      ),
    );
    final logStore = RuntimeLogStore(directories);
    final logRecoveryError = await tester.runAsync(() async {
      try {
        await logStore.initialize();
      } catch (error) {
        return error;
      }
      return null;
    });
    expect(logRecoveryError, isA<FormatException>());

    final startupBlocker = StateError('Component recovery remains required');
    final runtime = _FakeBackendRuntime();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories),
      logStore: logStore,
      initialLogRecoveryError: logRecoveryError,
      startupBlocker: startupBlocker,
    );
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: coordinator,
        enableWebView: false,
        locale: const Locale('en'),
      ),
    );
    expect(find.byKey(const ValueKey('log-recovery-banner')), findsOneWidget);
    expect(runtime.starts, 0);

    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();
    await tester.tap(find.text('History'));
    await _pumpRealIo(tester);
    final healthyTile = find.byKey(ValueKey('history-run-$healthyRunId'));
    expect(healthyTile, findsOneWidget);
    await tester.tap(healthyTile);
    await _pumpRealIo(tester);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data?.contains('healthy history remains readable') == true,
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('history-back')));
    await tester.pump();

    final deleteButton = find.descendant(
      of: healthyTile,
      matching: find.byType(IconButton),
    );
    expect(tester.widget<IconButton>(deleteButton).onPressed, isNull);
    final clearButton = find.widgetWithText(TextButton, 'Clear history');
    expect(tester.widget<TextButton>(clearButton).onPressed, isNull);
    expect(find.byKey(const ValueKey('recently-deleted')), findsNothing);
    expect(find.byKey(const ValueKey('history-delete-confirm')), findsNothing);

    await tester.runAsync(
      () => eventFile.writeAsBytes(originalEvents!, flush: true),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('log-recovery-banner')),
        matching: find.text('Retry'),
      ),
    );
    await _pumpUntilLogRecoveryCompletes(tester);
    expect(coordinator.logRecoveryError, isNull);
    expect(find.byKey(const ValueKey('log-recovery-banner')), findsNothing);
    expect(runtime.starts, 0);
    expect(coordinator.startupBlocker, same(startupBlocker));

    await tester.tap(find.text('Current'));
    await tester.pump();
    await tester.tap(find.text('History'));
    await _pumpRealIo(tester);
    final runTile = find.byKey(ValueKey('history-run-$runId'));
    expect(runTile, findsOneWidget);
    final subtitle = tester.widget<ListTile>(runTile).subtitle! as Text;
    expect(subtitle.data, contains('Incomplete log capture'));
    final storedLogs = await tester.runAsync(() => logStore.readRun(runId));
    expect(storedLogs!.single.message, 'recoverable prefix');
    expect(tester.widget<IconButton>(deleteButton).onPressed, isNotNull);
    expect(tester.widget<TextButton>(clearButton).onPressed, isNotNull);
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
    late String runId;
    await tester.runAsync(() async {
      await store.initialize();
      runId = await store.beginRun();
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
    await pumpApp(
      tester,
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
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('history-delete-confirm')));
    await _pumpRealIo(tester);
    expect(find.text('已删除'), findsWidgets);
    await tester.tap(find.text('撤销').last);
    await _pumpRealIo(tester);
    await _pumpUntilRestoredHistoryRun(tester, runId);
    expect(find.byType(ListTile), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('history retries the displayed list read after delete failure', (
    WidgetTester tester,
  ) async {
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
          message: 'retry the list read',
        ),
      );
      await store.finalize();
    });
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories),
      logStore: store,
    );
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();
    await tester.tap(find.text('History'));
    await _pumpRealIo(tester);

    final runTile = find.byKey(ValueKey('history-run-$runId'));
    expect(runTile, findsOneWidget);
    final trashPath = directories.logs.uri.resolve('trash').toFilePath();
    final savedTrash = Directory.fromUri(
      directories.logs.uri.resolve('trash-saved/'),
    );
    await tester.runAsync(() async {
      await Directory(trashPath).rename(savedTrash.path);
      await File(trashPath).writeAsString('blocks trash access', flush: true);
    });
    await tester.tap(find.byTooltip('Delete run'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('history-delete-confirm')));
    await _pumpRealIo(tester);
    final actionError = find.text(
      'A history change failed. Retry the action to try again.',
    );
    expect(actionError, findsOneWidget);

    await tester.runAsync(() async {
      await File(trashPath).delete();
      await savedTrash.rename(trashPath);
    });
    await tester.tap(find.text('Current'));
    await tester.pump();
    await tester.tap(find.text('History'));
    await _pumpRealIo(tester);
    expect(find.text('Unable to load history'), findsNothing);
    expect(actionError, findsOneWidget);

    final metadata = File.fromUri(
      directories.logs.uri.resolve('runs/$runId/meta.json'),
    );
    final savedMetadata = await tester.runAsync(() => metadata.readAsBytes());
    await tester.runAsync(() => metadata.writeAsString('{', flush: true));
    await tester.tap(find.text('Current'));
    await tester.pump();
    await tester.tap(find.text('History'));
    await _pumpRealIo(tester);
    expect(find.text('Unable to load history'), findsOneWidget);
    expect(actionError, findsOneWidget);

    await tester.runAsync(
      () => metadata.writeAsBytes(savedMetadata!, flush: true),
    );
    await tester.tap(find.byKey(const ValueKey('history-list-retry')));
    await _pumpRealIo(tester);
    expect(find.text('Unable to load history'), findsNothing);
    expect(actionError, findsOneWidget);
    expect(find.byKey(const ValueKey('history-delete-confirm')), findsNothing);
    expect(find.byKey(ValueKey('history-run-$runId')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('current logs expose an incomplete run finalization retry', (
    WidgetTester tester,
  ) async {
    final fixture = await _widgetRuntime(tester);
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: fixture.coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();

    const runId = 'failed-finalization-run';
    fixture.runtime.emitRunStarted(runId);
    fixture.runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.utc(2026, 10, 16),
        source: RuntimeLogSource.stdout,
        message: 'visible durable prefix',
      ),
    );
    fixture.runtime.emitLogRunUpdate(
      const RuntimeLogRunUpdate(
        runId: runId,
        integrity: RuntimeLogIntegrity.incomplete,
        finalized: true,
        persistenceConfirmed: false,
        retryAvailable: true,
      ),
    );
    await tester.pump();

    expect(find.text('visible durable prefix'), findsOneWidget);
    expect(
      find.text(
        'Log data could not be fully saved. Saving the status for this run could not be confirmed.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('logs-retry-finalization')));
    await tester.pump();
    expect(fixture.runtime.logFinalizationRetries, [runId]);
    fixture.runtime.emitLogRunUpdate(
      const RuntimeLogRunUpdate(
        runId: runId,
        integrity: RuntimeLogIntegrity.incomplete,
        finalized: true,
        persistenceConfirmed: true,
        retryAvailable: false,
      ),
    );
    await tester.pump();
    expect(find.text('Incomplete log capture'), findsOneWidget);
    expect(
      find.text(
        'Log data could not be fully saved. Saving the status for this run could not be confirmed.',
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('logs show completed maintenance while Backend is stopped', (
    WidgetTester tester,
  ) async {
    final updates = _FakeComponentUpdateOperations();
    updates.statuses[ComponentKind.backend] = const ComponentVersionStatus(
      current: '1.0.0',
      previous: '0.9.0',
    );
    final fixture = await _widgetRuntime(tester, componentUpdates: updates);
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: fixture.coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
      ),
    );
    await tester.runAsync(
      () => fixture.coordinator.updateComponent(
        ComponentUpdate(
          kind: ComponentKind.backend,
          currentVersion: '1.0.0',
          availableVersion: '2.0.0',
          release: GithubRelease(
            version: '2.0.0',
            releaseUri: Uri.parse('https://example.invalid/backend'),
            assets: const [],
          ),
        ),
      ),
    );
    expect(fixture.runtime.currentState.status, RuntimeStatus.stopped);

    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('logs-maintenance-activity')),
      findsOneWidget,
    );
    expect(find.text('组件维护活动'), findsOneWidget);
    expect(find.textContaining('维护已完成'), findsOneWidget);
    expect(find.textContaining('Backend'), findsWidgets);
    expect(find.byKey(const ValueKey('log-row-message')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('history read retries preserve the selected run and query', (
    WidgetTester tester,
  ) async {
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
          message: 'retry-marker payload',
        ),
      );
      await store.finalize();
    });
    final runDirectory = Directory.fromUri(
      directories.logs.uri.resolve('runs/$runId/'),
    );
    final unavailableDirectory = Directory.fromUri(
      directories.logs.uri.resolve('runs/$runId-unavailable/'),
    );
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories),
      logStore: store,
    );
    await pumpApp(
      tester,
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
    await tester.enterText(
      find.byKey(const ValueKey('logs-search')),
      'retry-marker',
    );
    await tester.runAsync(() => runDirectory.rename(unavailableDirectory.path));
    await tester.tap(runTile);
    await _pumpRealIo(tester);

    expect(find.text('无法加载历史记录'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('logs-search')))
          .controller!
          .text,
      'retry-marker',
    );
    expect(find.byKey(const ValueKey('history-back')), findsOneWidget);

    await tester.runAsync(() => unavailableDirectory.rename(runDirectory.path));
    await tester.tap(find.text('重试'));
    await _pumpRealIo(tester);
    expect(find.textContaining('retry-marker payload'), findsOneWidget);
    final platform =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var copied = '';
    platform.setMockMethodCallHandler(SystemChannels.platform, (call) {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => platform.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await Clipboard.setData(const ClipboardData(text: 'existing clipboard'));
    expect(copied, 'existing clipboard');

    await tester.runAsync(() => runDirectory.rename(unavailableDirectory.path));
    await tester.tap(find.byKey(const ValueKey('logs-copy-filtered')));
    await _pumpRealIo(tester);
    expect(copied, 'existing clipboard');
    expect(find.text('无法加载历史记录'), findsOneWidget);

    await tester.runAsync(() => unavailableDirectory.rename(runDirectory.path));
    await tester.tap(find.text('重试'));
    await _pumpRealIo(tester);
    await tester.tap(find.byKey(const ValueKey('logs-copy-filtered')));
    await _pumpRealIo(tester);
    expect(copied, contains('retry-marker payload'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('history copies every query match in the selected sort', (
    WidgetTester tester,
  ) async {
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
      for (var index = 0; index < 410; index++) {
        await store.append(
          RuntimeLog(
            timestamp: DateTime.now(),
            source: RuntimeLogSource.stdout,
            message: 'copy-entry-${index.toString().padLeft(3, '0')} info',
          ),
        );
      }
      await store.append(
        RuntimeLog(
          timestamp: DateTime.now(),
          source: RuntimeLogSource.stdout,
          message: 'copy-entry-failure error',
        ),
      );
      await store.append(
        RuntimeLog(
          timestamp: DateTime.now(),
          source: RuntimeLogSource.httpMetaStdout,
          message: 'copy-entry-auxiliary info',
        ),
      );
      await store.finalize();
    });
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories),
      logStore: store,
    );
    await pumpApp(
      tester,
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
    await tester.tap(find.byKey(ValueKey('history-run-$runId')));
    await _pumpRealIo(tester);

    await tester.enterText(
      find.byKey(const ValueKey('logs-search')),
      'COPY-ENTRY',
    );
    await _pumpRealIo(tester);
    await tester.tap(find.byKey(const ValueKey('logs-source-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Backend').last);
    await _pumpRealIo(tester);
    await tester.tap(find.byKey(const ValueKey('logs-level-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('信息').last);
    await _pumpRealIo(tester);
    await tester.tap(find.byKey(const ValueKey('logs-sort-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最早在前').last);
    await _pumpRealIo(tester);

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data?.contains('copy-entry-000 info') == true,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data?.contains('copy-entry-409 info') == true,
      ),
      findsNothing,
    );
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
    await tester.tap(find.byKey(const ValueKey('logs-copy-filtered')));
    await _pumpRealIo(tester);

    final copiedLines = copied!.split('\n');
    expect(copiedLines, hasLength(410));
    expect(copiedLines.first, contains('copy-entry-000 info'));
    expect(copiedLines.last, contains('copy-entry-409 info'));
    expect(copiedLines.any((line) => line.contains('auxiliary')), isFalse);
    expect(copiedLines.any((line) => line.contains('failure error')), isFalse);
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
    await pumpApp(
      tester,
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
    await tester.pumpAndSettle();
    expect(find.text('删除这次运行记录？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(runTile, findsOneWidget);
    expect(find.byKey(const ValueKey('recently-deleted')), findsNothing);

    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('history-delete-confirm')));
    await _pumpRealIo(tester);
    expect(find.byKey(const ValueKey('recently-deleted')), findsOneWidget);
    expect(find.text('撤销'), findsWidgets);
    await tester.tap(find.text('撤销').last);
    await _pumpRealIo(tester);
    await _pumpUntilRestoredHistoryRun(tester, runId);
    expect(find.byKey(ValueKey('history-run-$runId')), findsOneWidget);
    await tester.tap(find.text('清空历史'));
    await tester.pumpAndSettle();
    expect(find.text('清空已结束的运行记录？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('history-delete-confirm')));
    await _pumpRealIo(tester);
    expect(find.byKey(ValueKey('history-run-$runId')), findsNothing);
    expect(find.byKey(const ValueKey('recently-deleted')), findsOneWidget);
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

    await pumpApp(
      tester,
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

  testWidgets('overview displays component health and runtime statistics', (
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

    await pumpApp(
      tester,
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
    // http-meta 身份行带健康状态徽章（running -> 健康），与 Backend 对称。
    final httpMetaTop = tester.widget<Flex>(
      find.byKey(const ValueKey('overview-http-meta-hero-top')),
    );
    expect(httpMetaTop.direction, Axis.vertical);
    expect(httpMetaTop.children.length, 3);
    // 徽章是健康/状态词，不是「随 SubDock 提供」bundled 徽章。
    expect(find.text('随 SubDock 提供'), findsNothing);
    // HTTP-META 身份行带一个状态徽章（健康或状态词，视运行时状态）。
    expect(
      find.byKey(const ValueKey('overview-http-meta-badge')),
      findsOneWidget,
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
    // http-meta 身份行带健康徽章，桌面方向为水平。
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
    expect(find.text('独立运行状态；资源随 SubDock 安装包提供，不属于独立更新组件。'), findsNothing);
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
    // 组件卡片同时显示名称、监听端口和健康状态。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('overview-http-meta-hero')),
        matching: find.text('HTTP-META'),
      ),
      findsOneWidget,
    );
    // 端口是 hero 大字（呼应 Backend 版本大字），status 在 meta 行。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('overview-http-meta-hero')),
        matching: find.text('9876'),
      ),
      findsOneWidget,
    );
    // HTTP-META 版本不再在 Overview 显示（只显示健康状态）。
    expect(find.text('1.3.0'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('overview-http-meta-hero')),
        matching: find.textContaining('9876'),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('overview-http-meta-hero')),
        matching: find.textContaining('运行中'),
      ),
      findsOneWidget,
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
    await pumpApp(
      tester,
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

  testWidgets(
    'startup does not start after completed stopped-origin maintenance',
    (tester) async {
      late Directory temp;
      addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
      final directories = await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('subdock_widget_');
        return RuntimeDirectories.fromBaseDirectory(temp);
      });

      final normalRuntime = _FakeBackendRuntime();
      final normalCoordinator = AppCoordinator(
        runtime: normalRuntime,
        environmentStore: BackendEnvStore(directories!),
      );
      await pumpApp(
        tester,
        SubDockApp(
          coordinator: normalCoordinator,
          enableWebView: false,
          locale: const Locale('en'),
        ),
      );
      await _pumpRealIo(tester);
      expect(normalRuntime.starts, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.runAsync(() => normalCoordinator.dispose());

      final attemptStore = MaintenanceAttemptStore(directories);
      await tester.runAsync(
        () => attemptStore.save(
          MaintenanceAttempt(
            targets: const [
              MaintenanceTarget(
                kind: ComponentKind.frontend,
                action: MaintenanceAction.update,
                currentVersion: '1.0.0',
                targetVersion: '1.1.0',
              ),
            ],
            completed: const [ComponentKind.frontend],
            phase: MaintenancePhase.updating,
            restoreAfterChanges: false,
            startOnly: false,
          ),
        ),
      );
      final updates = _FakeComponentUpdateOperations()
        ..statuses[ComponentKind.frontend] = const ComponentVersionStatus(
          current: '1.1.0',
          previous: '1.0.0',
        );
      final runtime = _FakeBackendRuntime();
      final coordinator = AppCoordinator(
        runtime: runtime,
        environmentStore: BackendEnvStore(directories),
        componentUpdates: updates,
        maintenanceAttemptStore: attemptStore,
      );
      await tester.runAsync(() => coordinator.restoreMaintenanceAttempt());

      await pumpApp(
        tester,
        SubDockApp(
          coordinator: coordinator,
          enableWebView: false,
          locale: const Locale('en'),
        ),
      );
      await _pumpRealIo(tester);
      expect(runtime.starts, 0);
      expect(runtime.currentState.status, RuntimeStatus.stopped);
      expect(await tester.runAsync(attemptStore.load), isNull);

      await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
      await _pumpRealIo(tester);
      expect(
        coordinator.maintenanceOperation?.phase,
        MaintenancePhase.completed,
      );
      expect(
        find.byKey(const ValueKey('updates-maintenance-result')),
        findsOneWidget,
      );
      expect(find.text('Component maintenance completed.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('updates-maintenance-retry')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'updates layout keeps packaged resources distinct at 599 and 600 pixels',
    (WidgetTester tester) async {
      final updates = _FakeComponentUpdateOperations();
      final fixture = await _widgetRuntime(tester, componentUpdates: updates);
      await tester.binding.setSurfaceSize(const Size(600, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpApp(
        tester,
        SubDockApp(
          coordinator: fixture.coordinator,
          autoStart: false,
          enableWebView: false,
          locale: const Locale('en'),
        ),
      );
      fixture.runtime.emitState(
        RuntimeStatus.running,
        httpMetaStatus: HttpMetaStatus.running,
        httpMetaPort: 9876,
        httpMetaVersion: '1.3.0',
        httpMetaMihomoVersion: 'v1.19.30',
      );
      await _pumpRealIo(tester);
      await tester.tap(find.byKey(const ValueKey('nav-item-updates')));
      await _pumpRealIo(tester);

      const tileKeys = [
        ValueKey('updates-packaged-http-meta'),
        ValueKey('updates-packaged-mihomo'),
        ValueKey('updates-packaged-node'),
      ];
      final packagedSection = find.byKey(
        const ValueKey('updates-packaged-section'),
      );
      for (final width in const [600.0, 599.0]) {
        await tester.binding.setSurfaceSize(Size(width, 480));
        await tester.pump();
        final compact = width < 600;
        Rect unionRects(List<Rect> rects) => Rect.fromLTRB(
          rects
              .map((rect) => rect.left)
              .reduce((left, right) => left < right ? left : right),
          rects
              .map((rect) => rect.top)
              .reduce((top, bottom) => top < bottom ? top : bottom),
          rects
              .map((rect) => rect.right)
              .reduce((left, right) => left > right ? left : right),
          rects
              .map((rect) => rect.bottom)
              .reduce((top, bottom) => top > bottom ? top : bottom),
        );
        final l10n = AppLocalizations.of(
          tester.element(find.byKey(const ValueKey('page-updates'))),
        )!;
        for (final kind in const ['frontend', 'backend']) {
          final layout = find.byKey(ValueKey('component-layout-$kind'));
          final title = kind == 'frontend'
              ? l10n.frontendComponent
              : l10n.backendComponent;
          final description = kind == 'frontend'
              ? l10n.frontendComponentDescription
              : l10n.backendComponentDescription;
          final status = find.byKey(
            ValueKey('component-update-local-status-$kind'),
          );
          final checkResult = l10n.componentUpToDate(
            '1.0.0',
            kind == 'backend' ? 'backend-previous' : '-',
          );
          final detailTexts = [
            find.descendant(of: layout, matching: find.text(title)),
            find.descendant(of: layout, matching: find.text(description)),
            find.descendant(of: layout, matching: status),
            find.descendant(of: layout, matching: find.text(checkResult)),
          ];
          final detailRects = <Rect>[];
          for (final detail in detailTexts) {
            expect(detail, findsOneWidget);
            detailRects.add(tester.getRect(detail));
          }
          final detailsRect = unionRects(detailRects);
          final actionsRect = tester.getRect(
            find.byKey(ValueKey('component-actions-$kind')),
          );
          if (compact) {
            expect(actionsRect.top, greaterThan(detailsRect.bottom));
          } else {
            expect(actionsRect.left, greaterThanOrEqualTo(detailsRect.right));
            expect(actionsRect.top, lessThan(detailsRect.bottom));
            expect(actionsRect.bottom, greaterThan(detailsRect.top));
          }
        }

        expect(
          find.byKey(const ValueKey('updates-update-all')),
          findsOneWidget,
        );
        expect(find.text(l10n.maintenanceDescription), findsOneWidget);

        await tester.ensureVisible(packagedSection);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.descendant(
            of: find.byKey(tileKeys.first),
            matching: find.text('1.3.0'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(tileKeys.first),
            matching: find.text('Ships with SubDock'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(tileKeys.first),
            matching: find.textContaining('Running on port'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(tileKeys[1]),
            matching: find.text('v1.19.30'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(tileKeys[2]),
            matching: find.text('v24.20.0'),
          ),
          findsOneWidget,
        );
        for (final key in tileKeys) {
          expect(
            find.descendant(of: packagedSection, matching: find.byKey(key)),
            findsOneWidget,
          );
        }
        expect(
          find.descendant(
            of: packagedSection,
            matching: find.byType(FilledButton),
          ),
          findsNothing,
        );
        final description = find.descendant(
          of: packagedSection,
          matching: find.textContaining('not replaced independently'),
        );
        expect(description, findsOneWidget);

        final tileRects = tileKeys
            .map((key) => tester.getRect(find.byKey(key)))
            .toList();
        expect(
          (tester.getRect(description).left - tileRects.first.left).abs(),
          lessThan(0.5),
        );
        expect(tileRects[1].width, tileRects.first.width);
        expect(tileRects[2].width, tileRects.first.width);
        if (compact) {
          expect(tileRects[1].top, greaterThan(tileRects.first.bottom));
          expect(tileRects[2].top, greaterThan(tileRects[1].bottom));
          expect(
            (tileRects[1].left - tileRects.first.left).abs(),
            lessThan(0.5),
          );
          expect(
            (tileRects[2].left - tileRects.first.left).abs(),
            lessThan(0.5),
          );
        } else {
          expect(tileRects[1].left, greaterThan(tileRects.first.right));
          expect(tileRects[2].left, greaterThan(tileRects[1].right));
          expect((tileRects[1].top - tileRects.first.top).abs(), lessThan(0.5));
          expect((tileRects[2].top - tileRects.first.top).abs(), lessThan(0.5));
          expect(tileRects[1].height, tileRects.first.height);
          expect(tileRects[2].height, tileRects.first.height);
        }

        final sectionCard = tester.widget<Material>(
          find
              .descendant(of: packagedSection, matching: find.byType(Material))
              .first,
        );
        expect(
          (sectionCard.shape! as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(12),
        );
        final tileCard = tester.widget<Material>(
          find.descendant(
            of: find.byKey(tileKeys.first),
            matching: find.byType(Material),
          ),
        );
        expect(
          (tileCard.shape! as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(10),
        );
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('guided maintenance confirms and resumes a running Backend', (
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
    final runtime = _FakeBackendRuntime();
    await runtime.start();
    final updates = _FakeComponentUpdateOperations()
      ..statuses[ComponentKind.backend] = const ComponentVersionStatus(
        current: '1.0.0',
        previous: '0.9.0',
      )
      ..checkResults[ComponentKind.backend] = ComponentUpdate(
        kind: ComponentKind.backend,
        currentVersion: '1.0.0',
        availableVersion: '1.1.0',
        release: GithubRelease(
          version: '1.1.0',
          releaseUri: Uri.parse('https://example.invalid/backend'),
          assets: const [],
        ),
      );
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories!),
      componentUpdates: updates,
    );
    await pumpApp(
      tester,
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
    // 更新提示与随包资源卡片保持相同圆角。
    final backendNotice = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(const ValueKey('updates-backend-notice')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(
      (backendNotice.shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(10),
    );
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
      findsOneWidget,
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
            .widget<FilledButton>(
              find.byKey(const ValueKey('component-update-action-backend')),
            )
            .onPressed,
        isNull,
      );
    }
    runtime.emitState(RuntimeStatus.running);
    await tester.pump();
    final updateButton = find.byKey(
      const ValueKey('component-update-action-backend'),
    );
    await tester.ensureVisible(updateButton);
    expect(tester.widget<FilledButton>(updateButton).onPressed, isNotNull);
    await tester.tap(updateButton);
    await tester.pump();
    expect(
      find.textContaining('Selected versions: Backend 1.1.0'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(runtime.stops, 0);
    expect(updates.updateCalls, isEmpty);
    await tester.ensureVisible(updateButton);
    await tester.tap(updateButton);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await _pumpRealIo(tester);
    expect(runtime.stops, 1);
    expect(runtime.starts, 2);
    expect(runtime.restarts, 0);
    expect(updates.updateCalls, hasLength(1));
    expect(updates.rollbackCalls, isEmpty);
    expect(updates.statuses[ComponentKind.backend]?.current, '1.1.0');
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
    await pumpApp(
      tester,
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

  testWidgets('stopped component update keeps the Backend stopped', (
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
    var browserCalls = 0;
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories!),
      componentUpdates: updates,
    );
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
        onOpenExternalUri: (uri) async {
          browserCalls++;
          if (browserCalls == 1) return false;
          if (browserCalls == 2) {
            throw StateError('browser callback failed');
          }
          opened.add(uri);
          return true;
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
    final releaseNotes = find.byKey(
      const ValueKey('component-release-notes-frontend'),
    );
    await tester.ensureVisible(releaseNotes);
    await tester.tap(releaseNotes);
    await tester.pump();
    expect(find.byKey(const ValueKey('updates-action-error')), findsOneWidget);
    expect(
      find.textContaining('The system browser could not open'),
      findsOneWidget,
    );
    expect(updates.updateCalls, isEmpty);
    expect(runtime.stops, 0);

    await tester.ensureVisible(releaseNotes);
    await tester.tap(releaseNotes);
    await tester.pump();
    expect(find.textContaining('browser callback failed'), findsOneWidget);
    expect(updates.updateCalls, isEmpty);
    expect(runtime.stops, 0);

    await tester.ensureVisible(releaseNotes);
    await tester.tap(releaseNotes);
    await tester.pump();
    expect(opened, [Uri.parse('https://example.invalid/frontend')]);
    expect(find.byKey(const ValueKey('updates-action-error')), findsNothing);
    final updateButton = find.byKey(
      const ValueKey('component-update-action-frontend'),
    );
    await tester.ensureVisible(updateButton);
    await tester.tap(updateButton);
    await tester.pump();
    expect(
      find.textContaining('Selected versions: Frontend 1.1.0'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await _pumpRealIo(tester);
    expect(updates.updateCalls, hasLength(1));
    expect(updates.rollbackCalls, isEmpty);
    expect(runtime.starts, 0);
    expect(runtime.stops, 0);
    expect(runtime.restarts, 0);
    expect(find.textContaining('Current 1.1.0'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('updates-maintenance-result')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('component-start-now-frontend')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('component-release-notes-frontend')),
      findsNothing,
    );
    expect(updates.updateCalls, hasLength(1));
    expect(updates.rollbackCalls, isEmpty);
    final updateCount = updates.updateCalls.length;
    final rollbackCount = updates.rollbackCalls.length;
    final restartCount = runtime.restarts;
    final openedCount = opened.length;
    updates.checkErrors[ComponentKind.frontend] = StateError('network failed');
    final recheck = find.byKey(
      const ValueKey('component-update-recheck-frontend'),
    );
    await tester.ensureVisible(recheck);
    await tester.tap(recheck);
    await _pumpRealIo(tester);
    expect(
      find.byKey(const ValueKey('component-release-notes-frontend')),
      findsNothing,
    );
    expect(opened, hasLength(openedCount));
    expect(
      find.byKey(const ValueKey('component-update-local-status-frontend')),
      findsOneWidget,
    );
    expect(find.textContaining('Current 1.1.0'), findsOneWidget);
    expect(updates.updateCalls.length, updateCount);
    expect(updates.rollbackCalls.length, rollbackCount);
    expect(runtime.restarts, restartCount);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Backend rollback confirmation warns about its data snapshot', (
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
    final runtime = _FakeBackendRuntime();
    final coordinator = AppCoordinator(
      runtime: runtime,
      environmentStore: BackendEnvStore(directories!),
      componentUpdates: updates,
    );
    await pumpApp(
      tester,
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
    expect(
      find.textContaining(
        'Rolling back Backend also restores its linked data snapshot',
      ),
      findsOneWidget,
    );
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
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('component-update-local-status-backend')),
          )
          .data,
      'Current 1.0.0, previous 2.0.0',
    );
    expect(runtime.starts, 0);
    expect(runtime.stops, 0);
    expect(
      find.byKey(const ValueKey('updates-maintenance-result')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('component-start-now-backend')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed automatic start can be retried without reinstalling', (
    tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final runtime = _FakeBackendRuntime();
    await runtime.start();
    runtime.startError = StateError('start failed');
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
    await pumpApp(
      tester,
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
    final updateButton = find.byKey(
      const ValueKey('component-update-action-frontend'),
    );
    await tester.ensureVisible(updateButton);
    await tester.tap(updateButton);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await _pumpRealIo(tester, turns: 200);
    expect(runtime.starts, 1);
    expect(runtime.stops, 1);
    expect(updates.updateCalls, hasLength(1));
    expect(
      find.byKey(const ValueKey('component-start-now-frontend')),
      findsNothing,
    );
    final retry = find.byKey(const ValueKey('updates-maintenance-retry'));
    expect(retry, findsOneWidget);
    expect(find.text('Retry Backend start'), findsOneWidget);

    runtime.startError = null;
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await _pumpRealIo(tester);

    expect(runtime.starts, 2);
    expect(runtime.stops, 1);
    expect(updates.updateCalls, hasLength(1));
    expect(
      find.textContaining('Component maintenance completed'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('update failure retains the installed version and release', (
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
    await pumpApp(
      tester,
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
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await _pumpRealIo(tester);
    expect(updates.updateCalls, hasLength(1));
    expect(updates.rollbackCalls, isEmpty);
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const ValueKey('component-update-local-status-frontend'),
            ),
          )
          .data,
      'Current 1.0.0, previous 0.9.0',
    );
    expect(find.textContaining('update failed'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('component-start-now-frontend')),
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

  testWidgets('rollback failure retains the installed version', (tester) async {
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
    await pumpApp(
      tester,
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
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('component-update-local-status-backend')),
          )
          .data,
      'Current 2.0.0, previous 1.0.0',
    );
    expect(find.textContaining('rollback failed'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('component-start-now-backend')),
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
      operatingSystem: () => 'windows',
      architecture: () => 'arm64',
    );
    await pumpApp(
      tester,
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
    expect(find.text('Operating system: windows'), findsOneWidget);
    expect(find.text('Architecture: arm64'), findsOneWidget);
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
    await pumpApp(
      tester,
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
    await pumpApp(
      tester,
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
    await pumpApp(
      tester,
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
    await pumpApp(
      tester,
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
    // 来源下拉是按钮控件，初始为「全部」，可展开选择具体来源。
    final sourceFilter = find.byKey(const ValueKey('logs-source-filter'));
    expect(sourceFilter, findsOneWidget);
    expect(
      find.descendant(of: sourceFilter, matching: find.text('All')),
      findsOneWidget,
    );
    await tester.tap(sourceFilter);
    await tester.pumpAndSettle();
    // 菜单列出全部来源与 Backend/HTTP-META。
    expect(find.text('HTTP-META'), findsOneWidget);
    // 选择 Backend，随后在级别下拉里选 Warning。
    await tester.tap(find.text('Backend').last);
    await tester.pumpAndSettle();
    // 级别下拉展示全部级别选项。
    await tester.tap(find.byKey(const ValueKey('logs-level-filter')));
    await tester.pumpAndSettle();
    expect(find.text('Warning'), findsOneWidget);
    await tester.tap(find.text('Warning').last);
    await tester.pumpAndSettle();
    // 桌面下拉选择后自动关闭，无对话框 Back 按钮。
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
    await pumpApp(
      tester,
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
    expect(find.byKey(const ValueKey('logs-source-filter')), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
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
    await pumpApp(
      tester,
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
    expect(find.text('Current version'), findsNothing);
    expect(find.text('Previous version'), findsNothing);
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

    await pumpApp(
      tester,
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

    await pumpApp(
      tester,
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

    await pumpApp(
      tester,
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

    await pumpApp(
      tester,
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

  testWidgets('ready manage toolbar exposes browser navigation controls', (
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
    await pumpApp(
      tester,
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
    expect(find.byType(ClipRRect), findsNothing);
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

  testWidgets('manage follows SPA route changes reported over the bridge', (
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
    late void Function(String message) blobMessage;
    Uri? loadedUri;

    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(
      tester,
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
            }) {
              blobMessage = onBlobMessage;
              return EmbeddedWebViewController.testing(
                initialize: () async {},
                buildWidget: () =>
                    const SizedBox(key: ValueKey('fake-manage-webview')),
                loadRequest: (uri) async => loadedUri = uri,
                reload: () async {},
                currentUrl: () async => coordinator.webUiUri,
                canGoBack: () async => false,
                goBack: () async {},
                canGoForward: () async => false,
                goForward: () async {},
              );
            },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    await tester.pump();
    runtime.emitState(RuntimeStatus.running);
    await _pumpRealIo(tester);

    expect(find.byKey(const ValueKey('manage-url')), findsOneWidget);
    expect(find.text(coordinator.webUiUri.toString()), findsOneWidget);
    expect(loadedUri, coordinator.webUiUri);

    // SPA pushState to the /subs route reports via the bridge channel.
    final subsUri = coordinator.webUiUri.replace(path: '/subs');
    blobMessage('{"type":"url","url":"${subsUri.toString()}"}');
    await _pumpRealIo(tester);
    expect(find.text(subsUri.toString()), findsOneWidget);
    expect(find.text(coordinator.webUiUri.toString()), findsNothing);

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

    await pumpApp(
      tester,
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
    await pumpApp(
      tester,
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
    await pumpApp(
      tester,
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
      await pumpApp(
        tester,
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
      await pumpApp(
        tester,
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
      await pumpApp(
        tester,
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
    'minimum settings window supports config editing and responsive controls',
    (WidgetTester tester) async {
      late Directory temp;
      addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
      final directories = await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('subdock_widget_');
        return RuntimeDirectories.fromBaseDirectory(temp);
      });
      final store = SubDockConfigStore(directories!);
      final coordinator = AppCoordinator(
        runtime: _FakeBackendRuntime(),
        environmentStore: BackendEnvStore(directories),
        configurationStore: store,
      );

      await tester.binding.setSurfaceSize(const Size(600, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpApp(
        tester,
        SubDockApp(
          coordinator: coordinator,
          autoStart: false,
          enableWebView: false,
          locale: const Locale('en'),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
      await tester.pumpAndSettle();

      final l10n = AppLocalizations.of(
        tester.element(find.byKey(const ValueKey('settings-appearance'))),
      )!;
      expect(find.text(l10n.themeSubtitle), findsOneWidget);
      expect(find.text(l10n.languageSubtitle), findsOneWidget);
      final appearanceHeading = find.text(l10n.appearanceLanguageHeading);
      final appearanceCard = find.byKey(const ValueKey('settings-appearance'));
      final headingRect = tester.getRect(appearanceHeading);
      final appearanceCardRect = tester.getRect(appearanceCard);
      expect((headingRect.left - appearanceCardRect.left).abs(), lessThan(0.5));
      expect(
        find.descendant(of: appearanceCard, matching: appearanceHeading),
        findsNothing,
      );
      expect(appearanceCardRect.top - headingRect.bottom, 12);
      final themeDetails = find.byKey(const ValueKey('settings-theme-row'));
      final themeControl = find.byKey(const ValueKey('settings-theme-mode'));
      final desktopDetailsRect = tester.getRect(themeDetails);
      final desktopControlRect = tester.getRect(themeControl);
      expect(
        desktopControlRect.left,
        greaterThanOrEqualTo(desktopDetailsRect.right),
      );
      expect(desktopControlRect.top, lessThan(desktopDetailsRect.bottom));
      expect(desktopControlRect.bottom, greaterThan(desktopDetailsRect.top));
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('settings-theme-row')),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Padding &&
                widget.padding ==
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      final backendConfig = find.byKey(
        const ValueKey('settings-card-backend-config'),
      );
      await tester.ensureVisible(backendConfig);
      await tester.pumpAndSettle();
      await tester.tap(backendConfig);
      await tester.pumpAndSettle();
      final hostField = find.descendant(
        of: find.byKey(const ValueKey('settings-backend-host-row')),
        matching: find.byType(TextField),
      );
      await tester.enterText(hostField, '127.0.0.2');
      await tester.pump();
      final save = find.byKey(const ValueKey('settings-child-save'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.tap(save);
      await _pumpRealIo(tester);
      expect((await tester.runAsync(store.load))!.backend.apiHost, '127.0.0.2');

      final back = find.byKey(const ValueKey('settings-back'));
      await tester.ensureVisible(back);
      await tester.pumpAndSettle();
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-appearance')), findsOneWidget);

      final advancedEnv = find.byKey(
        const ValueKey('settings-card-advanced-env'),
      );
      await tester.ensureVisible(advancedEnv);
      await tester.pumpAndSettle();
      await tester.tap(advancedEnv);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('settings-raw-env-expansion')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-raw-env-editor')),
        findsOneWidget,
      );
      await tester.ensureVisible(back);
      await tester.pumpAndSettle();
      await tester.tap(back);
      await tester.pumpAndSettle();

      await tester.binding.setSurfaceSize(const Size(599, 480));
      await tester.pumpAndSettle();
      final cardRect = tester.getRect(appearanceCard);
      final compactDetailsRect = tester.getRect(themeDetails);
      final compactControlRect = tester.getRect(themeControl);
      final languageRect = tester.getRect(
        find.byKey(const ValueKey('settings-language')),
      );
      expect(compactControlRect.left, greaterThanOrEqualTo(cardRect.left));
      expect(languageRect.left, greaterThanOrEqualTo(cardRect.left));
      expect(compactControlRect.right, lessThanOrEqualTo(cardRect.right));
      expect(languageRect.right, lessThanOrEqualTo(cardRect.right));
      expect(languageRect.top, greaterThan(compactControlRect.bottom));
      expect(
        compactControlRect.top,
        greaterThanOrEqualTo(compactDetailsRect.bottom),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

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

    await pumpApp(
      tester,
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
        preferences: DesktopPreferences.defaults.copyWith(
          autoSavePreferences: false,
        ),
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
          .widget<FilledButton>(
            find.byKey(const ValueKey('settings-save-preferences')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('settings-save-preferences')));
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
          .widget<FilledButton>(
            find.byKey(const ValueKey('settings-save-preferences')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  for (final keepAutomaticSaving in [false, true]) {
    testWidgets(
      keepAutomaticSaving
          ? 'queued general edits retain a debounced log limit'
          : 'turning off auto-save cancels queued preference drafts',
      (WidgetTester tester) async {
        late Directory temp;
        addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
        final directories = await tester.runAsync(() async {
          temp = await Directory.systemTemp.createTemp('subdock_widget_');
          return RuntimeDirectories.fromBaseDirectory(temp);
        });
        final bootstrap = DesktopPreferencesStore(directories!);
        await tester.runAsync(
          () => bootstrap.save(DesktopPreferences.defaults),
        );
        final store = _BlockedDesktopPreferencesStore(directories);
        final coordinator = AppCoordinator(
          runtime: _FakeBackendRuntime(),
          environmentStore: BackendEnvStore(directories),
        );
        addTearDown(() async {
          while (store.pendingWrites > 0) {
            store.releaseNext();
          }
          await tester.pumpWidget(const SizedBox());
          final disposal = coordinator.dispose();
          await tester.pump();
          await disposal;
        });
        await tester.binding.setSurfaceSize(const Size(1024, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await pumpApp(
          tester,
          SubDockApp(
            coordinator: coordinator,
            autoStart: false,
            enableWebView: false,
            locale: const Locale('en'),
            preferences: DesktopPreferences.defaults,
            preferencesStore: store,
          ),
        );
        await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
        await tester.pumpAndSettle();
        final themeSelector = find.byType(SegmentedButton<ThemeMode>);

        Future<void> chooseTheme(String label) async {
          final option = find.descendant(
            of: themeSelector,
            matching: find.text(label),
          );
          await tester.scrollUntilVisible(
            option,
            -240,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.tap(option);
          await tester.pumpAndSettle();
        }

        await chooseTheme('Light');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        expect(store.attempted, hasLength(1));

        if (keepAutomaticSaving) {
          final limit = find.byKey(const ValueKey('settings-recent-log-limit'));
          await tester.scrollUntilVisible(
            limit,
            240,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.enterText(limit, '400');
          await tester.pump(const Duration(milliseconds: 700));
          await chooseTheme('Dark');
          store.releaseNext();
          await _pumpRealIo(tester);
          expect(store.pendingWrites, 1);
          store.releaseNext();
          await _pumpRealIo(tester);
          final saved = await tester.runAsync(bootstrap.load);
          expect(saved!.themeMode, ThemeMode.dark);
          expect(saved.recentLogLimit, 400);
          return;
        }

        await chooseTheme('Dark');
        final autoSave = find.byKey(const ValueKey('settings-auto-save'));
        await tester.scrollUntilVisible(
          autoSave,
          240,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(autoSave);
        await tester.pump();
        store.releaseNext();
        await _pumpRealIo(tester);

        expect(store.attempted, hasLength(2));
        expect(store.attempted.first.themeMode, ThemeMode.light);
        expect(store.attempted.last.autoSavePreferences, isFalse);
        expect(store.attempted.last.themeMode, ThemeMode.light);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('settings-save-preferences')),
              )
              .onPressed,
          isNotNull,
        );
        await tester.tap(
          find.byKey(const ValueKey('settings-discard-preferences')),
        );
        await tester.pump();
        store.releaseNext();
        await _pumpRealIo(tester);

        final persisted = await tester.runAsync(
          () => DesktopPreferencesStore(directories).load(),
        );
        expect(persisted!.themeMode, ThemeMode.light);
        expect(persisted.autoSavePreferences, isFalse);
        expect(
          tester.widget<SegmentedButton<ThemeMode>>(themeSelector).selected,
          {ThemeMode.light},
        );
        expect(
          find.byKey(const ValueKey('settings-save-preferences')),
          findsNothing,
        );
        expect(tester.widget<Switch>(autoSave).value, isFalse);
      },
    );
  }

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

    await pumpApp(
      tester,
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

  testWidgets('switching the language previews and saves it automatically', (
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

    await pumpApp(
      tester,
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
        preferences: await tester.runAsync(() => preferencesStore.load()),
        preferencesStore: preferencesStore,
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
      'en',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'applies persisted theme and language over the system preferences',
    (WidgetTester tester) async {
      late Directory temp;
      addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
      final directories = await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('subdock_widget_');
        return RuntimeDirectories.fromBaseDirectory(temp);
      });
      final preferencesStore = DesktopPreferencesStore(directories!);
      await tester.runAsync(
        () => preferencesStore.save(
          DesktopPreferences.defaults.copyWith(
            themeMode: ThemeMode.dark,
            locale: 'en',
          ),
        ),
      );
      tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      final coordinator = AppCoordinator(
        runtime: _FakeBackendRuntime(),
        environmentStore: BackendEnvStore(directories),
      );

      await pumpApp(
        tester,
        SubDockApp(
          coordinator: coordinator,
          autoStart: false,
          enableWebView: false,
          preferences: await tester.runAsync(() => preferencesStore.load()),
        ),
      );
      await _pumpRealIo(tester);

      expect(find.text('Settings'), findsOneWidget);
      expect(
        Theme.of(tester.element(find.text('SubDock'))).brightness,
        Brightness.dark,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('corrupt preferences fall back to system theme and language', (
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
    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.dark;
    addTearDown(
      tester.binding.platformDispatcher.clearPlatformBrightnessTestValue,
    );

    await pumpApp(
      tester,
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
    expect(
      Theme.of(tester.element(find.text('SubDock'))).brightness,
      Brightness.dark,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('theme selector round-trips through all three modes', (
    WidgetTester tester,
  ) async {
    final fixture = await _widgetRuntime(tester);
    final store = DesktopPreferencesStore(fixture.directories);
    await tester.runAsync(
      () => store.save(
        DesktopPreferences.defaults.copyWith(
          themeMode: ThemeMode.system,
          locale: 'zh',
        ),
      ),
    );
    final preferences = await tester.runAsync(store.load);
    final coordinator = fixture.coordinator;
    addTearDown(
      () => tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.light,
    );
    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.dark;

    await pumpApp(
      tester,
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        preferences: preferences,
        preferencesStore: store,
        locale: const Locale('zh'),
      ),
    );
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    Future<void> selectTheme(
      String label,
      Brightness expected,
      ThemeMode persisted,
    ) async {
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
      expect((await tester.runAsync(store.load))!.themeMode, persisted);
    }

    await selectTheme('浅色', Brightness.light, ThemeMode.light);
    await selectTheme('深色', Brightness.dark, ThemeMode.dark);
    // Following the system (which is dark in this test) after manual picks.
    await selectTheme('跟随系统', Brightness.dark, ThemeMode.system);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'shared shell reaches every page and keeps long runtime values selectable',
    (tester) async {
      final fixture = await _widgetRuntime(tester);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final expectedEndpoint =
          'http://${List.filled(60, 'a').join()}.${List.filled(60, 'b').join()}.example.invalid:3001/';
      fixture.runtime.endpoint = Uri.parse(expectedEndpoint);
      const pages = [
        'overview',
        'manage',
        'logs',
        'updates',
        'settings',
        'about',
      ];

      for (final size in const [Size(1024, 800), Size(1440, 960)]) {
        for (final brightness in [Brightness.light, Brightness.dark]) {
          tester.binding.platformDispatcher.platformBrightnessTestValue =
              brightness;
          await tester.binding.setSurfaceSize(size);
          await pumpApp(
            tester,
            SubDockApp(
              coordinator: fixture.coordinator,
              autoStart: false,
              enableWebView: false,
              locale: const Locale('zh'),
            ),
          );
          await _pumpRealIo(tester);

          for (final page in pages) {
            expect(
              find.byKey(ValueKey('nav-item-$page')),
              findsOneWidget,
              reason: '$page missing at $size in $brightness',
            );
            await tester.tap(find.byKey(ValueKey('nav-item-$page')));
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '$page overflowed at $size in $brightness',
            );
            expect(
              tester
                  .widget<Offstage>(find.byKey(ValueKey('page-$page')))
                  .offstage,
              isFalse,
            );
          }

          // Long runtime values stay selectable and use the bundled mono
          // family with a CJK-capable fallback.
          await tester.tap(find.byKey(const ValueKey('nav-item-overview')));
          await tester.pumpAndSettle();
          final endpointValue = find.byKey(
            const ValueKey('runtime-endpoint-value'),
          );
          expect(endpointValue, findsOneWidget);
          expect(
            tester.widget<SelectableText>(endpointValue).data,
            expectedEndpoint,
          );
          final valueStyle = tester
              .widget<SelectableText>(endpointValue)
              .style!;
          expect(valueStyle.fontFamily, uiMonoFontFamily);
          expect(valueStyle.fontFamilyFallback, contains(uiTextFontFamily));
        }
      }
      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.light;
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'system brightness drives the Material and Shad themes together',
    (tester) async {
      final fixture = await _widgetRuntime(tester);
      addTearDown(() {
        tester.binding.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
      });

      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.dark;
      await pumpApp(
        tester,
        SubDockApp(
          coordinator: fixture.coordinator,
          autoStart: false,
          enableWebView: false,
          locale: const Locale('zh'),
        ),
      );
      await tester.pumpAndSettle();

      final zhContext = tester.element(find.text('SubDock'));
      expect(Theme.of(zhContext).brightness, Brightness.dark);
      expect(ShadTheme.of(zhContext).brightness, Brightness.dark);
      expect(ShadLocalizations.of(zhContext).timePicker.hours, '时');

      // A locale is applied when the app is created, so build a fresh shell to
      // switch from the Chinese to the English bundle.
      await tester.pumpWidget(const SizedBox());
      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.light;
      await pumpApp(
        tester,
        SubDockApp(
          coordinator: fixture.coordinator,
          autoStart: false,
          enableWebView: false,
          locale: const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();

      final enContext = tester.element(find.text('SubDock'));
      expect(Theme.of(enContext).brightness, Brightness.light);
      expect(ShadTheme.of(enContext).brightness, Brightness.light);
      expect(ShadLocalizations.of(enContext).timePicker.hours, 'Hours');
      expect(find.text('Logs'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
    },
  );
}

Future<
  ({
    RuntimeDirectories directories,
    _FakeBackendRuntime runtime,
    AppCoordinator coordinator,
  })
>
_widgetRuntime(
  WidgetTester tester, {
  ComponentUpdateOperations? componentUpdates,
}) async {
  late Directory temp;
  addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
  final directories = await tester.runAsync(() async {
    temp = await Directory.systemTemp.createTemp('subdock_widget_');
    return RuntimeDirectories.fromBaseDirectory(temp);
  });
  final runtimeDirectories = directories!;
  final runtime = _FakeBackendRuntime();
  final coordinator = AppCoordinator(
    runtime: runtime,
    environmentStore: BackendEnvStore(runtimeDirectories),
    componentUpdates: componentUpdates,
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    final disposal = coordinator.dispose();
    await tester.pump();
    await disposal;
  });
  return (
    directories: runtimeDirectories,
    runtime: runtime,
    coordinator: coordinator,
  );
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

Future<void> _pumpUntilLogRecoveryCompletes(WidgetTester tester) async {
  final banner = find.byKey(const ValueKey('log-recovery-banner'));
  final elapsed = Stopwatch()..start();
  const deadline = Duration(seconds: 3);
  while (banner.evaluate().isNotEmpty) {
    if (elapsed.elapsed >= deadline) {
      expect(
        banner,
        findsNothing,
        reason: 'Log history recovery did not complete before the deadline.',
      );
      return;
    }
    await _pumpRealIo(tester, turns: 1);
  }
}

Future<void> _pumpUntilRestoredHistoryRun(
  WidgetTester tester,
  String runId,
) async {
  final runTile = find.byKey(ValueKey('history-run-$runId'));
  final elapsed = Stopwatch()..start();
  const deadline = Duration(seconds: 3);
  while (runTile.evaluate().isEmpty) {
    if (elapsed.elapsed >= deadline) {
      expect(
        runTile,
        findsOneWidget,
        reason: 'The restored log run did not appear before the deadline.',
      );
      return;
    }
    await _pumpRealIo(tester, turns: 1);
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

class _BlockedDesktopPreferencesStore extends DesktopPreferencesStore {
  _BlockedDesktopPreferencesStore(super.directories);

  final attempted = <DesktopPreferences>[];
  final _pending = <Completer<void>>[];

  int get pendingWrites => _pending.length;

  @override
  Future<void> save(DesktopPreferences preferences) async {
    attempted.add(preferences);
    final completer = Completer<void>();
    _pending.add(completer);
    await completer.future;
    try {
      await super.save(preferences);
    } finally {
      _pending.remove(completer);
    }
  }

  void releaseNext() {
    final completer = _pending.removeAt(0);
    completer.complete();
  }
}

class _FakeBackendRuntime extends BackendRuntime {
  final _logs = StreamController<RuntimeLog>.broadcast(sync: true);
  final _logRunStarted = StreamController<RuntimeLogRunStarted>.broadcast(
    sync: true,
  );
  final _logRunUpdates = StreamController<RuntimeLogRunUpdate>.broadcast(
    sync: true,
  );
  final _states = StreamController<RuntimeState>.broadcast(sync: true);
  final logFinalizationRetries = <String>[];
  var starts = 0;
  var stops = 0;
  var restarts = 0;
  Object? restartError;
  Object? startError;

  void emitLog(RuntimeLog log) => _logs.add(log);

  void emitRunStarted(String runId) =>
      _logRunStarted.add(RuntimeLogRunStarted(runId));

  void emitLogRunUpdate(RuntimeLogRunUpdate update) =>
      _logRunUpdates.add(update);

  void emitState(
    RuntimeStatus status, {
    HttpMetaStatus httpMetaStatus = HttpMetaStatus.disabled,
    int? httpMetaPort,
    String? httpMetaVersion,
    String? httpMetaMihomoVersion,
  }) => _states.add(
    RuntimeState(
      status: status,
      changedAt: DateTime.now(),
      httpMetaStatus: httpMetaStatus,
      httpMetaPort: httpMetaPort,
      httpMetaVersion: httpMetaVersion,
      httpMetaMihomoVersion: httpMetaMihomoVersion,
    ),
  );

  @override
  RuntimeState get currentState => RuntimeState(
    status: starts > stops ? RuntimeStatus.running : RuntimeStatus.stopped,
    changedAt: DateTime.now(),
  );

  @override
  Uri endpoint = Uri.parse('http://127.0.0.1:3001');

  @override
  Stream<RuntimeLog> get logs => _logs.stream;

  @override
  Stream<RuntimeLogRunStarted> get logRunStarted => _logRunStarted.stream;

  @override
  Stream<RuntimeLogRunUpdate> get logRunUpdates => _logRunUpdates.stream;

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
    if (startError != null) throw startError!;
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
  Future<void> retryLogFinalization(String runId) async {
    logFinalizationRetries.add(runId);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _logs.close();
    await _logRunStarted.close();
    await _logRunUpdates.close();
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

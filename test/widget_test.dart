import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show
        LicenseEntry,
        LicenseEntryWithLineBreaks,
        LicenseRegistry,
        TargetPlatform,
        defaultTargetPlatform;
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart'
    show
        Brightness,
        BorderRadius,
        ClipRRect,
        FilledButton,
        Locale,
        ListView,
        SelectableText,
        Scrollable,
        Semantics,
        Theme,
        ThemeMode,
        Text,
        ValueNotifier;
import 'package:flutter/scheduler.dart' show AppLifecycleState;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show
        EdgeInsets,
        Focus,
        GestureDetector,
        Offstage,
        Padding,
        SizedBox,
        ValueKey;
import 'package:flutter_test/flutter_test.dart';
// The Linux widget/transport is a pinned transitive implementation of webview_all.
// ignore: depend_on_referenced_packages
import 'package:webview_all_linux/webview_all_linux.dart' as linux_webview;
// ignore: depend_on_referenced_packages
import 'package:webview_platform_interface/webview_platform_interface.dart'
    as webview_platform;
import 'package:shadcn_ui/shadcn_ui.dart'
    show
        ShadButton,
        ShadCard,
        ShadContextMenu,
        ShadIconButton,
        ShadInput,
        ShadLocalizations,
        ShadOption,
        ShadSwitch,
        ShadTheme,
        ShadToast,
        ShadTooltip;
import 'package:subdock/app/app.dart';
import 'package:subdock/app/about_info.dart';
import 'package:subdock/app/app_coordinator.dart';
import 'package:subdock/app/app_typography.dart'
    show uiMonoFontFamily, uiTextFontFamily;
import 'package:subdock/app/embedded_webview.dart';
import 'package:subdock/app/close_request_guard.dart';
import 'package:subdock/app/mobile_placeholder_runtime.dart';
import 'package:subdock/app/maintenance_operation.dart';
import 'package:subdock/l10n/generated/app_localizations.dart';
import 'package:subdock/mobile_main.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/runtime/runtime_log_store.dart';
import 'package:subdock/settings/backend_env.dart';
import 'package:subdock/settings/backend_env_store.dart';
import 'package:subdock/settings/config_error.dart';
import 'package:subdock/settings/desktop_preferences.dart';
import 'package:subdock/settings/desktop_preferences_store.dart';
import 'package:subdock/settings/subdock_config.dart';
import 'package:subdock/settings/subdock_config_store.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/component_update_checker.dart';
import 'package:subdock/update/github_release_client.dart';
import 'package:subdock/update/component_update_service.dart';
import 'package:subdock/update/maintenance_attempt_store.dart';

import 'support/pump_app.dart';

late List<LicenseEntry> _realLicenseRegistryEntries;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerBundledFontLicenses();
    _realLicenseRegistryEntries = await LicenseRegistry.licenses
        .toList()
        .timeout(const Duration(seconds: 5));
    expect(
      _realLicenseRegistryEntries.any(
        (entry) => entry.packages.contains('Noto Sans CJK SC 2.004'),
      ),
      isTrue,
    );
    expect(
      _realLicenseRegistryEntries.any(
        (entry) => entry.packages.contains('DejaVu Sans Mono 2.37'),
      ),
      isTrue,
    );
  });
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
    expect(find.byKey(const ValueKey('nav-item-about')), findsNothing);
    expect(find.byKey(const ValueKey('page-about')), findsNothing);
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
    final runtimePanel = find.byKey(
      const ValueKey('overview-runtime-information'),
    );
    final overviewScrollable = find
        .descendant(
          of: find.byKey(const ValueKey('page-overview')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      runtimePanel,
      200,
      scrollable: overviewScrollable,
    );
    expect(
      find.descendant(
        of: runtimePanel,
        matching: find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == '-',
        ),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: runtimePanel,
        matching: find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == '0',
        ),
      ),
      findsNWidgets(2),
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
    final l10n = AppLocalizations.of(
      tester.element(find.byKey(const ValueKey('page-overview'))),
    )!;
    expect(find.text(l10n.serviceStoppedTitle), findsOneWidget);
    expect(find.textContaining('Node'), findsWidgets);
    expect(find.textContaining('Backend'), findsWidgets);
    expect(
      find.byKey(const ValueKey('overview-component-status')),
      findsOneWidget,
    );
    final startButton = find.widgetWithText(ShadButton, '启动');
    expect(tester.widget<ShadButton>(startButton).onPressed, isNotNull);

    runtime.emitState(RuntimeStatus.crashed, message: 'fixture crash');
    await tester.pump();
    expect(find.byKey(const ValueKey('overview-view-logs')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('overview-view-logs')));
    await tester.pump();
    expect(
      tester.widget<Offstage>(find.byKey(const ValueKey('page-logs'))).offstage,
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-overview')));
    await tester.pump();
    await tester.ensureVisible(startButton);
    await tester.pumpAndSettle();
    await tester.tap(startButton);
    await _pumpRealIo(tester);

    expect(runtime.starts, 1);
    expect(find.text(l10n.serviceRunningTitle), findsOneWidget);
    expect(find.textContaining('v24.20.0'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('overview-component-backend')),
        matching: find.text(l10n.unavailable),
      ),
      findsWidgets,
    );
    expect(find.textContaining('3001'), findsWidgets);
    expect(tester.takeException(), isNull);

    final restartButton = find.widgetWithText(ShadButton, '重启');
    await tester.ensureVisible(restartButton);
    await tester.pumpAndSettle();
    await tester.tap(restartButton);
    await tester.pumpAndSettle();
    expect(find.text('重启本地服务？'), findsOneWidget);
    await tester.tap(find.widgetWithText(ShadButton, '取消'));
    await tester.pumpAndSettle();
    expect(runtime.stops, 0);
    expect(runtime.starts, 1);

    await tester.tap(restartButton);
    await tester.pumpAndSettle();
    expect(find.text('重启本地服务？'), findsOneWidget);
    await tester.tap(find.widgetWithText(ShadButton, '重启').last);
    await _pumpRealIo(tester);
    expect(runtime.stops, 1);
    expect(runtime.starts, 2);
    expect(find.text(l10n.serviceRunningTitle), findsOneWidget);

    final stopButton = find.widgetWithText(ShadButton, '停止');
    await tester.tap(stopButton);
    await tester.pumpAndSettle();
    expect(find.text('停止本地服务？'), findsOneWidget);
    expect(runtime.stops, 1);
    await tester.tap(find.widgetWithText(ShadButton, '取消'));
    await tester.pumpAndSettle();
    expect(runtime.stops, 1);
    expect(find.text(l10n.serviceRunningTitle), findsOneWidget);

    runtime.stopError = StateError('stop fixture failure');
    await tester.tap(stopButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ShadButton, '停止').last);
    await _pumpRealIo(tester);
    expect(runtime.stops, 1);
    expect(runtime.currentState.status, RuntimeStatus.running);
    expect(find.textContaining('stop fixture failure'), findsOneWidget);
    expect(find.byKey(const ValueKey('overview-view-logs')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('overview-view-logs')));
    await tester.pump();
    expect(
      tester.widget<Offstage>(find.byKey(const ValueKey('page-logs'))).offstage,
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-overview')));
    await tester.pump();

    runtime.stopError = null;
    await tester.ensureVisible(stopButton);
    await tester.tap(stopButton);
    await tester.pumpAndSettle();
    expect(find.text('停止本地服务？'), findsOneWidget);
    await tester.tap(find.widgetWithText(ShadButton, '停止').last);
    await _pumpRealIo(tester);
    expect(runtime.stops, 2);
    expect(runtime.currentState.status, RuntimeStatus.stopped);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('overview-service-card')),
      -200,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('page-overview')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n.serviceStoppedTitle), findsOneWidget);
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

  testWidgets('manage keeps a failed system-browser fallback visible', (
    WidgetTester tester,
  ) async {
    final fixture = await _widgetRuntime(tester);
    var browserCalls = 0;
    final browserResults = <Completer<bool>>[
      Completer<bool>(),
      Completer<bool>(),
      Completer<bool>(),
    ];
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: fixture.coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
        onOpenExternalUri: (_) => browserResults[browserCalls++].future,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    await tester.pump();
    fixture.runtime.emitState(RuntimeStatus.running);
    await tester.pump();

    final browserButton = find.byKey(
      const ValueKey('manage-open-fallback-browser'),
    );
    expect(browserButton, findsOneWidget);
    final appliedWebUiUri = fixture.coordinator.appliedWebUiUri!;
    final appliedWebUiApiUri = fixture.coordinator.appliedWebUiApiUri!;
    await tester.tap(browserButton);
    expect(browserCalls, 1);
    fixture.runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.now(),
        source: RuntimeLogSource.stdout,
        message: 'unrelated log update',
      ),
    );
    await tester.pump();
    browserResults[0].complete(false);
    await _pumpRealIo(tester);
    expect(
      find.text('The system browser could not be opened.'),
      findsOneWidget,
    );
    fixture.runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.now(),
        source: RuntimeLogSource.stdout,
        message: 'later unrelated log update',
      ),
    );
    await tester.pump();
    expect(
      find.text('The system browser could not be opened.'),
      findsOneWidget,
    );

    await tester.tap(browserButton);
    expect(browserCalls, 2);
    browserResults[1].complete(true);
    await _pumpRealIo(tester);
    expect(find.text('The system browser could not be opened.'), findsNothing);

    await tester.tap(browserButton);
    expect(browserCalls, 3);
    browserResults[2].complete(false);
    await _pumpRealIo(tester);
    expect(
      find.text('The system browser could not be opened.'),
      findsOneWidget,
    );
    fixture.runtime.emitState(RuntimeStatus.stopping);
    await tester.pump();
    expect(fixture.coordinator.appliedWebUiUri, appliedWebUiUri);
    expect(fixture.coordinator.appliedWebUiApiUri, appliedWebUiApiUri);
    fixture.runtime.emitState(
      RuntimeStatus.crashed,
      message: 'fixture backend crash',
    );
    await tester.pump();
    expect(fixture.coordinator.appliedWebUiUri, appliedWebUiUri);
    expect(fixture.coordinator.appliedWebUiApiUri, appliedWebUiApiUri);
    expect(find.text('fixture backend crash'), findsOneWidget);
    expect(find.text('The system browser could not be opened.'), findsNothing);
    expect(fixture.runtime.stops, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manage can start the saved service and stay in Sub-Store', (
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
    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    await tester.pump();

    final startAndEnter = find.byKey(const ValueKey('manage-start-and-enter'));
    expect(startAndEnter, findsOneWidget);
    expect(tester.widget<ShadButton>(startAndEnter).enabled, isTrue);
    await tester.tap(startAndEnter);
    await _pumpRealIo(tester);

    expect(fixture.runtime.starts, 1);
    expect(
      tester
          .widget<Offstage>(find.byKey(const ValueKey('page-manage')))
          .offstage,
      isFalse,
    );
    expect(fixture.runtime.stops, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manage exposes stopped guidance and service details', (
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
    expect(find.text('本地服务尚未启动'), findsOneWidget);
    expect(find.text('启动并进入'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('manage-service-details')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('manage-service-details')));
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
    final backendConfig = find.byKey(
      const ValueKey('settings-card-backend-config'),
    );
    await tester.ensureVisible(backendConfig);
    await tester.pumpAndSettle();
    await tester.tap(backendConfig);
    await tester.pumpAndSettle();
    final httpMetaSwitch = find.byKey(
      const ValueKey('settings-http-meta-toggle'),
    );
    expect(httpMetaSwitch, findsOneWidget);
    await tester.ensureVisible(httpMetaSwitch);
    await tester.pumpAndSettle();
    await tester.tap(httpMetaSwitch);
    await tester.pump();

    final save = find.byKey(const ValueKey('settings-child-save'));
    expect(tester.widget<ShadButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.pump();
    await _pumpRealIo(tester);

    final saved = await tester.runAsync(store.load);
    expect(saved!.httpMeta.enabled, isFalse);
    expect(save, findsNothing);
    expect(find.byType(ShadToast), findsNothing);
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
    // The shadcn controls expose the single selected source accessibly.
    Semantics semanticsFor(Finder button) => tester.widget<Semantics>(
      find
          .ancestor(
            of: button,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.selected != null,
            ),
          )
          .first,
    );
    final httpMeta = find.byKey(const ValueKey('logs-source-HTTP-META'));
    final back = find.byKey(const ValueKey('logs-source-Backend'));
    final all = find.byKey(const ValueKey('logs-source-all'));
    expect(semanticsFor(all).properties.selected, isTrue);
    expect(semanticsFor(httpMeta).properties.selected, isFalse);
    expect(semanticsFor(back).properties.selected, isFalse);
    await tester.tap(back);
    await tester.tap(find.byKey(const ValueKey('logs-mobile-sort')));
    await tester.pumpAndSettle();
    expect(find.text('Newest last'), findsOneWidget);
    await tester.tap(find.text('Newest last'));
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
    await tester.binding.setSurfaceSize(const Size(599, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: fixture.coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('zh'),
        desktopWarning: ValueNotifier<AppConfigError>(
          const AppConfigError(
            AppConfigErrorCode.exitFailed,
            detail: 'fixture shutdown failure',
          ),
        ),
        onRetryExit: () async {},
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();
    expect(find.textContaining('SubDock 未能完成退出'), findsOneWidget);
    expect(find.text('暂无日志'), findsOneWidget);
    expect(tester.takeException(), isNull);

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
    await tester.pump();
    final rows = find.byKey(const ValueKey('logs-mobile-row'));
    expect(rows, findsNWidgets(3));
    final message = find.text('mobile fixture');
    final body = find.byKey(const ValueKey('logs-body'));
    final scrollables = find.ancestor(
      of: body,
      matching: find.byType(Scrollable),
    );
    await tester.drag(scrollables.first, const Offset(0, -150));
    await tester.pump();
    await tester.ensureVisible(message);
    expect(message.hitTestable(), findsOneWidget);
    final copy = find.byKey(const ValueKey('logs-copy-filtered'));
    await tester.ensureVisible(copy);
    expect(copy.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    for (final width in const [600.0, 599.0]) {
      await tester.binding.setSurfaceSize(Size(width, 700));
      await tester.pump();
      final toolbar = find.byKey(const ValueKey('logs-mobile-toolbar'));
      final surface = find.byKey(const ValueKey('logs-surface'));
      final row = find.byKey(const ValueKey('logs-mobile-row'));
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

      final card = tester.widget<ShadCard>(surface);
      expect(card.radius, BorderRadius.circular(12));
      final searchTheme = ShadTheme.of(
        tester.element(find.byKey(const ValueKey('logs-search'))),
      );
      expect(searchTheme.radius, BorderRadius.circular(8));
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
    await tester.binding.setSurfaceSize(const Size(1000, 700));
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

    await tester.enterText(find.byType(ShadInput), 'Backend');
    await tester.pump();
    expect(find.byType(SelectableText), findsNothing);
    await tester.enterText(find.byType(ShadInput), 'log-0');
    await tester.pump();
    expect(find.byType(SelectableText), findsNothing);
    await tester.enterText(find.byType(ShadInput), 'log-59');
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText && widget.data?.contains('log-59') == true,
      ),
      findsOneWidget,
    );
    final sourceFilter = find.byKey(const ValueKey('logs-source-filter'));
    await tester.tap(sourceFilter);
    await tester.pumpAndSettle();
    final httpMetaOption = find.widgetWithText(
      ShadOption<String?>,
      'HTTP-META',
    );
    expect(httpMetaOption.hitTestable(), findsOneWidget);
    await tester.tap(httpMetaOption);
    await tester.pumpAndSettle();
    // 单一审(HTTP-META)下,后端日志 log-59 被过滤掉。
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(sourceFilter);
    await tester.pumpAndSettle();
    final backendOption = find.widgetWithText(ShadOption<String?>, 'Backend');
    expect(backendOption.hitTestable(), findsOneWidget);
    await tester.tap(backendOption);
    await tester.pumpAndSettle();
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
    await tester.enterText(find.byType(ShadInput), 'sort-');
    final sortSelector = find.byKey(const ValueKey('logs-sort-selector'));
    await tester.tap(sortSelector);
    await tester.pumpAndSettle();
    final oldestOption = find.widgetWithText(ShadOption<LogSort?>, '最早在前');
    expect(oldestOption.hitTestable(), findsOneWidget);
    await tester.tap(oldestOption);
    await tester.pumpAndSettle();
    List<String?> sortedMessages() => tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.data)
        .toList();
    var sortedRows = sortedMessages();
    expect(sortedRows, ['sort-oldest', 'sort-newest']);
    await tester.tap(sortSelector);
    await tester.pumpAndSettle();
    final newestOption = find.widgetWithText(ShadOption<LogSort?>, '最新在前');
    expect(newestOption.hitTestable(), findsOneWidget);
    await tester.tap(newestOption);
    await tester.pumpAndSettle();
    sortedRows = sortedMessages();
    expect(sortedRows, ['sort-newest', 'sort-oldest']);
    await tester.enterText(find.byType(ShadInput), '');

    await tester.enterText(find.byType(ShadInput), 'panic');
    await tester.tap(find.byKey(const ValueKey('nav-item-overview')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();
    expect(find.byType(ShadInput), findsOneWidget);
    expect(
      tester.widget<ShadInput>(find.byType(ShadInput)).controller!.text,
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
    await tester.enterText(find.byType(ShadInput), '');
    await tester.tap(sourceFilter);
    await tester.pumpAndSettle();
    expect(httpMetaOption.hitTestable(), findsOneWidget);
    await tester.tap(httpMetaOption);
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP-META info line'), findsOneWidget);
    await tester.tap(sourceFilter);
    await tester.pumpAndSettle();
    expect(backendOption.hitTestable(), findsOneWidget);
    await tester.tap(backendOption);
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP-META info line'), findsNothing);
    await tester.tap(sourceFilter);
    await tester.pumpAndSettle();
    final allSourcesOption = find.widgetWithText(ShadOption<String?>, '全部');
    expect(allSourcesOption.hitTestable(), findsOneWidget);
    await tester.tap(allSourcesOption);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: sourceFilter, matching: find.text('全部')),
      findsOneWidget,
    );

    final platform =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? copied;
    var clipboardFails = false;
    Completer<void>? clipboardReply;
    Completer<void>? clipboardEntered;
    platform.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        if (clipboardFails) {
          throw PlatformException(code: 'clipboard_unavailable');
        }
        copied = (call.arguments as Map)['text'] as String;
        clipboardEntered?.complete();
        if (clipboardReply != null) await clipboardReply.future;
      }
      return null;
    });
    addTearDown(
      () => platform.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final displayed = tester
        .widget<SelectableText>(find.byType(SelectableText).first)
        .data;
    final copy = find.byKey(const ValueKey('logs-row-copy')).first;
    await tester.ensureVisible(copy);
    await tester.pump();
    expect(tester.getSize(copy), const Size(40, 40));
    await tester.tap(copy);
    await tester.pump();
    expect(copied, contains(displayed));
    final toast = find.byType(ShadToast);
    await tester.pumpAndSettle();
    expect(toast, findsOneWidget);
    await tester.tap(
      find.descendant(of: toast, matching: find.byType(ShadIconButton)),
    );
    await tester.pumpAndSettle();
    expect(toast, findsNothing);

    clipboardFails = true;
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(find.text('无法将日志复制到剪贴板。'), findsOneWidget);
    expect(toast, findsNothing);

    clipboardFails = false;
    final releaseClipboard = Completer<void>();
    final enteredClipboard = Completer<void>();
    clipboardReply = releaseClipboard;
    clipboardEntered = enteredClipboard;
    try {
      await tester.tap(copy);
      await tester.idle();
      expect(enteredClipboard.isCompleted, isTrue);
      await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
      releaseClipboard.complete();
      await tester.idle();
      await tester.pumpAndSettle();
      expect(toast, findsNothing);
      await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
      await tester.pumpAndSettle();
      expect(toast, findsNothing);
      expect(find.text('无法将日志复制到剪贴板。'), findsNothing);
    } finally {
      if (!releaseClipboard.isCompleted) releaseClipboard.complete();
      await tester.idle();
      clipboardReply = null;
      clipboardEntered = null;
    }

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

    await tester.enterText(find.byKey(const ValueKey('logs-search')), '');
    await tester.pump();
    final currentList = find.descendant(
      of: find.byKey(const ValueKey('logs-surface')),
      matching: find.byType(Scrollable),
    );
    await tester.drag(currentList.first, const Offset(0, -220));
    await tester.pump();
    expect(find.text('查看最新日志'), findsOneWidget);
    final rowsBeforeArrival = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.data)
        .toList();
    final scrollArrival = find.byWidgetPredicate(
      (widget) =>
          widget is SelectableText &&
          widget.data?.contains('scroll-paused-arrival') == true,
    );
    runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.now(),
        source: RuntimeLogSource.stdout,
        message: 'scroll-paused-arrival',
      ),
    );
    await tester.pump();
    expect(find.text('新增日志：1'), findsOneWidget);
    expect(
      tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((widget) => widget.data)
          .toList(),
      rowsBeforeArrival,
    );
    expect(scrollArrival, findsNothing);
    await tester.tap(follow);
    await tester.pumpAndSettle();
    expect(find.text('暂停阅读'), findsOneWidget);
    expect(scrollArrival, findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(599, 480));
    await tester.pump();
    final workspace = find.byKey(const ValueKey('logs-body'));
    final workspaceScroll = find
        .ancestor(of: workspace, matching: find.byType(Scrollable))
        .first;
    var latestBeforeOuterScroll = scrollArrival;
    Future<void> dragOuter(Offset delta) async {
      final viewportRect = tester.getRect(workspaceScroll);
      final workspaceRect = tester.getRect(workspace);
      final origin = Offset(workspaceRect.left + 2, viewportRect.center.dy);
      expect(workspaceRect.contains(origin), isTrue);
      await tester.dragFrom(origin, delta);
      await tester.pump();
    }

    expect(find.text('暂停阅读'), findsOneWidget);
    await dragOuter(const Offset(0, -120));
    expect(latestBeforeOuterScroll.hitTestable(), findsOneWidget);
    final header = find.byKey(const ValueKey('logs-panel-header'));
    runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.now(),
        source: RuntimeLogSource.stdout,
        message: 'quiet-newest-arrival',
      ),
    );
    await tester.pump();
    final quietArrival = find.byWidgetPredicate(
      (widget) =>
          widget is SelectableText &&
          widget.data?.contains('quiet-newest-arrival') == true,
    );
    expect(quietArrival.hitTestable(), findsOneWidget);
    final viewportBeforeQuietWheel = tester.getRect(workspaceScroll);
    final workspaceBeforeQuietWheel = tester.getRect(workspace);
    final quietWheelOrigin = Offset(
      workspaceBeforeQuietWheel.left + 2,
      viewportBeforeQuietWheel.center.dy,
    );
    final headerBeforeQuietWheel = tester.getRect(header);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: quietWheelOrigin,
        scrollDelta: const Offset(0, 260),
      ),
    );
    expect(
      tester.getRect(header).top,
      lessThan(headerBeforeQuietWheel.top),
      reason: 'the first wheel event must physically move the outer workspace',
    );
    await tester.pump();
    expect(find.text('查看最新日志'), findsOneWidget);
    final rowsAfterQuietWheel = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.data)
        .toList();
    runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.now(),
        source: RuntimeLogSource.stdout,
        message: 'quiet-after-wheel',
      ),
    );
    await tester.pump();
    expect(find.text('新增日志：1'), findsOneWidget);
    expect(
      tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((widget) => widget.data)
          .toList(),
      rowsAfterQuietWheel,
    );
    final quietAfterWheel = find.byWidgetPredicate(
      (widget) =>
          widget is SelectableText &&
          widget.data?.contains('quiet-after-wheel') == true,
    );
    expect(quietAfterWheel, findsNothing);
    await tester.ensureVisible(follow);
    expect(follow.hitTestable(), findsOneWidget);
    await tester.tap(follow);
    await tester.pumpAndSettle();
    expect(quietAfterWheel.hitTestable(), findsOneWidget);
    latestBeforeOuterScroll = quietAfterWheel;
    final headerBeforeAwayScroll = tester.getRect(header);
    final viewportRect = tester.getRect(workspaceScroll);
    final latestRect = tester.getRect(latestBeforeOuterScroll);
    await dragOuter(Offset(0, -(latestRect.top - viewportRect.top + 40)));
    expect(tester.getRect(header).top, lessThan(headerBeforeAwayScroll.top));
    expect(find.text('查看最新日志'), findsOneWidget);
    final shortWindowRows = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.data)
        .toList();
    runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.now(),
        source: RuntimeLogSource.stdout,
        message: 'outer-scroll-arrival',
      ),
    );
    await tester.pump();
    expect(find.text('新增日志：1'), findsOneWidget);
    expect(
      tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((widget) => widget.data)
          .toList(),
      shortWindowRows,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data?.contains('outer-scroll-arrival') == true,
      ),
      findsNothing,
    );
    await tester.ensureVisible(follow);
    expect(follow.hitTestable(), findsOneWidget);
    await tester.tap(follow);
    await tester.pumpAndSettle();
    final latestMessage = find.byWidgetPredicate(
      (widget) =>
          widget is SelectableText &&
          widget.data?.contains('outer-scroll-arrival') == true,
    );
    expect(latestMessage.hitTestable(), findsOneWidget);
    final workspaceRect = tester.getRect(workspace);
    final viewportAfterResume = tester.getRect(workspaceScroll);
    final wheelOrigin = Offset(
      workspaceRect.left + 2,
      viewportAfterResume.center.dy,
    );
    final headerBeforeWheel = tester.getRect(header);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: wheelOrigin,
        scrollDelta: const Offset(0, 260),
      ),
    );
    await tester.pump();
    expect(tester.getRect(header).top, lessThan(headerBeforeWheel.top));
    expect(find.text('查看最新日志'), findsOneWidget);
    final rowsBeforeWheelArrival = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.data)
        .toList();
    runtime.emitLog(
      RuntimeLog(
        timestamp: DateTime.now(),
        source: RuntimeLogSource.stdout,
        message: 'outer-wheel-arrival',
      ),
    );
    await tester.pump();
    expect(find.text('新增日志：1'), findsOneWidget);
    expect(
      tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((widget) => widget.data)
          .toList(),
      rowsBeforeWheelArrival,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('logs-mobile-filter')),
    );
    final mobileFilter = find.byKey(const ValueKey('logs-mobile-filter'));
    expect(mobileFilter.hitTestable(), findsOneWidget);
    await tester.tap(mobileFilter);
    await tester.pumpAndSettle();
    final mobileSort = find.byKey(const ValueKey('logs-mobile-sort'));
    await tester.ensureVisible(mobileSort);
    expect(mobileSort.hitTestable(), findsOneWidget);
    await tester.tap(mobileSort);
    await tester.pumpAndSettle();
    final mobileOldestOption = find.widgetWithText(ShadOption<LogSort>, '最早在前');
    expect(mobileOldestOption.hitTestable(), findsOneWidget);
    await tester.tap(mobileOldestOption);
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回').last);
    await tester.pumpAndSettle();
    final wheelArrival = find.byWidgetPredicate(
      (widget) =>
          widget is SelectableText &&
          widget.data?.contains('outer-wheel-arrival') == true,
    );
    await tester.ensureVisible(follow);
    expect(follow.hitTestable(), findsOneWidget);
    await tester.tap(follow);
    await tester.pumpAndSettle();
    expect(find.text('暂停阅读'), findsOneWidget);
    expect(wheelArrival.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
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
    final recoverableTimestamp = DateTime.now();
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
          timestamp: recoverableTimestamp,
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
    final logStore = _RecoveryGatedRuntimeLogStore(directories);
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
    await tester.tap(find.byKey(ValueKey('history-view-$healthyRunId')));
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

    final deleteButton = find.byKey(ValueKey('history-delete-$healthyRunId'));
    expect(tester.widget<ShadIconButton>(deleteButton).onPressed, isNull);
    expect(tester.widget<ShadIconButton>(deleteButton).enabled, isFalse);
    final clearButton = find.widgetWithText(ShadButton, 'Clear history');
    expect(tester.widget<ShadButton>(clearButton).onPressed, isNull);
    expect(tester.widget<ShadButton>(clearButton).enabled, isFalse);
    expect(find.byKey(const ValueKey('recently-deleted')), findsNothing);
    expect(find.byKey(const ValueKey('history-delete-confirm')), findsNothing);

    await tester.runAsync(
      () => eventFile.writeAsBytes(originalEvents!, flush: true),
    );
    final releaseRecovery = Completer<void>();
    logStore.recoveryGate = releaseRecovery;
    try {
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('log-recovery-banner')),
          matching: find.text('Retry'),
        ),
      );
      await _pumpRealIo(tester, turns: 1);
      expect(logStore.recoveryEntered.isCompleted, isTrue);
      final retrying = find.widgetWithText(ShadButton, 'Retrying…');
      expect(tester.widget<ShadButton>(retrying).onPressed, isNull);
      expect(tester.widget<ShadButton>(retrying).enabled, isFalse);
      expect(
        Focus.of(tester.element(find.text('Retrying…'))).canRequestFocus,
        isFalse,
      );
      final semantics = tester.ensureSemantics();
      try {
        expect(
          tester.getSemantics(find.text('Retrying…')),
          matchesSemantics(
            label: 'Retrying…',
            isButton: true,
            isFocusable: true,
            hasEnabledState: true,
            isEnabled: false,
          ),
        );
      } finally {
        semantics.dispose();
      }
    } finally {
      if (!releaseRecovery.isCompleted) releaseRecovery.complete();
      await _pumpUntilLogRecoveryCompletes(tester);
      expect(logStore.recoveryFinished.isCompleted, isTrue);
    }
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
    expect(
      find.descendant(
        of: runTile,
        matching: find.textContaining('Incomplete log capture'),
      ),
      findsOneWidget,
    );
    final storedLogs = await tester.runAsync(() => logStore.readRun(runId));
    expect(storedLogs!.single.message, 'recoverable prefix');
    expect(tester.widget<ShadIconButton>(deleteButton).onPressed, isNotNull);
    expect(tester.widget<ShadIconButton>(deleteButton).enabled, isTrue);
    expect(tester.widget<ShadButton>(clearButton).onPressed, isNotNull);
    expect(tester.widget<ShadButton>(clearButton).enabled, isTrue);
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
    expect(find.byKey(ValueKey('history-run-$runId')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('history-view-$runId')));
    await _pumpRealIo(tester);
    expect(find.textContaining('history-404'), findsOneWidget);
    expect(find.textContaining('historical entry'), findsNothing);
    final nextPage = find.text('下一页');
    await tester.ensureVisible(nextPage);
    expect(nextPage.hitTestable(), findsOneWidget);
    await tester.tap(nextPage);
    await _pumpRealIo(tester);
    expect(find.textContaining('history-204'), findsOneWidget);
    expect(find.textContaining('history-404'), findsNothing);
    await tester.ensureVisible(nextPage);
    expect(nextPage.hitTestable(), findsOneWidget);
    await tester.tap(nextPage);
    await _pumpRealIo(tester);
    expect(find.textContaining('history-004'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -10000));
    await tester.pump();
    expect(find.textContaining('historical entry'), findsOneWidget);
    expect(find.textContaining('history-204'), findsNothing);
    await tester.enterText(find.byType(ShadInput).first, 'no-such-log');
    await _pumpRealIo(tester);
    expect(find.text('没有匹配的日志'), findsOneWidget);
    await tester.enterText(find.byType(ShadInput).first, '');
    await _pumpRealIo(tester);
    await tester.tap(find.byKey(const ValueKey('history-back')));
    await tester.pump();
    expect(find.byKey(ValueKey('history-run-$runId')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('history-delete-$runId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('history-delete-confirm')));
    await _pumpRealIo(tester);
    expect(find.text('已删除'), findsWidgets);
    await tester.tap(find.text('撤销').last);
    await _pumpRealIo(tester);
    await _pumpUntilRestoredHistoryRun(tester, runId);
    expect(find.byKey(ValueKey('history-run-$runId')), findsOneWidget);
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
    await tester.tap(find.byKey(ValueKey('history-delete-$runId')));
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
    await tester.tap(find.byKey(ValueKey('history-view-$runId')));
    await _pumpRealIo(tester);

    expect(find.text('无法加载历史记录'), findsOneWidget);
    expect(
      tester
          .widget<ShadInput>(find.byKey(const ValueKey('logs-search')))
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
        if (index.isEven) {
          await store.append(
            RuntimeLog(
              timestamp: DateTime.now(),
              source: RuntimeLogSource.httpMetaStdout,
              message: 'copy-entry-source-$index info',
            ),
          );
          await store.append(
            RuntimeLog(
              timestamp: DateTime.now(),
              source: RuntimeLogSource.stdout,
              message: 'copy-entry-level-$index error',
            ),
          );
          await store.append(
            RuntimeLog(
              timestamp: DateTime.now(),
              source: RuntimeLogSource.stdout,
              message: 'interleaved-query-$index info',
            ),
          );
        }
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
    await tester.tap(find.byKey(ValueKey('history-view-$runId')));
    await _pumpRealIo(tester);

    await tester.enterText(
      find.byKey(const ValueKey('logs-search')),
      'COPY-ENTRY',
    );
    await _pumpRealIo(tester);
    final sourceFilter = find.byKey(const ValueKey('logs-source-filter'));
    await tester.tap(sourceFilter);
    await tester.pumpAndSettle();
    final backendOption = find.widgetWithText(ShadOption<String?>, 'Backend');
    expect(backendOption.hitTestable(), findsOneWidget);
    await tester.tap(backendOption);
    await _pumpRealIo(tester);
    expect(
      find.descendant(of: sourceFilter, matching: find.text('Backend')),
      findsOneWidget,
    );
    final levelFilter = find.byKey(const ValueKey('logs-level-filter'));
    await tester.tap(levelFilter);
    await tester.pumpAndSettle();
    final infoOption = find.widgetWithText(ShadOption<String?>, '信息');
    expect(infoOption.hitTestable(), findsOneWidget);
    await tester.tap(infoOption);
    await _pumpRealIo(tester);
    expect(
      find.descendant(of: levelFilter, matching: find.text('信息')),
      findsOneWidget,
    );
    expect(find.textContaining('copy-entry-source-'), findsNothing);
    expect(find.textContaining('copy-entry-level-'), findsNothing);
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
    final nextPage = find.widgetWithText(ShadButton, '下一页');
    expect(tester.widget<ShadButton>(nextPage).onPressed, isNotNull);
    await tester.ensureVisible(nextPage);
    expect(nextPage.hitTestable(), findsOneWidget);
    await tester.tap(nextPage);
    await _pumpUntilLogEntry(tester, 'copy-entry-200 info');
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data?.contains('copy-entry-200 info') == true,
      ),
      findsOneWidget,
    );
    expect(tester.widget<ShadButton>(nextPage).onPressed, isNotNull);
    await tester.ensureVisible(nextPage);
    expect(nextPage.hitTestable(), findsOneWidget);
    await tester.tap(nextPage);
    await _pumpUntilLogEntry(tester, 'copy-entry-400 info');
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data?.contains('copy-entry-400 info') == true,
      ),
      findsOneWidget,
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
    expect(find.text('第 401–410 条 / 共 410 条匹配'), findsOneWidget);
    expect(copiedLines.first, contains('copy-entry-000 info'));
    expect(copiedLines.last, contains('copy-entry-409 info'));
    expect(copiedLines.any((line) => line.contains('auxiliary')), isFalse);
    expect(copiedLines.any((line) => line.contains('failure error')), isFalse);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(ShadToast),
        matching: find.byType(ShadIconButton),
      ),
    );
    await tester.pumpAndSettle();
    final resetFilters = find.byKey(const ValueKey('logs-reset-filters'));
    expect(resetFilters, findsOneWidget);
    await tester.ensureVisible(resetFilters);
    expect(resetFilters.hitTestable(), findsOneWidget);
    await tester.tap(resetFilters);
    await _pumpUntilLogEntry(tester, 'copy-entry-source-0 info');
    final search = find.byKey(const ValueKey('logs-search'));
    expect(tester.widget<ShadInput>(search).controller!.text, isEmpty);
    expect(
      find.descendant(of: sourceFilter, matching: find.text('全部')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: levelFilter, matching: find.text('级别')),
      findsOneWidget,
    );
    final restoredError = find.textContaining('copy-entry-level-0 error');
    await tester.scrollUntilVisible(
      restoredError,
      80,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('logs-surface')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(restoredError, findsOneWidget);
    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.text('第 1–200 条 / 共 1027 条匹配'), findsOneWidget);
    expect(resetFilters, findsNothing);

    await tester.enterText(search, 'no-matching-history-event');
    await _pumpRealIo(tester);
    expect(find.text('没有匹配的日志'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('logs-clear-filters')));
    await _pumpUntilLogEntry(tester, 'copy-entry-000 info');
    expect(tester.widget<ShadInput>(search).controller!.text, isEmpty);
    expect(resetFilters, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('history clipboard publishes only complete current reads', (
    tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final store = _ReadGatedRuntimeLogStore(directories!);
    final gates = <_ReadGate>[];
    addTearDown(() async {
      for (final gate in gates) {
        if (!gate.release.isCompleted) gate.release.complete();
      }
      if (gates.any(
        (gate) => gate.prefixRead.isCompleted && !gate.finished.isCompleted,
      )) {
        await _pumpRealIo(tester);
      }
    });
    late String runId;
    await tester.runAsync(() async {
      await store.initialize();
      runId = await store.beginRun();
      await store.append(
        RuntimeLog(
          timestamp: DateTime.utc(2026, 1, 1),
          source: RuntimeLogSource.stdout,
          message: 'stale-old marker',
        ),
      );
      await store.append(
        RuntimeLog(
          timestamp: DateTime.utc(2026, 1, 2),
          source: RuntimeLogSource.stdout,
          message: 'current marker',
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
    await tester.tap(find.byKey(ValueKey('history-view-$runId')));
    await _pumpRealIo(tester);
    await tester.enterText(find.byKey(const ValueKey('logs-search')), 'marker');
    await _pumpRealIo(tester);
    expect(find.textContaining('stale-old marker'), findsOneWidget);
    expect(find.textContaining('current marker'), findsOneWidget);
    expect(
      tester
          .widget<ShadButton>(find.byKey(const ValueKey('logs-copy-filtered')))
          .onPressed,
      isNotNull,
    );

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
    await Clipboard.setData(const ClipboardData(text: 'prior clipboard'));
    expect(copied, 'prior clipboard');

    final failedRead = store.gateNextRead(failAfterPrefix: true);
    gates.add(failedRead);
    await tester.tap(find.byKey(const ValueKey('logs-copy-filtered')));
    await _pumpRealIo(tester);
    expect(failedRead.prefixRead.isCompleted, isTrue);
    expect(copied, 'prior clipboard');
    failedRead.release.complete();
    await _pumpRealIo(tester);
    expect(failedRead.finished.isCompleted, isTrue);
    expect(copied, 'prior clipboard');
    expect(find.text('无法加载历史记录'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('logs-search')),
      'stale-old',
    );
    await _pumpRealIo(tester);
    expect(find.textContaining('stale-old marker'), findsOneWidget);
    expect(find.textContaining('current marker'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('logs-search')), 'marker');
    await _pumpRealIo(tester);
    expect(find.textContaining('stale-old marker'), findsOneWidget);
    expect(find.textContaining('current marker'), findsOneWidget);
    expect(
      tester
          .widget<ShadButton>(find.byKey(const ValueKey('logs-copy-filtered')))
          .onPressed,
      isNotNull,
    );
    final staleRead = store.gateNextRead();
    gates.add(staleRead);
    await tester.tap(find.byKey(const ValueKey('logs-copy-filtered')));
    await _pumpRealIo(tester);
    expect(staleRead.prefixRead.isCompleted, isTrue);
    expect(copied, 'prior clipboard');

    await tester.enterText(
      find.byKey(const ValueKey('logs-search')),
      'stale-old',
    );
    await _pumpRealIo(tester);
    expect(find.textContaining('stale-old marker'), findsOneWidget);
    expect(find.textContaining('current marker'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('logs-copy-filtered')));
    await _pumpRealIo(tester);
    expect(copied, contains('stale-old marker'));
    expect(copied, isNot(contains('current marker')));

    staleRead.release.complete();
    await _pumpRealIo(tester);
    expect(staleRead.finished.isCompleted, isTrue);
    expect(copied, contains('stale-old marker'));
    expect(copied, isNot(contains('current marker')));
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
      tester.getSemantics(
        find.descendant(
          of: find.byKey(ValueKey('history-view-$runId')),
          matching: find.text('打开'),
        ),
      ),
      matchesSemantics(
        label: '打开',
        hasTapAction: true,
        hasFocusAction: true,
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
      ),
    );
    final delete = find.bySemanticsLabel('删除运行记录');
    expect(delete, findsOneWidget);
    expect(
      tester.getSemantics(delete),
      matchesSemantics(
        label: '删除运行记录',
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

    await tester.tap(find.byKey(ValueKey('history-view-$runId')));
    await _pumpRealIo(tester);
    expect(find.text('semantic history entry'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('history-delete-detail')));
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
    expect(find.text('最新'), findsNothing);
    expect(
      find.descendant(of: frontend, matching: find.text('已安装')),
      findsOneWidget,
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
      find.descendant(
        of: frontend,
        matching: find.text(
          AppLocalizations.of(tester.element(frontend))!.unavailable,
        ),
      ),
      findsWidgets,
    );
    updates.statusErrors.remove(ComponentKind.frontend);
    await tester.tap(find.byKey(const ValueKey('nav-item-logs')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-item-overview')));
    await _pumpRealIo(tester);
    expect(
      find.descendant(of: frontend, matching: find.text('当前 frontend-current')),
      findsOneWidget,
    );
    expect(updates.checkCalls, isEmpty);
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

    final runtimePanel = find.byKey(
      const ValueKey('overview-runtime-information'),
    );
    final endpoint = find.byKey(const ValueKey('runtime-endpoint-value'));
    final l10n = AppLocalizations.of(tester.element(runtimePanel))!;
    for (final width in [599.0, 600.0]) {
      await tester.binding.setSurfaceSize(Size(width, 800));
      await tester.pump();
      await tester.ensureVisible(runtimePanel);
      final backendLabel = find.descendant(
        of: runtimePanel,
        matching: find.text(l10n.backendRuntime),
      );
      final metaLabel = find.descendant(
        of: runtimePanel,
        matching: find.text(l10n.httpMetaResource),
      );
      expect(
        tester.getTopLeft(metaLabel).dx,
        greaterThan(tester.getTopLeft(backendLabel).dx),
      );
      expect(
        (tester.getTopLeft(metaLabel).dy - tester.getTopLeft(backendLabel).dy)
            .abs(),
        lessThan(0.5),
      );
      expect(
        tester.widget<SelectableText>(endpoint).style!.fontFamily,
        uiMonoFontFamily,
      );
      expect(tester.takeException(), isNull);
    }
    final toggle = find.byKey(const ValueKey('overview-runtime-toggle'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    expect(endpoint, findsNothing);
    await tester.tap(toggle);
    await tester.pump();
    expect(endpoint, findsOneWidget);

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

    final serviceCard = find.byKey(const ValueKey('overview-service-card'));
    final components = find.byKey(const ValueKey('overview-component-status'));
    expect(
      find.descendant(
        of: serviceCard,
        matching: find.text(l10n.serviceRunningTitle),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: components, matching: find.text('1.3.0')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: runtimePanel, matching: find.text('9876')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: runtimePanel,
        matching: find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == '1',
        ),
      ),
      findsWidgets,
    );

    runtime.emitState(RuntimeStatus.unhealthy);
    await tester.pump();
    expect(
      find.descendant(
        of: serviceCard,
        matching: find.text(l10n.serviceUnhealthyTitle),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: serviceCard,
        matching: find.text(l10n.serviceUnhealthyDescription),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: serviceCard,
        matching: find.widgetWithText(ShadButton, l10n.start),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: runtimePanel,
        matching: find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == '1',
        ),
      ),
      findsNWidgets(2),
    );

    runtime.emitState(
      RuntimeStatus.running,
      httpMetaStatus: HttpMetaStatus.degraded,
      httpMetaMessage: 'auxiliary unavailable',
    );
    await _pumpRealIo(tester);
    expect(
      find.descendant(
        of: serviceCard,
        matching: find.text(l10n.serviceRunningTitle),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: components,
        matching: find.textContaining('auxiliary unavailable'),
      ),
      findsWidgets,
    );
    final manage = find.byKey(const ValueKey('overview-open-manage'));
    await tester.ensureVisible(manage);
    await tester.tap(manage);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('page-manage')), findsOneWidget);
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
          .widget<ShadButton>(find.byKey(const ValueKey('updates-check-all')))
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

    updates.checkResults[ComponentKind.backend] = ComponentUpdate(
      kind: ComponentKind.backend,
      currentVersion: '1.0.0',
      availableVersion: '1.1.0',
      release: GithubRelease(
        version: '1.1.0',
        releaseUri: Uri.parse('https://example.invalid/backend'),
        assets: const [],
      ),
    );
    final backendRecheck = find.byKey(
      const ValueKey('component-update-recheck-backend'),
    );
    await tester.ensureVisible(backendRecheck);
    await tester.tap(backendRecheck);
    await _pumpRealIo(tester);
    final update = find.byKey(
      const ValueKey('component-update-action-backend'),
    );
    final rollback = find.byKey(
      const ValueKey('component-rollback-action-backend'),
    );
    expect(tester.widget<ShadButton>(update).enabled, isTrue);
    expect(tester.widget<ShadButton>(rollback).enabled, isTrue);
    final checking = Completer<void>();
    updates.checkGates[ComponentKind.backend] = checking.future;
    try {
      await tester.ensureVisible(backendRecheck);
      await tester.tap(backendRecheck);
      await tester.pump();
      expect(coordinator.componentsChecking, contains(ComponentKind.backend));
      expect(update, findsNothing);
      expect(tester.widget<ShadButton>(rollback).enabled, isFalse);
    } finally {
      checking.complete();
    }
    await _pumpRealIo(tester);
    expect(tester.widget<ShadButton>(update).enabled, isTrue);
    expect(tester.widget<ShadButton>(rollback).enabled, isTrue);
    expect(updates.updateCalls, isEmpty);
    expect(updates.rollbackCalls, isEmpty);
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
        final l10n = AppLocalizations.of(
          tester.element(find.byKey(const ValueKey('page-updates'))),
        )!;
        for (final kind in const ['frontend', 'backend']) {
          final card = find.byKey(ValueKey('component-update-card-$kind'));
          final title = kind == 'frontend'
              ? l10n.frontendComponent
              : l10n.backendComponent;
          final description = kind == 'frontend'
              ? l10n.frontendComponentDescription
              : l10n.backendComponentDescription;
          final currentValue = find.byKey(
            ValueKey('component-update-local-status-$kind'),
          );
          final currentLabel = find.descendant(
            of: card,
            matching: find.text(l10n.currentVersion),
          );
          final availableLabel = find.descendant(
            of: card,
            matching: find.text(l10n.availableVersion),
          );
          final previousLabel = find.descendant(
            of: card,
            matching: find.text(l10n.previousVersion),
          );
          for (final detail in [
            find.descendant(of: card, matching: find.text(title)),
            find.descendant(of: card, matching: find.text(description)),
            currentValue,
            currentLabel,
            availableLabel,
            previousLabel,
          ]) {
            expect(detail, findsOneWidget);
          }
          final currentLabelRect = tester.getRect(currentLabel);
          final availableLabelRect = tester.getRect(availableLabel);
          final previousLabelRect = tester.getRect(previousLabel);
          expect(availableLabelRect.left, greaterThan(currentLabelRect.left));
          expect(previousLabelRect.top, greaterThan(availableLabelRect.top));
          final contentBottom =
              [
                    tester.getRect(
                      find.descendant(of: card, matching: find.text(title)),
                    ),
                    tester.getRect(
                      find.descendant(
                        of: card,
                        matching: find.text(description),
                      ),
                    ),
                    tester.getRect(currentValue),
                    currentLabelRect,
                    availableLabelRect,
                    previousLabelRect,
                  ]
                  .map((rect) => rect.bottom)
                  .reduce((top, bottom) => top > bottom ? top : bottom);
          expect(
            tester.getRect(find.byKey(ValueKey('component-actions-$kind'))).top,
            greaterThan(contentBottom),
          );
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
        expect(
          (tileRects[1].width - tileRects.first.width).abs(),
          lessThan(0.5),
        );
        expect(
          (tileRects[2].width - tileRects.first.width).abs(),
          lessThan(0.5),
        );
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

        final sectionCard = tester.widget<ShadCard>(
          find
              .descendant(of: packagedSection, matching: find.byType(ShadCard))
              .first,
        );
        expect(sectionCard.radius, BorderRadius.circular(12));
        final tileCard = tester.widget<ShadCard>(
          find.descendant(
            of: find.byKey(tileKeys.first),
            matching: find.byType(ShadCard),
          ),
        );
        expect(tileCard.radius, BorderRadius.circular(10));
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
    final backendNotice = tester.widget<ShadCard>(
      find.descendant(
        of: find.byKey(const ValueKey('updates-backend-notice')),
        matching: find.byType(ShadCard),
      ),
    );
    expect(backendNotice.radius, BorderRadius.circular(10));
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
            .widget<ShadButton>(
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
    expect(tester.widget<ShadButton>(updateButton).onPressed, isNotNull);
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
    final operationCompleted = Completer<void>();
    void observeCompletion() {
      if (coordinator.maintenanceOperation?.phase ==
              MaintenancePhase.completed &&
          !operationCompleted.isCompleted) {
        operationCompleted.complete();
      }
    }

    coordinator.maintenanceChanges.addListener(observeCompletion);
    try {
      await tester.tap(find.widgetWithText(ShadButton, 'Continue'));
      for (
        var turn = 0;
        turn < 200 && !operationCompleted.isCompleted;
        turn++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(operationCompleted.isCompleted, isTrue);
    } finally {
      coordinator.maintenanceChanges.removeListener(observeCompletion);
    }
    await tester.pumpAndSettle();
    final maintenanceMessage = find.text('Component maintenance completed.');
    expect(maintenanceMessage, findsNWidgets(2));
    expect(
      coordinator.componentsChecking,
      isNot(contains(ComponentKind.backend)),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('component-update-card-backend')),
        matching: find.text('Not confirmed'),
      ),
      findsOneWidget,
    );
    final toast = find.byType(ShadToast);
    final toastClose = find.descendant(
      of: toast,
      matching: find.byType(ShadIconButton),
    );
    expect(toastClose, findsOneWidget);
    await tester.tap(toastClose);
    await tester.pumpAndSettle();
    expect(toast, findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('updates-maintenance-result')),
        matching: find.text('Component maintenance completed.'),
      ),
      findsOneWidget,
    );
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
          .widget<ShadButton>(
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
    await tester.tap(find.widgetWithText(ShadButton, 'Continue'));
    await _pumpRealIo(tester);
    expect(updates.updateCalls, hasLength(1));
    expect(updates.rollbackCalls, isEmpty);
    expect(runtime.starts, 0);
    expect(runtime.stops, 0);
    expect(runtime.restarts, 0);
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const ValueKey('component-update-local-status-frontend'),
            ),
          )
          .data,
      '1.1.0',
    );
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
      tester
          .widget<Text>(
            find.byKey(
              const ValueKey('component-update-local-status-frontend'),
            ),
          )
          .data,
      '1.1.0',
    );
    expect(updates.updateCalls.length, updateCount);
    expect(updates.rollbackCalls.length, rollbackCount);
    expect(runtime.restarts, restartCount);

    final toast = find.byType(ShadToast);
    if (toast.evaluate().isNotEmpty) {
      final toastClose = find.descendant(
        of: toast,
        matching: find.byType(ShadIconButton),
      );
      expect(toastClose, findsOneWidget);
      await tester.tap(toastClose);
      await tester.pumpAndSettle();
    }
    expect(coordinator.maintenanceOperation?.phase, MaintenancePhase.completed);
    expect(runtime.starts, 0);
    expect(runtime.stops, 0);
    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    await tester.pump();
    final startAndEnter = find.byKey(const ValueKey('manage-start-and-enter'));
    expect(startAndEnter, findsOneWidget);
    await tester.ensureVisible(startAndEnter);
    expect(tester.widget<ShadButton>(startAndEnter).enabled, isTrue);
    await tester.tap(startAndEnter);
    await _pumpRealIo(tester);
    expect(
      tester
          .widget<Offstage>(find.byKey(const ValueKey('page-manage')))
          .offstage,
      isFalse,
    );
    expect(runtime.starts, 1);
    expect(runtime.stops, 0);
    expect(runtime.restarts, 0);
    expect(updates.updateCalls, hasLength(1));
    expect(updates.rollbackCalls, isEmpty);
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
      '1.0.0',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('component-update-card-backend')),
        matching: find.text('2.0.0'),
      ),
      findsOneWidget,
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
    await tester.tap(find.widgetWithText(ShadButton, 'Continue'));
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
      find.descendant(
        of: find.byKey(const ValueKey('updates-maintenance-result')),
        matching: find.textContaining('Component maintenance completed'),
      ),
      findsOneWidget,
    );
    expect(find.byType(ShadToast), findsOneWidget);
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
    await tester.tap(find.widgetWithText(ShadButton, 'Continue'));
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
      '1.0.0',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('component-update-card-frontend')),
        matching: find.text('0.9.0'),
      ),
      findsOneWidget,
    );
    expect(find.byType(ShadToast), findsNothing);
    expect(find.textContaining('update failed'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('component-start-now-frontend')),
      findsNothing,
    );
    expect(runtime.restarts, 0);
    expect(
      tester
          .widget<ShadButton>(
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
      '2.0.0',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('component-update-card-backend')),
        matching: find.text('1.0.0'),
      ),
      findsOneWidget,
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
      find.byKey(const ValueKey('about-project-homepage')),
      findsOneWidget,
    );
    expect(find.text('Operating system: windows'), findsOneWidget);
    expect(find.text('Architecture: arm64'), findsOneWidget);
    for (final key in [
      'about-version',
      'about-build-number',
      'about-license',
      'about-project-homepage',
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
    final serviceDetails = find.byKey(const ValueKey('about-service-details'));
    await tester.dragUntilVisible(
      serviceDetails.hitTestable(),
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -300),
      maxIteration: 12,
    );
    await tester.tap(serviceDetails);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('overview-service-card')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-about-page')), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, 800),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('settings-back')));
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
    var loadAttempts = 0;
    var metadataUnavailable = true;
    final loader = AboutInfoLoader(
      loadPackageMetadata: () async {
        loadAttempts++;
        if (metadataUnavailable) throw StateError('metadata failed');
        return (version: '1.2.3', buildNumber: '4');
      },
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
    final settingsAbout = find.byKey(const ValueKey('settings-about-page'));
    final metadataError = find.descendant(
      of: settingsAbout,
      matching: find.byKey(const ValueKey('about-metadata-error')),
    );
    expect(settingsAbout, findsOneWidget);
    expect(
      find.descendant(
        of: metadataError,
        matching: find.text('Application information unavailable'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('metadata failed'), findsNothing);
    final retryMetadata = find.descendant(
      of: settingsAbout,
      matching: find.byKey(const ValueKey('about-retry-metadata')),
    );
    expect(retryMetadata, findsOneWidget);
    final metadataSemantics = tester.ensureSemantics();
    try {
      expect(
        tester.getSemantics(metadataError).flagsCollection.isLiveRegion,
        isTrue,
      );
    } finally {
      metadataSemantics.dispose();
    }
    expect(
      find.descendant(
        of: settingsAbout,
        matching: find.byKey(const ValueKey('about-version')),
      ),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('settings-child-save')), findsNothing);

    final attemptsBeforeRetry = loadAttempts;
    metadataUnavailable = false;
    await tester.tap(retryMetadata);
    await _pumpRealIo(tester);
    expect(loadAttempts, attemptsBeforeRetry + 1);
    expect(
      find.descendant(
        of: settingsAbout,
        matching: find.text('SubDock version: 1.2.3'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: settingsAbout,
        matching: find.text('Build number: 4'),
      ),
      findsOneWidget,
    );
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
        label: 'Service',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('nav-item-manage'))),
      matchesSemantics(
        label: 'Sub-Store',
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
        label: 'Service',
        isButton: true,
        isSelected: false,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('nav-item-manage'))),
      matchesSemantics(
        label: 'Sub-Store',
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

    Finder tabLabel(String label) => find.descendant(
      of: find.widgetWithText(ShadButton, label),
      matching: find.text(label),
    );
    expect(
      tester.getSemantics(tabLabel('Current')),
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
      tester.getSemantics(tabLabel('History')),
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
      tester.getSemantics(
        find.descendant(
          of: find.widgetWithText(ShadButton, '当前'),
          matching: find.text('当前'),
        ),
      ),
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
      find.byKey(const ValueKey('about-project-homepage')),
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
    final licenses = find.byKey(const ValueKey('about-view-licenses'));
    final settingsScroll = find
        .descendant(
          of: find.byKey(const ValueKey('settings-list')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.dragUntilVisible(
      licenses.hitTestable(),
      settingsScroll,
      const Offset(0, -500),
      maxIteration: 10,
    );
    expect(licenses.hitTestable(), findsOneWidget);
    await tester.tap(licenses);
    await tester.pumpAndSettle();
    expect(find.text('返回关于'), findsOneWidget);
    final licenseBack = find.byKey(const ValueKey('about-license-back'));
    await tester.dragUntilVisible(
      licenseBack.hitTestable(),
      settingsScroll,
      const Offset(0, 500),
      maxIteration: 100,
    );
    expect(licenseBack.hitTestable(), findsOneWidget);
    await tester.tap(licenseBack);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manage directs component recovery to updates', (
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
      startupBlocker: const AppConfigError(
        AppConfigErrorCode.componentRecoveryFailed,
        detail: 'startup recovery remains required',
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      final disposal = coordinator.dispose();
      await tester.pump();
      await disposal;
    });
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    await tester.pump();

    expect(
      tester
          .widget<ShadButton>(
            find.byKey(const ValueKey('manage-start-and-enter')),
          )
          .enabled,
      isFalse,
    );
    final recoveryAction = find.descendant(
      of: find.byKey(const ValueKey('manage-recovery')),
      matching: find.widgetWithText(ShadButton, 'Updates'),
    );
    expect(recoveryAction, findsOneWidget);
    await tester.tap(recoveryAction);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Offstage>(find.byKey(const ValueKey('page-updates')))
          .offstage,
      isFalse,
    );
    expect(
      find.byKey(const ValueKey('updates-revalidate-recovery')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ShadButton>(find.byKey(const ValueKey('updates-update-all')))
          .enabled,
      isFalse,
    );
    expect(coordinator.startupBlocker, isA<AppConfigError>());
    expect(runtime.starts, 0);
    expect(runtime.stops, 0);
    expect(coordinator.runtime.currentState.status, RuntimeStatus.stopped);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manage does not offer start for an unhealthy live service', (
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
    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    fixture.runtime.emitState(
      RuntimeStatus.unhealthy,
      message: 'Health check failed; backend process is still running.',
    );
    await tester.pump();

    expect(find.text('Service response is unhealthy'), findsOneWidget);
    expect(
      find.text('Health check failed; backend process is still running.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('manage-start-and-enter')), findsNothing);
    expect(
      find.byKey(const ValueKey('manage-service-details')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('manage-service-details')));
    await tester.pump();
    expect(fixture.runtime.starts, 0);
    expect(fixture.runtime.stops, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manage keeps its header visible before WebView is ready', (
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
    expect(
      find.byKey(const ValueKey('manage-browser-toolbar')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('manage-reload')), findsOneWidget);
    expect(find.byKey(const ValueKey('manage-open-external')), findsOneWidget);

    runtime.emitState(RuntimeStatus.starting);
    await tester.pump();
    expect(find.byKey(const ValueKey('manage-transition')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('manage-browser-toolbar')),
      findsOneWidget,
    );

    runtime.emitState(RuntimeStatus.stopping);
    await tester.pump();
    expect(find.byKey(const ValueKey('manage-transition')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('manage-browser-toolbar')),
      findsOneWidget,
    );
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
              required trustedOrigin,
              onPageChanged,
              onMainFrameFailure,
              initialDarkMode,
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
    expect(find.text('Sub-Store 页面无法加载。请重试或改用系统浏览器打开。'), findsOneWidget);
    expect(find.text('本地服务仍在运行；可以重试加载 Sub-Store，或在系统浏览器中打开。'), findsOneWidget);
    expect(find.textContaining('initialization failed'), findsNothing);
    expect(runtime.stops, 0);
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
              required trustedOrigin,
              onPageChanged,
              onMainFrameFailure,
              initialDarkMode,
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
    expect(find.text('Sub-Store 页面无法加载。请重试或改用系统浏览器打开。'), findsOneWidget);
    expect(find.text('本地服务仍在运行；可以重试加载 Sub-Store，或在系统浏览器中打开。'), findsOneWidget);
    expect(find.textContaining('load failed'), findsNothing);
    expect(runtime.stops, 0);
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
              required trustedOrigin,
              onPageChanged,
              onMainFrameFailure,
              initialDarkMode,
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

  testWidgets('exit confirmation hides and restores the live Linux WebView', (
    WidgetTester tester,
  ) async {
    const channelPrefix = 'com.abandoft.webview_all_linux';
    const rootChannel = MethodChannel(channelPrefix);
    const instanceId = 8701;
    const instanceChannel = MethodChannel('$channelPrefix/$instanceId');
    const eventChannel = MethodChannel('$channelPrefix/$instanceId/events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final frames = <Map<Object?, Object?>>[];
    var createCalls = 0;
    messenger.setMockMethodCallHandler(rootChannel, (call) async {
      if (call.method == 'createWebView') {
        createCalls++;
        return instanceId;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(instanceChannel, (call) async {
      if (call.method == 'setFrame') {
        frames.add(Map<Object?, Object?>.from(call.arguments as Map));
      }
      return null;
    });
    messenger.setMockMethodCallHandler(eventChannel, (_) async => null);
    final previousPlatform = webview_platform.WebViewPlatform.instance;
    webview_platform.WebViewPlatform.instance =
        linux_webview.LinuxWebViewPlatform();
    addTearDown(() {
      messenger.setMockMethodCallHandler(rootChannel, null);
      messenger.setMockMethodCallHandler(instanceChannel, null);
      messenger.setMockMethodCallHandler(eventChannel, null);
      webview_platform.WebViewPlatform.instance =
          previousPlatform ?? linux_webview.LinuxWebViewPlatform();
    });

    final fixture = await _widgetRuntime(tester);
    var denyPriorApproval = true;
    var throwPriorApproval = false;
    final closeGuard = CloseRequestGuard(
      approvalHandler: () async {
        if (throwPriorApproval) throw StateError('prior close denied');
        return !denyPriorApproval;
      },
    );
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: fixture.coordinator,
        autoStart: false,
        closeRequestGuard: closeGuard,
        locale: const Locale('en'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    await tester.pump();
    fixture.runtime.emitState(RuntimeStatus.running);
    await _pumpRealIo(tester);
    await tester.pump();

    expect(createCalls, 1);
    expect(frames, isNotEmpty);
    expect(frames.last['visible'], isTrue);
    final closeRequest = closeGuard.request();
    await tester.pump();
    await _pumpRealIo(tester);
    expect(
      find.byKey(const ValueKey('desktop-exit-confirmation')),
      findsOneWidget,
    );
    expect(frames.last['visible'], isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await closeRequest, isFalse);
    expect(frames.last['visible'], isTrue);

    denyPriorApproval = true;
    final deniedRequest = closeGuard.request();
    await tester.pump();
    await _pumpRealIo(tester);
    expect(
      find.byKey(const ValueKey('desktop-exit-confirmation')),
      findsOneWidget,
    );
    await tester.tap(find.text('Exit app'));
    await tester.pumpAndSettle();
    expect(await deniedRequest, isFalse);
    expect(frames.last['visible'], isTrue);

    throwPriorApproval = true;
    final failedRequest = closeGuard.request();
    final failureExpectation = expectLater(failedRequest, throwsStateError);
    await tester.pump();
    await _pumpRealIo(tester);
    expect(
      find.byKey(const ValueKey('desktop-exit-confirmation')),
      findsOneWidget,
    );
    await tester.tap(find.text('Exit app'));
    await tester.pumpAndSettle();
    await failureExpectation;
    expect(frames.last['visible'], isTrue);

    denyPriorApproval = false;
    throwPriorApproval = false;
    final approvedRequest = closeGuard.request();
    await tester.pump();
    await _pumpRealIo(tester);
    expect(
      find.byKey(const ValueKey('desktop-exit-confirmation')),
      findsOneWidget,
    );
    await tester.tap(find.text('Exit app'));
    await tester.pump(const Duration(milliseconds: 10));
    expect(frames.last['visible'], isFalse);
    await tester.pumpAndSettle();
    expect(await approvedRequest, isTrue);
    expect(frames.last['visible'], isTrue);

    fixture.runtime.stopError = StateError('stop failed after approval');
    await expectLater(fixture.coordinator.stop(), throwsStateError);
    expect(frames.last['visible'], isTrue);
    expect(createCalls, 1);
    fixture.runtime.stopError = null;
    await tester.pumpWidget(const SizedBox());
  }, skip: !Platform.isLinux);

  testWidgets('Manage follows effective theme without recreating its session', (
    WidgetTester tester,
  ) async {
    final fixture = await _widgetRuntime(tester);
    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.dark;
    addTearDown(
      tester.binding.platformDispatcher.clearPlatformBrightnessTestValue,
    );
    final themeUpdates = <bool>[];
    var controllerCreations = 0;
    late EmbeddedPageChangeHandler? pageChanged;
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: fixture.coordinator,
        autoStart: false,
        locale: const Locale('en'),
        webViewControllerFactory:
            ({
              required onNavigationRequest,
              required onBlobMessage,
              required bridgeScript,
              required trustedOrigin,
              onPageChanged,
              onMainFrameFailure,
              initialDarkMode,
            }) {
              controllerCreations++;
              pageChanged = onPageChanged;
              return EmbeddedWebViewController.testing(
                initialize: () async {},
                buildWidget: () => const SizedBox(),
                loadRequest: (uri) async => pageChanged?.call(uri),
                reload: () async {},
                currentUrl: () async => fixture.coordinator.webUiUri,
                canGoBack: () async => false,
                goBack: () async {},
                canGoForward: () async => false,
                goForward: () async {},
                setColorScheme: (isDark, _) async {
                  themeUpdates.add(isDark);
                  return true;
                },
              );
            },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    await tester.pump();
    fixture.runtime.emitState(RuntimeStatus.running);
    await _pumpRealIo(tester);
    expect(themeUpdates, [true]);

    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.light;
    await tester.pump();
    await _pumpRealIo(tester);
    expect(themeUpdates, [true, false]);
    expect(controllerCreations, 1);
    await tester.pumpWidget(const SizedBox());
  }, skip: !EmbeddedWebViewController.supportsEffectiveColorSchemeSync);

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
    var controllerCreations = 0;
    final semanticsHandle = tester.ensureSemantics();
    String? copiedAddress;
    final platformMessenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    platformMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) {
      if (call.method == 'Clipboard.setData') {
        copiedAddress = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => platformMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.binding.setSurfaceSize(const Size(1440, 900));
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
              required trustedOrigin,
              onPageChanged,
              onMainFrameFailure,
              initialDarkMode,
            }) {
              controllerCreations++;
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
    runtime.emitState(
      RuntimeStatus.running,
      httpMetaStatus: HttpMetaStatus.degraded,
      httpMetaMessage: 'fixture auxiliary failure',
    );
    await _pumpRealIo(tester);

    expect(
      find.byKey(const ValueKey('manage-browser-toolbar')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('page-title')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('manage-browser-toolbar')),
        matching: find.text('Sub-Store'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('manage-auxiliary-warning')),
      findsOneWidget,
    );
    expect(find.text('辅助服务不可用；订阅管理仍可使用。'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-manage-webview')), findsOneWidget);
    expect(find.byType(ClipRRect), findsNothing);
    final addressFinder = find.byKey(const ValueKey('manage-current-address'));
    expect(addressFinder.hitTestable(), findsOneWidget);
    final addressInput = tester.widget<ShadInput>(addressFinder);
    expect(addressInput.readOnly, isTrue);
    expect(addressInput.enableInteractiveSelection, isTrue);
    expect(addressInput.controller!.text, coordinator.webUiUri.toString());
    final addressFocusNode = addressInput.focusNode!;
    for (var tabIndex = 0; tabIndex < 60; tabIndex++) {
      if (addressFocusNode.hasFocus) break;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(
      addressFocusNode.hasFocus,
      isTrue,
      reason: 'The read-only address must be reachable through keyboard Tab.',
    );
    final primaryModifier = defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    Future<void> pressPrimaryShortcut(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(primaryModifier);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(primaryModifier);
      await tester.pump();
    }

    await pressPrimaryShortcut(LogicalKeyboardKey.keyA);
    expect(addressInput.controller!.selection.start, 0);
    expect(
      addressInput.controller!.selection.end,
      coordinator.webUiUri.toString().length,
    );
    await pressPrimaryShortcut(LogicalKeyboardKey.keyC);
    await _pumpRealIo(tester);
    expect(copiedAddress, coordinator.webUiUri.toString());
    copiedAddress = null;

    final shadInputStrings = ShadLocalizations.of(tester.element(addressFinder))
        .input;
    await tester.longPress(addressFinder);
    await tester.pumpAndSettle();
    expect(find.byType(ShadContextMenu), findsWidgets);
    final selectAllAction = find.text(shadInputStrings.selectAll).hitTestable();
    expect(selectAllAction, findsOneWidget);
    await tester.tap(selectAllAction);
    await tester.pumpAndSettle();
    final copyAction = find.text(shadInputStrings.copy).hitTestable();
    expect(copyAction, findsOneWidget);
    await tester.tap(copyAction);
    await _pumpRealIo(tester);
    expect(copiedAddress, coordinator.webUiUri.toString());
    final actionLabels = {
      'manage-back': AppLocalizations.of(
        tester.element(find.byKey(const ValueKey('manage-browser-toolbar'))),
      )!.back,
      'manage-forward': AppLocalizations.of(
        tester.element(find.byKey(const ValueKey('manage-browser-toolbar'))),
      )!.forward,
      'manage-reload': AppLocalizations.of(
        tester.element(find.byKey(const ValueKey('manage-browser-toolbar'))),
      )!.refresh,
      'manage-open-external': AppLocalizations.of(
        tester.element(find.byKey(const ValueKey('manage-browser-toolbar'))),
      )!.openInSystemBrowser,
      'manage-service-details': AppLocalizations.of(
        tester.element(find.byKey(const ValueKey('manage-browser-toolbar'))),
      )!.manageServiceDetails,
    };
    for (final entry in actionLabels.entries) {
      final action = find.byKey(ValueKey(entry.key));
      expect(action, findsOneWidget);
      final actionSemantics = find.descendant(
        of: action,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == entry.value,
        ),
      );
      expect(actionSemantics, findsOneWidget);
      expect(tester.getSemantics(actionSemantics).label, entry.value);
      expect(
        find.ancestor(of: action, matching: find.byType(ShadTooltip)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: action, matching: find.byType(Text)),
        findsNothing,
      );
    }
    for (final key in [
      'manage-back',
      'manage-forward',
      'manage-reload',
      'manage-open-external',
      'manage-service-details',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
    expect(
      tester
          .widget<ShadIconButton>(find.byKey(const ValueKey('manage-back')))
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<ShadIconButton>(find.byKey(const ValueKey('manage-forward')))
          .enabled,
      isFalse,
    );

    await tester.tap(find.byKey(const ValueKey('manage-open-external')));
    await _pumpRealIo(tester);
    expect(openedUri, coordinator.webUiUri);

    canGoBack = true;
    canGoForward = true;
    pageChanged!.call(Uri.parse('${coordinator.webUiUri}/settings'));
    await _pumpRealIo(tester);
    expect(
      tester.widget<ShadInput>(addressFinder).controller!.text,
      '${coordinator.webUiUri}/settings',
    );
    expect(
      tester
          .widget<ShadIconButton>(find.byKey(const ValueKey('manage-back')))
          .enabled,
      isTrue,
    );
    expect(
      tester
          .widget<ShadIconButton>(find.byKey(const ValueKey('manage-forward')))
          .enabled,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('manage-back')));
    await tester.tap(find.byKey(const ValueKey('manage-forward')));
    await _pumpRealIo(tester);
    expect(wentBack, isTrue);
    expect(wentForward, isTrue);
    await tester.tap(
      find.byKey(const ValueKey('manage-open-external')).hitTestable(),
    );
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

    Future<void> expectToolbarAtViewport(Size size) async {
      openedUri = null;
      await tester.binding.setSurfaceSize(size);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        controllerCreations,
        1,
        reason: 'The responsive change must retain the active WebView session.',
      );
      expect(find.byKey(const ValueKey('manage-url')), findsNothing);
      expect(
        find.byKey(const ValueKey('manage-current-address')).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester.widget<ShadInput>(addressFinder).controller!.text,
        '${coordinator.webUiUri}/settings',
      );
      for (final key in [
        'manage-back',
        'manage-forward',
        'manage-reload',
        'manage-open-external',
        'manage-service-details',
      ]) {
        final action = find.byKey(ValueKey(key));
        expect(action, findsOneWidget);
        expect(action.hitTestable(), findsOneWidget);
        expect(tester.widget<ShadIconButton>(action).enabled, isTrue);
      }
      await tester.tap(find.byKey(const ValueKey('manage-open-external')));
      await _pumpRealIo(tester);
      expect(openedUri, Uri.parse('${coordinator.webUiUri}/settings'));
    }

    await expectToolbarAtViewport(const Size(1440, 900));
    await expectToolbarAtViewport(const Size(1024, 768));
    await expectToolbarAtViewport(const Size(600, 480));
    await expectToolbarAtViewport(const Size(599, 480));
    await tester.pumpWidget(const SizedBox());
    semanticsHandle.dispose();
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
    final openedUris = <Uri>[];

    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        locale: const Locale('zh'),
        onOpenExternalUri: (uri) async {
          openedUris.add(uri);
          return true;
        },
        webViewControllerFactory:
            ({
              required onNavigationRequest,
              required onBlobMessage,
              required bridgeScript,
              required trustedOrigin,
              onPageChanged,
              onMainFrameFailure,
              initialDarkMode,
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

    expect(find.byKey(const ValueKey('manage-url')), findsNothing);
    final addressFinder = find.byKey(const ValueKey('manage-current-address'));
    expect(
      tester.widget<ShadInput>(addressFinder).controller!.text,
      coordinator.webUiUri.toString(),
    );
    expect(loadedUri, coordinator.webUiUri);

    // SPA pushState to the /subs route reports via the bridge channel.
    final subsUri = coordinator.webUiUri.replace(path: '/subs');
    blobMessage('{"type":"url","url":"${subsUri.toString()}"}');
    await _pumpRealIo(tester);
    expect(
      tester.widget<ShadInput>(addressFinder).controller!.text,
      subsUri.toString(),
    );
    final openSpaRoute = find
        .byKey(const ValueKey('manage-open-external'))
        .hitTestable();
    expect(openSpaRoute, findsOneWidget);
    await tester.tap(openSpaRoute);
    await _pumpRealIo(tester);
    expect(openedUris, [subsUri]);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('About diagnostics redact runtime and environment secrets', (
    WidgetTester tester,
  ) async {
    final updates = _FakeComponentUpdateOperations()
      ..statuses[ComponentKind.backend] = const ComponentVersionStatus(
        current: '1.2.3',
        previous: 'PRIVATE_COMPONENT_SECRET',
      );
    final fixture = await _widgetRuntime(tester, componentUpdates: updates);
    final runtime = fixture.runtime
      ..appliedConfiguration = EffectiveRuntimeConfig.resolve(
        systemEnvironment: const {'SYSTEM_SECRET': 'PRIVATE_SYSTEM_SECRET'},
        backendEnvironment: BackendEnvDocument.parse(
          'PRIVATE_TOKEN=PRIVATE_ENV_SECRET\nSUB_STORE_FRONTEND_BACKEND_PATH=/PRIVATE_PATH_SECRET',
        ),
        config: const SubDockConfig(),
      );

    expect(
      runtime.appliedConfiguration!.environment[BackendEnvPolicy
          .frontendBackendPath],
      '/PRIVATE_PATH_SECRET',
    );
    expect(
      fixture.coordinator.appliedWebUiApiUri!.path,
      '/PRIVATE_PATH_SECRET',
    );
    String? externalLaunchFailure;
    var rejectClipboardCopy = false;
    var browserCalls = 0;
    var homepageCalls = 0;

    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? copied;
    var clipboardCalls = 0;
    Completer<Object?>? pendingClipboard;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) {
      if (call.method == 'Clipboard.setData') {
        clipboardCalls++;
        if (rejectClipboardCopy) {
          throw PlatformException(
            code: 'clipboard-failure',
            message: 'PRIVATE_CLIPBOARD_ERROR',
          );
        }
        copied = (call.arguments as Map)['text'] as String;
        if (pendingClipboard != null) return pendingClipboard.future;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await pumpApp(
      tester,
      SubDockApp(
        coordinator: fixture.coordinator,
        autoStart: false,
        enableWebView: false,
        locale: const Locale('en'),
        onOpenExternalUri: (uri) async {
          browserCalls++;
          if (uri.toString() == subDockProjectHomepage) homepageCalls++;
          if (externalLaunchFailure == 'throw') {
            throw StateError('PRIVATE_BROWSER_ERROR');
          }
          return externalLaunchFailure != 'false';
        },
        aboutInfoLoader: AboutInfoLoader(
          loadPackageMetadata: () async =>
              (version: '2.3.4', buildNumber: 'PRIVATE_BUILD_SECRET'),
          operatingSystem: () => 'PRIVATE_OS_SECRET',
          architecture: () => 'x64',
        ),
      ),
    );
    await _pumpRealIo(tester);
    runtime.emitState(
      RuntimeStatus.crashed,
      message: 'PRIVATE_BACKEND_ERROR',
      httpMetaStatus: HttpMetaStatus.degraded,
      httpMetaMessage: 'PRIVATE_HTTP_META_ERROR',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('nav-item-about')), findsNothing);
    expect(find.byKey(const ValueKey('page-about')), findsNothing);
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

    final homepage = find.byKey(const ValueKey('about-project-homepage'));
    externalLaunchFailure = 'throw';
    await tester.tap(homepage);
    await _pumpRealIo(tester);
    expect(find.text('The project page could not be opened.'), findsOneWidget);
    expect(find.textContaining('PRIVATE_BROWSER_ERROR'), findsNothing);
    final homepageActionSemantics = tester.ensureSemantics();
    try {
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('about-source-action-error')),
            )
            .flagsCollection
            .isLiveRegion,
        isTrue,
      );
    } finally {
      homepageActionSemantics.dispose();
    }
    externalLaunchFailure = 'false';
    await tester.tap(homepage);
    await _pumpRealIo(tester);
    expect(find.text('The project page could not be opened.'), findsOneWidget);
    externalLaunchFailure = null;
    await tester.tap(homepage);
    await _pumpRealIo(tester);
    expect(find.text('The project page could not be opened.'), findsNothing);
    expect(homepageCalls, 3);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
    browserCalls = 0;

    expect(
      find.byKey(const ValueKey('about-diagnostics-value')),
      findsOneWidget,
    );
    for (final key in ['about-view-licenses', 'about-copy-diagnostics']) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
    final serviceDetails = find.byKey(const ValueKey('about-service-details'));
    await tester.drag(
      find.byKey(const ValueKey('settings-list')),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    await tester.tap(serviceDetails);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('overview-service-card')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
    await _pumpRealIo(tester);
    expect(find.byKey(const ValueKey('settings-about-page')), findsOneWidget);

    rejectClipboardCopy = true;
    final copy = find.byKey(const ValueKey('about-copy-diagnostics'));
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await _pumpRealIo(tester);
    expect(
      find.text('The diagnostic summary could not be copied.'),
      findsOneWidget,
    );
    expect(find.textContaining('PRIVATE_CLIPBOARD_ERROR'), findsNothing);
    final clipboardActionSemantics = tester.ensureSemantics();
    try {
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('about-clipboard-action-error')),
            )
            .flagsCollection
            .isLiveRegion,
        isTrue,
      );
    } finally {
      clipboardActionSemantics.dispose();
    }

    rejectClipboardCopy = false;
    await tester.tap(copy);
    await _pumpRealIo(tester);
    expect(
      find.text('The diagnostic summary could not be copied.'),
      findsNothing,
    );
    expect(copied, contains('SubDock version: 2.3.4'));
    expect(find.text('Diagnostic summary copied'), findsOneWidget);
    expect(copied, contains('Backend status: crashed'));
    expect(copied, contains('HTTP-META status: degraded'));
    expect(copied, contains('Build number: unavailable'));
    expect(copied, contains('Operating system: unavailable'));
    for (final secret in [
      'PRIVATE_BUILD_SECRET',
      'PRIVATE_OS_SECRET',
      'PRIVATE_SYSTEM_SECRET',
      'PRIVATE_ENV_SECRET',
      'PRIVATE_PATH_SECRET',
      'PRIVATE_BACKEND_ERROR',
      'PRIVATE_HTTP_META_ERROR',
      'PRIVATE_COMPONENT_SECRET',
    ]) {
      expect(copied, isNot(contains(secret)));
    }

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
    expect(find.text('Diagnostic summary copied'), findsNothing);
    final clipboardCallsBeforeLateCopy = clipboardCalls;
    final lateClipboardReply = Completer<Object?>();
    pendingClipboard = lateClipboardReply;
    try {
      await tester.tap(copy);
      await tester.pump();
      expect(clipboardCalls, clipboardCallsBeforeLateCopy + 1);
      await tester.tap(find.byKey(const ValueKey('nav-item-overview')));
      await tester.pumpAndSettle();
    } finally {
      if (!lateClipboardReply.isCompleted) lateClipboardReply.complete(null);
      pendingClipboard = null;
      await _pumpRealIo(tester);
    }
    expect(find.text('Diagnostic summary copied'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('nav-item-settings')));
    await _pumpRealIo(tester);
    expect(find.byKey(const ValueKey('settings-about-page')), findsOneWidget);

    // Keep the bundled license load out of a prior widget's fake-async cache.
    rootBundle.evict('LICENSE');
    final realSubDockLicenseText = await tester.runAsync(
      () =>
          rootBundle.loadString('LICENSE').timeout(const Duration(seconds: 5)),
    );
    expect(realSubDockLicenseText, isNotEmpty);
    final realLicenseEntries = _realLicenseRegistryEntries;

    var realEntriesCollectorStarted = 0;
    var realEntriesCollectorCompleted = 0;
    Stream<LicenseEntry> emitCapturedRealEntries() async* {
      realEntriesCollectorStarted++;
      try {
        yield* Stream<LicenseEntry>.fromIterable(realLicenseEntries);
      } finally {
        realEntriesCollectorCompleted++;
      }
    }

    LicenseRegistry.reset();
    LicenseRegistry.addLicense(emitCapturedRealEntries);
    final registryGate = Completer<void>();
    final registryCollectorEntered = Completer<void>();
    var registryCollectorReads = 0;
    LicenseRegistry.addLicense(() async* {
      registryCollectorReads++;
      if (!registryCollectorEntered.isCompleted) {
        registryCollectorEntered.complete();
      }
      await registryGate.future;
      yield const LicenseEntryWithLineBreaks([
        'synthetic-about-reentry',
      ], 'Synthetic license entry for the reentry test.');
    });
    final licenses = find.byKey(const ValueKey('about-view-licenses'));
    try {
      await tester.ensureVisible(licenses);
      await tester.runAsync(() => tester.tap(licenses));
      for (
        var turn = 0;
        turn < 100 && !registryCollectorEntered.isCompleted;
        turn++
      ) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(Duration.zero);
      }
      expect(
        registryCollectorEntered.isCompleted,
        isTrue,
        reason:
            'Captured starts=$realEntriesCollectorStarted, '
            'captured completes=$realEntriesCollectorCompleted, '
            'delayed reads=$registryCollectorReads.',
      );
      expect(find.text('Loading license information…'), findsOneWidget);
      for (final key in [
        'about-source-substore',
        'about-source-node',
        'about-source-http-meta',
        'about-source-mihomo',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      final licenseBackButton = find.byKey(
        const ValueKey('about-license-back'),
      );
      await tester.tap(licenseBackButton);
      await tester.pumpAndSettle();
      await tester.ensureVisible(licenses);
      await tester.tap(licenses);
      await _pumpRealIo(tester);
      expect(registryCollectorReads, 1);
    } finally {
      if (!registryGate.isCompleted) registryGate.complete();
      await _pumpRealIo(tester);
      LicenseRegistry.reset();
      LicenseRegistry.addLicense(emitCapturedRealEntries);
    }
    expect(find.text('Back to About'), findsOneWidget);
    externalLaunchFailure = 'throw';
    final source = find.byKey(const ValueKey('about-source-substore'));
    await tester.ensureVisible(source);
    await tester.tap(source);
    await _pumpRealIo(tester);
    expect(find.text('The project page could not be opened.'), findsOneWidget);
    expect(find.textContaining('PRIVATE_BROWSER_ERROR'), findsNothing);
    final sourceActionSemantics = tester.ensureSemantics();
    try {
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('about-source-action-error')),
            )
            .flagsCollection
            .isLiveRegion,
        isTrue,
      );
    } finally {
      sourceActionSemantics.dispose();
    }
    externalLaunchFailure = 'false';
    await tester.ensureVisible(source);
    await tester.tap(source);
    await _pumpRealIo(tester);
    expect(find.text('The project page could not be opened.'), findsOneWidget);
    expect(browserCalls, 2);
    externalLaunchFailure = null;
    await tester.ensureVisible(source);
    await tester.tap(source);
    await _pumpRealIo(tester);
    expect(browserCalls, 3);
    expect(find.text('Project page launch requested.'), findsOneWidget);
    expect(find.text('The project page could not be opened.'), findsNothing);
    final subDockLicense = find.byKey(const ValueKey('about-sublicense-open'));
    await tester.tap(subDockLicense);
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'The GNU General Public License is a free, copyleft license',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('about-license-list-back')));
    await tester.pumpAndSettle();
    final settingsList = find.byKey(const ValueKey('settings-list'));
    final notoLicense = find.text('Noto Sans CJK SC 2.004');
    await tester.dragUntilVisible(
      notoLicense.hitTestable(),
      settingsList,
      const Offset(0, -400),
      maxIteration: 30,
    );
    await tester.tap(notoLicense);
    await tester.pumpAndSettle();
    expect(find.textContaining('Noto Sans CJK SC 2.004'), findsOneWidget);
    expect(
      find.textContaining(
        'The OFL allows the licensed fonts to be used, studied, modified',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('about-license-list-back')));
    await tester.pumpAndSettle();
    final monoLicense = find.text('DejaVu Sans Mono 2.37');
    await tester.dragUntilVisible(
      monoLicense.hitTestable(),
      settingsList,
      const Offset(0, -400),
      maxIteration: 30,
    );
    await tester.tap(monoLicense);
    await tester.pumpAndSettle();
    expect(find.textContaining('DejaVu Sans Mono 2.37'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('about-component-license-detail')),
        matching: find.textContaining(
          'Except as contained in this notice, the name of Tavmjong Bah shall not be used',
        ),
      ),
      findsOneWidget,
    );
    final licenseBack = find.byKey(const ValueKey('about-license-back'));
    await tester.drag(settingsList, const Offset(0, 1000));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
    expect(licenseBack.hitTestable(), findsOneWidget);
    await tester.tap(licenseBack);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('about-diagnostics-value')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manage ignores callbacks from a previous runtime session', (
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
    final sessions = <_CapturedManageCallbacks>[];
    final openedUris = <Uri>[];
    const selectorChannel = MethodChannel('plugins.flutter.io/file_selector');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var savePath = Completer<String?>();
    var savePathCalls = 0;
    messenger.setMockMethodCallHandler(selectorChannel, (call) {
      if (call.method == 'getSavePath') {
        savePathCalls++;
        return savePath.future;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(selectorChannel, null),
    );
    final target = File.fromUri(temp.uri.resolve('stale-export.json'));

    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(
      tester,
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        locale: const Locale('zh'),
        onOpenExternalUri: (uri) async {
          openedUris.add(uri);
          return true;
        },
        webViewControllerFactory:
            ({
              required onNavigationRequest,
              required onBlobMessage,
              required bridgeScript,
              required trustedOrigin,
              onPageChanged,
              onMainFrameFailure,
              initialDarkMode,
            }) {
              sessions.add(
                _CapturedManageCallbacks(
                  onNavigationRequest: onNavigationRequest,
                  onBlobMessage: onBlobMessage,
                  onPageChanged: onPageChanged,
                  onMainFrameFailure: onMainFrameFailure,
                ),
              );
              return _testWebViewController(
                initialize: () async {},
                loadRequest: (uri) async => onPageChanged?.call(uri),
              );
            },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nav-item-manage')));
    await tester.pump();
    runtime.emitState(RuntimeStatus.running);
    await _pumpRealIo(tester);
    expect(sessions, hasLength(1));
    final initialOpenAction = find
        .byKey(const ValueKey('manage-open-external'))
        .hitTestable();
    expect(initialOpenAction, findsOneWidget);
    await tester.tap(initialOpenAction);
    await _pumpRealIo(tester);
    expect(openedUris, [coordinator.webUiUri]);
    openedUris.clear();

    const blobMessage =
        '{"type":"blob","name":"stale-export.json","data":"AQID"}';
    sessions.first.onBlobMessage(blobMessage);
    await tester.pump();
    expect(savePathCalls, 1);

    runtime.emitRunStarted('next-runtime-session');
    await _pumpRealIo(tester);
    expect(sessions, hasLength(2));
    final staleUri = coordinator.webUiUri.replace(path: '/stale');
    sessions.first.onBlobMessage(blobMessage);
    sessions.first.onMainFrameFailure?.call(
      const EmbeddedMainFrameFailure(errorCode: -105),
    );
    sessions.first.onPageChanged?.call(staleUri);
    expect(
      await sessions.first.onNavigationRequest(
        EmbeddedNavigationRequest(Uri.parse('https://example.invalid/stale')),
      ),
      EmbeddedNavigationDecision.prevent,
    );
    await tester.pump();
    expect(savePathCalls, 1);
    expect(openedUris, isEmpty);
    final openAfterStalePage = find
        .byKey(const ValueKey('manage-open-external'))
        .hitTestable();
    expect(openAfterStalePage, findsOneWidget);
    await tester.tap(openAfterStalePage);
    await _pumpRealIo(tester);
    expect(openedUris, [coordinator.appliedWebUiUri]);
    expect(find.text('Sub-Store 页面加载失败。后端仍在运行；请重试或改用系统浏览器。'), findsNothing);

    savePath.complete(target.path);
    await _pumpRealIo(tester);
    expect(await tester.runAsync(target.exists), isFalse);
    savePath = Completer<String?>();

    final currentSession = sessions.last;
    currentSession.onMainFrameFailure?.call(
      const EmbeddedMainFrameFailure(errorCode: -105),
    );
    await tester.pump();
    expect(find.text('Sub-Store 页面加载失败。后端仍在运行；请重试或改用系统浏览器。'), findsOneWidget);

    currentSession.onPageChanged?.call(coordinator.appliedWebUiUri!);
    currentSession.onBlobMessage(
      '{"type":"url","url":"${coordinator.appliedWebUiUri!.replace(path: '/after-failure')}"}',
    );
    await tester.pump();
    expect(find.text('Sub-Store 页面加载失败。后端仍在运行；请重试或改用系统浏览器。'), findsOneWidget);
    expect(find.byKey(const ValueKey('manage-retry-load')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('manage-open-failed-browser')),
      findsOneWidget,
    );

    currentSession.onBlobMessage(blobMessage);
    await tester.pump();
    expect(savePathCalls, 2);
    await tester.tap(find.byKey(const ValueKey('manage-retry-load')));
    await _pumpRealIo(tester);
    expect(sessions, hasLength(3));
    expect(find.byKey(const ValueKey('manage-webview-error')), findsNothing);
    expect(find.byKey(const ValueKey('fake-manage-webview')), findsOneWidget);
    final openAfterRetry = find
        .byKey(const ValueKey('manage-open-external'))
        .hitTestable();
    expect(openAfterRetry, findsOneWidget);
    await tester.tap(openAfterRetry);
    await _pumpRealIo(tester);
    expect(openedUris.last, coordinator.appliedWebUiUri);

    final replacementSession = sessions.last;
    currentSession.onMainFrameFailure?.call(
      const EmbeddedMainFrameFailure(errorCode: -105),
    );
    currentSession.onPageChanged?.call(staleUri);
    currentSession.onBlobMessage(blobMessage);
    expect(
      await currentSession.onNavigationRequest(
        EmbeddedNavigationRequest(
          Uri.parse('https://example.invalid/after-retry'),
        ),
      ),
      EmbeddedNavigationDecision.prevent,
    );
    await tester.pump();
    expect(savePathCalls, 2);

    savePath.complete(target.path);
    await _pumpRealIo(tester);
    expect(await tester.runAsync(target.exists), isFalse);

    final recoveredUri = coordinator.appliedWebUiUri!.replace(
      path: '/recovered',
    );
    replacementSession.onPageChanged?.call(recoveredUri);
    await _pumpRealIo(tester);
    expect(find.byKey(const ValueKey('manage-webview-error')), findsNothing);
    final openRecoveredRoute = find
        .byKey(const ValueKey('manage-open-external'))
        .hitTestable();
    expect(openRecoveredRoute, findsOneWidget);
    await tester.tap(openRecoveredRoute);
    await _pumpRealIo(tester);
    expect(openedUris.last, recoveredUri);
    expect(runtime.stops, 0);
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
    final maximized = ValueNotifier(false);
    addTearDown(maximized.dispose);
    final semantics = tester.ensureSemantics();

    try {
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
          isMaximized: maximized,
        ),
      );

      await tester.tap(find.bySemanticsLabel('最小化'));
      await tester.tap(find.bySemanticsLabel('最大化'));
      maximized.value = true;
      await tester.pump();
      expect(find.bySemanticsLabel('还原'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('还原'));
      await tester.tap(find.bySemanticsLabel('关闭'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.drag(find.text('SubDock'), const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 50));

      expect(minimizes, 1);
      expect(maximizeToggles, 2);
      expect(closes, 1);
      expect(drags, 1);
      await tester.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
    }
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
      var retryAttempts = 0;
      await pumpApp(
        tester,
        SubDockApp(
          coordinator: coordinator,
          autoStart: false,
          enableWebView: false,
          desktopWarning: ValueNotifier<AppConfigError>(
            const AppConfigError(
              AppConfigErrorCode.exitFailed,
              detail: 'fixture shutdown failure',
            ),
          ),
          onRetryExit: () async => retryAttempts++,
          locale: const Locale('zh'),
        ),
      );
      final originalSize =
          tester.view.physicalSize / tester.view.devicePixelRatio;
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // Following the system brightness, the shell applies the dark theme.
      expect(
        Theme.of(tester.element(find.text('SubDock'))).brightness,
        Brightness.dark,
      );
      expect(find.textContaining('SubDock 未能完成退出'), findsOneWidget);
      final retryExit = find.text('重试退出');
      expect(retryExit, findsOneWidget);
      for (final size in [const Size(600, 480), const Size(599, 480)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        expect(find.textContaining('SubDock 未能完成退出'), findsOneWidget);
        expect(retryExit, findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.binding.setSurfaceSize(originalSize);
      await tester.pumpAndSettle();
      await tester.tap(retryExit);
      await tester.pump();
      expect(retryAttempts, 1);

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
      expect(find.text(l10n.themeSubtitleAutomatic), findsOneWidget);
      expect(find.text(l10n.languageSubtitleAutomatic), findsOneWidget);
      final appearanceHeading = find.text(l10n.settingsQuickAppearanceHeading);
      final appearanceGroup = find.byKey(const ValueKey('settings-appearance'));
      final desktopGroup = find.byKey(
        const ValueKey('settings-desktop-behavior'),
      );
      final autoSaveCard = find.byKey(
        const ValueKey('settings-auto-save-card'),
      );
      expect(autoSaveCard, findsOneWidget);
      expect(
        find.descendant(of: appearanceGroup, matching: autoSaveCard),
        findsNothing,
      );
      final preferencePanel = find.byKey(
        const ValueKey('settings-preferences-panel'),
      );
      expect(preferencePanel, findsOneWidget);
      expect(
        find.descendant(of: preferencePanel, matching: appearanceHeading),
        findsOneWidget,
      );
      final appearanceCardRect = tester.getRect(appearanceGroup);
      final desktopCardRect = tester.getRect(desktopGroup);
      expect(
        desktopCardRect.top,
        greaterThanOrEqualTo(appearanceCardRect.bottom),
      );
      final themeDetails = find.byKey(const ValueKey('settings-theme-row'));
      final themeControl = find.byKey(const ValueKey('settings-theme-mode'));
      final compactDetailsRect = tester.getRect(themeDetails);
      final compactControlRect = tester.getRect(themeControl);
      expect(
        compactControlRect.left,
        greaterThanOrEqualTo(appearanceCardRect.left),
      );
      expect(
        compactControlRect.top,
        greaterThanOrEqualTo(compactDetailsRect.bottom),
      );
      expect(compactControlRect.bottom, greaterThan(compactDetailsRect.top));
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
        matching: find.byType(ShadInput),
      );
      await tester.enterText(hostField, '127.0.0.2');
      await tester.pump();
      final save = find.byKey(const ValueKey('settings-child-save'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      expect(tester.widget<ShadButton>(save).onPressed, isNotNull);
      await tester.tap(save);
      await _pumpRealIo(tester);
      expect((await tester.runAsync(store.load))!.backend.apiHost, '127.0.0.2');

      final back = find.byKey(const ValueKey('settings-back'));
      await tester.ensureVisible(back);
      await tester.pumpAndSettle();
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-appearance')), findsOneWidget);

      await tester.ensureVisible(backendConfig);
      await tester.pumpAndSettle();
      await tester.tap(backendConfig);
      await tester.pumpAndSettle();
      final advancedEnv = find.byKey(
        const ValueKey('settings-card-advanced-env'),
      );
      await tester.ensureVisible(advancedEnv);
      await tester.pumpAndSettle();
      await tester.tap(advancedEnv);
      await tester.pumpAndSettle();
      final rawEnvExpansion = find.byKey(
        const ValueKey('settings-raw-env-expansion'),
      );
      await tester.ensureVisible(rawEnvExpansion);
      await tester.pumpAndSettle();
      await tester.tap(rawEnvExpansion);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-raw-env-editor')),
        findsOneWidget,
      );
      await tester.ensureVisible(back);
      await tester.pumpAndSettle();
      await tester.tap(back);
      await tester.pumpAndSettle();
      await tester.ensureVisible(back);
      await tester.pumpAndSettle();
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-appearance')), findsOneWidget);

      await tester.binding.setSurfaceSize(const Size(599, 480));
      await tester.pumpAndSettle();
      final cardRect = tester.getRect(appearanceGroup);
      final narrowDetailsRect = tester.getRect(themeDetails);
      final narrowControlRect = tester.getRect(themeControl);
      final languageRect = tester.getRect(
        find.byKey(const ValueKey('settings-language')),
      );
      expect(narrowControlRect.left, greaterThanOrEqualTo(cardRect.left));
      expect(languageRect.left, greaterThanOrEqualTo(cardRect.left));
      expect(narrowControlRect.right, lessThanOrEqualTo(cardRect.right));
      expect(languageRect.right, lessThanOrEqualTo(cardRect.right));
      expect(languageRect.top, greaterThan(narrowControlRect.bottom));
      expect(
        narrowControlRect.top,
        greaterThanOrEqualTo(narrowDetailsRect.bottom),
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
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭到托盘'));
    await tester.pump();
    expect(
      tester
          .widget<ShadButton>(
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
        of: find.byKey(const ValueKey('settings-theme-mode')),
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
          .widget<ShadButton>(
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
        final themeSelector = find.byKey(const ValueKey('settings-theme-mode'));

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
              .widget<ShadButton>(
                find.byKey(const ValueKey('settings-save-preferences')),
              )
              .onPressed,
          isNotNull,
        );
        // Settings confirms a save through its own state, not a success toast,
        // so nothing can cover the floating action buttons.
        expect(find.text('Saved'), findsNothing);
        expect(find.byType(ShadToast), findsNothing);

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
          Theme.of(tester.element(find.byKey(const ValueKey('settings-list'))))
              .brightness,
          Brightness.light,
        );
        final savePreferences = find.byKey(
          const ValueKey('settings-save-preferences'),
        );
        expect(savePreferences, findsOneWidget);
        expect(tester.widget<ShadButton>(savePreferences).enabled, isFalse);
        expect(tester.widget<ShadSwitch>(autoSave).value, isFalse);
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
    expect(find.text('Service'), findsWidgets);
    expect(find.text('Logs'), findsWidgets);
    expect(find.text('Sub-Store'), findsWidgets);
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
    final languageSelector = find.byKey(const ValueKey('settings-language'));
    await tester.ensureVisible(languageSelector);
    await tester.pumpAndSettle();
    await tester.tap(languageSelector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Interface & records'), findsOneWidget);
    expect(find.text('Window & startup'), findsOneWidget);
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
      final themeSelector = find.byKey(const ValueKey('settings-theme-mode'));
      await tester.ensureVisible(themeSelector);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: themeSelector, matching: find.text(label)),
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
      const pages = ['overview', 'manage', 'logs', 'updates', 'settings'];

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

          expect(find.byKey(const ValueKey('nav-item-about')), findsNothing);
          expect(find.byKey(const ValueKey('page-about')), findsNothing);
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

class _ReadGate {
  _ReadGate({required this.failAfterPrefix});

  final bool failAfterPrefix;
  final prefixRead = Completer<void>();
  final release = Completer<void>();
  final finished = Completer<void>();
}

class _RecoveryGatedRuntimeLogStore extends RuntimeLogStore {
  _RecoveryGatedRuntimeLogStore(super.directories);

  Completer<void>? recoveryGate;
  final recoveryEntered = Completer<void>();
  final recoveryFinished = Completer<void>();

  @override
  Future<void> initialize() async {
    final gate = recoveryGate;
    recoveryGate = null;
    if (gate == null) return super.initialize();
    recoveryEntered.complete();
    try {
      await gate.future;
      await super.initialize();
    } finally {
      recoveryFinished.complete();
    }
  }
}

class _ReadGatedRuntimeLogStore extends RuntimeLogStore {
  _ReadGatedRuntimeLogStore(super.directories);

  _ReadGate? _nextRead;

  _ReadGate gateNextRead({bool failAfterPrefix = false}) {
    final gate = _ReadGate(failAfterPrefix: failAfterPrefix);
    _nextRead = gate;
    return gate;
  }

  @override
  Stream<RuntimeLog> readRunStream(String id, {bool reverse = false}) {
    final gate = _nextRead;
    _nextRead = null;
    if (gate == null) return super.readRunStream(id, reverse: reverse);
    return _readWithGate(id, reverse: reverse, gate: gate);
  }

  Stream<RuntimeLog> _readWithGate(
    String id, {
    required bool reverse,
    required _ReadGate gate,
  }) async* {
    try {
      var stoppedAfterPrefix = false;
      await for (final log in super.readRunStream(id, reverse: reverse)) {
        yield log;
        if (stoppedAfterPrefix) continue;
        stoppedAfterPrefix = true;
        gate.prefixRead.complete();
        await gate.release.future;
        if (gate.failAfterPrefix) {
          throw StateError('History stream failed after a stored event.');
        }
      }
    } finally {
      gate.finished.complete();
    }
  }
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

Future<void> _pumpUntilLogEntry(WidgetTester tester, String message) async {
  final entry = find.byWidgetPredicate(
    (widget) =>
        widget is SelectableText && widget.data?.contains(message) == true,
  );
  final elapsed = Stopwatch()..start();
  const deadline = Duration(seconds: 3);
  while (entry.evaluate().isEmpty) {
    if (elapsed.elapsed >= deadline) {
      fail('Log page did not publish the requested entry: $message');
    }
    await _pumpRealIo(tester, turns: 1);
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

class _CapturedManageCallbacks {
  const _CapturedManageCallbacks({
    required this.onNavigationRequest,
    required this.onBlobMessage,
    required this.onPageChanged,
    required this.onMainFrameFailure,
  });

  final EmbeddedNavigationHandler onNavigationRequest;
  final void Function(String message) onBlobMessage;
  final EmbeddedPageChangeHandler? onPageChanged;
  final EmbeddedMainFrameFailureHandler? onMainFrameFailure;
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
  Object? stopError;
  String? stateMessage;
  String? httpMetaMessage;
  HttpMetaStatus httpMetaStatus = HttpMetaStatus.disabled;
  int? httpMetaPort;
  String? httpMetaVersion;
  String? httpMetaMihomoVersion;

  @override
  EffectiveRuntimeConfig? appliedConfiguration = EffectiveRuntimeConfig.resolve(
    systemEnvironment: const {},
    backendEnvironment: BackendEnvDocument.parse(''),
    config: const SubDockConfig(),
  );

  void emitLog(RuntimeLog log) => _logs.add(log);

  void emitRunStarted(String runId) =>
      _logRunStarted.add(RuntimeLogRunStarted(runId));

  void emitLogRunUpdate(RuntimeLogRunUpdate update) =>
      _logRunUpdates.add(update);

  void emitState(
    RuntimeStatus status, {
    String? message,
    HttpMetaStatus httpMetaStatus = HttpMetaStatus.disabled,
    String? httpMetaMessage,
    int? httpMetaPort,
    String? httpMetaVersion,
    String? httpMetaMihomoVersion,
  }) {
    stateMessage = message;
    this.httpMetaStatus = httpMetaStatus;
    this.httpMetaPort = httpMetaPort;
    this.httpMetaVersion = httpMetaVersion;
    this.httpMetaMihomoVersion = httpMetaMihomoVersion;
    this.httpMetaMessage = httpMetaMessage;
    _states.add(
      RuntimeState(
        status: status,
        changedAt: DateTime.now(),
        message: message,
        httpMetaStatus: httpMetaStatus,
        httpMetaPort: httpMetaPort,
        httpMetaVersion: httpMetaVersion,
        httpMetaMessage: httpMetaMessage,
        httpMetaMihomoVersion: httpMetaMihomoVersion,
      ),
    );
  }

  @override
  RuntimeState get currentState => RuntimeState(
    status: starts > stops ? RuntimeStatus.running : RuntimeStatus.stopped,
    changedAt: DateTime.now(),
    message: stateMessage,
    httpMetaStatus: httpMetaStatus,
    httpMetaPort: httpMetaPort,
    httpMetaMessage: httpMetaMessage,
    httpMetaVersion: httpMetaVersion,
    httpMetaMihomoVersion: httpMetaMihomoVersion,
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
    if (stopError != null) throw stopError!;
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
  final checkGates = <ComponentKind, Future<void>>{};
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
    final gate = checkGates[kind];
    if (gate != null) await gate;
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
  Future<ComponentRollbackResult> rollback(ComponentKind kind) async {
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
    return const ComponentRollbackResult.completed();
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

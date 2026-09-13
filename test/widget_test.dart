import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/material.dart'
    show
        Brightness,
        DropdownButton,
        FilledButton,
        Locale,
        NavigationBar,
        OutlinedButton,
        SelectableText,
        SegmentedButton,
        Theme,
        ThemeMode,
        ValueNotifier;
import 'package:flutter/scheduler.dart' show AppLifecycleState;
import 'package:flutter/widgets.dart' show Offstage, SizedBox, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/app.dart';
import 'package:subdock/app/app_coordinator.dart';
import 'package:subdock/runtime/backend_runtime.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/settings/backend_env_store.dart';
import 'package:subdock/settings/config_error.dart';
import 'package:subdock/settings/locale_preference_store.dart';
import 'package:subdock/settings/theme_mode_store.dart';

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

    await tester.tap(find.text('运行状态'));
    await tester.pump();

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

    expect(find.byKey(const ValueKey('manage-recovery')), findsOneWidget);
    expect(find.text('Backend 未运行'), findsOneWidget);
    expect(find.text('查看运行状态'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
    final log = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(log.data, contains('2026-09-13T04:30:00.000Z'));
    expect(log.data, contains('[stdout] fixture log line'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'desktop controls minimize, toggle fullscreen, and close to tray',
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
      var minimizes = 0;
      var fullscreenToggles = 0;
      var closesToTray = 0;
      var drags = 0;

      await tester.pumpWidget(
        SubDockApp(
          coordinator: coordinator,
          autoStart: false,
          enableWebView: false,
          locale: const Locale('zh'),
          onMinimize: () async => minimizes++,
          onToggleFullscreen: () async => fullscreenToggles++,
          onCloseToTray: () async => closesToTray++,
          onStartDragging: () async => drags++,
        ),
      );

      await tester.tap(find.byTooltip('最小化'));
      await tester.tap(find.byTooltip('切换全屏'));
      await tester.tap(find.byTooltip('关闭到托盘'));
      await tester.drag(find.text('SubDock'), const Offset(40, 0));

      expect(minimizes, 1);
      expect(fullscreenToggles, 1);
      expect(closesToTray, 1);
      expect(drags, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

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

      for (final label in ['运行状态', '日志', '设置', '管理']) {
        await tester.tap(find.text(label));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: label);
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
    final store = ThemeModeStore(directories!);
    await tester.runAsync(() => store.save(ThemeMode.dark));
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories),
    );

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        themeModeStore: store,
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

  testWidgets('changing the theme in settings persists to the store', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final store = ThemeModeStore(directories!);
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories),
    );

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        themeModeStore: store,
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
    expect(await tester.runAsync(() => store.load()), ThemeMode.light);
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
      final store = ThemeModeStore(directories!);
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
      expect(await tester.runAsync(() => store.file.exists()), isFalse);
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
    final store = ThemeModeStore(directories!);
    await tester.runAsync(() => store.file.writeAsString('{not json'));
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
        themeModeStore: store,
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
    expect(find.text('Runtime Status'), findsWidgets);
    expect(find.text('Logs'), findsWidgets);
    expect(find.text('Manage'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('switching the language applies and persists it', (
    WidgetTester tester,
  ) async {
    late Directory temp;
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
    final directories = await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('subdock_widget_');
      return RuntimeDirectories.fromBaseDirectory(temp);
    });
    final localeStore = LocalePreferenceStore(directories!);
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
        localeStore: localeStore,
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
    expect(await tester.runAsync(() => localeStore.load()), 'en');
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
    final localeStore = LocalePreferenceStore(directories!);
    await tester.runAsync(() => localeStore.save('en'));
    final coordinator = AppCoordinator(
      runtime: _FakeBackendRuntime(),
      environmentStore: BackendEnvStore(directories),
    );

    await tester.pumpWidget(
      SubDockApp(
        coordinator: coordinator,
        autoStart: false,
        enableWebView: false,
        localeStore: localeStore,
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
    final localeStore = LocalePreferenceStore(directories!);
    await tester.runAsync(() => localeStore.file.writeAsString('{not json'));
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
        localeStore: localeStore,
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
    final store = ThemeModeStore(directories!);
    Future<void>? pendingThemeSave;
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
        themeModeStore: store,
        onThemeSaveScheduled: (future) => pendingThemeSave = future,
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

    await _pumpRealIo(tester);
    await pendingThemeSave;
    expect(await tester.runAsync(() => store.load()), ThemeMode.system);
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

  void emitLog(RuntimeLog log) => _logs.add(log);

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
  Future<void> restart() async {}

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

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Loads deferred translations outside fake async, then renders localization's frame.
Future<void> pumpApp(WidgetTester tester, Widget app) async {
  await tester.runAsync(() => ShadLocale.zh.build());
  await tester.pumpWidget(app);
  // loadLibrary schedules a zero-duration timer; a null-duration pump won't run it.
  await tester.pump(Duration.zero);
}

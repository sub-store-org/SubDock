import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/close_request_guard.dart';

void main() {
  test('allows close without an approval handler', () async {
    expect(await CloseRequestGuard().request(), isTrue);
  });

  test('returns the handler decision', () async {
    expect(
      await CloseRequestGuard(approvalHandler: () async => false).request(),
      isFalse,
    );
    expect(
      await CloseRequestGuard(approvalHandler: () async => true).request(),
      isTrue,
    );
  });

  test('shares one pending approval between concurrent requests', () async {
    var approvals = 0;
    final guard = CloseRequestGuard(
      approvalHandler: () async {
        approvals++;
        await Future<void>.delayed(Duration.zero);
        return true;
      },
    );

    final results = await Future.wait([guard.request(), guard.request()]);

    expect(results, [true, true]);
    expect(approvals, 1);
  });

  test(
    'allows replacing and clearing the handler for later requests',
    () async {
      final guard = CloseRequestGuard(approvalHandler: () async => false);

      expect(await guard.request(), isFalse);
      guard.approvalHandler = () async => true;
      expect(await guard.request(), isTrue);
      guard.approvalHandler = null;
      expect(await guard.request(), isTrue);
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/about_info.dart';

void main() {
  test('default loader reports a normalized platform architecture', () async {
    final info = await AboutInfoLoader(
      loadPackageMetadata: () async => (version: '1.2.3', buildNumber: '1'),
    ).load();

    expect(
      info.architecture,
      matches(RegExp(r'^(arm|arm64|ia32|riscv32|riscv64|x64)$')),
    );
  });
}

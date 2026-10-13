import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/app_typography.dart';

void main() {
  test('light and dark share the same metric values', () {
    // AppTypography.== compares every field, so one equality assertion covers
    // the whole value set.
    expect(AppTypography.light, AppTypography.dark);
  });

  test('every text role specifies a font size', () {
    for (final t in const [AppTypography.light, AppTypography.dark]) {
      for (final textStyle in [
        t.titleLarge,
        t.titleMedium,
        t.titleSmall,
        t.bodyLarge,
        t.bodyMedium,
        t.bodySmall,
        t.labelSmall,
      ]) {
        expect(textStyle.fontSize, isNotNull, reason: '$textStyle');
      }
    }
  });

  test('copyWith copies every field and keeps unset fields', () {
    const typography = AppTypography.light;
    final copied = typography.copyWith(
      bodyMedium: const TextStyle(fontSize: 99),
    );
    expect(copied.bodyMedium.fontSize, 99);
    expect(copied.titleLarge, typography.titleLarge);
    expect(copied.titleMedium, typography.titleMedium);
    expect(copied.titleSmall, typography.titleSmall);
    expect(copied.bodyLarge, typography.bodyLarge);
    expect(copied.bodySmall, typography.bodySmall);
    expect(copied.labelSmall, typography.labelSmall);
    expect(copied.spacingXs, typography.spacingXs);
    expect(copied.spacingS, typography.spacingS);
    expect(copied.spacingSm, typography.spacingSm);
    expect(copied.spacingMd, typography.spacingMd);
    expect(copied.spacingLg, typography.spacingLg);
    expect(copied.spacingXl, typography.spacingXl);
    expect(copied.radiusSm, typography.radiusSm);
    expect(copied.radiusMd, typography.radiusMd);
    expect(copied.radiusLg, typography.radiusLg);
  });

  test('lerp interpolates text and spacing between distinct values', () {
    const source = AppTypography.light;
    final target = source.copyWith(
      bodyMedium: source.bodyMedium.copyWith(fontSize: 18),
      spacingMd: 32,
    );
    expect(source.lerp(target, 0), source);
    expect(source.lerp(target, 1), target);
    final middle = source.lerp(target, 0.5);
    expect(middle.bodyMedium.fontSize, 16);
    expect(middle.spacingMd, 24);
  });
}

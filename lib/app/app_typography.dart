import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Bundled text family: Noto Sans CJK SC, shipped in `assets/fonts/` so the
/// shell does not depend on the host's installed fonts.
const uiTextFontFamily = 'UiText';

/// Bundled code/monospace family: DejaVu Sans Mono.
const uiMonoFontFamily = 'UiMono';

/// Fallback for [uiMonoFontFamily]. DejaVu Sans Mono has no CJK glyphs, so
/// without this the Chinese characters in runtime values render as missing
/// glyph boxes; falling back to the text family keeps them readable.
const uiMonoFontFamilyFallback = <String>[uiTextFontFamily];

/// Typography and metric tokens for the SubDock shell.
///
/// Mirrors [AppColors]: one value set per brightness (currently the metrics
/// are brightness-independent, so both instances hold the same values — the
/// two instances stay distinct so dark-mode metric drift remains a local
/// edit). Pages read tokens via `Theme.of(context).extension<AppTypography>()!`
/// instead of hardcoding font sizes, spacing, and radii.
@immutable
class AppTypography extends ThemeExtension<AppTypography> {
  const AppTypography({
    required this.titleLarge,
    required this.titleMedium,
    required this.titleSmall,
    required this.bodyLarge,
    required this.bodyMedium,
    required this.bodySmall,
    required this.labelSmall,
    required this.codeSmall,
    required this.spacingXs,
    required this.spacingS,
    required this.spacingSm,
    required this.spacingMd,
    required this.spacingLg,
    required this.spacingXl,
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
  });

  /// Light value set. Metrics follow the seeded Material 3 text scale with the
  /// neutral-gray ladder; spacing/radius match the 4-8-12-16-24-32
  /// grid the shell already uses in its EdgeInsets constants.
  static const AppTypography light = AppTypography(
    titleLarge: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w500,
      height: 1.27,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      height: 1.5,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      height: 1.43,
    ),
    bodyLarge: TextStyle(fontSize: 16, height: 1.5),
    bodyMedium: TextStyle(fontSize: 14, height: 1.43),
    bodySmall: TextStyle(fontSize: 12, height: 1.33),
    labelSmall: TextStyle(fontSize: 11, height: 1.45),
    codeSmall: TextStyle(
      fontSize: 12,
      height: 1.33,
      fontFamily: uiMonoFontFamily,
      fontFamilyFallback: uiMonoFontFamilyFallback,
    ),
    spacingXs: 4,
    spacingS: 8,
    spacingSm: 12,
    spacingMd: 16,
    spacingLg: 24,
    spacingXl: 32,
    radiusSm: 4,
    radiusMd: 8,
    radiusLg: 12,
  );

  /// Dark value set. Metrics are brightness-independent today; kept as a
  /// separate instance so a future dark-mode metric override is a one-line edit.
  static const AppTypography dark = AppTypography(
    titleLarge: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w500,
      height: 1.27,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      height: 1.5,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      height: 1.43,
    ),
    bodyLarge: TextStyle(fontSize: 16, height: 1.5),
    bodyMedium: TextStyle(fontSize: 14, height: 1.43),
    bodySmall: TextStyle(fontSize: 12, height: 1.33),
    labelSmall: TextStyle(fontSize: 11, height: 1.45),
    codeSmall: TextStyle(
      fontSize: 12,
      height: 1.33,
      fontFamily: uiMonoFontFamily,
      fontFamilyFallback: uiMonoFontFamilyFallback,
    ),
    spacingXs: 4,
    spacingS: 8,
    spacingSm: 12,
    spacingMd: 16,
    spacingLg: 24,
    spacingXl: 32,
    radiusSm: 4,
    radiusMd: 8,
    radiusLg: 12,
  );

  final TextStyle titleLarge;
  final TextStyle titleMedium;
  final TextStyle titleSmall;
  final TextStyle bodyLarge;
  final TextStyle bodyMedium;
  final TextStyle bodySmall;
  final TextStyle labelSmall;

  /// Code/monospace value style: bundled mono family with the text family as
  /// CJK fallback, for runtime addresses and versions.
  final TextStyle codeSmall;
  final double spacingXs;
  final double spacingS;
  final double spacingSm;
  final double spacingMd;
  final double spacingLg;
  final double spacingXl;
  final double radiusSm;
  final double radiusMd;
  final double radiusLg;

  @override
  AppTypography copyWith({
    TextStyle? titleLarge,
    TextStyle? titleMedium,
    TextStyle? titleSmall,
    TextStyle? bodyLarge,
    TextStyle? bodyMedium,
    TextStyle? bodySmall,
    TextStyle? labelSmall,
    TextStyle? codeSmall,
    double? spacingXs,
    double? spacingS,
    double? spacingSm,
    double? spacingMd,
    double? spacingLg,
    double? spacingXl,
    double? radiusSm,
    double? radiusMd,
    double? radiusLg,
  }) {
    return AppTypography(
      titleLarge: titleLarge ?? this.titleLarge,
      titleMedium: titleMedium ?? this.titleMedium,
      titleSmall: titleSmall ?? this.titleSmall,
      bodyLarge: bodyLarge ?? this.bodyLarge,
      bodyMedium: bodyMedium ?? this.bodyMedium,
      bodySmall: bodySmall ?? this.bodySmall,
      labelSmall: labelSmall ?? this.labelSmall,
      codeSmall: codeSmall ?? this.codeSmall,
      spacingXs: spacingXs ?? this.spacingXs,
      spacingS: spacingS ?? this.spacingS,
      spacingSm: spacingSm ?? this.spacingSm,
      spacingMd: spacingMd ?? this.spacingMd,
      spacingLg: spacingLg ?? this.spacingLg,
      spacingXl: spacingXl ?? this.spacingXl,
      radiusSm: radiusSm ?? this.radiusSm,
      radiusMd: radiusMd ?? this.radiusMd,
      radiusLg: radiusLg ?? this.radiusLg,
    );
  }

  @override
  AppTypography lerp(covariant AppTypography? other, double t) {
    if (other == null) return this;
    return AppTypography(
      titleLarge: TextStyle.lerp(titleLarge, other.titleLarge, t)!,
      titleMedium: TextStyle.lerp(titleMedium, other.titleMedium, t)!,
      titleSmall: TextStyle.lerp(titleSmall, other.titleSmall, t)!,
      bodyLarge: TextStyle.lerp(bodyLarge, other.bodyLarge, t)!,
      bodyMedium: TextStyle.lerp(bodyMedium, other.bodyMedium, t)!,
      bodySmall: TextStyle.lerp(bodySmall, other.bodySmall, t)!,
      labelSmall: TextStyle.lerp(labelSmall, other.labelSmall, t)!,
      codeSmall: TextStyle.lerp(codeSmall, other.codeSmall, t)!,
      spacingXs: lerpDouble(spacingXs, other.spacingXs, t)!,
      spacingS: lerpDouble(spacingS, other.spacingS, t)!,
      spacingSm: lerpDouble(spacingSm, other.spacingSm, t)!,
      spacingMd: lerpDouble(spacingMd, other.spacingMd, t)!,
      spacingLg: lerpDouble(spacingLg, other.spacingLg, t)!,
      spacingXl: lerpDouble(spacingXl, other.spacingXl, t)!,
      radiusSm: lerpDouble(radiusSm, other.radiusSm, t)!,
      radiusMd: lerpDouble(radiusMd, other.radiusMd, t)!,
      radiusLg: lerpDouble(radiusLg, other.radiusLg, t)!,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppTypography &&
        titleLarge == other.titleLarge &&
        titleMedium == other.titleMedium &&
        titleSmall == other.titleSmall &&
        bodyLarge == other.bodyLarge &&
        bodyMedium == other.bodyMedium &&
        bodySmall == other.bodySmall &&
        labelSmall == other.labelSmall &&
        codeSmall == other.codeSmall &&
        spacingXs == other.spacingXs &&
        spacingS == other.spacingS &&
        spacingSm == other.spacingSm &&
        spacingMd == other.spacingMd &&
        spacingLg == other.spacingLg &&
        spacingXl == other.spacingXl &&
        radiusSm == other.radiusSm &&
        radiusMd == other.radiusMd &&
        radiusLg == other.radiusLg;
  }

  @override
  int get hashCode => Object.hash(
    titleLarge,
    titleMedium,
    titleSmall,
    bodyLarge,
    bodyMedium,
    bodySmall,
    labelSmall,
    codeSmall,
    spacingXs,
    spacingS,
    spacingSm,
    spacingMd,
    spacingLg,
    spacingXl,
    radiusSm,
    radiusMd,
    radiusLg,
  );
}

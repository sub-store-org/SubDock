import 'package:flutter/material.dart';

/// Semantic color tokens for the SubDock shell.
///
/// One value set per brightness. Pages read tokens via
/// `Theme.of(context).extension<AppColors>()!` instead of reaching into
/// `ColorScheme` directly, so a missing role fails at compile time rather
/// than silently falling back to a wrong surface.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.surfaceLowest,
    required this.surfaceLow,
    required this.surfaceHigh,
    required this.onSurface,
    required this.accent,
    required this.error,
    required this.errorSurface,
    required this.warning,
    required this.success,
    required this.disabled,
    required this.divider,
  });

  /// Neutral light surfaces with a blue accent and accessible error colors.
  static const AppColors light = AppColors(
    surfaceLowest: Color(0xFFF4F4F4),
    surfaceLow: Color(0xFFFAFAFA),
    surfaceHigh: Color(0xFFE5EBF2),
    onSurface: Color(0xFF303133),
    accent: Color(0xFF2367C9),
    error: Color(0xFF9D3329),
    errorSurface: Color(0xFFFFF0ED),
    warning: Color(0xFF783B00),
    success: Color(0xFF17633C),
    disabled: Color(0xFF87919E),
    divider: Color(0xFFD6D9DE),
  );

  /// Dark surfaces with a lighter accent to preserve contrast.
  static const AppColors dark = AppColors(
    surfaceLowest: Color(0xFF121212),
    surfaceLow: Color(0xFF202020),
    surfaceHigh: Color(0xFF272B33),
    onSurface: Color(0xFFEDEDED),
    accent: Color(0xFF8CB8FA),
    error: Color(0xFFFFB5A8),
    errorSurface: Color(0xFF422824),
    warning: Color(0xFFFFCE85),
    success: Color(0xFF8BD3AC),
    disabled: Color(0xFF8998AD),
    divider: Color(0xFF52545B),
  );

  final Color surfaceLowest;
  final Color surfaceLow;
  final Color surfaceHigh;
  final Color onSurface;
  final Color accent;
  final Color error;
  final Color errorSurface;
  final Color warning;
  final Color success;
  final Color disabled;
  final Color divider;

  @override
  AppColors copyWith({
    Color? surfaceLowest,
    Color? surfaceLow,
    Color? surfaceHigh,
    Color? onSurface,
    Color? accent,
    Color? error,
    Color? errorSurface,
    Color? warning,
    Color? success,
    Color? disabled,
    Color? divider,
  }) {
    return AppColors(
      surfaceLowest: surfaceLowest ?? this.surfaceLowest,
      surfaceLow: surfaceLow ?? this.surfaceLow,
      surfaceHigh: surfaceHigh ?? this.surfaceHigh,
      onSurface: onSurface ?? this.onSurface,
      accent: accent ?? this.accent,
      error: error ?? this.error,
      errorSurface: errorSurface ?? this.errorSurface,
      warning: warning ?? this.warning,
      success: success ?? this.success,
      disabled: disabled ?? this.disabled,
      divider: divider ?? this.divider,
    );
  }

  @override
  AppColors lerp(covariant AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      surfaceLowest: Color.lerp(surfaceLowest, other.surfaceLowest, t)!,
      surfaceLow: Color.lerp(surfaceLow, other.surfaceLow, t)!,
      surfaceHigh: Color.lerp(surfaceHigh, other.surfaceHigh, t)!,
      onSurface: Color.lerp(onSurface, other.onSurface, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      error: Color.lerp(error, other.error, t)!,
      errorSurface: Color.lerp(errorSurface, other.errorSurface, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      success: Color.lerp(success, other.success, t)!,
      disabled: Color.lerp(disabled, other.disabled, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppColors &&
        surfaceLowest == other.surfaceLowest &&
        surfaceLow == other.surfaceLow &&
        surfaceHigh == other.surfaceHigh &&
        onSurface == other.onSurface &&
        accent == other.accent &&
        error == other.error &&
        errorSurface == other.errorSurface &&
        warning == other.warning &&
        success == other.success &&
        disabled == other.disabled &&
        divider == other.divider;
  }

  @override
  int get hashCode => Object.hash(
    surfaceLowest,
    surfaceLow,
    surfaceHigh,
    onSurface,
    accent,
    error,
    errorSurface,
    warning,
    success,
    disabled,
    divider,
  );
}

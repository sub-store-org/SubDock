import 'package:flutter/material.dart';

enum CloseBehavior { exitApp, closeToTray }

enum LogSort { newestFirst, newestLast }

class DesktopPreferences {
  const DesktopPreferences({
    required this.themeMode,
    required this.locale,
    required this.closeBehavior,
    required this.recentLogLimit,
    required this.logSort,
    this.launchAtLogin = false,
    this.startHiddenToTray = false,
  });

  static const defaults = DesktopPreferences(
    themeMode: ThemeMode.system,
    locale: null,
    closeBehavior: CloseBehavior.exitApp,
    recentLogLimit: 200,
    logSort: LogSort.newestFirst,
  );

  static const schemaVersion = 1;

  final ThemeMode themeMode;
  final String? locale;
  final CloseBehavior closeBehavior;
  final int recentLogLimit;
  final LogSort logSort;
  final bool launchAtLogin;
  final bool startHiddenToTray;

  factory DesktopPreferences.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('preferences must be an object');
    }
    final schema = json['schemaVersion'];
    final theme = json['themeMode'];
    final locale = json['locale'];
    final close = json['closeBehavior'];
    final limit = json['recentLogLimit'];
    final sort = json['logSort'];
    final launch = json['launchAtLogin'];
    final hidden = json['startHiddenToTray'];
    if (schema != schemaVersion ||
        theme is! String ||
        locale != null && locale is! String ||
        close is! String ||
        limit is! int ||
        sort is! String ||
        launch != null && launch is! bool ||
        hidden != null && hidden is! bool) {
      throw const FormatException('invalid desktop preferences');
    }
    if (locale != null && locale != 'zh' && locale != 'en') {
      throw const FormatException('invalid locale');
    }
    if (limit < 50 || limit > 2000) {
      throw const FormatException('invalid recent log limit');
    }
    return DesktopPreferences(
      themeMode: _themeMode(theme),
      locale: locale as String?,
      closeBehavior: _closeBehavior(close),
      recentLogLimit: limit,
      logSort: _logSort(sort),
      launchAtLogin: launch as bool? ?? false,
      startHiddenToTray: hidden as bool? ?? false,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'themeMode': themeMode.name,
    'locale': locale,
    'closeBehavior': closeBehavior.name,
    'recentLogLimit': recentLogLimit,
    'logSort': logSort.name,
    'launchAtLogin': launchAtLogin,
    'startHiddenToTray': startHiddenToTray,
  };

  DesktopPreferences copyWith({
    ThemeMode? themeMode,
    Object? locale = _unset,
    CloseBehavior? closeBehavior,
    int? recentLogLimit,
    LogSort? logSort,
    bool? launchAtLogin,
    bool? startHiddenToTray,
  }) => DesktopPreferences(
    themeMode: themeMode ?? this.themeMode,
    locale: identical(locale, _unset) ? this.locale : locale as String?,
    closeBehavior: closeBehavior ?? this.closeBehavior,
    recentLogLimit: recentLogLimit ?? this.recentLogLimit,
    logSort: logSort ?? this.logSort,
    launchAtLogin: launchAtLogin ?? this.launchAtLogin,
    startHiddenToTray: startHiddenToTray ?? this.startHiddenToTray,
  );

  @override
  bool operator ==(Object other) =>
      other is DesktopPreferences &&
      other.themeMode == themeMode &&
      other.locale == locale &&
      other.closeBehavior == closeBehavior &&
      other.recentLogLimit == recentLogLimit &&
      other.logSort == logSort &&
      other.launchAtLogin == launchAtLogin &&
      other.startHiddenToTray == startHiddenToTray;

  @override
  int get hashCode => Object.hash(
    themeMode,
    locale,
    closeBehavior,
    recentLogLimit,
    logSort,
    launchAtLogin,
    startHiddenToTray,
  );
}

class _Unset {
  const _Unset();
}

const _unset = _Unset();

ThemeMode _themeMode(String value) {
  try {
    return ThemeMode.values.byName(value);
  } on ArgumentError {
    throw const FormatException('invalid theme mode');
  }
}

CloseBehavior _closeBehavior(String value) {
  try {
    return CloseBehavior.values.byName(value);
  } on ArgumentError {
    throw const FormatException('invalid close behavior');
  }
}

LogSort _logSort(String value) {
  try {
    return LogSort.values.byName(value);
  } on ArgumentError {
    throw const FormatException('invalid log sort');
  }
}

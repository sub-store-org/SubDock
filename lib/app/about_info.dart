import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../runtime/backend_runtime.dart';
import '../update/component_update_service.dart';
import 'maintenance_operation.dart';

const subDockLicenseId = 'GPL-3.0';
const subDockProjectHomepage = 'https://github.com/Delusions6515/SubDock';
const subStoreProjectSource = 'https://github.com/sub-store-org/Sub-Store';
const nodeProjectSource = 'https://github.com/nodejs/node';
const httpMetaProjectSource = 'https://github.com/xream/http-meta';
const mihomoProjectSource = 'https://github.com/MetaCubeX/mihomo';

var _fontLicensesRegistered = false;

void registerBundledFontLicenses() {
  if (_fontLicensesRegistered) return;
  _fontLicensesRegistered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Noto Sans CJK SC 2.004',
    ], await rootBundle.loadString('assets/fonts/LICENSE-Noto-Sans-CJK.txt'));
    yield LicenseEntryWithLineBreaks([
      'DejaVu Sans Mono 2.37',
    ], await rootBundle.loadString('assets/fonts/LICENSE-DejaVu.txt'));
  });
}

class AboutInfo {
  const AboutInfo({
    required this.version,
    required this.buildNumber,
    required this.operatingSystem,
    required this.architecture,
  });

  final String version;
  final String buildNumber;
  final String operatingSystem;
  final String architecture;
}

class AboutDiagnosticSnapshot {
  const AboutDiagnosticSnapshot({
    required this.info,
    required this.runtimeStatus,
    required this.httpMetaStatus,
    required this.maintenancePhase,
    required this.backendStatus,
    required this.frontendStatus,
  });

  final AboutInfo info;
  final RuntimeStatus runtimeStatus;
  final HttpMetaStatus httpMetaStatus;
  final MaintenancePhase? maintenancePhase;
  final ComponentVersionStatus? backendStatus;
  final ComponentVersionStatus? frontendStatus;

  String format() => [
    'SubDock version: ${_safeVersion(info.version)}',
    'Build number: ${_safeBuildNumber(info.buildNumber)}',
    'Operating system: ${_safeOperatingSystem(info.operatingSystem)}',
    'Architecture: ${_safeArchitecture(info.architecture)}',
    'Backend status: ${runtimeStatus.name}',
    'HTTP-META status: ${httpMetaStatus.name}',
    'Maintenance phase: ${maintenancePhase?.name ?? 'none'}',
    'Backend component: ${_componentVersion(backendStatus)}',
    'Frontend component: ${_componentVersion(frontendStatus)}',
  ].join('\n');

  static String _componentVersion(ComponentVersionStatus? status) {
    if (status == null) return 'unavailable';
    final current = _safeVersion(status.current);
    final previous = status.previous;
    return previous == null
        ? 'current $current'
        : 'current $current; previous ${_safeVersion(previous)}';
  }

  static String _safeVersion(String value) =>
      RegExp(r'^v?[0-9]+(?:\.[0-9]+){0,3}(?:[-+][A-Za-z0-9.-]+)?$')
          .hasMatch(value)
      ? value
      : 'unavailable';

  static String _safeBuildNumber(String value) =>
      RegExp(r'^[0-9]{1,20}$').hasMatch(value) ? value : 'unavailable';

  static String _safeOperatingSystem(String value) =>
      const {
        'android',
        'fuchsia',
        'ios',
        'linux',
        'macos',
        'windows',
      }.contains(value)
      ? value
      : 'unavailable';

  static String _safeArchitecture(String value) =>
      const {
        'arm',
        'arm64',
        'ia32',
        'riscv32',
        'riscv64',
        'wasm',
        'x64',
      }.contains(value)
      ? value
      : 'unavailable';
}

class AboutInfoLoader {
  AboutInfoLoader({
    Future<({String version, String buildNumber})> Function()?
    loadPackageMetadata,
    String Function()? operatingSystem,
    String Function()? architecture,
  }) : _loadPackageMetadata =
           loadPackageMetadata ?? _loadPackageMetadataFromPlatform,
       _operatingSystem = operatingSystem ?? _platformOperatingSystem,
       _architecture = architecture ?? _platformArchitecture;

  final Future<({String version, String buildNumber})> Function()
  _loadPackageMetadata;
  final String Function() _operatingSystem;
  final String Function() _architecture;

  Future<AboutInfo> load() async {
    final package = await _loadPackageMetadata();
    return AboutInfo(
      version: package.version,
      buildNumber: package.buildNumber,
      operatingSystem: _operatingSystem(),
      architecture: _architecture(),
    );
  }
}

Future<({String version, String buildNumber})>
_loadPackageMetadataFromPlatform() async {
  final info = await PackageInfo.fromPlatform();
  return (version: info.version, buildNumber: info.buildNumber);
}

String _platformOperatingSystem() => Platform.operatingSystem;

String _platformArchitecture() {
  final architecture = Abi.current().toString().split('_').last;
  return const {
        'arm',
        'arm64',
        'ia32',
        'riscv32',
        'riscv64',
        'x64',
      }.contains(architecture)
      ? architecture
      : 'unavailable';
}

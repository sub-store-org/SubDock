import 'dart:ffi';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

const subDockLicenseId = 'GPL-3.0';
const subDockProjectHomepage = 'https://github.com/Delusions6515/SubDock';

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

String _platformArchitecture() => Abi.current().toString();

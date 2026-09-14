import 'dart:io';

import 'package:archive/archive.dart';

import '../runtime/backend_runtime.dart';
import '../runtime/runtime_directories.dart';
import '../runtime/runtime_permissions.dart';
import 'component_metadata_store.dart';
import 'component_resource_resolver.dart';
import 'component_storage.dart';
import 'github_release_client.dart';

/// Applies a Frontend ZIP release without allowing its archive to escape the
/// private component directory.
class FrontendComponentUpdater {
  FrontendComponentUpdater({
    required this.runtime,
    required this.directories,
    required this.metadataStore,
    required this.resources,
    required this.downloads,
  });

  static const _maximumFileSize = 64 * 1024 * 1024;
  static const _maximumTotalSize = 256 * 1024 * 1024;
  static final _versionPattern = RegExp(r'^[A-Za-z0-9._-]+$');

  final BackendRuntime runtime;
  final RuntimeDirectories directories;
  final ComponentMetadataStore metadataStore;
  final ComponentResourceResolver resources;
  final GithubReleaseDownloader downloads;

  Future<void> update(GithubRelease release) async {
    _requireStopped();
    final version = _safeVersion(release.version);
    final current = await resources.resolve();
    final prior = await metadataStore.load(
      ComponentKind.frontend,
      baseline: current.frontendVersion,
    );
    if (prior.active == version) return;

    final staged = Directory.fromUri(
      directories.staging.uri.resolve('frontend-$version-$pid/'),
    );
    final archive = File.fromUri(staged.uri.resolve('dist.zip'));
    final extracted = Directory.fromUri(staged.uri.resolve('content/'));
    final candidate = Directory.fromUri(
      directories.components.uri.resolve('frontend/$version/'),
    );
    if (await candidate.exists()) {
      throw StateError('Frontend component candidate already exists: $version');
    }

    var pendingSaved = false;
    try {
      await staged.create(recursive: true);
      await restrictDirectoryToCurrentUser(staged);
      await downloads.downloadVerified(release.assetNamed('dist.zip'), archive);
      await _extract(archive, extracted);
      final content =
          await File.fromUri(extracted.uri.resolve('index.html')).exists()
          ? extracted
          : Directory.fromUri(extracted.uri.resolve('dist/'));
      if (!await File.fromUri(content.uri.resolve('index.html')).exists()) {
        throw const FormatException('Frontend archive has no index.html');
      }

      await candidate.parent.create(recursive: true);
      await restrictDirectoryToCurrentUser(candidate.parent);
      await content.rename(candidate.path);
      await restrictDirectoryToCurrentUser(candidate);
      final previous = prior.active ?? prior.baseline;
      await metadataStore.save(
        ComponentKind.frontend,
        ComponentMetadata(
          baseline: prior.baseline,
          active: version,
          previous: previous,
          pending: ComponentPending(version: version),
        ),
      );
      pendingSaved = true;
      await metadataStore.save(
        ComponentKind.frontend,
        ComponentMetadata(
          baseline: prior.baseline,
          active: version,
          previous: previous,
        ),
      );
      await ComponentStorage(directories.components)
          .retain(ComponentKind.frontend, [version, previous]);
    } catch (_) {
      if (pendingSaved) await _rollback(prior);
      rethrow;
    } finally {
      if (await staged.exists()) await staged.delete(recursive: true);
    }
  }

  Future<void> _rollback(ComponentMetadata prior) async {
    await metadataStore.save(ComponentKind.frontend, prior);
  }

  void _requireStopped() {
    if (runtime.currentState.status != RuntimeStatus.stopped) {
      throw StateError(
        'Frontend component mutation requires a stopped Backend',
      );
    }
  }

  Future<void> _extract(File zip, Directory destination) async {
    final entries = ZipDecoder().decodeBytes(
      await zip.readAsBytes(),
      verify: true,
    );
    var totalSize = 0;
    for (final entry in entries) {
      final parts = _safeParts(entry.name);
      if (entry.isSymbolicLink) {
        throw FormatException(
          'Frontend archive contains a symlink: ${entry.name}',
        );
      }
      if (!entry.isFile && !entry.isDirectory) {
        throw FormatException(
          'Frontend archive entry type is invalid: ${entry.name}',
        );
      }
      if (entry.size < 0 || entry.size > _maximumFileSize) {
        throw FormatException(
          'Frontend archive entry is too large: ${entry.name}',
        );
      }
      totalSize += entry.size;
      if (totalSize > _maximumTotalSize) {
        throw const FormatException('Frontend archive is too large');
      }
      final target = File(
        '${destination.path}${Platform.pathSeparator}${parts.join(Platform.pathSeparator)}',
      );
      if (entry.isDirectory) {
        await Directory(target.path).create(recursive: true);
        continue;
      }
      await target.parent.create(recursive: true);
      await target.writeAsBytes(entry.readBytes()!, flush: true);
      await restrictFileToCurrentUser(target);
    }
    await restrictDirectoryToCurrentUser(destination);
  }

  List<String> _safeParts(String name) {
    if (name.isEmpty ||
        name.startsWith('/') ||
        name.startsWith('\\') ||
        name.contains('\u0000')) {
      throw FormatException('Frontend archive path is invalid: $name');
    }
    final parts = name.split(RegExp(r'[/\\]'));
    if (parts.last.isEmpty) parts.removeLast();
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw FormatException('Frontend archive path escapes destination: $name');
    }
    return parts;
  }

  String _safeVersion(String version) {
    if (!_versionPattern.hasMatch(version)) {
      throw ArgumentError.value(version, 'release.version');
    }
    return version;
  }
}

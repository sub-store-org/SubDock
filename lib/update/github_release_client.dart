import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../runtime/runtime_permissions.dart';

class GithubReleaseAsset {
  const GithubReleaseAsset({
    required this.name,
    required this.downloadUri,
    required this.sha256,
  });

  final String name;
  final Uri downloadUri;
  final String sha256;
}

class GithubRelease {
  const GithubRelease({
    required this.version,
    required this.releaseUri,
    required this.assets,
  });

  final String version;
  final Uri releaseUri;
  final List<GithubReleaseAsset> assets;

  GithubReleaseAsset assetNamed(String name) => assets.firstWhere(
    (asset) => asset.name == name,
    orElse: () => throw StateError('Release $version has no asset: $name'),
  );
}

abstract class GithubReleaseSource {
  Future<GithubRelease> latest(String repository);
}

abstract class GithubReleaseDownloader implements GithubReleaseSource {
  Future<void> downloadVerified(GithubReleaseAsset asset, File target);
}

class GithubReleaseClient implements GithubReleaseDownloader {
  GithubReleaseClient({HttpClient? httpClient, Uri? apiBase})
    : _httpClient = httpClient ?? HttpClient(),
      _apiBase = apiBase ?? Uri.parse('https://api.github.com/');

  static final _repositoryPattern = RegExp(
    r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$',
  );
  static final _digestPattern = RegExp(r'^sha256:([a-fA-F0-9]{64})$');

  final HttpClient _httpClient;
  final Uri _apiBase;

  @override
  Future<GithubRelease> latest(String repository) async {
    if (!_repositoryPattern.hasMatch(repository)) {
      throw ArgumentError.value(repository, 'repository');
    }
    final response = await _get(
      _apiBase.replace(path: '/repos/$repository/releases/latest'),
    );
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'GitHub Release query failed: HTTP ${response.statusCode}',
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map ||
        decoded['tag_name'] is! String ||
        decoded['draft'] == true ||
        decoded['prerelease'] == true ||
        decoded['assets'] is! List) {
      throw const FormatException('GitHub Release response is invalid');
    }
    final version = decoded['tag_name'] as String;
    if (version.isEmpty) {
      throw const FormatException('GitHub Release tag is empty');
    }
    return GithubRelease(
      version: version,
      releaseUri: _releaseUri(decoded['html_url']),
      assets: (decoded['assets'] as List)
          .map(_assetFromJson)
          .toList(growable: false),
    );
  }

  Uri _releaseUri(Object? value) {
    if (value is! String) {
      throw const FormatException('GitHub Release URL is invalid');
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('GitHub Release URL is invalid');
    }
    return uri;
  }

  @override
  Future<void> downloadVerified(GithubReleaseAsset asset, File target) async {
    if (await target.exists()) {
      throw StateError('Staging target already exists: ${target.path}');
    }
    await target.parent.create(recursive: true);
    await restrictDirectoryToCurrentUser(target.parent);
    final temporary = File('${target.path}.download');
    try {
      final response = await _get(asset.downloadUri);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          'Release asset download failed: HTTP ${response.statusCode}',
        );
      }
      final sink = temporary.openWrite();
      final digestSink = _DigestSink();
      final hasher = sha256.startChunkedConversion(digestSink);
      try {
        await for (final bytes in response) {
          hasher.add(bytes);
          sink.add(bytes);
        }
        hasher.close();
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (digestSink.digest?.toString().toLowerCase() != asset.sha256) {
        throw StateError('Release asset checksum did not match: ${asset.name}');
      }
      await restrictFileToCurrentUser(temporary);
      await temporary.rename(target.path);
      await restrictFileToCurrentUser(target);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  void close() => _httpClient.close(force: true);

  Future<HttpClientResponse> _get(Uri uri) async {
    final request = await _httpClient.getUrl(uri);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, 'SubDock');
    return request.close();
  }

  GithubReleaseAsset _assetFromJson(Object? value) {
    if (value is! Map ||
        value['name'] is! String ||
        value['browser_download_url'] is! String ||
        value['digest'] is! String) {
      throw const FormatException('GitHub Release asset is invalid');
    }
    final uri = Uri.tryParse(value['browser_download_url'] as String);
    final digest = _digestPattern.firstMatch(value['digest'] as String);
    if (uri == null || !uri.hasScheme || digest == null) {
      throw const FormatException('GitHub Release asset digest is invalid');
    }
    return GithubReleaseAsset(
      name: value['name'] as String,
      downloadUri: uri,
      sha256: digest.group(1)!.toLowerCase(),
    );
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest value) => digest = value;

  @override
  void close() {}
}

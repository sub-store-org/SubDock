import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/update/github_release_client.dart';

void main() {
  late Directory temp;
  late HttpServer server;
  late GithubReleaseClient client;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('subdock_release_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = GithubReleaseClient(
      apiBase: Uri.parse('http://${server.address.address}:${server.port}/'),
    );
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
    await temp.delete(recursive: true);
  });

  test(
    'loads a stable release and verifies a streamed asset download',
    () async {
      unawaited(
        _serve(server, (request) async {
          if (request.uri.path.endsWith('/releases/latest')) {
            request.response
              ..headers.contentType = ContentType.json
              ..write(
                jsonEncode({
                  'tag_name': '2.39.0',
                  'html_url': 'https://github.com/example/release',
                  'draft': false,
                  'prerelease': false,
                  'assets': [
                    {
                      'name': 'dist.zip',
                      'browser_download_url': Uri(
                        scheme: 'http',
                        host: server.address.address,
                        port: server.port,
                        path: '/dist.zip',
                      ).toString(),
                      'digest': 'sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
                    },
                  ],
                }),
              );
          } else if (request.uri.path == '/dist.zip') {
            request.response
              ..write('a')
              ..write('bc');
          } else {
            request.response.statusCode = HttpStatus.notFound;
          }
          await request.response.close();
        }),
      );

      final release = await client.latest('sub-store-org/Sub-Store-Front-End');
      final target = File('${temp.path}/dist.zip');
      await client.downloadVerified(release.assetNamed('dist.zip'), target);

      expect(release.version, '2.39.0');
      expect(await target.readAsBytes(), [97, 98, 99]);
      expect(await File('${target.path}.download').exists(), isFalse);
    },
  );

  test('rejects assets without a GitHub SHA-256 digest', () async {
    unawaited(
      _serve(server, (request) async {
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'tag_name': '2.39.0',
              'html_url': 'https://github.com/example/release',
              'draft': false,
              'prerelease': false,
              'assets': [
                {
                  'name': 'dist.zip',
                  'browser_download_url': Uri(
                    scheme: 'http',
                    host: server.address.address,
                    port: server.port,
                    path: '/dist.zip',
                  ).toString(),
                },
              ],
            }),
          );
        await request.response.close();
      }),
    );

    await expectLater(
      client.latest('sub-store-org/Sub-Store-Front-End'),
      throwsFormatException,
    );
  });

  test('rejects missing, relative, and non-HTTP release pages', () async {
    const pages = [null, '/relative-release', 'ftp://example.invalid/release'];
    var requestIndex = 0;
    unawaited(
      _serve(server, (request) async {
        final page = pages[requestIndex++];
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'tag_name': '2.39.0',
              'html_url': ?page,
              'draft': false,
              'prerelease': false,
              'assets': <Object>[],
            }),
          );
        await request.response.close();
      }),
    );

    for (final page in pages) {
      await expectLater(
        client.latest('sub-store-org/Sub-Store'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'GitHub Release URL is invalid',
          ),
        ),
        reason: 'release page: $page',
      );
    }
  });

  test(
    'removes an unverified download when its checksum does not match',
    () async {
      unawaited(
        _serve(server, (request) async {
          request.response.write('not the expected release asset');
          await request.response.close();
        }),
      );
      final target = File('${temp.path}/candidate.zip');
      final asset = GithubReleaseAsset(
        name: 'candidate.zip',
        downloadUri: Uri(
          scheme: 'http',
          host: server.address.address,
          port: server.port,
          path: '/candidate.zip',
        ),
        sha256:
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );

      await expectLater(
        client.downloadVerified(asset, target),
        throwsStateError,
      );

      expect(await target.exists(), isFalse);
      expect(await File('${target.path}.download').exists(), isFalse);
    },
  );
}

Future<void> _serve(
  HttpServer server,
  Future<void> Function(HttpRequest request) handler,
) async {
  await for (final request in server) {
    unawaited(handler(request));
  }
}

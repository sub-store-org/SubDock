import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/settings/backend_env.dart';
import 'package:subdock/settings/backend_env_store.dart';

void main() {
  test('parses comments, empty values, and the first equals sign', () {
    final document = BackendEnvDocument.parse(
      '# comment\nEMPTY=\nTOKEN=value=with=equals\n',
    );

    expect(document.isValid, isTrue);
    expect(document.values, {'EMPTY': '', 'TOKEN': 'value=with=equals'});
  });

  test('retains a raw draft while a form field changes', () {
    final document = BackendEnvDocument.parse('# keep\nPORT=3001\n');

    final changed = document.withValue('PORT', '3002');

    expect(changed.rawText, '# keep\nPORT=3002\n');
    expect(changed.values['PORT'], '3002');
  });

  test('rejects invalid, duplicate, and reserved environment variables', () {
    final document = BackendEnvDocument.parse(
      'BAD-NAME=value\nDUP=one\nDUP=two\nSUB_STORE_DATA_BASE_PATH=/tmp\n',
    );

    expect(BackendEnvPolicy.validate(document), hasLength(3));
  });

  test('validates port limits and reports external origins', () {
    final document = BackendEnvDocument.parse(
      'SUB_STORE_BACKEND_API_HOST=127.0.0.1\n'
      'SUB_STORE_BACKEND_API_PORT=65536\n'
      'SUB_STORE_CORS_ALLOWED_ORIGINS=http://127.0.0.1:3001,https://example.com\n',
    );

    expect(BackendEnvPolicy.validate(document), hasLength(1));
    expect(BackendEnvPolicy.externalOrigins(document), ['https://example.com']);
  });

  test('accepts wildcard CORS and reports it as external', () {
    final document = BackendEnvDocument.parse(
      'SUB_STORE_BACKEND_API_HOST=127.0.0.1\n'
      'SUB_STORE_BACKEND_API_PORT=3001\n'
      'SUB_STORE_CORS_ALLOWED_ORIGINS=*\n',
    );

    expect(BackendEnvPolicy.validate(document), isEmpty);
    expect(BackendEnvPolicy.externalOrigins(document), ['*']);
  });

  test('wildcard support does not relax invalid CORS URL validation', () {
    final document = BackendEnvDocument.parse(
      'SUB_STORE_CORS_ALLOWED_ORIGINS=not-an-origin\n',
    );

    expect(
      BackendEnvPolicy.validate(document),
      contains(
        isA<BackendEnvIssue>().having(
          (issue) => issue.code,
          'code',
          BackendEnvIssueCode.corsOrigin,
        ),
      ),
    );
  });

  test('saves a valid document atomically with private permissions', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_env_test_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = BackendEnvStore(directories);
    final document = BackendEnvDocument.parse(
      'SUB_STORE_BACKEND_API_PORT=3001\n',
    );

    await store.save(document);
    await store.save(document.withValue('SUB_STORE_BACKEND_API_PORT', '3002'));

    expect((await store.load()).values['SUB_STORE_BACKEND_API_PORT'], '3002');
    if (!Platform.isWindows) {
      expect((await store.file.stat()).mode & 0x1ff, 0x180);
      expect((await directories.config.stat()).mode & 0x1ff, 0x1c0);
    }
  });
}

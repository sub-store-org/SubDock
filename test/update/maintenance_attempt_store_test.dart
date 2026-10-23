import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subdock/app/maintenance_operation.dart';
import 'package:subdock/runtime/runtime_directories.dart';
import 'package:subdock/update/component_metadata_store.dart';
import 'package:subdock/update/maintenance_attempt_store.dart';

void main() {
  test(
    'persists the interrupted component results in the private config area',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'subdock_maintenance_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final directories = await RuntimeDirectories.fromBaseDirectory(temp);
      final store = MaintenanceAttemptStore(directories);
      final attempt = MaintenanceAttempt(
        targets: const [
          MaintenanceTarget(
            kind: ComponentKind.frontend,
            action: MaintenanceAction.update,
            currentVersion: '2.31.3',
            targetVersion: '2.32.0',
          ),
          MaintenanceTarget(
            kind: ComponentKind.backend,
            action: MaintenanceAction.update,
            currentVersion: '2.38.4',
            targetVersion: '2.39.0',
          ),
        ],
        completed: const [ComponentKind.frontend],
        phase: MaintenancePhase.failed,
        restoreAfterChanges: true,
        startOnly: false,
        failedKind: ComponentKind.backend,
        failureStage: MaintenanceFailureStage.updating,
      );

      await store.save(attempt);
      final restored = await store.load();
      final disk = jsonDecode(await store.file.readAsString()) as Map;

      final pathSegments = store.file.uri.pathSegments;
      expect(pathSegments.sublist(pathSegments.length - 2), [
        'config',
        'maintenance-attempt.json',
      ]);
      expect(restored?.targets.map((target) => target.targetVersion), [
        '2.32.0',
        '2.39.0',
      ]);
      expect(restored?.completed, [ComponentKind.frontend]);
      expect(restored?.failedKind, ComponentKind.backend);
      expect(restored?.failureStage, MaintenanceFailureStage.updating);
      expect(disk['version'], 1);
      expect(await store.file.exists(), isTrue);
    },
  );

  test('retains an unreadable attempt for explicit recovery', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_maintenance_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = MaintenanceAttemptStore(directories);
    await store.file.writeAsString('{not json');

    await expectLater(store.load(), throwsFormatException);

    expect(await store.file.readAsString(), '{not json');
    expect(await store.file.exists(), isTrue);
  });

  test('removes an attempt only when its owner clears it', () async {
    final temp = await Directory.systemTemp.createTemp('subdock_maintenance_');
    addTearDown(() => temp.delete(recursive: true));
    final directories = await RuntimeDirectories.fromBaseDirectory(temp);
    final store = MaintenanceAttemptStore(directories);
    await store.save(
      MaintenanceAttempt(
        targets: const [
          MaintenanceTarget(
            kind: ComponentKind.frontend,
            action: MaintenanceAction.update,
            currentVersion: '2.31.3',
            targetVersion: '2.32.0',
          ),
        ],
        completed: const [],
        phase: MaintenancePhase.updating,
        restoreAfterChanges: false,
        startOnly: false,
      ),
    );

    await store.clear();

    expect(await store.file.exists(), isFalse);
    expect(await store.load(), isNull);
  });
}

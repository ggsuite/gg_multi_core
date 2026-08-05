// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_core/src/backend/constants.dart';
import 'package:gg_multi_core/src/backend/ocean_migration.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('migrateMasterFolderToOcean', () {
    late Directory tempRoot;
    late String originalCwd;
    final messages = <String>[];

    String oceanPath() => path.join(tempRoot.path, ggMultiOceanFolder);
    String legacyPath() => path.join(tempRoot.path, ggMultiLegacyMasterFolder);

    bool migrate() => migrateMasterFolderToOcean(
      rootPath: tempRoot.path,
      ggLog: messages.add,
    );

    setUp(() async {
      // Resolve symlinks (e.g. /var -> /private/var on macOS) so paths built
      // from tempRoot compare equal to what Directory.current reports.
      final tmp = await Directory.systemTemp.createTemp('ocean_migration_');
      tempRoot = Directory(await tmp.resolveSymbolicLinks());
      originalCwd = Directory.current.path;
      messages.clear();
    });

    tearDown(() async {
      Directory.current = originalCwd;
      await tempRoot.delete(recursive: true);
    });

    test('renames .master to .ocean and reports it', () {
      Directory(legacyPath()).createSync();
      File(path.join(legacyPath(), '.organizations')).writeAsStringSync('[]');

      final result = migrate();

      expect(result, isTrue);
      expect(Directory(oceanPath()).existsSync(), isTrue);
      expect(Directory(legacyPath()).existsSync(), isFalse);
      expect(
        File(path.join(oceanPath(), '.organizations')).existsSync(),
        isTrue,
        reason: 'the folder content moves along',
      );
      expect(messages.join('\n'), contains('✓ Renamed workspace folder'));
    });

    test('is a no-op when nothing legacy exists', () {
      final result = migrate();

      expect(result, isFalse);
      expect(messages, isEmpty);
    });

    test('is a no-op when .ocean is already in place', () {
      Directory(oceanPath()).createSync();

      final result = migrate();

      expect(result, isTrue);
      expect(messages, isEmpty);
    });

    test('keeps both folders and warns only once when both exist', () {
      Directory(oceanPath()).createSync();
      Directory(legacyPath()).createSync();

      final first = migrate();
      final second = migrate();

      expect(first, isTrue);
      expect(second, isTrue);
      expect(Directory(oceanPath()).existsSync(), isTrue);
      expect(Directory(legacyPath()).existsSync(), isTrue);
      final warnings = messages.where((m) => m.contains('Both »')).toList();
      expect(warnings, hasLength(1));
      expect(warnings.first, contains('merge or delete'));
    });

    test('uses the global log sink when no GgLog is passed', () {
      final global = <String>[];
      oceanMigrationLog = global.add;
      addTearDown(() => oceanMigrationLog = print);
      Directory(legacyPath()).createSync();

      final result = migrateMasterFolderToOcean(rootPath: tempRoot.path);

      expect(result, isTrue);
      expect(global.join('\n'), contains('✓ Renamed workspace folder'));
    });

    test('reports a failed rename only once and keeps the legacy folder', () {
      Directory(legacyPath()).createSync();
      // A FILE named .ocean blocks the rename but is no ocean directory.
      File(oceanPath()).writeAsStringSync('');

      final first = migrate();
      final second = migrate();

      expect(first, isFalse);
      expect(second, isFalse);
      expect(Directory(legacyPath()).existsSync(), isTrue);
      final errors = messages
          .where((m) => m.contains('Failed to rename'))
          .toList();
      expect(errors, hasLength(1));
    });

    test('renames .trash/.master to .trash/.ocean', () {
      Directory(legacyPath()).createSync();
      final legacyTrash = Directory(
        path.join(tempRoot.path, ggMultiTrashFolder, ggMultiLegacyMasterFolder),
      )..createSync(recursive: true);

      final result = migrate();

      expect(result, isTrue);
      expect(legacyTrash.existsSync(), isFalse);
      expect(
        Directory(
          path.join(tempRoot.path, ggMultiTrashFolder, ggMultiOceanFolder),
        ).existsSync(),
        isTrue,
      );
    });

    test('leaves .trash/.master alone when .trash/.ocean exists', () {
      Directory(oceanPath()).createSync();
      final legacyTrash = Directory(
        path.join(tempRoot.path, ggMultiTrashFolder, ggMultiLegacyMasterFolder),
      )..createSync(recursive: true);
      Directory(
        path.join(tempRoot.path, ggMultiTrashFolder, ggMultiOceanFolder),
      ).createSync(recursive: true);

      final result = migrate();

      expect(result, isTrue);
      expect(legacyTrash.existsSync(), isTrue);
    });

    test('tolerates a blocked trash rename silently', () {
      Directory(oceanPath()).createSync();
      Directory(
        path.join(tempRoot.path, ggMultiTrashFolder, ggMultiLegacyMasterFolder),
      ).createSync(recursive: true);
      // A FILE named .trash/.ocean blocks the rename.
      File(
        path.join(tempRoot.path, ggMultiTrashFolder, ggMultiOceanFolder),
      ).writeAsStringSync('');

      final result = migrate();

      expect(result, isTrue);
      expect(messages, isEmpty);
    });

    test('moves the current directory into the renamed folder', () {
      final repo = Directory(path.join(legacyPath(), 'ggsuite', 'gg_multi'))
        ..createSync(recursive: true);
      Directory.current = repo.path;

      final result = migrate();

      expect(result, isTrue);
      expect(
        path.equals(
          Directory.current.path,
          path.join(oceanPath(), 'ggsuite', 'gg_multi'),
        ),
        isTrue,
      );
    });

    test('restores the current directory when the rename fails', () {
      Directory(legacyPath()).createSync();
      File(oceanPath()).writeAsStringSync('');
      Directory.current = legacyPath();

      final result = migrate();

      expect(result, isFalse);
      expect(path.equals(Directory.current.path, legacyPath()), isTrue);
    });
  });
}

// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_core/src/backend/filesystem_utils.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('copyDirectory', () {
    late Directory sourceDir;
    late Directory destinationDir;

    setUp(() async {
      // Create a temporary source directory for every test.
      sourceDir = await Directory.systemTemp.createTemp('copy_test_src_');

      // Create an empty destination directory path and remove the folder so
      // that copyDirectory needs to create it.
      destinationDir = await Directory.systemTemp.createTemp('copy_test_dst_');
      await destinationDir.delete(recursive: true);
    });

    tearDown(() async {
      // Clean up any leftover directories.
      if (sourceDir.existsSync()) {
        await sourceDir.delete(recursive: true);
      }
      if (destinationDir.existsSync()) {
        await destinationDir.delete(recursive: true);
      }
    });

    test('copies files and sub-directories', () async {
      // Arrange – create some files and a nested folder.
      final nestedDir = Directory(path.join(sourceDir.path, 'nested'));
      await nestedDir.create(recursive: true);

      final rootFile = File(path.join(sourceDir.path, 'root.txt'));
      await rootFile.writeAsString('root file');

      final nestedFile = File(path.join(nestedDir.path, 'nested.txt'));
      await nestedFile.writeAsString('nested file');

      final dartaFile = File(path.join(sourceDir.path, 'example.darta'));
      await dartaFile.writeAsString('darta file');

      // Act.
      await copyDirectory(sourceDir, destinationDir);

      // Assert – both files must exist with their original content.
      final copiedRootFile = File(path.join(destinationDir.path, 'root.txt'));
      final copiedNestedFile = File(
        path.join(destinationDir.path, 'nested', 'nested.txt'),
      );
      final copiedDartaFile = File(
        path.join(destinationDir.path, 'example.dart'),
      );

      expect(copiedRootFile.existsSync(), isTrue);
      expect(copiedNestedFile.existsSync(), isTrue);
      expect(copiedDartaFile.existsSync(), isTrue);
      expect(copiedRootFile.readAsStringSync(), 'root file');
      expect(copiedNestedFile.readAsStringSync(), 'nested file');
      expect(copiedDartaFile.readAsStringSync(), 'darta file');
    });

    test('skips .gg on every level by default', () async {
      // Arrange – a repo-like source with publish progress inside .gg.
      final ggDir = Directory(path.join(sourceDir.path, '.gg'));
      await ggDir.create(recursive: true);

      final publishProgress = File(path.join(ggDir.path, 'gg-publish.json'));
      await publishProgress.writeAsString('{"done_steps":["merge"]}');

      final ggJson = File(path.join(ggDir.path, '.gg.json'));
      await ggJson.writeAsString('{}');

      // Act.
      await copyDirectory(sourceDir, destinationDir);

      // Assert – the publish progress must not travel with the copy,
      // its sibling .gg.json must.
      final copiedProgress = File(
        path.join(destinationDir.path, '.gg', 'gg-publish.json'),
      );
      final copiedGgJson = File(
        path.join(destinationDir.path, '.gg', '.gg.json'),
      );
      expect(copiedProgress.existsSync(), isFalse);
      expect(copiedGgJson.existsSync(), isTrue);
    });

    test('copies symlinks as symlinks', () async {
      // A file, a link to it, and a link to a sub directory.
      final target = File(path.join(sourceDir.path, 'target.txt'));
      await target.writeAsString('content');
      final subDir = Directory(path.join(sourceDir.path, 'sub'))..createSync();
      await File(path.join(subDir.path, 'inner.txt')).writeAsString('i');

      await Link(
        path.join(sourceDir.path, 'file_link.txt'),
      ).create('target.txt');
      await Link(path.join(sourceDir.path, 'dir_link')).create('sub');

      // Act.
      await copyDirectory(sourceDir, destinationDir);

      // Assert - both links are links again, with their original target.
      final fileLink = Link(path.join(destinationDir.path, 'file_link.txt'));
      final dirLink = Link(path.join(destinationDir.path, 'dir_link'));
      expect(fileLink.existsSync(), isTrue);
      expect(await fileLink.target(), 'target.txt');
      expect(dirLink.existsSync(), isTrue);
      expect(await dirLink.target(), 'sub');

      // They resolve inside the destination.
      expect(
        File(
          path.join(destinationDir.path, 'file_link.txt'),
        ).readAsStringSync(),
        'content',
      );
    });

    test('copies a broken symlink instead of dropping it', () async {
      await Link(
        path.join(sourceDir.path, 'broken'),
      ).create('does_not_exist.txt');

      await copyDirectory(sourceDir, destinationDir);

      final link = Link(path.join(destinationDir.path, 'broken'));
      expect(link.existsSync(), isTrue);
      expect(await link.target(), 'does_not_exist.txt');
    });

    test('throws ArgumentError when source does not exist', () async {
      final nonExisting = Directory(
        path.join(
          Directory.systemTemp.path,
          'does_not_exist_${DateTime.now().microsecondsSinceEpoch}',
        ),
      );

      expect(
        () => copyDirectory(nonExisting, destinationDir),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

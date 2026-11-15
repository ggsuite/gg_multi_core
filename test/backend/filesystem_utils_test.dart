// @license
// Copyright (c) ggsuite
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

    /// Writes a file at [parts] below the source, creating its folders.
    void write(List<String> parts) {
      File(path.joinAll([sourceDir.path, ...parts]))
        ..createSync(recursive: true)
        ..writeAsStringSync('content');
    }

    /// Whether the copy holds something at [parts].
    bool isCopied(List<String> parts) {
      final target = path.joinAll([destinationDir.path, ...parts]);
      return FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound;
    }

    group('by default', () {
      /// The files of one working copy, all of them in the .gg folder.
      const workingCopyFiles = [
        'publish_config.json',
        'publish_state.json',
        'create_repo_state.json',
        'gg-publish.json',
        '.gg-publish.json',
        '.ticket.json',
        'ticket.json',
        '.gg_localize_refs_publish_to_backup.json',
      ];

      test('skips the files of one working copy in the .gg folder, '
          'not their siblings', () async {
        for (final name in workingCopyFiles) {
          write(['.gg', name]);
        }
        write(['.gg', 'gg.json']);

        await copyDirectory(sourceDir, destinationDir);

        // Publish answers and progress, the progress of creating the
        // repository and the ticket marker stay where they are.
        for (final name in workingCopyFiles) {
          expect(isCopied(['.gg', name]), isFalse, reason: name);
        }
        expect(isCopied(['.gg', 'gg.json']), isTrue);
      });

      test('copies files of the same names everywhere else', () async {
        // A repository tracks such files as fixtures of its tests, or
        // because they mean something else there.
        for (final name in workingCopyFiles) {
          write([name]);
          write(['test', 'sample', name]);
          write(['test', 'sample', '.gg', name]);
        }

        await copyDirectory(sourceDir, destinationDir);

        for (final name in workingCopyFiles) {
          expect(isCopied([name]), isTrue, reason: name);
          expect(isCopied(['test', 'sample', name]), isTrue, reason: name);
          expect(
            isCopied(['test', 'sample', '.gg', name]),
            isTrue,
            reason: name,
          );
        }
      });

      test('skips node_modules on every level', () async {
        write(['node_modules', 'dep', 'index.js']);
        write(['packages', 'a', 'node_modules', 'dep', 'index.js']);
        write(['packages', 'a', 'index.js']);

        await copyDirectory(sourceDir, destinationDir);

        expect(isCopied(['node_modules']), isFalse);
        expect(isCopied(['packages', 'a', 'node_modules']), isFalse);
        expect(isCopied(['packages', 'a', 'index.js']), isTrue);
      });
    });

    group('with skipNames', () {
      test('skips a plain name on every level', () async {
        write(['build', 'out.txt']);
        write(['sub', 'build', 'out.txt']);
        write(['sub', 'kept.txt']);

        await copyDirectory(sourceDir, destinationDir, skipNames: {'build'});

        expect(isCopied(['build']), isFalse);
        expect(isCopied(['sub', 'build']), isFalse);
        expect(isCopied(['sub', 'kept.txt']), isTrue);
      });

      test('skips an entry with a slash at that place only', () async {
        write(['a', 'b', 'skipped.txt']);
        write(['b', 'skipped.txt']);
        write(['a', 'skipped.txt']);
        write(['a', 'b', 'c', 'skipped.txt']);

        await copyDirectory(
          sourceDir,
          destinationDir,
          skipNames: {'a/b/skipped.txt'},
        );

        expect(isCopied(['a', 'b', 'skipped.txt']), isFalse);
        expect(isCopied(['b', 'skipped.txt']), isTrue);
        expect(isCopied(['a', 'skipped.txt']), isTrue);
        expect(isCopied(['a', 'b', 'c', 'skipped.txt']), isTrue);
      });

      test('skips a whole folder named by its place', () async {
        write(['a', 'cache', 'x.txt']);
        write(['cache', 'x.txt']);

        await copyDirectory(sourceDir, destinationDir, skipNames: {'a/cache'});

        expect(isCopied(['a', 'cache']), isFalse);
        expect(isCopied(['a']), isTrue);
        expect(isCopied(['cache', 'x.txt']), isTrue);
      });

      test('takes a leading slash for the source directory itself', () async {
        write(['ticket.json']);
        write(['sub', 'ticket.json']);

        await copyDirectory(
          sourceDir,
          destinationDir,
          skipNames: {'/ticket.json'},
        );

        expect(isCopied(['ticket.json']), isFalse);
        expect(isCopied(['sub', 'ticket.json']), isTrue);
      });

      test('ignores trailing and doubled slashes of an entry', () async {
        write(['a', 'b', 'x.txt']);
        write(['a', 'kept.txt']);

        await copyDirectory(sourceDir, destinationDir, skipNames: {'/a//b/'});

        expect(isCopied(['a', 'b']), isFalse);
        expect(isCopied(['a', 'kept.txt']), isTrue);
      });

      test('copies everything when the set is empty', () async {
        write(['node_modules', 'dep', 'index.js']);
        write(['.gg', 'publish_state.json']);

        await copyDirectory(sourceDir, destinationDir, skipNames: const {});

        expect(isCopied(['node_modules', 'dep', 'index.js']), isTrue);
        expect(isCopied(['.gg', 'publish_state.json']), isTrue);
      });
    });

    test('copies symlinks as symlinks', () async {
      // A file, a link to it, and a link to a sub directory.
      final target = File(path.join(sourceDir.path, 'target.txt'));
      await target.writeAsString('content');
      final subDir = Directory(path.join(sourceDir.path, 'sub'))..createSync();
      await File(path.join(subDir.path, 'inner.txt')).writeAsString('i');

      await Link(path.join(sourceDir.path, 'file_link.txt'))
          .create('target.txt');
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
        File(path.join(destinationDir.path, 'file_link.txt'))
            .readAsStringSync(),
        'content',
      );
    });

    test('copies a broken symlink instead of dropping it', () async {
      await Link(path.join(sourceDir.path, 'broken'))
          .create('does_not_exist.txt');

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

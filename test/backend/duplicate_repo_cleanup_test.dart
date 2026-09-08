// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_core/src/backend/constants.dart';
import 'package:gg_multi_core/src/backend/duplicate_repo_cleanup.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String oceanPath;
  final messages = <String>[];
  void ggLog(String m) => messages.add(m);

  setUp(() {
    root = Directory.systemTemp.createTempSync('duplicate_cleanup_test_');
    oceanPath = path.join(root.path, ggMultiOceanFolder);
    Directory(oceanPath).createSync(recursive: true);
    messages.clear();
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  // Creates `<ocean>/<org>/<folder>` holding a package named [packageName]
  // that declares [declaredRepo] as its repository.
  Directory makeRepo(
    String org,
    String folder, {
    required String packageName,
    String? declaredRepo,
    String? declaredOrg,
  }) {
    final dir = Directory(path.join(oceanPath, org, folder))
      ..createSync(recursive: true);

    final repository = declaredRepo == null
        ? ''
        : 'repository: https://github.com/'
              '${declaredOrg ?? org}/$declaredRepo.git\n';
    File(path.join(dir.path, 'pubspec.yaml'))
        .writeAsStringSync('name: $packageName\nversion: 1.0.0\n$repository');

    return dir;
  }

  Directory trashOf(String org, String folder) => Directory(
    path.join(root.path, ggMultiTrashFolder, ggMultiOceanFolder, org, folder),
  );

  group('DuplicateRepoCleanup', () {
    group('run', () {
      test('keeps the folder the package names as its repository', () async {
        // What a rename leaves behind: the platform redirects `dart_dna`, so
        // the clone succeeded although the package publishes as `dna_dart`.
        final stale = makeRepo(
          'ggsuite',
          'dart_dna',
          packageName: 'dna_dart',
          declaredRepo: 'dna_dart',
        );
        final current = makeRepo(
          'ggsuite',
          'dna_dart',
          packageName: 'dna_dart',
          declaredRepo: 'dna_dart',
        );

        final removed = await const DuplicateRepoCleanup().run(
          workspacePath: oceanPath,
          rootPath: root.path,
          ggLog: ggLog,
        );

        expect(removed, ['ggsuite/dart_dna']);
        expect(stale.existsSync(), isFalse);
        expect(current.existsSync(), isTrue);
        expect(trashOf('ggsuite', 'dart_dna').existsSync(), isTrue);
        expect(
          messages.join('\n'),
          contains('Moving ggsuite/dart_dna to the trash'),
        );
        expect(messages.join('\n'), contains('dna_dart under a former name'));
      });

      test('keeps it no matter which folder comes first', () async {
        // `helix` sorts after `gg_dna`, so the current checkout is the one
        // visited last — order must not decide.
        final stale = makeRepo(
          'ggsuite',
          'gg_dna',
          packageName: 'helix',
          declaredRepo: 'helix',
        );
        final current = makeRepo(
          'ggsuite',
          'helix',
          packageName: 'helix',
          declaredRepo: 'helix',
        );

        await const DuplicateRepoCleanup().run(
          workspacePath: oceanPath,
          rootPath: root.path,
          ggLog: ggLog,
        );

        expect(stale.existsSync(), isFalse);
        expect(current.existsSync(), isTrue);
      });

      test('reports without moving anything on a dry run', () async {
        final stale = makeRepo(
          'ggsuite',
          'dart_dna',
          packageName: 'dna_dart',
          declaredRepo: 'dna_dart',
        );
        makeRepo(
          'ggsuite',
          'dna_dart',
          packageName: 'dna_dart',
          declaredRepo: 'dna_dart',
        );

        final removed = await const DuplicateRepoCleanup().run(
          workspacePath: oceanPath,
          rootPath: root.path,
          ggLog: ggLog,
          dryRun: true,
        );

        expect(removed, ['ggsuite/dart_dna']);
        expect(stale.existsSync(), isTrue);
        expect(trashOf('ggsuite', 'dart_dna').existsSync(), isFalse);
        expect(
          messages.join('\n'),
          contains('Would move ggsuite/dart_dna to the trash'),
        );
      });

      test('drops an organization folder that lost its last repo', () async {
        makeRepo(
          'ggsuite',
          'dna_dart',
          packageName: 'dna_dart',
          declaredRepo: 'dna_dart',
        );
        makeRepo(
          'former',
          'dart_dna',
          packageName: 'dna_dart',
          declaredRepo: 'dna_dart',
          declaredOrg: 'ggsuite',
        );

        await const DuplicateRepoCleanup().run(
          workspacePath: oceanPath,
          rootPath: root.path,
          ggLog: ggLog,
        );

        expect(Directory(path.join(oceanPath, 'former')).existsSync(), isFalse);
      });

      test('keeps the first when no folder matches its repository', () async {
        // Both declare the same repository but neither sits in its folder —
        // one has to go, and which one must at least stay deterministic.
        final first = makeRepo(
          'ggsuite',
          'a_helix',
          packageName: 'helix',
          declaredRepo: 'helix',
        );
        final second = makeRepo(
          'ggsuite',
          'b_helix',
          packageName: 'helix',
          declaredRepo: 'helix',
        );

        final removed = await const DuplicateRepoCleanup().run(
          workspacePath: oceanPath,
          rootPath: root.path,
          ggLog: ggLog,
        );

        expect(removed, ['ggsuite/b_helix']);
        expect(first.existsSync(), isTrue);
        expect(second.existsSync(), isFalse);
      });

      test('never groups two repos that only share a package name', () async {
        // Two organizations may each own a `gg_foo`. Moving one of them away
        // would be a guess — and an expensive one.
        final ours = makeRepo('ggsuite', 'gg_foo', packageName: 'gg_foo');
        final theirs = makeRepo('other', 'gg_foo', packageName: 'gg_foo');

        final removed = await const DuplicateRepoCleanup().run(
          workspacePath: oceanPath,
          rootPath: root.path,
          ggLog: ggLog,
        );

        expect(removed, isEmpty);
        expect(ours.existsSync(), isTrue);
        expect(theirs.existsSync(), isTrue);
      });

      test('leaves a workspace without duplicates alone', () async {
        makeRepo(
          'ggsuite',
          'dna_dart',
          packageName: 'dna_dart',
          declaredRepo: 'dna_dart',
        );
        makeRepo(
          'ggsuite',
          'helix',
          packageName: 'helix',
          declaredRepo: 'helix',
        );

        final removed = await const DuplicateRepoCleanup().run(
          workspacePath: oceanPath,
          rootPath: root.path,
          ggLog: ggLog,
        );

        expect(removed, isEmpty);
        expect(messages, isEmpty);
      });
    });
  });
}

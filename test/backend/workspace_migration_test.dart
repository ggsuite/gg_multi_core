// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_core/src/backend/workspace_migration.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory workspace;
  late List<String> logs;

  void ggLog(String message) {
    logs.add(rmControls(message));
  }

  setUp(() {
    logs = <String>[];
    workspace = Directory.systemTemp.createTempSync('workspace_migration_');
  });

  tearDown(() {
    if (workspace.existsSync()) {
      workspace.deleteSync(recursive: true);
    }
  });

  // Creates a repo folder at [relativePath] with an optional git remote.
  Directory makeRepo(String relativePath, {String? remoteUrl}) {
    final dir = Directory(path.join(workspace.path, relativePath))
      ..createSync(recursive: true);
    File(path.join(dir.path, 'pubspec.yaml')).writeAsStringSync(
      'name: ${path.basename(relativePath)}\nversion: 1.0.0\n',
    );
    if (remoteUrl != null) {
      final gitDir = Directory(path.join(dir.path, '.git'))..createSync();
      File(
        path.join(gitDir.path, 'config'),
      ).writeAsStringSync('[remote "origin"]\n\turl = $remoteUrl\n');
    }
    return dir;
  }

  bool exists(String relativePath) =>
      Directory(path.join(workspace.path, relativePath)).existsSync();

  group('migrateToOrgFolders', () {
    test('moves every repo into the folder of its organization', () {
      makeRepo('gg_foo', remoteUrl: 'https://github.com/ggsuite/gg_foo.git');
      makeRepo('ts_foo', remoteUrl: 'git@github.com:tssuite/ts_foo.git');

      final moved = migrateToOrgFolders(
        workspacePath: workspace.path,
        ggLog: ggLog,
      );

      expect(moved, <String>['gg_foo', 'ts_foo']);
      expect(exists(path.join('ggsuite', 'gg_foo')), isTrue);
      expect(exists(path.join('tssuite', 'ts_foo')), isTrue);
      expect(exists('gg_foo'), isFalse);
      expect(exists('ts_foo'), isFalse);
      expect(
        logs,
        containsAll(<String>[
          'Moving repositories into their organization folders ...',
          '✓ ggsuite/gg_foo',
          '✓ tssuite/ts_foo',
        ]),
      );
    });

    test('keeps the content of a moved repo', () {
      final repo = makeRepo(
        'gg_foo',
        remoteUrl: 'https://github.com/ggsuite/gg_foo.git',
      );
      File(path.join(repo.path, 'README.md')).writeAsStringSync('hello');

      migrateToOrgFolders(workspacePath: workspace.path, ggLog: ggLog);

      expect(
        File(
          path.join(workspace.path, 'ggsuite', 'gg_foo', 'README.md'),
        ).readAsStringSync(),
        'hello',
      );
    });

    test('is a no-op for an already migrated workspace', () {
      makeRepo(
        path.join('ggsuite', 'gg_foo'),
        remoteUrl: 'https://github.com/ggsuite/gg_foo.git',
      );

      final moved = migrateToOrgFolders(
        workspacePath: workspace.path,
        ggLog: ggLog,
      );

      expect(moved, isEmpty);
      expect(logs, isEmpty);
      expect(exists(path.join('ggsuite', 'gg_foo')), isTrue);
    });

    test('moves repos that are still flat next to migrated ones', () {
      makeRepo(
        path.join('ggsuite', 'gg_foo'),
        remoteUrl: 'https://github.com/ggsuite/gg_foo.git',
      );
      makeRepo('gg_bar', remoteUrl: 'https://github.com/ggsuite/gg_bar.git');

      final moved = migrateToOrgFolders(
        workspacePath: workspace.path,
        ggLog: ggLog,
      );

      expect(moved, <String>['gg_bar']);
      expect(exists(path.join('ggsuite', 'gg_bar')), isTrue);
    });

    test('does nothing when the workspace does not exist', () {
      final moved = migrateToOrgFolders(
        workspacePath: path.join(workspace.path, 'nope'),
        ggLog: ggLog,
      );

      expect(moved, isEmpty);
      expect(logs, isEmpty);
    });

    test('ignores hidden folders', () {
      makeRepo(
        path.join('.gg', 'cached'),
        remoteUrl: 'https://github.com/ggsuite/cached.git',
      );

      expect(
        migrateToOrgFolders(workspacePath: workspace.path, ggLog: ggLog),
        isEmpty,
      );
      expect(exists(path.join('.gg', 'cached')), isTrue);
    });

    test('leaves a repo without a git remote in place', () {
      makeRepo('gg_foo');
      makeRepo('gg_bar', remoteUrl: 'https://github.com/ggsuite/gg_bar.git');

      final moved = migrateToOrgFolders(
        workspacePath: workspace.path,
        ggLog: ggLog,
      );

      expect(moved, <String>['gg_bar']);
      expect(exists('gg_foo'), isTrue);
      expect(
        logs,
        contains(
          'Cannot determine the organization of gg_foo. '
          'Leaving it where it is.',
        ),
      );
    });

    test('leaves a repo whose url names no organization in place', () {
      makeRepo('gg_foo', remoteUrl: 'https://host/gg_foo.git');

      expect(
        migrateToOrgFolders(workspacePath: workspace.path, ggLog: ggLog),
        isEmpty,
      );
      expect(exists('gg_foo'), isTrue);
    });

    test('does not overwrite an existing folder', () {
      makeRepo('gg_foo', remoteUrl: 'https://github.com/ggsuite/gg_foo.git');
      makeRepo(
        path.join('ggsuite', 'gg_foo'),
        remoteUrl: 'https://github.com/ggsuite/gg_foo.git',
      );

      final moved = migrateToOrgFolders(
        workspacePath: workspace.path,
        ggLog: ggLog,
      );

      expect(moved, isEmpty);
      expect(exists('gg_foo'), isTrue);
      expect(
        logs,
        contains(
          'Cannot move gg_foo to ggsuite/gg_foo: the folder already exists.',
        ),
      );
    });

    test('reports a repo that cannot be moved', () {
      makeRepo('gg_foo', remoteUrl: 'https://github.com/ggsuite/gg_foo.git');
      // A file where the organization folder has to be created makes the
      // move fail without taking the whole migration down.
      File(path.join(workspace.path, 'ggsuite')).writeAsStringSync('');

      final moved = migrateToOrgFolders(
        workspacePath: workspace.path,
        ggLog: ggLog,
      );

      expect(moved, isEmpty);
      expect(exists('gg_foo'), isTrue);
      expect(
        logs,
        anyElement(startsWith('Failed to move gg_foo to ggsuite/gg_foo:')),
      );
    });
  });
}

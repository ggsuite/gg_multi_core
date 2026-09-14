// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_core/src/backend/constants.dart';
import 'package:gg_multi_core/src/backend/ticket_json.dart';
import 'package:gg_multi_core/src/backend/ocean_migration.dart';
import 'package:gg_multi_core/src/backend/workspace_utils.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('WorkspaceUtils.defaultOceanWorkspacePath', () {
    late Directory tempRoot;
    final messages = <String>[];

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('workspace_utils_test_');
      messages.clear();
      oceanMigrationLog = messages.add;
    });

    tearDown(() async {
      oceanMigrationLog = print;
      await tempRoot.delete(recursive: true);
    });

    test('returns existing ocean in current folder', () async {
      // Arrange ---------------------------------------------------------------
      final oceanDir = Directory(path.join(tempRoot.path, ggMultiOceanFolder));
      await oceanDir.create();

      // Act -------------------------------------------------------------------
      final result = WorkspaceUtils.defaultOceanWorkspacePath(
        workingDir: tempRoot.path,
      );

      // Assert ----------------------------------------------------------------
      expect(result, oceanDir.path);
    });

    test('resolves ocean from a ticket workspace', () async {
      // Arrange ---------------------------------------------------------------
      final ticketsDir = Directory(
        path.join(tempRoot.path, ggMultiLegacyTicketFolder),
      );
      final ticketDir = Directory(path.join(ticketsDir.path, 'ticket_123'));
      await ticketDir.create(recursive: true);

      final expectedMaster = path.join(tempRoot.path, ggMultiOceanFolder);

      // Act -------------------------------------------------------------------
      final result = WorkspaceUtils.defaultOceanWorkspacePath(
        workingDir: ticketDir.path,
      );

      // Assert ----------------------------------------------------------------
      expect(result, expectedMaster);
    });

    test('resolves the ocean from a ticket in the workspace root', () async {
      // Arrange ---------------------------------------------------------------
      final ticketDir = Directory(path.join(tempRoot.path, 'ticket_123'))
        ..createSync(recursive: true);
      File(path.join(ticketDir.path, ticketJsonFileName))
          .writeAsStringSync('{"issue_id": "ticket_123"}');

      // Act -------------------------------------------------------------------
      final result = WorkspaceUtils.defaultOceanWorkspacePath(
        workingDir: ticketDir.path,
      );

      // Assert ----------------------------------------------------------------
      expect(result, path.join(tempRoot.path, ggMultiOceanFolder));
    });

    test('resolves the ocean of the workspace from a closed ticket in the '
        'trash, not the .ocean the trash holds', () async {
      // Arrange ---------------------------------------------------------------
      Directory(path.join(tempRoot.path, ggMultiOceanFolder)).createSync();
      final trash = Directory(path.join(tempRoot.path, ggMultiTrashFolder));
      // The trash keeps the repos removed from the ocean in an ocean of its
      // own.
      Directory(path.join(trash.path, ggMultiOceanFolder))
          .createSync(recursive: true);
      final closed = makeTicket(trash, 'T1');
      final repo = Directory(path.join(closed.path, 'gg_foo'))..createSync();

      // Act -------------------------------------------------------------------
      final result = WorkspaceUtils.defaultOceanWorkspacePath(
        workingDir: repo.path,
      );

      // Assert ----------------------------------------------------------------
      expect(result, path.join(tempRoot.path, ggMultiOceanFolder));
      // The same from the trash itself and from its ocean.
      for (final dir in <String>[
        trash.path,
        path.join(trash.path, ggMultiOceanFolder),
      ]) {
        expect(
          WorkspaceUtils.defaultOceanWorkspacePath(workingDir: dir),
          path.join(tempRoot.path, ggMultiOceanFolder),
          reason: dir,
        );
      }
    });

    test('neither migrates a .master in the trash nor takes a tickets folder '
        'in it for a workspace', () async {
      // Arrange ---------------------------------------------------------------
      Directory(path.join(tempRoot.path, ggMultiOceanFolder)).createSync();
      final trash = Directory(path.join(tempRoot.path, ggMultiTrashFolder));
      final trashedMaster = Directory(
        path.join(trash.path, ggMultiLegacyMasterFolder),
      )..createSync(recursive: true);
      Directory(path.join(trash.path, ggMultiLegacyTicketFolder)).createSync();
      final sub = Directory(path.join(trash.path, 'sub'))..createSync();

      // Act -------------------------------------------------------------------
      final result = WorkspaceUtils.defaultOceanWorkspacePath(
        workingDir: sub.path,
      );

      // Assert ----------------------------------------------------------------
      expect(result, path.join(tempRoot.path, ggMultiOceanFolder));
      expect(trashedMaster.existsSync(), isTrue);
      expect(messages, isEmpty);
    });

    test('resolves the ocean of the workspace root from a legacy ticket that '
        'holds a ticket.json, in any case of the tickets folder', () async {
      for (final legacyFolder in <String>[
        ggMultiLegacyTicketFolder,
        ggMultiLegacyTicketFolder.toUpperCase(),
      ]) {
        // Arrange -------------------------------------------------------------
        final root = Directory(path.join(tempRoot.path, 'root_$legacyFolder'))
          ..createSync();
        final ticket = makeTicket(
          Directory(path.join(root.path, legacyFolder)),
          'L1',
        );
        final repo = Directory(path.join(ticket.path, 'repo'))..createSync();

        // Act + Assert --------------------------------------------------------
        expect(
          WorkspaceUtils.defaultOceanWorkspacePath(workingDir: repo.path),
          path.join(root.path, ggMultiOceanFolder),
          reason: legacyFolder,
        );
      }
    });

    test('resolves the ocean of a workspace root named tickets, in any '
        'case, from its tickets — a legacy one included', () async {
      var i = 0;
      for (final rootName in <String>[ggMultiLegacyTicketFolder, 'Tickets']) {
        // Arrange -------------------------------------------------------------
        final parent = Directory(path.join(tempRoot.path, 'work${i++}'))
          ..createSync();
        final root = Directory(path.join(parent.path, rootName))..createSync();
        final ocean = Directory(path.join(root.path, ggMultiOceanFolder))
          ..createSync();
        final repo = Directory(path.join(makeTicket(root, 'T1').path, 'repo'))
          ..createSync();
        final legacyTickets = Directory(
          path.join(root.path, ggMultiLegacyTicketFolder),
        );
        final legacyRepo = Directory(
          path.join(makeTicket(legacyTickets, 'L1').path, 'repo'),
        )..createSync();
        final other = Directory(path.join(parent.path, 'other'))..createSync();

        // Act + Assert --------------------------------------------------------
        for (final dir in <Directory>[repo, legacyRepo]) {
          expect(
            WorkspaceUtils.defaultOceanWorkspacePath(workingDir: dir.path),
            ocean.path,
            reason: dir.path,
          );
        }
        // The root named tickets does not make the folder around it the root
        // of a legacy workspace.
        expect(
          WorkspaceUtils.defaultOceanWorkspacePath(workingDir: other.path),
          path.join(other.path, ggMultiOceanFolder),
          reason: rootName,
        );
      }
    });

    test('climbs from a relative working dir such as .', () async {
      // Arrange ---------------------------------------------------------------
      Directory(path.join(tempRoot.path, ggMultiOceanFolder)).createSync();
      final trash = Directory(path.join(tempRoot.path, ggMultiTrashFolder));
      Directory(path.join(trash.path, ggMultiOceanFolder))
          .createSync(recursive: true);
      final cwd = Directory.current;

      try {
        Directory.current = trash;
        // The cwd as the process sees it, links resolved.
        final root = path.dirname(Directory.current.path);

        // Act + Assert --------------------------------------------------------
        expect(
          WorkspaceUtils.defaultOceanWorkspacePath(workingDir: '.'),
          path.join(root, ggMultiOceanFolder),
        );
      } finally {
        Directory.current = cwd;
      }
    });

    test('walks past a trash folder spelled in another case', () async {
      // Arrange ---------------------------------------------------------------
      Directory(path.join(tempRoot.path, ggMultiOceanFolder)).createSync();
      final trash = Directory(
        path.join(tempRoot.path, ggMultiTrashFolder.toUpperCase()),
      );
      Directory(path.join(trash.path, ggMultiOceanFolder))
          .createSync(recursive: true);
      final repo = Directory(path.join(makeTicket(trash, 'T1').path, 'repo'))
        ..createSync();

      // Act + Assert ----------------------------------------------------------
      expect(
        WorkspaceUtils.defaultOceanWorkspacePath(workingDir: repo.path),
        path.join(tempRoot.path, ggMultiOceanFolder),
      );
    });

    test('renames a legacy .master and returns the .ocean path', () async {
      // Arrange ---------------------------------------------------------------
      final legacyDir = Directory(
        path.join(tempRoot.path, ggMultiLegacyMasterFolder),
      );
      await legacyDir.create();

      // Act -------------------------------------------------------------------
      final result = WorkspaceUtils.defaultOceanWorkspacePath(
        workingDir: tempRoot.path,
      );

      // Assert ----------------------------------------------------------------
      expect(result, path.join(tempRoot.path, ggMultiOceanFolder));
      expect(Directory(result).existsSync(), isTrue);
      expect(legacyDir.existsSync(), isFalse);
      expect(messages.join('\n'), contains('Renamed workspace folder'));
    });

    test('prefers .ocean when both folders exist', () async {
      // Arrange ---------------------------------------------------------------
      final oceanDir = Directory(path.join(tempRoot.path, ggMultiOceanFolder));
      final legacyDir = Directory(
        path.join(tempRoot.path, ggMultiLegacyMasterFolder),
      );
      await oceanDir.create();
      await legacyDir.create();

      // Act -------------------------------------------------------------------
      final result = WorkspaceUtils.defaultOceanWorkspacePath(
        workingDir: tempRoot.path,
      );

      // Assert ----------------------------------------------------------------
      expect(result, oceanDir.path);
      expect(legacyDir.existsSync(), isTrue, reason: 'never merged or deleted');
    });

    test('returns the legacy path when the rename is not possible', () async {
      // Arrange ---------------------------------------------------------------
      final legacyDir = Directory(
        path.join(tempRoot.path, ggMultiLegacyMasterFolder),
      );
      await legacyDir.create();
      // A FILE named .ocean blocks the rename but is no ocean directory.
      File(path.join(tempRoot.path, ggMultiOceanFolder)).writeAsStringSync('');

      // Act -------------------------------------------------------------------
      final result = WorkspaceUtils.defaultOceanWorkspacePath(
        workingDir: tempRoot.path,
      );

      // Assert ----------------------------------------------------------------
      expect(result, legacyDir.path);
      expect(legacyDir.existsSync(), isTrue);
      expect(messages.join('\n'), contains('Failed to rename'));
    });

    test('falls back to cwd when nothing is found', () async {
      // Arrange ---------------------------------------------------------------
      final randomDir = Directory(
        path.join(tempRoot.path, 'random', 'sub', 'folder'),
      );
      await randomDir.create(recursive: true);
      final expectedMaster = path.join(randomDir.path, ggMultiOceanFolder);

      // Act -------------------------------------------------------------------
      final result = WorkspaceUtils.defaultOceanWorkspacePath(
        workingDir: randomDir.path,
      );

      // Assert ----------------------------------------------------------------
      expect(result, expectedMaster);
    });
  });

  group('WorkspaceUtils.defaultGgMultiWorkspacePath', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp(
        'workspace_utils_testK_',
      );
    });

    tearDown(() async {
      await tempRoot.delete(recursive: true);
    });

    test('returns parent of ocean if existing', () async {
      final wsParent = Directory(path.join(tempRoot.path, 'the_workspace'));
      final oceanDir = Directory(path.join(wsParent.path, ggMultiOceanFolder));
      await oceanDir.create(recursive: true);

      final result = WorkspaceUtils.defaultGgMultiWorkspacePath(
        workingDir: wsParent.path,
      );
      expect(result, equals(wsParent.path));
    });

    test('returns parent of resolved ocean path', () async {
      final ticketDir = Directory(
        path.join(
          tempRoot.path,
          'parent',
          ggMultiLegacyTicketFolder,
          'TICKET-42',
        ),
      )..createSync(recursive: true);
      final wsParent = Directory(path.join(tempRoot.path, 'parent'));

      final result = WorkspaceUtils.defaultGgMultiWorkspacePath(
        workingDir: ticketDir.path,
      );
      expect(result, equals(wsParent.path));
    });

    test('uses the parent of fallback cwd/.ocean '
        'when nothing is found', () async {
      final customCwd = Directory(path.join(tempRoot.path, 'zombie'));
      await customCwd.create(recursive: true);
      final result = WorkspaceUtils.defaultGgMultiWorkspacePath(
        workingDir: customCwd.path,
      );
      expect(result, equals(customCwd.path));
    });

    test('is the workspace root, not the trash, inside the trash', () async {
      final root = Directory(path.join(tempRoot.path, 'root'));
      Directory(path.join(root.path, ggMultiOceanFolder))
          .createSync(recursive: true);
      Directory(path.join(root.path, ggMultiTrashFolder, ggMultiOceanFolder))
          .createSync(recursive: true);
      final repo = Directory(
        path.join(root.path, ggMultiTrashFolder, 'T1', 'repo'),
      )..createSync(recursive: true);

      final result = WorkspaceUtils.defaultGgMultiWorkspacePath(
        workingDir: repo.path,
      );
      expect(result, equals(root.path));
    });
  });

  group('WorkspaceUtils.isInsideExistingWorkspace', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('utils_is_inside_test_');
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('returns false for directory not in or under any ocean', () async {
      // Arrange -----------------------------------------------------------
      final randomDir = Directory(path.join(tempRoot.path, 'random', 'sub'));
      await randomDir.create(recursive: true);

      // Act ---------------------------------------------------------------
      final isInside = WorkspaceUtils.isInsideExistingWorkspace(randomDir.path);

      // Assert ------------------------------------------------------------
      expect(isInside, isFalse);
    });

    test('returns true for direct child of a folder with ocean', () async {
      final root = Directory(path.join(tempRoot.path, 'myroot'));
      final ws = Directory(path.join(root.path, ggMultiOceanFolder));
      await ws.create(recursive: true);

      final child = Directory(path.join(root.path, 'foo'));
      await child.create();

      final isInside = WorkspaceUtils.isInsideExistingWorkspace(child.path);

      expect(isInside, isTrue);
    });

    test('returns true for nested grandchild inside workspace', () async {
      // Arrange --------------------------------------------------------------
      final root = Directory(path.join(tempRoot.path, 'parent'));
      final ws = Directory(path.join(root.path, ggMultiOceanFolder));
      await ws.create(recursive: true);
      final grandChild = Directory(path.join(root.path, 'nested', 'sub'));
      await grandChild.create(recursive: true);

      // Act ------------------------------------------------------------------
      final isInside = WorkspaceUtils.isInsideExistingWorkspace(
        grandChild.path,
      );

      // Assert ---------------------------------------------------------------
      expect(isInside, isTrue);
    });

    test('returns true if searching at the workspace root itself', () async {
      // Arrange ---------------------------------------------------------------
      final root = Directory(path.join(tempRoot.path, 'x'));
      final ws = Directory(path.join(root.path, ggMultiOceanFolder));
      await ws.create(recursive: true);

      // Act ------------------------------------------------------------------
      final isInside = WorkspaceUtils.isInsideExistingWorkspace(root.path);

      // Assert ---------------------------------------------------------------
      // The workspace folder is in root, not above root. So should be false.
      expect(isInside, isTrue);
    });

    test('returns true when rootPath is the actual ocean folder', () async {
      // Arrange ------------------------------------------------------------
      final root = Directory(path.join(tempRoot.path, 'top'));
      final ws = Directory(path.join(root.path, ggMultiOceanFolder));
      await ws.create(recursive: true);

      // Act ---------------------------------------------------------------
      // Call on the ocean folder directly
      final isInside = WorkspaceUtils.isInsideExistingWorkspace(ws.path);

      // Assert ------------------------------------------------------------
      // Should be false: isInside means being a child or deeper
      expect(isInside, isTrue);
    });

    test('detects a legacy .master workspace and does not rename it', () async {
      // Arrange ------------------------------------------------------------
      final root = Directory(path.join(tempRoot.path, 'legacy_root'));
      final legacy = Directory(path.join(root.path, ggMultiLegacyMasterFolder));
      await legacy.create(recursive: true);
      final child = Directory(path.join(root.path, 'foo'));
      await child.create();

      // Act ---------------------------------------------------------------
      final isInside = WorkspaceUtils.isInsideExistingWorkspace(child.path);

      // Assert ------------------------------------------------------------
      // A pure predicate: the legacy folder counts but stays untouched.
      expect(isInside, isTrue);
      expect(legacy.existsSync(), isTrue);
      expect(
        Directory(path.join(root.path, ggMultiOceanFolder)).existsSync(),
        isFalse,
      );
    });

    test('does not count the .ocean of a trash spelled in another '
        'case', () async {
      final trash = Directory(
        path.join(tempRoot.path, 'root', ggMultiTrashFolder.toUpperCase()),
      );
      Directory(path.join(trash.path, ggMultiOceanFolder))
          .createSync(recursive: true);
      final inTrash = Directory(path.join(trash.path, 'T1'))..createSync();

      expect(WorkspaceUtils.isInsideExistingWorkspace(inTrash.path), isFalse);
    });

    test('does not count the .ocean or .master of the trash', () async {
      // Arrange ------------------------------------------------------------
      final root = Directory(path.join(tempRoot.path, 'root'));
      final trash = Directory(path.join(root.path, ggMultiTrashFolder));
      Directory(path.join(trash.path, ggMultiOceanFolder))
          .createSync(recursive: true);
      Directory(path.join(trash.path, ggMultiLegacyMasterFolder)).createSync();
      final inTrash = Directory(path.join(trash.path, 'T1'))..createSync();

      // Act + Assert -------------------------------------------------------
      expect(WorkspaceUtils.isInsideExistingWorkspace(inTrash.path), isFalse);

      // The ocean of the workspace root above still counts.
      Directory(path.join(root.path, ggMultiOceanFolder)).createSync();
      expect(WorkspaceUtils.isInsideExistingWorkspace(inTrash.path), isTrue);
    });
  });

  group('WorkspaceUtils.detectTicketPath', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('detectTicketPath_');
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('returns ticket directory when found', () async {
      // Create /tmp/XYZ/tickets/T1
      final ticketsDir = Directory(
        path.join(tempRoot.path, ggMultiLegacyTicketFolder),
      );
      final ticketDir = Directory(path.join(ticketsDir.path, 'T1'));
      await ticketDir.create(recursive: true);
      // The input should be a subdir inside ticketsDir
      final result = WorkspaceUtils.detectTicketPath(ticketDir.path);
      expect(result, ticketDir.path);
    });

    test('finds a legacy ticket in a tickets folder of any case', () async {
      final ticketDir = Directory(
        path.join(tempRoot.path, ggMultiLegacyTicketFolder.toUpperCase(), 'L1'),
      );
      final sub = Directory(path.join(ticketDir.path, 'sub'))
        ..createSync(recursive: true);
      expect(WorkspaceUtils.detectTicketPath(sub.path), ticketDir.path);
    });

    test('returns null when no ticket folder exists', () async {
      // Just a random non-ticket path
      final randomDir = Directory(path.join(tempRoot.path, 'foo', 'bar'));
      await randomDir.create(recursive: true);
      final result = WorkspaceUtils.detectTicketPath(randomDir.path);
      expect(result, isNull);
    });

    test('recognizes a ticket in the workspace root by its '
        'ticket.json', () async {
      final ticketDir = makeTicket(tempRoot, 'T1');
      // Also from a repo inside it.
      final repoDir = Directory(path.join(ticketDir.path, 'gg_foo'))
        ..createSync(recursive: true);

      expect(WorkspaceUtils.detectTicketPath(ticketDir.path), ticketDir.path);
      expect(WorkspaceUtils.detectTicketPath(repoDir.path), ticketDir.path);
    });

    test('does not mistake the workspace root for a ticket', () async {
      Directory(path.join(tempRoot.path, ggMultiOceanFolder))
          .createSync(recursive: true);
      expect(WorkspaceUtils.detectTicketPath(tempRoot.path), isNull);
    });

    test('takes no plain folder of a workspace root named tickets for a '
        'legacy ticket', () {
      final root = Directory(path.join(tempRoot.path, 'Tickets'))..createSync();
      Directory(path.join(root.path, ggMultiLegacyMasterFolder)).createSync();
      final doc = Directory(path.join(root.path, 'doc', 'sub'))
        ..createSync(recursive: true);
      final ticket = makeTicket(root, 'T1');

      expect(WorkspaceUtils.detectTicketPath(doc.path), isNull);
      expect(WorkspaceUtils.detectTicketPath(ticket.path), ticket.path);
    });

    test('finds a ticket in a workspace root with a hidden name', () {
      final root = Directory(path.join(tempRoot.path, '.ws'))..createSync();
      Directory(path.join(root.path, ggMultiOceanFolder)).createSync();
      final ticket = makeTicket(root, 'T1');
      final repo = Directory(path.join(ticket.path, 'gg_foo'))..createSync();

      expect(WorkspaceUtils.detectTicketPath(ticket.path), ticket.path);
      expect(WorkspaceUtils.detectTicketPath(repo.path), ticket.path);
    });

    group('never finds a ticket in a hidden folder', () {
      setUp(() {
        Directory(path.join(tempRoot.path, ggMultiOceanFolder)).createSync();
      });

      test('even when the hidden folder holds a ticket.json', () {
        for (final name in <String>['.github', '.claude', '.dart_tool']) {
          final hidden = makeTicket(tempRoot, name);
          final sub = Directory(path.join(hidden.path, 'sub'))..createSync();
          expect(WorkspaceUtils.detectTicketPath(hidden.path), isNull);
          expect(WorkspaceUtils.detectTicketPath(sub.path), isNull);
        }
      });

      test('nor a closed ticket in the trash', () {
        final trash = Directory(path.join(tempRoot.path, ggMultiTrashFolder));
        for (final name in <String>['T1', 'T1 (2)']) {
          final closed = makeTicket(trash, name);
          final repo = Directory(path.join(closed.path, 'gg_foo'))
            ..createSync();
          expect(WorkspaceUtils.detectTicketPath(closed.path), isNull);
          expect(WorkspaceUtils.detectTicketPath(repo.path), isNull);
        }
      });

      test('nor a hidden folder inside a legacy tickets folder', () {
        final hidden = Directory(
          path.join(tempRoot.path, ggMultiLegacyTicketFolder, '.foo', 'sub'),
        )..createSync(recursive: true);
        expect(WorkspaceUtils.detectTicketPath(hidden.path), isNull);
      });

      test('but the ticket around the hidden folder of a repo', () {
        final ticket = makeTicket(tempRoot, 'T1');
        // A repo's `.gg` may still hold the marker of an older gg.
        final dotGg = makeTicket(
          Directory(path.join(ticket.path, 'gg_foo')),
          '.gg',
        );
        expect(WorkspaceUtils.detectTicketPath(dotGg.path), ticket.path);
      });
    });
  });

  group('WorkspaceUtils ticket lookup', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('ticket_lookup_');
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    group('isTicketDir', () {
      test('is false for a closed ticket in a trash of any case', () {
        final trash = Directory(
          path.join(tempRoot.path, ggMultiTrashFolder.toUpperCase()),
        );
        expect(WorkspaceUtils.isTicketDir(makeTicket(trash, 'T1')), isFalse);
      });

      test('is true exactly for a folder holding a ticket.json', () {
        expect(WorkspaceUtils.isTicketDir(makeTicket(tempRoot, 'T1')), isTrue);
        final plain = Directory(path.join(tempRoot.path, 'plain'))
          ..createSync();
        expect(WorkspaceUtils.isTicketDir(plain), isFalse);
      });

      test('is false for a hidden folder holding a ticket.json', () {
        for (final name in <String>['.github', '.claude', '.dart_tool']) {
          expect(
            WorkspaceUtils.isTicketDir(makeTicket(tempRoot, name)),
            isFalse,
            reason: name,
          );
        }
      });

      test('is false for a closed ticket in the trash', () {
        final trash = Directory(path.join(tempRoot.path, ggMultiTrashFolder));
        for (final name in <String>['T1', 'T1 (2)']) {
          expect(
            WorkspaceUtils.isTicketDir(makeTicket(trash, name)),
            isFalse,
            reason: name,
          );
        }
      });

      test('is true for a ticket in a workspace root with a hidden name', () {
        final root = Directory(path.join(tempRoot.path, '.ws'))..createSync();
        expect(WorkspaceUtils.isTicketDir(makeTicket(root, 'T1')), isTrue);
      });

      test('judges the folder, not the spelling of its path', () {
        final ticket = makeTicket(tempRoot, 'T1');
        final hidden = makeTicket(tempRoot, '.hidden');
        Directory(path.join(ticket.path, 'sub')).createSync();

        // `..` segments and a trailing separator do not hide a ticket …
        expect(
          WorkspaceUtils.isTicketDir(
            Directory(path.join(hidden.path, '..', 'T1')),
          ),
          isTrue,
        );
        expect(
          WorkspaceUtils.isTicketDir(
            Directory(path.join(ticket.path, 'sub', '..')),
          ),
          isTrue,
        );
        expect(
          WorkspaceUtils.isTicketDir(
            Directory('${ticket.path}${path.separator}'),
          ),
          isTrue,
        );
        // … and do not reveal a hidden one.
        expect(
          WorkspaceUtils.isTicketDir(
            Directory(path.join(ticket.path, '..', '.hidden')),
          ),
          isFalse,
        );
      });
    });

    group('isHiddenName', () {
      test('is true exactly for names starting with a dot', () {
        for (final name in <String>['.github', ggMultiTrashFolder, '.', '..']) {
          expect(WorkspaceUtils.isHiddenName(name), isTrue, reason: name);
        }
        for (final name in <String>['T1', 'a.b', 'doc']) {
          expect(WorkspaceUtils.isHiddenName(name), isFalse, reason: name);
        }
      });
    });

    group('existingTicketDir', () {
      Directory? existing(String name) => WorkspaceUtils.existingTicketDir(
        rootPath: tempRoot.path,
        ticketName: name,
      );

      Directory legacyRoot() =>
          Directory(path.join(tempRoot.path, ggMultiLegacyTicketFolder))
            ..createSync(recursive: true);

      test('returns a ticket in the root', () {
        final ticket = makeTicket(tempRoot, 'T1');
        expect(existing('T1')?.path, ticket.path);
      });

      test('returns a legacy ticket, even without a ticket.json', () {
        final legacy = Directory(path.join(legacyRoot().path, 'OLD'))
          ..createSync();
        expect(existing('OLD')?.path, legacy.path);
      });

      test('prefers the root over the legacy folder', () {
        final ticket = makeTicket(tempRoot, 'T1');
        makeTicket(legacyRoot(), 'T1');
        expect(existing('T1')?.path, ticket.path);
      });

      test('returns the legacy ticket when the root only holds a plain '
          'folder of that name', () {
        Directory(path.join(tempRoot.path, 'T1')).createSync();
        final legacy = makeTicket(legacyRoot(), 'T1');
        expect(existing('T1')?.path, legacy.path);
      });

      test('is null for hidden folders, even with a ticket.json', () {
        Directory(path.join(tempRoot.path, ggMultiOceanFolder)).createSync();
        makeTicket(tempRoot, '.github');
        makeTicket(
          Directory(path.join(tempRoot.path, ggMultiTrashFolder)),
          'T1',
        );
        Directory(path.join(legacyRoot().path, '.foo')).createSync();
        for (final name in <String>[
          '.github',
          '.ocean',
          ggMultiTrashFolder,
          '.foo',
          '.',
          '..',
        ]) {
          expect(existing(name), isNull, reason: name);
        }
      });

      test('is null for a plain folder and for a missing one', () {
        Directory(path.join(tempRoot.path, 'doc')).createSync();
        expect(existing('doc'), isNull);
        expect(existing('ghost'), isNull);
      });

      test('returns a ticket of a workspace root with a hidden name', () {
        final root = Directory(path.join(tempRoot.path, '.ws'))..createSync();
        final ticket = makeTicket(root, 'T1');
        expect(
          WorkspaceUtils.existingTicketDir(
            rootPath: root.path,
            ticketName: 'T1',
          )?.path,
          ticket.path,
        );
      });

      test('is null for a closed ticket, also when called on the trash', () {
        final trash = Directory(path.join(tempRoot.path, ggMultiTrashFolder));
        makeTicket(trash, 'T1');
        makeTicket(trash, 'T1 (2)');
        for (final name in <String>['T1', 'T1 (2)']) {
          expect(
            WorkspaceUtils.existingTicketDir(
              rootPath: trash.path,
              ticketName: name,
            ),
            isNull,
            reason: name,
          );
        }
      });
    });

    group('ticket names', () {
      test('ticketNameError accepts one visible folder name', () {
        for (final name in <String>['T1', 'GGS-145', 'feat_x', 'a.b', ' T1']) {
          expect(WorkspaceUtils.ticketNameError(name), isNull, reason: name);
          expect(WorkspaceUtils.isValidTicketName(name), isTrue, reason: name);
        }
      });

      test('ticketNameError names why a name is no ticket name', () {
        final legacyUpper = ggMultiLegacyTicketFolder.toUpperCase();
        final expected = <String, String>{
          '': 'A ticket name must not be empty.',
          '   ': 'A ticket name must not be empty.',
          'a/b': 'The ticket name "a/b" is a path',
          r'a\b': r'The ticket name "a\b" is a path',
          tempRoot.path: 'The ticket name "${tempRoot.path}" is a path',
          '.github':
              '".github" starts with a dot, but hidden folders are never '
              'tickets.',
          '.': '"." starts with a dot',
          '..': '".." starts with a dot',
          ggMultiLegacyTicketFolder:
              '"$ggMultiLegacyTicketFolder" is reserved for the folder older '
              'gg versions kept their tickets in.',
          legacyUpper: '"$legacyUpper" is reserved',
        };
        for (final MapEntry(key: name, value: reason) in expected.entries) {
          expect(
            WorkspaceUtils.ticketNameError(name),
            contains(reason),
            reason: name,
          );
          expect(WorkspaceUtils.isValidTicketName(name), isFalse, reason: name);
        }
      });

      test('normalizeTicketName drops exactly one trailing separator and one '
          'leading tickets folder that leaves a valid name', () {
        final expected = <String, String>{
          'T1/': 'T1',
          r'T1\': 'T1',
          'T1//': 'T1/',
          'T1': 'T1',
          '/': '/',
          r'\': r'\',
          '': '',
          // What the tab completion makes of a legacy ticket.
          'tickets/L1/': 'L1',
          'tickets/L1': 'L1',
          r'Tickets\L1\': 'L1',
          'TICKETS/L1': 'L1',
          // Everything else stays for ticketNameError to refuse.
          'tickets': 'tickets',
          'tickets/': 'tickets',
          'tickets//': 'tickets/',
          'tickets/L1//': 'tickets/L1/',
          'tickets/a/b': 'tickets/a/b',
          'tickets/.github': 'tickets/.github',
          'tickets/tickets': 'tickets/tickets',
          'tickets/ ': 'tickets/ ',
          'ticketsX/L1': 'ticketsX/L1',
          'my/L1': 'my/L1',
        };
        for (final MapEntry(key: name, value: normalized) in expected.entries) {
          expect(
            WorkspaceUtils.normalizeTicketName(name),
            normalized,
            reason: name,
          );
        }
      });

      test('existingTicketDir resolves no invalid name — not to the legacy '
          'tickets folder, the root or any folder an absolute name '
          'addresses', () {
        final legacyRoot = Directory(
          path.join(tempRoot.path, ggMultiLegacyTicketFolder),
        )..createSync();
        makeTicket(legacyRoot, 'T1');
        final elsewhere = makeTicket(tempRoot, 'elsewhere');

        for (final name in <String>[
          '',
          '  ',
          elsewhere.path,
          tempRoot.path,
          path.join(ggMultiLegacyTicketFolder, 'T1'),
          ggMultiLegacyTicketFolder,
          ggMultiLegacyTicketFolder.toUpperCase(),
        ]) {
          expect(
            WorkspaceUtils.existingTicketDir(
              rootPath: tempRoot.path,
              ticketName: name,
            ),
            isNull,
            reason: name,
          );
        }
      });

      test('existingTicketDir takes only a real directory in the legacy '
          'folder', () {
        final legacyRoot = Directory(
          path.join(tempRoot.path, ggMultiLegacyTicketFolder),
        )..createSync();
        File(path.join(legacyRoot.path, 'F1')).writeAsStringSync('');
        expect(
          WorkspaceUtils.existingTicketDir(
            rootPath: tempRoot.path,
            ticketName: 'F1',
          ),
          isNull,
        );
      });
    });

    group('newTicketDir', () {
      Directory create(String name, {String? relativeTo}) =>
          WorkspaceUtils.newTicketDir(
            rootPath: tempRoot.path,
            ticketName: name,
            relativeTo: relativeTo,
          );

      Matcher throwsWith(String message) => throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains(message),
        ),
      );

      test('creates the folder directly in the workspace root', () {
        final dir = create('T1');
        expect(dir.path, path.join(tempRoot.path, 'T1'));
        expect(dir.existsSync(), isTrue);
        expect(dir.listSync(), isEmpty);
      });

      test('takes an empty folder as it is', () {
        final prepared = Directory(path.join(tempRoot.path, 'T1'))
          ..createSync();
        expect(create('T1').path, prepared.path);
      });

      test('throws for a name that is no ticket name and creates nothing', () {
        expect(() => create(''), throwsWith('must not be empty'));
        expect(() => create(tempRoot.path), throwsWith('is a path'));
        expect(() => create('.github'), throwsWith('starts with a dot'));
        expect(
          () => create(ggMultiLegacyTicketFolder),
          throwsWith('is reserved'),
        );
        expect(tempRoot.listSync(), isEmpty);
      });

      test('throws for an existing ticket, in the root or legacy', () {
        makeTicket(tempRoot, 'T1');
        final legacyRoot = Directory(
          path.join(tempRoot.path, ggMultiLegacyTicketFolder),
        )..createSync();
        Directory(path.join(legacyRoot.path, 'L1')).createSync();

        expect(
          () => create('T1'),
          throwsWith(
            'Ticket T1 already exists at ${path.join(tempRoot.path, 'T1')}.',
          ),
        );
        expect(
          () => create('T1', relativeTo: tempRoot.path),
          throwsWith('Ticket T1 already exists at T1.'),
        );
        expect(
          () => create('L1', relativeTo: tempRoot.path),
          throwsWith(
            'Ticket L1 already exists at '
            '${path.join(ggMultiLegacyTicketFolder, 'L1')}.',
          ),
        );
      });

      test('throws for a place taken by something that is no ticket and '
          'leaves it untouched', () {
        final doc = Directory(path.join(tempRoot.path, 'doc'))..createSync();
        File(path.join(doc.path, 'guide.md')).writeAsStringSync('# Guide');
        final license = File(path.join(tempRoot.path, 'LICENSE'))
          ..writeAsStringSync('license text');
        final target = Directory(path.join(tempRoot.path, 'target'))
          ..createSync();
        Link(path.join(tempRoot.path, 'lnk')).createSync(target.path);
        final legacyRoot = Directory(
          path.join(tempRoot.path, ggMultiLegacyTicketFolder),
        )..createSync();
        File(path.join(legacyRoot.path, 'F1')).writeAsStringSync('');

        final expected = <String, String>{
          'doc': 'doc',
          'LICENSE': 'LICENSE',
          'lnk': 'lnk',
          'F1': path.join(ggMultiLegacyTicketFolder, 'F1'),
        };
        for (final MapEntry(key: name, value: shown) in expected.entries) {
          expect(
            () => create(name, relativeTo: tempRoot.path),
            throwsWith(
              '$shown already exists and is no ticket. '
              'Choose another ticket name.',
            ),
            reason: name,
          );
        }

        expect(
          File(path.join(doc.path, ticketJsonFileName)).existsSync(),
          isFalse,
        );
        expect(license.readAsStringSync(), 'license text');
        expect(target.listSync(), isEmpty);
      });

      test('rethrows when the workspace root does not exist', () {
        expect(
          () => WorkspaceUtils.newTicketDir(
            rootPath: path.join(tempRoot.path, 'nowhere'),
            ticketName: 'T1',
          ),
          throwsA(isA<FileSystemException>()),
        );
      });
    });

    group('rootOfTicket', () {
      test('is the parent of a ticket in the root', () {
        final ticket = makeTicket(tempRoot, 'T1');
        expect(WorkspaceUtils.rootOfTicket(ticket), tempRoot.path);
      });

      test('skips the legacy tickets folder', () {
        final legacyRoot = Directory(
          path.join(tempRoot.path, ggMultiLegacyTicketFolder),
        )..createSync();
        final ticket = makeTicket(legacyRoot, 'T1');
        expect(WorkspaceUtils.rootOfTicket(ticket), tempRoot.path);
      });

      test('skips a legacy tickets folder of any case', () {
        final legacyRoot = Directory(
          path.join(tempRoot.path, ggMultiLegacyTicketFolder.toUpperCase()),
        )..createSync();
        final ticket = makeTicket(legacyRoot, 'T1');
        expect(WorkspaceUtils.rootOfTicket(ticket), tempRoot.path);
      });

      test('is the parent named tickets when that one is a workspace root '
          'itself', () {
        final roots = <String, String>{
          ggMultiLegacyTicketFolder: ggMultiOceanFolder,
          'Tickets': ggMultiLegacyMasterFolder,
        };
        var i = 0;
        for (final MapEntry(key: name, value: ocean) in roots.entries) {
          final root = Directory(path.join(tempRoot.path, 'ws${i++}', name))
            ..createSync(recursive: true);
          Directory(path.join(root.path, ocean)).createSync();
          final ticket = makeTicket(root, 'T1');
          expect(WorkspaceUtils.rootOfTicket(ticket), root.path, reason: name);
        }
      });
    });

    group('ticketDir', () {
      test('resolves a name to a folder in the root', () {
        expect(
          WorkspaceUtils.ticketDir(rootPath: tempRoot.path, ticketName: 'T1'),
          isA<Directory>().having(
            (d) => d.path,
            'path',
            path.join(tempRoot.path, 'T1'),
          ),
        );
      });

      test('resolves a name to an existing legacy ticket', () {
        final legacyRoot = Directory(
          path.join(tempRoot.path, ggMultiLegacyTicketFolder),
        )..createSync();
        final ticket = makeTicket(legacyRoot, 'T1');
        expect(
          WorkspaceUtils.ticketDir(
            rootPath: tempRoot.path,
            ticketName: 'T1',
          ).path,
          ticket.path,
        );
      });

      test('prefers the root over the legacy folder', () {
        final ticket = makeTicket(tempRoot, 'T1');
        final legacyRoot = Directory(
          path.join(tempRoot.path, ggMultiLegacyTicketFolder),
        )..createSync();
        makeTicket(legacyRoot, 'T1');
        expect(
          WorkspaceUtils.ticketDir(
            rootPath: tempRoot.path,
            ticketName: 'T1',
          ).path,
          ticket.path,
        );
      });
    });

    group('ticketDirs', () {
      test('lists the tickets of the root and of the legacy folder', () {
        makeTicket(tempRoot, 'T2');
        makeTicket(tempRoot, 'T1');
        final legacyRoot = Directory(
          path.join(tempRoot.path, ggMultiLegacyTicketFolder),
        )..createSync();
        makeTicket(legacyRoot, 'T0');

        // Neither the ocean nor a plain folder is a ticket.
        Directory(path.join(tempRoot.path, ggMultiOceanFolder)).createSync();
        Directory(path.join(tempRoot.path, 'plain')).createSync();

        expect(
          WorkspaceUtils.ticketDirs(tempRoot.path)
              .map((d) => path.basename(d.path)),
          <String>['T0', 'T1', 'T2'],
        );
      });

      test('never lists hidden folders, even with a ticket.json', () {
        makeTicket(tempRoot, 'T1');
        // What a DNA instantiates in the workspace root …
        for (final name in <String>['.github', '.claude', '.dart_tool']) {
          makeTicket(tempRoot, name);
        }
        // … the trash with a closed ticket, and a hidden legacy folder.
        makeTicket(
          Directory(path.join(tempRoot.path, ggMultiTrashFolder)),
          'X',
        );
        makeTicket(
          Directory(path.join(tempRoot.path, ggMultiLegacyTicketFolder)),
          '.foo',
        );

        expect(
          WorkspaceUtils.ticketDirs(tempRoot.path)
              .map((d) => path.basename(d.path)),
          <String>['T1'],
        );
      });

      test('lists the tickets of a workspace root with a hidden name', () {
        final root = Directory(path.join(tempRoot.path, '.ws'))..createSync();
        makeTicket(root, 'T2');
        makeTicket(root, 'T1');
        makeTicket(root, '.github');
        final trash = Directory(path.join(root.path, ggMultiTrashFolder));
        makeTicket(trash, 'T0');
        makeTicket(trash, 'T0 (2)');

        expect(
          WorkspaceUtils.ticketDirs(root.path)
              .map((d) => path.basename(d.path)),
          <String>['T1', 'T2'],
        );
        // Listing the trash itself does not revive its closed tickets.
        expect(WorkspaceUtils.ticketDirs(trash.path), isEmpty);
      });

      test('is empty for a root that does not exist', () {
        expect(
          WorkspaceUtils.ticketDirs(path.join(tempRoot.path, 'nowhere')),
          isEmpty,
        );
      });
    });
  });
}

/// Creates a ticket folder named [name] below [parent].
Directory makeTicket(Directory parent, String name) {
  final dir = Directory(path.join(parent.path, name))
    ..createSync(recursive: true);
  File(path.join(dir.path, ticketJsonFileName))
      .writeAsStringSync('{"issue_id": "$name"}');
  return dir;
}

// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_core/src/backend/constants.dart';
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
        path.join(tempRoot.path, ggMultiTicketFolder),
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
        path.join(tempRoot.path, 'parent', ggMultiTicketFolder, 'TICKET-42'),
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
      final ticketsDir = Directory(path.join(tempRoot.path, 'tickets'));
      final ticketDir = Directory(path.join(ticketsDir.path, 'T1'));
      await ticketDir.create(recursive: true);
      // The input should be a subdir inside ticketsDir
      final result = WorkspaceUtils.detectTicketPath(ticketDir.path);
      expect(result, ticketDir.path);
    });

    test('returns null when no ticket folder exists', () async {
      // Just a random non-ticket path
      final randomDir = Directory(path.join(tempRoot.path, 'foo', 'bar'));
      await randomDir.create(recursive: true);
      final result = WorkspaceUtils.detectTicketPath(randomDir.path);
      expect(result, isNull);
    });
  });
}

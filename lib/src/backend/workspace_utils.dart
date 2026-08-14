// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:path/path.dart' as path;

import 'package:gg_multi_core/src/backend/constants.dart';
import 'package:gg_multi_core/src/backend/ocean_migration.dart';
import 'package:gg_multi_core/src/backend/ticket_json.dart';

/// Utility functions that deal with the location of workspaces on disk.
class WorkspaceUtils {
  /// Returns the full path of the ocean directory that belongs to
  /// the current working directory.
  ///
  /// The lookup algorithm climbs up the directory tree starting from
  /// [Directory.current] following these rules until a match is found or the
  /// filesystem root is reached:
  ///
  /// 1. If the ocean directory exists in the **examined** folder, that
  ///    directory is returned. A legacy `.master` directory found instead is
  ///    renamed to `.ocean` first ([migrateMasterFolderToOcean]) — this is
  ///    the »auto-rename at the next start«: every command resolves this path
  ///    before it runs. When the rename is not possible, the legacy path is
  ///    returned for this run and the next start retries.
  /// 2. If the **examined** folder holds a ticket — either a `ticket.json` of
  ///    its own or a legacy `tickets` directory — its parent is considered
  ///    the project root and the path `<root>/.ocean` is returned (even if
  ///    the directory does not yet exist).
  /// 3. If neither 1 nor 2 matches, the algorithm continues with the parent
  ///    directory. When the root of the filesystem is reached without a match
  ///    the path `<original working dir>/.ocean` is returned.  NOTE:
  ///    The path component separators of the *original* working directory are
  ///    preserved so that tests that have been written with mixed path
  ///    separators (e.g. forward slashes on Windows) still pass.
  ///
  /// This logic makes it possible to execute the binary from
  /// * inside the ocean,
  /// * inside a ticket workspace, or
  /// * from any random sub-folder in the project tree,
  /// while still resolving the correct location for the ocean.
  static String defaultOceanWorkspacePath({String? workingDir}) {
    // coverage:ignore-start
    workingDir ??= Directory.current.path;
    // coverage:ignore-end

    var dir = Directory(workingDir);

    while (true) {
      final ocean = path.join(dir.path, ggMultiOceanFolder);
      final legacy = path.join(dir.path, ggMultiLegacyMasterFolder);

      // 1. Is there an existing ocean in the current folder? --------
      if (Directory(legacy).existsSync()) {
        migrateMasterFolderToOcean(rootPath: dir.path);
      }
      if (Directory(ocean).existsSync()) {
        return ocean;
      }
      if (Directory(legacy).existsSync()) {
        // The rename was not possible — stay on the legacy folder for this
        // run; the next start retries.
        return legacy;
      }

      // 2. Is the current folder a ticket, or the root of a legacy workspace
      //    that still groups its tickets in a `tickets` folder? --------------
      if (Directory(path.join(dir.path, ggMultiLegacyTicketFolder))
          .existsSync()) {
        return ocean;
      }
      // A ticket sits directly in the root today, so the root is its parent.
      if (isTicketDir(dir)) {
        return path.join(dir.parent.path, ggMultiOceanFolder);
      }

      // 3. Go one level up or break when we are at the filesystem root. -------
      final parent = dir.parent;
      if (parent.path == dir.path) {
        // Reached filesystem root - build the fallback path **without**
        // modifying the original string so that any forward slashes that were
        // present in the test setup remain untouched.  We only append the
        // platform specific separator *between* the original path and the
        // `.ocean` segment.
        return path.join(workingDir, ggMultiOceanFolder);
      }
      dir = parent;
    }
  }

  /// Returns the path of the Gg Multi workspace, which is the parent directory
  /// of the ocean.
  static String defaultGgMultiWorkspacePath({String? workingDir}) {
    return path.dirname(defaultOceanWorkspacePath(workingDir: workingDir));
  }

  /// Returns `true` if [directoryPath] is located *inside* an existing Gg
  /// Multi workspace (i.e. one of its ancestor directories already contains
  /// an ocean folder — or a legacy `.master` folder, which counts too).
  /// This is used by `init` to prevent nested workspaces.
  ///
  /// A pure predicate: it never renames anything, it only answers whether a
  /// workspace already exists here.
  static bool isInsideExistingWorkspace(String directoryPath) {
    var dir = Directory(directoryPath).absolute;

    while (true) {
      if (Directory(path.join(dir.path, ggMultiOceanFolder)).existsSync() ||
          Directory(path.join(dir.path, ggMultiLegacyMasterFolder))
              .existsSync()) {
        return true;
      }

      final parent = dir.parent;
      if (parent.path == dir.path) {
        // We reached the filesystem root without finding a workspace.
        return false;
      }

      dir = parent;
    }
  }

  /// Walks up the directory tree to find a ticket directory and returns its
  /// path when found, otherwise `null`.
  ///
  /// A ticket is recognized by its `ticket.json` — the file `do create
  /// ticket` writes before anything else and that every ticket carries next
  /// to its repositories. The folder name says nothing anymore: tickets sit
  /// directly in the workspace root, so there is no `tickets` parent left to
  /// recognize them by. A legacy `<root>/tickets/<ticket>` is found by the
  /// same file — and, so a ticket of an older gg that lost its `ticket.json`
  /// is still recognized, by that parent folder name as well.
  static String? detectTicketPath(String executionPath) {
    var current = Directory(executionPath);
    while (true) {
      if (isTicketDir(current) ||
          path.basename(current.parent.path) == ggMultiLegacyTicketFolder) {
        return current.path;
      }
      final parent = current.parent;
      if (current.path == parent.path) {
        // Reached filesystem root without finding a ticket.
        return null;
      }
      current = parent;
    }
  }

  /// Returns `true` when [directory] is a ticket folder, i.e. when it holds
  /// a `ticket.json`.
  static bool isTicketDir(Directory directory) =>
      File(path.join(directory.path, ticketJsonFileName)).existsSync();

  /// Returns the workspace root a ticket at [ticketDir] belongs to: its
  /// parent, or its grandparent for a legacy `<root>/tickets/<ticket>`.
  static String rootOfTicket(Directory ticketDir) {
    final parent = ticketDir.parent;
    return path.basename(parent.path) == ggMultiLegacyTicketFolder
        ? parent.parent.path
        : parent.path;
  }

  /// Returns the folder of the ticket named [ticketName] in the workspace
  /// [rootPath] — `<root>/<ticket>`, or the legacy `<root>/tickets/<ticket>`
  /// when only that one exists.
  ///
  /// The returned directory does not have to exist; callers that create a
  /// ticket use it as the place to create it in.
  static Directory ticketDir({
    required String rootPath,
    required String ticketName,
  }) {
    final dir = Directory(path.join(rootPath, ticketName));
    if (dir.existsSync()) {
      return dir;
    }
    final legacy = Directory(
      path.join(rootPath, ggMultiLegacyTicketFolder, ticketName),
    );
    return legacy.existsSync() ? legacy : dir;
  }

  /// Returns every ticket of the workspace [rootPath], sorted by name: the
  /// folders that hold a `ticket.json` directly in the root, plus the ones a
  /// legacy `<root>/tickets` folder still holds.
  static List<Directory> ticketDirs(String rootPath) {
    final result = <Directory>[
      ..._ticketDirsIn(rootPath),
      ..._ticketDirsIn(path.join(rootPath, ggMultiLegacyTicketFolder)),
    ];
    return result
      ..sort((a, b) => path.basename(a.path).compareTo(path.basename(b.path)));
  }

  // ######################
  // Private
  // ######################

  // ...........................................................................
  /// The direct subdirectories of [parentPath] that are tickets. Hidden
  /// folders (`.ocean`, `.trash`, …) are never tickets.
  static List<Directory> _ticketDirsIn(String parentPath) {
    final parent = Directory(parentPath);
    if (!parent.existsSync()) {
      return const <Directory>[];
    }
    return <Directory>[
      for (final dir in parent.listSync().whereType<Directory>())
        if (!path.basename(dir.path).startsWith('.') && isTicketDir(dir)) dir,
    ];
  }
}

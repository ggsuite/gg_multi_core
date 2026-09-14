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
  ///
  ///    The trash folder `.trash` is never a workspace root: it holds a
  ///    `.ocean` of its own for the repositories gg removed from the ocean,
  ///    so on its level neither rule is checked — and no `.master` in it is
  ///    migrated. A command run in `<root>/.trash/…` resolves `<root>/.ocean`.
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

      // The trash is never a workspace root — continue with its parent.
      if (!_isTrash(dir)) {
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

        // 2. Is the current folder a ticket, or the root of a legacy
        //    workspace that still groups its tickets in a `tickets` folder?
        if (Directory(path.join(dir.path, ggMultiLegacyTicketFolder))
            .existsSync()) {
          return ocean;
        }
        // A ticket sits directly in the root today, so the root is its
        // parent.
        if (isTicketDir(dir)) {
          return path.join(dir.parent.path, ggMultiOceanFolder);
        }
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
  ///
  /// Resolved through [defaultOceanWorkspacePath], so the trash folder is
  /// never taken for a workspace here either.
  static String defaultGgMultiWorkspacePath({String? workingDir}) {
    return path.dirname(defaultOceanWorkspacePath(workingDir: workingDir));
  }

  /// Returns `true` if [directoryPath] is located *inside* an existing Gg
  /// Multi workspace (i.e. one of its ancestor directories already contains
  /// an ocean folder — or a legacy `.master` folder, which counts too).
  /// This is used by `init` to prevent nested workspaces.
  ///
  /// The `.ocean` the trash folder `.trash` holds does not count, just as for
  /// [defaultOceanWorkspacePath]: the trash is no workspace.
  ///
  /// A pure predicate: it never renames anything, it only answers whether a
  /// workspace already exists here.
  static bool isInsideExistingWorkspace(String directoryPath) {
    var dir = Directory(directoryPath).absolute;

    while (true) {
      if (!_isTrash(dir) &&
          (Directory(path.join(dir.path, ggMultiOceanFolder)).existsSync() ||
              Directory(path.join(dir.path, ggMultiLegacyMasterFolder))
                  .existsSync())) {
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
  ///
  /// Hidden folders and closed tickets are skipped on the way up
  /// ([isTicketDir]), so a command run inside `<root>/.github` or a closed
  /// ticket in `<root>/.trash` finds no ticket.
  static String? detectTicketPath(String executionPath) {
    var current = Directory(executionPath);
    while (true) {
      if (isTicketDir(current) || _isLegacyTicketDir(current)) {
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
  /// a `ticket.json`, its name does not start with a dot and it does not sit
  /// in the trash.
  ///
  /// This is the one place that decides what a ticket is. Hidden folders are
  /// never tickets, even when they happen to hold a `ticket.json`: the
  /// `.github`, `.claude` or `.dart_tool` a DNA instantiates in the workspace
  /// root, or the `.gg` folder of a repository that still carries a legacy
  /// marker. Neither is a closed ticket in `<root>/.trash/<ticket>` (or
  /// `<ticket> (2)`, …): it keeps its `ticket.json` but is no active ticket
  /// any more. Only the folder's own name and the trash count — a workspace
  /// root with a hidden name (`~/.ws/<ticket>`) holds tickets like any other.
  static bool isTicketDir(Directory directory) =>
      !_isHiddenOrInTrash(directory) &&
      File(path.join(directory.path, ticketJsonFileName)).existsSync();

  /// Returns `true` when [name] is the name of a hidden folder, i.e. when it
  /// starts with a dot. Such a folder is never a ticket, so no ticket may be
  /// created under such a name either.
  static bool isHiddenName(String name) => name.startsWith('.');

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

  /// Returns the existing ticket named [ticketName] in the workspace
  /// [rootPath] — `<root>/<ticket>`, or the legacy `<root>/tickets/<ticket>`
  /// — or `null` when there is no such ticket.
  ///
  /// Unlike [ticketDir] the result is always a real ticket, never just a
  /// folder of that name: `<root>/<ticket>` has to be a ticket
  /// ([isTicketDir]), so neither a hidden folder (`.github`, `.trash`, `.`)
  /// nor a plain one (the `doc` or `dna` folder a DNA instantiates in the
  /// root) is taken for one. A legacy folder counts by its place, as it does
  /// for [detectTicketPath]. Commands that act on a named ticket use this.
  static Directory? existingTicketDir({
    required String rootPath,
    required String ticketName,
  }) {
    if (isHiddenName(ticketName)) {
      return null;
    }
    final dir = Directory(path.join(rootPath, ticketName));
    if (isTicketDir(dir)) {
      return dir;
    }
    final legacy = Directory(
      path.join(rootPath, ggMultiLegacyTicketFolder, ticketName),
    );
    return legacy.existsSync() ? legacy : null;
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
  /// folders (`.ocean`, `.trash`, …) are never tickets — [isTicketDir] knows.
  static List<Directory> _ticketDirsIn(String parentPath) {
    final parent = Directory(parentPath);
    if (!parent.existsSync()) {
      return const <Directory>[];
    }
    return <Directory>[
      for (final dir in parent.listSync().whereType<Directory>())
        if (isTicketDir(dir)) dir,
    ];
  }

  // ...........................................................................
  /// Whether [directory] is a visible folder inside a legacy `tickets`
  /// folder, which makes it a ticket of an older gg even without a
  /// `ticket.json`.
  static bool _isLegacyTicketDir(Directory directory) =>
      !isHiddenName(_name(directory.path)) &&
      path.basename(directory.parent.path) == ggMultiLegacyTicketFolder;

  // ...........................................................................
  /// Whether [directory] is hidden or sits directly in the trash folder.
  static bool _isHiddenOrInTrash(Directory directory) {
    final absolute = path.normalize(path.absolute(directory.path));
    return isHiddenName(path.basename(absolute)) ||
        path.basename(path.dirname(absolute)) == ggMultiTrashFolder;
  }

  // ...........................................................................
  /// Whether [directory] is the trash folder `.trash`.
  static bool _isTrash(Directory directory) =>
      _name(directory.path) == ggMultiTrashFolder;

  // ...........................................................................
  /// The name of the folder at [folderPath], independent of `.` / `..`
  /// segments and a trailing separator.
  static String _name(String folderPath) =>
      path.basename(path.normalize(path.absolute(folderPath)));
}

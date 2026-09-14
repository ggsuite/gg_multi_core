// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
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
  /// 2. If the **examined** folder holds a legacy `tickets` folder, it is the
  ///    root of an older workspace and `<folder>/.ocean` is returned. If the
  ///    examined folder is a ticket itself ([isTicketDir]), the `.ocean` of
  ///    the workspace root it belongs to ([rootOfTicket]) is returned — the
  ///    parent of `<root>/<ticket>`, the grandparent of a legacy
  ///    `<root>/tickets/<ticket>`. Both paths are returned even if the
  ///    directory does not yet exist. A folder named `tickets` that holds a
  ///    `.ocean` or `.master` is a workspace root itself, never a legacy
  ///    `tickets` folder.
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
  /// The walk itself runs over the absolute, normalized [workingDir], so a
  /// relative one such as `.` climbs the real folders above it as well.
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

    var dir = Directory(_absolute(workingDir));

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

        // 2. Is the current folder the root of a legacy workspace that still
        //    groups its tickets in a `tickets` folder, or a ticket? ---------
        final legacyTickets = path.join(dir.path, ggMultiLegacyTicketFolder);
        if (Directory(legacyTickets).existsSync() &&
            _isLegacyTicketFolder(legacyTickets)) {
          return ocean;
        }
        if (isTicketDir(dir)) {
          return path.join(rootOfTicket(dir), ggMultiOceanFolder);
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
    var dir = Directory(_absolute(directoryPath));

    while (true) {
      if (!_isTrash(dir) && _holdsOcean(dir.path)) {
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
  /// `<ticket> (2)`, …, and in a `.Trash` spelled differently): it keeps its
  /// `ticket.json` but is no active ticket any more. Only the folder's own
  /// name and the trash count — a workspace root with a hidden name
  /// (`~/.ws/<ticket>`) holds tickets like any other.
  static bool isTicketDir(Directory directory) =>
      !_isHiddenOrInTrash(directory) &&
      File(path.join(directory.path, ticketJsonFileName)).existsSync();

  /// Returns `true` when [name] is the name of a hidden folder, i.e. when it
  /// starts with a dot. Such a folder is never a ticket, so no ticket may be
  /// created under such a name either.
  static bool isHiddenName(String name) => name.startsWith('.');

  /// Returns [name] the way a user means it when typing a ticket name.
  ///
  /// One trailing separator is removed, the way a shell's tab completion
  /// appends it to a folder (`T1/`). One leading legacy `tickets/` (or
  /// `tickets\`, in any case) is removed as well when a valid ticket name
  /// ([isValidTicketName]) is left — what the tab completion in the root of
  /// an older workspace makes of a legacy ticket (`tickets/L1/` → `L1`).
  /// Nothing else is removed, so a name that is a path (`T1//`,
  /// `tickets/a/b`) or `tickets` itself stays one for [ticketNameError].
  static String normalizeTicketName(String name) {
    final trimmed =
        name.length > 1 && (name.endsWith('/') || name.endsWith(r'\'))
        ? name.substring(0, name.length - 1)
        : name;

    const prefix = ggMultiLegacyTicketFolder.length;
    if (trimmed.length > prefix + 1 &&
        _isLegacyTicketFolderName(trimmed.substring(0, prefix)) &&
        (trimmed[prefix] == '/' || trimmed[prefix] == r'\')) {
      final rest = trimmed.substring(prefix + 1);
      if (isValidTicketName(rest)) {
        return rest;
      }
    }
    return trimmed;
  }

  /// Returns why [name] cannot name a ticket, or `null` when it can.
  ///
  /// A ticket is named by exactly one visible folder name of the workspace
  /// root: not empty, no path (no `/` or `\`, not absolute), not hidden and
  /// not `tickets` — in whatever case —, the folder older gg versions kept
  /// their tickets in. The check comes before a name is joined to a path:
  /// `path.join(root, name)` drops `root` in front of an absolute name, and
  /// an empty name addresses the folder itself.
  ///
  /// Apply [normalizeTicketName] first to names a user typed.
  static String? ticketNameError(String name) {
    if (name.trim().isEmpty) {
      return 'A ticket name must not be empty.';
    }
    if (name.contains('/') || name.contains(r'\') || path.isAbsolute(name)) {
      return 'The ticket name "$name" is a path, but a ticket is named by a '
          'single folder name.';
    }
    if (isHiddenName(name)) {
      return 'The ticket name "$name" starts with a dot, but hidden folders '
          'are never tickets.';
    }
    if (_isLegacyTicketFolderName(name)) {
      return 'The ticket name "$name" is reserved for the folder older gg '
          'versions kept their tickets in.';
    }
    return null;
  }

  /// Returns `true` when [name] can name a ticket ([ticketNameError]).
  static bool isValidTicketName(String name) => ticketNameError(name) == null;

  /// Returns the workspace root a ticket at [ticketDir] belongs to: its
  /// parent, or its grandparent for a legacy `<root>/tickets/<ticket>`.
  ///
  /// A parent named `tickets` that holds a `.ocean` or `.master` is the
  /// workspace root itself (`~/work/Tickets/<ticket>`), so it is returned.
  static String rootOfTicket(Directory ticketDir) {
    final parent = ticketDir.parent;
    return _isLegacyTicketFolder(parent.path)
        ? parent.parent.path
        : parent.path;
  }

  /// Returns the folder of the ticket named [ticketName] in the workspace
  /// [rootPath] — `<root>/<ticket>`, or the legacy `<root>/tickets/<ticket>`
  /// when only that one exists.
  ///
  /// The returned directory does not have to exist and is not checked to be
  /// a ticket: use [existingTicketDir] to act on a ticket and [newTicketDir]
  /// to create one.
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
  /// folder of that name: a name that is no ticket name ([ticketNameError]:
  /// empty, a path, hidden, `tickets`) resolves to nothing, `<root>/<ticket>`
  /// has to be a ticket ([isTicketDir]), so a plain folder (the `doc` or `dna`
  /// folder a DNA instantiates in the root) is none, and a legacy one has to
  /// be a real directory — it counts by its place, as it does for
  /// [detectTicketPath]. Commands that act on a named ticket use this.
  static Directory? existingTicketDir({
    required String rootPath,
    required String ticketName,
  }) {
    if (!isValidTicketName(ticketName)) {
      return null;
    }
    final dir = Directory(path.join(rootPath, ticketName));
    if (isTicketDir(dir)) {
      return dir;
    }
    final legacy = Directory(
      path.join(rootPath, ggMultiLegacyTicketFolder, ticketName),
    );
    return _typeOf(legacy.path) == FileSystemEntityType.directory
        ? legacy
        : null;
  }

  /// Creates the folder of the new ticket [ticketName] directly in the
  /// workspace [rootPath] and returns it.
  ///
  /// This is the one place a ticket folder comes into being. It throws an
  /// [Exception] naming the reason instead when
  /// * [ticketName] is no ticket name ([ticketNameError]),
  /// * a ticket of that name exists already ([existingTicketDir]), or
  /// * `<root>/<ticket>` — or the legacy `<root>/tickets/<ticket>` — is
  ///   already taken by something that is no ticket: the `doc` folder of the
  ///   DNA, a file, a link, a folder of the user.
  ///
  /// An empty real folder is taken as it is: it holds nothing to take over,
  /// and it is what an attempt that failed half-way — or a user preparing
  /// the folder — leaves behind. The folder is created non-recursively; when
  /// that fails because something got in the way, the same »is no ticket«
  /// message is thrown. Paths in the messages are shown relative to
  /// [relativeTo] when it is given.
  static Directory newTicketDir({
    required String rootPath,
    required String ticketName,
    String? relativeTo,
  }) {
    final nameError = ticketNameError(ticketName);
    if (nameError != null) {
      throw Exception(cError(nameError));
    }

    String shown(String folderPath) => relativeTo == null
        ? folderPath
        : path.relative(folderPath, from: relativeTo);

    Exception noTicket(String folderPath) => Exception(
      cError(
        '${shown(folderPath)} already exists and is no ticket. '
        'Choose another ticket name.',
      ),
    );

    final existing = existingTicketDir(
      rootPath: rootPath,
      ticketName: ticketName,
    );
    if (existing != null) {
      throw Exception(
        cError('Ticket $ticketName already exists at ${shown(existing.path)}.'),
      );
    }

    final legacy = path.join(rootPath, ggMultiLegacyTicketFolder, ticketName);
    if (_typeOf(legacy) != FileSystemEntityType.notFound) {
      throw noTicket(legacy);
    }

    final dir = Directory(path.join(rootPath, ticketName));
    final type = _typeOf(dir.path);
    if (type == FileSystemEntityType.directory) {
      if (dir.listSync().isEmpty) {
        return dir;
      }
      throw noTicket(dir.path);
    }
    if (type == FileSystemEntityType.link) {
      throw noTicket(dir.path);
    }

    try {
      dir.createSync();
    } on FileSystemException {
      // A file in the way, or something that appeared since the check above.
      if (_typeOf(dir.path) != FileSystemEntityType.notFound) {
        throw noTicket(dir.path);
      }
      rethrow;
    }
    return dir;
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
      _isLegacyTicketFolder(path.dirname(_absolute(directory.path)));

  // ...........................................................................
  /// Whether the folder at [folderPath] is a legacy `tickets` folder that
  /// groups the tickets of an older workspace: named `tickets` in any case,
  /// but no workspace root itself — a root of that name holds a `.ocean` or
  /// `.master` ([_holdsOcean]).
  static bool _isLegacyTicketFolder(String folderPath) =>
      _isLegacyTicketFolderName(path.basename(folderPath)) &&
      !_holdsOcean(folderPath);

  // ...........................................................................
  /// Whether the folder at [folderPath] holds a `.ocean` or a legacy
  /// `.master`, which makes it a workspace root.
  static bool _holdsOcean(String folderPath) =>
      Directory(path.join(folderPath, ggMultiOceanFolder)).existsSync() ||
      Directory(path.join(folderPath, ggMultiLegacyMasterFolder)).existsSync();

  // ...........................................................................
  /// Whether [directory] is hidden or sits directly in the trash folder.
  static bool _isHiddenOrInTrash(Directory directory) =>
      isHiddenName(_name(directory.path)) ||
      _isTrashName(_parentName(directory.path));

  // ...........................................................................
  /// Whether [directory] is the trash folder `.trash`.
  static bool _isTrash(Directory directory) =>
      _isTrashName(_name(directory.path));

  // ...........................................................................
  /// Whether [name] names the trash folder, in whatever case.
  static bool _isTrashName(String name) =>
      name.toLowerCase() == ggMultiTrashFolder;

  // ...........................................................................
  /// Whether [name] names the legacy `tickets` folder, in whatever case.
  static bool _isLegacyTicketFolderName(String name) =>
      name.toLowerCase() == ggMultiLegacyTicketFolder;

  // ...........................................................................
  /// [folderPath] as an absolute path without `.` / `..` segments and without
  /// a trailing separator — the one spelling every name check works on.
  static String _absolute(String folderPath) =>
      path.normalize(path.absolute(folderPath));

  // ...........................................................................
  /// The name of the folder at [folderPath].
  static String _name(String folderPath) =>
      path.basename(_absolute(folderPath));

  // ...........................................................................
  /// The name of the folder [folderPath] sits in.
  static String _parentName(String folderPath) =>
      path.basename(path.dirname(_absolute(folderPath)));

  // ...........................................................................
  /// What sits at [entityPath], links not followed.
  static FileSystemEntityType _typeOf(String entityPath) =>
      FileSystemEntity.typeSync(entityPath, followLinks: false);
}

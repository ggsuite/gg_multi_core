// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'package:gg_multi_core/src/backend/constants.dart';
import 'package:gg_multi_core/src/backend/workspace_utils.dart';

/// The trash workspace `<root>/.trash`, the sibling of `.ocean` and of the
/// ticket folders that holds everything gg removed from a ticket.
///
/// Nothing gg deletes on behalf of the user is lost right away: a published
/// ticket's repositories and its `.code-workspace` file are moved here, so a
/// forgotten local change can still be recovered. Recovering is the user's
/// job — but keeping the trash is not: [expire] drops what has been sitting
/// here for [maxAge].
class Trash {
  /// How long the trash keeps an entry before [expire] removes it.
  ///
  /// Long enough that »I need that branch back« is still a thing that
  /// happens, short enough that a workspace does not accumulate every
  /// repository it ever published.
  static const Duration maxAge = Duration(days: 30);

  /// The file that records when each trash entry arrived, relative to the
  /// trash folder.
  ///
  /// The arrival time cannot be read off the file system: a `rename` keeps
  /// the modification time of the moved folder, so a ticket whose files were
  /// last touched a year ago would look a year old the second it is trashed
  /// — and would be deleted by the very next [expire]. The index is what
  /// makes »30 days in the trash« mean what it says.
  static const String indexFileName = '.trashed.json';

  /// Returns `<root>/.trash` for the workspace root [rootPath].
  static Directory dirFor(String rootPath) =>
      Directory(path.join(rootPath, ggMultiTrashFolder));

  /// Returns `<root>/.trash/<ticket>` for the ticket directory [ticketDir].
  ///
  /// [ticketDir] is `<root>/<ticket>`, so the root is its parent — the same
  /// folder that holds `.ocean`. A legacy `<root>/tickets/<ticket>` has the
  /// root one level further up; `WorkspaceUtils.rootOfTicket` knows both.
  static Directory dirForTicket(Directory ticketDir) => Directory(
    path.join(
      WorkspaceUtils.rootOfTicket(ticketDir),
      ggMultiTrashFolder,
      path.basename(ticketDir.path),
    ),
  );

  /// Creates `<root>/.trash/<ticket>` when it does not exist and returns it.
  static Directory createDirForTicket(Directory ticketDir) {
    final dir = dirForTicket(ticketDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// Moves [source] into the trash of the ticket [ticketDir], keeping the
  /// path it had relative to the ticket (`<org>/<repo>`,
  /// `<ticket>.code-workspace`, …). Returns the path it was moved to.
  ///
  /// An already occupied target — the same repo trashed by an earlier
  /// publish — is not overwritten; a ` (2)`, ` (3)`, … suffix is appended
  /// instead, so no previous trash content is ever lost.
  static Future<String> moveFromTicket({
    required FileSystemEntity source,
    required Directory ticketDir,
  }) async {
    final relative = path.relative(source.path, from: ticketDir.path);
    final trashDir = createDirForTicket(ticketDir);
    return _moveInto(source, path.join(trashDir.path, relative));
  }

  /// Moves the **whole** ticket folder [ticketDir] into the trash as one
  /// unit — repositories, `ticket.json`, `.gg/`, the
  /// `.code-workspace` file, everything — and returns the directory it was
  /// moved to (normally `<root>/.trash/<ticket>`).
  ///
  /// `do create ticket` pre-creates an **empty** `<root>/.trash/<ticket>`;
  /// that placeholder is deleted so the ticket folder can take its place. A
  /// **non-empty** target — a previously closed ticket of the same name —
  /// is never overwritten: the folder moves to the first free ` (2)`,
  /// ` (3)`, … variant instead, exactly like [moveFromTicket] does per
  /// entry. When trash and ticket live on different volumes the rename
  /// falls back to copy + delete.
  static Future<Directory> moveTicketToTrash({
    required Directory ticketDir,
  }) async {
    final target = dirForTicket(ticketDir);
    if (target.existsSync() && target.listSync().isEmpty) {
      target.deleteSync();
    }

    final movedTo = await _moveInto(ticketDir, target.path);
    return Directory(movedTo);
  }

  /// Moves [source] — a repository of the ocean — into
  /// `<root>/.trash/.ocean/<org>/<repo>`, keeping the path it had relative to
  /// `<root>/.ocean`. Returns the path it was moved to.
  ///
  /// The trash mirrors the ocean layout under its own `.ocean` folder, so a
  /// trashed ocean repository can never collide with the
  /// `<root>/.trash/<ticket>/…` entries a published ticket leaves behind. An
  /// already occupied target gets the same ` (2)`, ` (3)`, … suffix
  /// [moveFromTicket] uses — nothing in the trash is ever overwritten.
  static Future<String> moveFromOcean({
    required FileSystemEntity source,
    required String rootPath,
  }) async {
    final oceanPath = path.join(rootPath, ggMultiOceanFolder);
    // A run that fell back to the legacy folder (rename not possible) hands
    // in sources below ».master« — relate them to that base then.
    final base = path.isWithin(oceanPath, source.path)
        ? oceanPath
        : path.join(rootPath, ggMultiLegacyMasterFolder);
    final relative = path.relative(source.path, from: base);
    return _moveInto(
      source,
      path.join(rootPath, ggMultiTrashFolder, ggMultiOceanFolder, relative),
    );
  }

  /// Moves [source] to [targetPath], or to the first free ` (n)` variant of
  /// it, creating the parent folders on the way. Returns the path used.
  static Future<String> _moveInto(
    FileSystemEntity source,
    String targetPath,
  ) async {
    final target = _freeTarget(targetPath);

    final parent = Directory(path.dirname(target));
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }

    try {
      await source.rename(target);
    } on FileSystemException {
      // Trash and ticket may live on different volumes — rename fails there,
      // so fall back to copy + delete.
      await _copy(source, target);
      await source.delete(recursive: true);
    }

    _stampArrival(target);
    return target;
  }

  /// Records that the unit [target] belongs to arrived now, so [expire] can
  /// tell how long it has been lying around.
  ///
  /// The stamp is refreshed on every move: a repository trashed into a ticket
  /// folder that is already in the trash restarts that folder's clock,
  /// because the newest thing in it is what the user might still want back.
  /// A trash folder that cannot be written to — read-only volume, a file
  /// where the index should be — costs the entry its expiry, never the move
  /// that is in progress.
  static void _stampArrival(String target, {DateTime? now}) {
    final trashDir = _trashDirOf(target);
    if (trashDir == null) return;

    final unit = _unitOf(trashDir, target);
    if (unit == null) return;

    try {
      final index = _readIndex(trashDir);
      index[unit] = (now ?? DateTime.now()).toUtc();
      _writeIndex(trashDir, index);
    } on Object {
      // An unwritable index is not worth failing a move over.
    }
  }

  /// Deletes every trash entry that arrived more than [maxAge] ago and
  /// returns the paths removed, newest last.
  ///
  /// An *entry* is what the user would want back as one piece: a ticket
  /// folder below `<root>/.trash`, or a single repository below
  /// `<root>/.trash/.ocean/<org>/`. The ocean mirror is never treated as one
  /// unit — it collects repositories of wildly different ages, and dropping
  /// it wholesale would take yesterday's clone with it.
  ///
  /// An entry gg never saw arrive — trash from before this index existed, or
  /// a folder someone dropped in by hand — is stamped on this run and
  /// expires [maxAge] later. That way old trash is cleaned eventually
  /// without a single run ever deleting something it only just learned
  /// about.
  ///
  /// Failure is never fatal: an entry that cannot be deleted — open in an
  /// editor, locked by a running tool — keeps its stamp and is retried on
  /// the next run.
  static Future<List<String>> expire({
    required String rootPath,
    Duration? maxAge,
    DateTime? now,
  }) async {
    final trashDir = dirFor(rootPath);
    if (!trashDir.existsSync()) return const <String>[];

    final limit = maxAge ?? Trash.maxAge;
    final moment = (now ?? DateTime.now()).toUtc();
    final index = _readIndex(trashDir);
    final units = _unitsOf(trashDir);

    // Forget what is no longer there, so a name that comes back later is
    // treated as the new arrival it is.
    index.removeWhere((unit, _) => !units.contains(unit));

    final removed = <String>[];
    for (final unit in units) {
      final arrival = index[unit];
      if (arrival == null) {
        index[unit] = moment;
        continue;
      }

      if (moment.difference(arrival) < limit) continue;

      final target = path.join(trashDir.path, path.joinAll(unit.split('/')));
      try {
        _deleteEntity(target);
        index.remove(unit);
        removed.add(target);
        // Locked or in use — keep the stamp and try again next time. There
        // is no portable way to provoke this: Windows refuses to delete a
        // folder with an open handle, POSIX happily does.
        // coverage:ignore-start
      } on FileSystemException {
        continue;
      }
      // coverage:ignore-end
    }

    _pruneEmptyOceanFolders(trashDir);

    try {
      _writeIndex(trashDir, index);
    } on Object {
      // An unwritable index only costs the bookkeeping, not the deletions.
    }

    return removed;
  }

  /// Returns every trash entry as a `/`-separated path relative to
  /// [trashDir] — ticket folders, and the repositories inside the ocean
  /// mirror.
  static Set<String> _unitsOf(Directory trashDir) {
    final units = <String>{};
    for (final entity in trashDir.listSync(followLinks: false)) {
      final name = path.basename(entity.path);
      if (name == indexFileName) continue;

      if (name != ggMultiOceanFolder) {
        units.add(name);
        continue;
      }

      // `.ocean/<org>/<repo>` — two levels down, and only what is there.
      for (final org in Directory(entity.path).listSync(followLinks: false)) {
        if (org is! Directory) continue;
        final orgName = path.basename(org.path);
        for (final repo in org.listSync(followLinks: false)) {
          units.add('$name/$orgName/${path.basename(repo.path)}');
        }
      }
    }
    return units;
  }

  /// Removes the `<org>` folders — and the `.ocean` mirror itself — that
  /// expiring their repositories left empty.
  ///
  /// The folders were listed as empty a statement earlier, so deleting them
  /// is not guarded: a failure here is a file system that changed under the
  /// run, and the caller of [expire] is the one that decides what a broken
  /// trash costs.
  static void _pruneEmptyOceanFolders(Directory trashDir) {
    final ocean = Directory(path.join(trashDir.path, ggMultiOceanFolder));
    if (!ocean.existsSync()) return;

    for (final org in ocean.listSync(followLinks: false)) {
      if (org is Directory && org.listSync(followLinks: false).isEmpty) {
        org.deleteSync();
      }
    }

    if (ocean.listSync(followLinks: false).isEmpty) {
      ocean.deleteSync();
    }
  }

  /// Deletes what lives at [target] — a trashed ticket folder, or the
  /// `.code-workspace` file that was trashed beside it.
  ///
  /// The type is read without following links, so a symlink is unlinked
  /// rather than followed into whatever it points at — `File.deleteSync`
  /// removes the link itself.
  static void _deleteEntity(String target) {
    final type = FileSystemEntity.typeSync(target, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      Directory(target).deleteSync(recursive: true);
      return;
    }

    File(target).deleteSync();
  }

  /// Returns the `<root>/.trash` folder [target] lies in, or null when it
  /// lies outside a trash folder.
  static Directory? _trashDirOf(String target) {
    for (
      var dir = path.dirname(target);
      dir != path.dirname(dir);
      dir = path.dirname(dir)
    ) {
      if (path.basename(dir) == ggMultiTrashFolder) return Directory(dir);
    }
    return null;
  }

  /// Returns the entry [target] belongs to, as a `/`-separated path relative
  /// to [trashDir] — or null when [target] is the trash folder itself.
  static String? _unitOf(Directory trashDir, String target) {
    final segments = path
        .split(path.relative(target, from: trashDir.path))
        .where((segment) => segment.isNotEmpty && segment != '.')
        .toList();
    if (segments.isEmpty) return null;

    if (segments.first != ggMultiOceanFolder) return segments.first;
    return segments.take(3).join('/');
  }

  /// Reads the arrival index, answering with an empty one whenever it is
  /// missing or unreadable — a broken index must never block a move.
  static Map<String, DateTime> _readIndex(Directory trashDir) {
    final file = File(path.join(trashDir.path, indexFileName));
    if (!file.existsSync()) return <String, DateTime>{};

    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return <String, DateTime>{};

      final index = <String, DateTime>{};
      decoded.forEach((key, value) {
        final parsed = value is String ? DateTime.tryParse(value) : null;
        if (key is String && parsed != null) index[key] = parsed.toUtc();
      });
      return index;
    } on Object {
      return <String, DateTime>{};
    }
  }

  /// Writes the arrival index, or deletes it when nothing is left to record.
  static void _writeIndex(Directory trashDir, Map<String, DateTime> index) {
    final file = File(path.join(trashDir.path, indexFileName));
    if (index.isEmpty) {
      if (file.existsSync()) file.deleteSync();
      return;
    }

    if (!trashDir.existsSync()) trashDir.createSync(recursive: true);
    final encoded = <String, String>{
      for (final entry in index.entries)
        entry.key: entry.value.toUtc().toIso8601String(),
    };
    file.writeAsStringSync('${jsonEncode(encoded)}\n');
  }

  /// Returns [target] or, when it is taken, the first free ` (n)` variant.
  static String _freeTarget(String target) {
    if (!_exists(target)) return target;

    final dir = path.dirname(target);
    final extension = path.extension(target);
    final base = path.basenameWithoutExtension(target);
    for (var i = 2; ; i++) {
      final candidate = path.join(dir, '$base ($i)$extension');
      if (!_exists(candidate)) return candidate;
    }
  }

  /// Whether a file or a directory lives at [target].
  static bool _exists(String target) =>
      File(target).existsSync() || Directory(target).existsSync();

  /// Recursively copies [source] to [target]. Symlinks are recreated as
  /// links, so a `node_modules` tree is never dereferenced into a copy.
  static Future<void> _copy(FileSystemEntity source, String target) async {
    if (source is Link) {
      await Link(target).create(await source.target());
      return;
    }

    if (source is File) {
      await source.copy(target);
      return;
    }

    final directory = Directory(source.path);
    await Directory(target).create(recursive: true);
    final entities = directory.list(recursive: false, followLinks: false);
    await for (final entity in entities) {
      await _copy(entity, path.join(target, path.basename(entity.path)));
    }
  }
}

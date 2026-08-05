// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:path/path.dart' as path;

import 'package:gg_multi_core/src/backend/constants.dart';

/// The trash workspace `<root>/.trash`, the sibling of `.ocean` and
/// `tickets` that holds everything gg removed from a ticket.
///
/// Nothing gg deletes on behalf of the user is lost right away: a published
/// ticket's repositories and its `.code-workspace` file are moved here, so a
/// forgotten local change can still be recovered. Emptying the trash is the
/// user's job.
class Trash {
  /// Returns `<root>/.trash` for the workspace root [rootPath].
  static Directory dirFor(String rootPath) =>
      Directory(path.join(rootPath, ggMultiTrashFolder));

  /// Returns `<root>/.trash/<ticket>` for the ticket directory [ticketDir].
  ///
  /// [ticketDir] is `<root>/tickets/<ticket>`, so the root is its
  /// grandparent — the same folder that holds `.ocean`.
  static Directory dirForTicket(Directory ticketDir) => Directory(
    path.join(
      ticketDir.parent.parent.path,
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
  /// unit — repositories, `ticket.json`, `.ticket`, `.gg/`, the
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

    return target;
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

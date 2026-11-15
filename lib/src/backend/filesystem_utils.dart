// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:path/path.dart' as path;

/// Recursively copies [source] to [destination].
///
/// * Creates the destination directory if it does not exist.
/// * Copies files and sub-directories.
/// * Copies symlinks *as symlinks*, keeping their target as it is written in
///   the source link. A link is neither followed nor dropped, so a repository
///   holding one arrives complete in the ticket.
/// * Skips the entries listed in [skipNames]. An entry is either
///   * a plain name, e.g. `node_modules`: skipped on every level, or
///   * a path with `/`, e.g. `.gg/publish_state.json` or `/ticket.json`:
///     skipped at that one place below [source] only. A file of the same
///     name anywhere else is copied.
///
///   The default skip-list excludes `node_modules` so pnpm's symlinked
///   `node_modules/.pnpm/<pkg>/node_modules/<dep>` chains never get
///   dereferenced and reduced to a flat copy. The destination repo is
///   expected to run its package-manager's install step after copying
///   to rebuild `node_modules` from scratch. It also excludes the publish
///   files (`.gg/publish_config.json`, `.gg/publish_state.json` and the
///   legacy `.gg/gg-publish.json`): they are gitignored and belong to the
///   publish of one working copy only — carried into a ticket copy they
///   would block or corrupt the next publish there (skipped steps, wrong
///   feature branch, answers that describe another ticket's work). The
///   progress of `gg do create repo` (`.gg/create_repo_state.json`) stays
///   in the ocean for the same reason: it describes the run that created
///   the repository, not the ticket copy.
///
///   These files are named by their place in the `.gg` folder of [source],
///   the only place gg writes them to. A repository may well track files of
///   the same name elsewhere — a test fixture `test/sample/ticket.json`, a
///   `publish_config.json` of its own — and a copy without them would be a
///   working copy git reports as changed.
///
/// Throws an [ArgumentError] if the source directory does not exist.
Future<void> copyDirectory(
  Directory source,
  Directory destination, {
  Set<String> skipNames = const {
    'node_modules',
    '.gg/publish_config.json',
    '.gg/publish_state.json',
    '.gg/create_repo_state.json',
    '.gg/gg-publish.json',
    '.gg/.gg-publish.json',
    '.gg/.ticket.json',
    '.gg/ticket.json',
    '.gg/.gg_localize_refs_publish_to_backup.json',
  },
}) async {
  if (!source.existsSync()) {
    throw ArgumentError('Source directory ${source.path} does not exist');
  }

  // A plain name applies on every level, an entry with a slash names one
  // place below the source. Leading, trailing and doubled slashes do not
  // matter: `/a//b/` is the place `a/b`.
  final names = <String>{};
  final places = <String>{};
  for (final entry in skipNames) {
    if (entry.contains('/')) {
      places.add(entry.split('/').where((part) => part.isNotEmpty).join('/'));
    } else {
      names.add(entry);
    }
  }

  await _copyDirectory(
    source,
    destination,
    names: names,
    places: places,
    parent: '',
  );
}

// .............................................................................
/// Copies [source] to [destination] and leaves out the entries named
/// [names], on every level, and the ones at one of the [places].
///
/// [parent] is the place of [source] below the directory the copy started
/// with, written with `/` and empty for that directory itself.
Future<void> _copyDirectory(
  Directory source,
  Directory destination, {
  required Set<String> names,
  required Set<String> places,
  required String parent,
}) async {
  // Ensure the destination directory exists.
  if (!destination.existsSync()) {
    await destination.create(recursive: true);
  }

  // followLinks: false — a symlink is copied as a symlink (see below) instead
  // of being dereferenced into a copy of what it points to.
  await for (final entity in source.list(
    recursive: false,
    followLinks: false,
  )) {
    final name = path.basename(entity.path);
    final place = parent.isEmpty ? name : '$parent/$name';
    if (names.contains(name) || places.contains(place)) continue;
    String newPath = path.join(destination.path, name);
    // change .darta to .dart if the file is a .darta file
    if (entity is File && path.extension(entity.path) == '.darta') {
      newPath = '${path.withoutExtension(newPath)}.dart';
    }
    if (entity is Link) {
      // The link is recreated with its original target — the same relative
      // or absolute path the source link holds. Dereferencing it would
      // duplicate the target (and loop on a link pointing at an ancestor),
      // and skipping it would silently lose a file of the repository.
      await Link(newPath).create(await entity.target(), recursive: true);
    } else if (entity is File) {
      await entity.copy(newPath);
    } else if (entity is Directory) {
      // Recurse into sub-directories.
      await _copyDirectory(
        entity,
        Directory(newPath),
        names: names,
        places: places,
        parent: place,
      );
    }
  }
}

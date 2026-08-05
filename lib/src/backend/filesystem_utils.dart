// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
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
/// * Skips entries (on every level) whose name is listed in [skipNames].
///   The default skip-list excludes `node_modules` so pnpm's symlinked
///   `node_modules/.pnpm/<pkg>/node_modules/<dep>` chains never get
///   dereferenced and reduced to a flat copy. The destination repo is
///   expected to run its package-manager's install step after copying
///   to rebuild `node_modules` from scratch. It also excludes
///   `.gg/gg-publish.json`: the runtime progress of a publish is
///   gitignored and belongs to the publish of one working copy only —
///   carried into a ticket copy it would block or corrupt the next
///   publish there (skipped steps, wrong feature branch).
///
/// Throws an [ArgumentError] if the source directory does not exist.
Future<void> copyDirectory(
  Directory source,
  Directory destination, {
  Set<String> skipNames = const {
    'node_modules',
    'gg-publish.json',
    '.gg-publish.json',
    '.ticket.json',
    'ticket.json',
    '.gg_localize_refs_publish_to_backup.json',
  },
}) async {
  if (!source.existsSync()) {
    throw ArgumentError('Source directory ${source.path} does not exist');
  }

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
    if (skipNames.contains(name)) continue;
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
      await copyDirectory(entity, Directory(newPath), skipNames: skipNames);
    }
  }
}

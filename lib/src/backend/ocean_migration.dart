// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_log/gg_log.dart';
import 'package:path/path.dart' as path;

import 'package:gg_multi_core/src/backend/constants.dart';

/// The log sink [migrateMasterFolderToOcean] uses when no [GgLog] is passed.
///
/// The migration is triggered from the workspace path resolution, which runs
/// in constructor default arguments where no logger is in scope. Defaults to
/// [print] — the logger the CLI runs with in production; tests replace it.
GgLog oceanMigrationLog = print;

/// The workspace roots whose conflict or failure was already reported in this
/// process, so the message is not repeated on every path resolution.
final Set<String> _reportedRoots = <String>{};

/// Renames the legacy `<root>/.master` folder to `<root>/.ocean` and an
/// existing `<root>/.trash/.master` to `<root>/.trash/.ocean`.
///
/// This is the backward-compatibility step for workspaces created before the
/// ocean folder got its name: the rename happens the moment the workspace
/// path is resolved — i.e. at the next start of the tool. It is a silent
/// no-op when nothing legacy exists, keeps both folders (preferring `.ocean`,
/// warning once) when both exist, and never throws — a failed rename falls
/// back to the legacy folder for this run and is retried at the next start.
///
/// When the current working directory lies inside the renamed folder, it is
/// moved to the corresponding `.ocean` path, so later path comparisons
/// against [Directory.current] stay truthful.
///
/// Returns true when `<root>/.ocean` exists on return.
bool migrateMasterFolderToOcean({required String rootPath, GgLog? ggLog}) {
  final log = ggLog ?? oceanMigrationLog;
  final legacy = Directory(path.join(rootPath, ggMultiLegacyMasterFolder));
  final ocean = Directory(path.join(rootPath, ggMultiOceanFolder));

  if (legacy.existsSync()) {
    if (ocean.existsSync()) {
      // Never merge two clone trees — prefer .ocean, warn once per root.
      if (!_reportedRoots.contains(rootPath)) {
        _reportedRoots.add(rootPath);
        log(
          yellow(
            'Both »$ggMultiOceanFolder« and the legacy '
            '»$ggMultiLegacyMasterFolder« folder exist in $rootPath. '
            'Using »$ggMultiOceanFolder« — please merge or delete '
            '»$ggMultiLegacyMasterFolder« manually.',
          ),
        );
      }
    } else if (!_renameLegacyFolder(legacy, ocean, rootPath, log)) {
      return false;
    }
  }

  _migrateTrash(rootPath);
  return ocean.existsSync();
}

// .............................................................................
/// Renames [legacy] to [ocean], keeping [Directory.current] truthful when it
/// lies inside the renamed folder. Returns true on success; a failure is
/// reported once per [rootPath] and leaves the legacy folder in place.
bool _renameLegacyFolder(
  Directory legacy,
  Directory ocean,
  String rootPath,
  GgLog log,
) {
  final cwdBefore = Directory.current.path;
  final cwdInLegacy =
      path.equals(legacy.path, cwdBefore) ||
      path.isWithin(legacy.path, cwdBefore);
  final cwdRelative = cwdInLegacy
      ? path.relative(cwdBefore, from: legacy.path)
      : null;

  try {
    if (cwdInLegacy) {
      // Windows refuses to rename a folder the process is standing in.
      Directory.current = rootPath;
    }
    legacy.renameSync(ocean.path);
  } on FileSystemException catch (e) {
    if (cwdInLegacy) {
      Directory.current = cwdBefore;
    }
    if (!_reportedRoots.contains(rootPath)) {
      _reportedRoots.add(rootPath);
      log(
        cError(
          'Failed to rename »$ggMultiLegacyMasterFolder« to '
          '»$ggMultiOceanFolder« in $rootPath: ${e.message} — '
          'continuing with »$ggMultiLegacyMasterFolder«.',
        ),
      );
    }
    return false;
  }

  if (cwdRelative != null) {
    Directory.current = path.normalize(path.join(ocean.path, cwdRelative));
  }

  log(
    cDetail(
      '✓ Renamed workspace folder »$ggMultiLegacyMasterFolder« to '
      '»$ggMultiOceanFolder« in $rootPath',
    ),
  );
  return true;
}

// .............................................................................
/// Renames `<root>/.trash/.master` to `<root>/.trash/.ocean` when possible.
/// Conflicts and failures are tolerated silently — nothing gg does ever
/// reads the trash, it exists for the user.
void _migrateTrash(String rootPath) {
  final legacy = Directory(
    path.join(rootPath, ggMultiTrashFolder, ggMultiLegacyMasterFolder),
  );
  final ocean = Directory(
    path.join(rootPath, ggMultiTrashFolder, ggMultiOceanFolder),
  );
  if (!legacy.existsSync() || ocean.existsSync()) {
    return;
  }
  try {
    legacy.renameSync(ocean.path);
  } on FileSystemException {
    // Tolerated: the next start retries, and the trash content stays usable
    // under its old name in the meantime.
  }
}

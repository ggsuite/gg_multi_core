// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_core/src/backend/repo_folder_resolver.dart';
import 'package:path/path.dart' as path;

// .............................................................................
/// The repo folders a workspace dependency graph is built from: the repos of
/// [ticketPath] first, then every repo of [oceanPath] no ticket repo of the
/// same folder name shadows. [ticketNames] are the ticket repos' folder names.
({List<Directory> dirs, Set<String> ticketNames}) graphPackageDirs({
  required String oceanPath,
  required String? ticketPath,
}) {
  final ticketDirs = ticketPath == null
      ? const <Directory>[]
      : RepoFolderResolver.repoDirs(ticketPath);
  final ticketNames = ticketDirs.map((d) => path.basename(d.path)).toSet();

  return (
    dirs: <Directory>[
      ...ticketDirs,
      ...RepoFolderResolver.repoDirs(oceanPath)
          .where((d) => !ticketNames.contains(path.basename(d.path))),
    ],
    ticketNames: ticketNames,
  );
}

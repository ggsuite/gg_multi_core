// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_log/gg_log.dart';
import 'package:path/path.dart' as path;

import 'package:gg_multi_core/src/backend/repo_folder_resolver.dart';

/// Moves every repository that still sits directly in [workspacePath] into a
/// folder named after the organization of its git remote
/// (`<workspace>/<org>/<repo>`).
///
/// This is the maintenance step for workspaces created before gg grouped the
/// repositories by organization. It recognizes an old workspace by the
/// repositories lying flat in it, is a no-op for a workspace that was already
/// migrated, and never touches a repository whose organization cannot be
/// determined or whose target folder is taken.
///
/// A ticket workspace holds relative path references between its
/// repositories, so the caller must re-localize the ticket after moving —
/// `do add` does that in its final pass.
///
/// Returns the folder names of the repositories that were moved.
List<String> migrateToOrgFolders({
  required String workspacePath,
  required GgLog ggLog,
}) {
  final flatRepos = _flatRepos(workspacePath);
  if (flatRepos.isEmpty) {
    return const <String>[];
  }

  ggLog(cDetail('Moving repositories into their organization folders ...'));

  final moved = <String>[];
  for (final repoDir in flatRepos) {
    final repoName = path.basename(repoDir.path);
    final organization = _organizationOf(repoDir);
    if (organization == null) {
      ggLog(
        cError(
          'Cannot determine the organization of $repoName. '
          'Leaving it where it is.',
        ),
      );
      continue;
    }

    final target = Directory(path.join(workspacePath, organization, repoName));
    if (target.existsSync()) {
      ggLog(
        cError(
          'Cannot move $repoName to $organization/$repoName: '
          'the folder already exists.',
        ),
      );
      continue;
    }

    try {
      target.parent.createSync(recursive: true);
      repoDir.renameSync(target.path);
    } catch (e) {
      ggLog(cError('Failed to move $repoName to $organization/$repoName: $e'));
      continue;
    }

    ggLog(darkGray('✓ $organization/$repoName'));
    moved.add(repoName);
  }

  return moved;
}

// .............................................................................
/// Returns the repositories that still sit directly in [workspacePath].
///
/// An organization folder holds no manifest and no `.git`, so it is not
/// mistaken for a repository, and hidden folders (`.gg`, `.dart_tool`, …) are
/// skipped.
List<Directory> _flatRepos(String workspacePath) {
  final workspace = Directory(workspacePath);
  if (!workspace.existsSync()) {
    return const <Directory>[];
  }
  return <Directory>[
    for (final dir in workspace.listSync().whereType<Directory>())
      if (!path.basename(dir.path).startsWith('.') &&
          RepoFolderResolver.isRepoDir(dir))
        dir,
  ]..sort((a, b) => a.path.compareTo(b.path));
}

// .............................................................................
/// Returns the organization name of the repository in [repoDir], read from
/// its git remote, or null when there is none.
String? _organizationOf(Directory repoDir) {
  final url = RepoFolderResolver.remoteUrl(repoDir);
  if (url == null) {
    return null;
  }
  return RepoFolderResolver.organizationOf(url);
}

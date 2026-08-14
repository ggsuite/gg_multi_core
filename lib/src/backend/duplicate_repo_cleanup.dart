// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_log/gg_log.dart';
import 'package:path/path.dart' as path;

import 'package:gg_multi_core/src/backend/repo_folder_resolver.dart';
import 'package:gg_multi_core/src/backend/repo_identity.dart';
import 'package:gg_multi_core/src/backend/trash.dart';

/// Moves the folders a repository rename left behind out of a workspace.
///
/// Renaming a repository does not invalidate its old name — the platform
/// redirects it — so a manifest that still names the old one keeps cloning
/// successfully and the workspace ends up holding the same repository twice.
/// The dependency graph then sees one package name in two folders, drops one
/// of them, and whichever it drops is decided by folder order rather than by
/// which checkout is current.
///
/// The checkout that lies in the folder its own manifests name is kept; the
/// others go to `<root>/.trash/.ocean/<org>/<repo>`. Nothing is deleted, so a
/// forgotten local change is still recoverable — which is also why this runs
/// without asking.
class DuplicateRepoCleanup {
  /// Constructor.
  const DuplicateRepoCleanup();

  /// Trashes every leftover checkout in [workspacePath] and returns the
  /// `<org>/<repo>` labels it moved.
  ///
  /// [rootPath] is the workspace root that holds `.ocean` and `.trash`.
  Future<List<String>> run({
    required String workspacePath,
    required String rootPath,
    required GgLog ggLog,
    bool dryRun = false,
  }) async {
    final removed = <String>[];

    for (final group in _duplicateGroups(workspacePath)) {
      final kept = _pick(group);

      for (final leftover in group) {
        if (identical(leftover, kept)) {
          continue;
        }

        final label = RepoFolderResolver.relativePath(
          workspacePath: workspacePath,
          repoDir: leftover.directory,
        ).replaceAll(r'\', '/');

        ggLog(
          cDetail(
            '🗑️ ${dryRun ? 'Would move' : 'Moving'} $label to the trash: it '
            'is ${path.basename(kept.directory.path)} under a former name.',
          ),
        );
        removed.add(label);

        if (dryRun) {
          continue;
        }

        await Trash.moveFromOcean(
          source: leftover.directory,
          rootPath: rootPath,
        );
        RepoFolderResolver.removeEmptyOrgFolder(
          workspacePath: workspacePath,
          repoDir: leftover.directory,
        );
      }
    }

    return removed;
  }

  // ######################
  // Private
  // ######################

  // ...........................................................................
  /// The checkouts of [workspacePath] grouped per repository, keeping only the
  /// groups that hold more than one.
  ///
  /// A checkout that declares no repository joins no group: nothing here may
  /// rest on a guess, because what follows from a group is that a folder is
  /// moved away.
  List<List<RepoIdentity>> _duplicateGroups(String workspacePath) {
    final identities = [
      for (final dir in RepoFolderResolver.repoDirs(workspacePath))
        RepoIdentity.of(dir),
    ];

    final groups = <List<RepoIdentity>>[];
    for (final identity in identities) {
      final group = groups.where((g) => g.first.isSameRepoAs(identity));
      if (group.isEmpty) {
        groups.add(<RepoIdentity>[identity]);
      } else {
        group.first.add(identity);
      }
    }

    return groups.where((group) => group.length > 1).toList();
  }

  // ...........................................................................
  /// The checkout of [group] that stays.
  ///
  /// A repository is at home in the folder its own manifests name. When none
  /// of the checkouts is — or several are, which two folders of one repository
  /// cannot be — the first one wins, so the outcome stays deterministic.
  RepoIdentity _pick(List<RepoIdentity> group) => group.firstWhere(
    (identity) => identity.sitsInDeclaredRepoFolder,
    orElse: () => group.first,
  );
}

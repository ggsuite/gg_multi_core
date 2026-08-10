// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_log/gg_log.dart';
import 'package:path/path.dart' as path;

import 'package:gg_multi_core/src/backend/trash.dart';
import 'package:gg_git/gg_git.dart';

/// Closes a finished ticket: deletes the remote feature branches, then
/// moves the **whole** ticket folder into `<root>/.trash/<ticket>`.
///
/// Shared by `do publish` (when the user accepts the cleanup offer after
/// every repo is published) and `do rm ticket` (the explicit way to close a
/// ticket later). Nothing is deleted outright — the ticket moves to the
/// trash **as it is**, in one piece: repositories on their feature branches
/// with restored overrides and uncommitted leftovers, `ticket.json`,
/// `.gg/`, the `<ticket>.code-workspace` file. Reopening — or
/// even re-importing (`gg do import ticket <path>`) — the closed ticket
/// from the trash therefore stays possible.
///
/// Only the remote branches need per-repo handling: each repository in
/// [repoDirs] gets its remote feature branch (named after the ticket)
/// deleted — unless [deleteRemoteBranch] is false. The deletions run
/// *before* the move, while the repos' git folders are still at their
/// original paths; when one fails, the ticket is kept in place so the
/// command can simply be retried.
///
/// After the ticket folder is gone the caller's shell sits in a deleted
/// directory, so the command to change to the workspace root is printed in
/// blue.
Future<void> cleanUpTicket({
  required Directory ticketDir,
  required List<Directory> repoDirs,
  required bool deleteRemoteBranch,
  required GgLog ggLog,
  required GgLog taskLog,
  ProcessRunner? processRunner,
}) async {
  final runner = processRunner ?? defaultProcessRunner;
  final ticketName = path.basename(ticketDir.path);

  // Step 1: Delete the remote branches — per repo, from the repos'
  // original locations. A failed deletion keeps the ticket where it is:
  // moving it anyway would strand the remaining branches, because the git
  // folders they are deleted from would be gone.
  var allBranchesHandled = true;
  for (final repoDir in repoDirs) {
    final repoName = path.basename(repoDir.path);

    if (!deleteRemoteBranch) {
      taskLog(cDetail('✓ Kept remote branch $ticketName for $repoName.'));
      continue;
    }

    if (!repoDir.existsSync()) {
      // Without the repo folder there is no git context to delete from —
      // e.g. the repo was removed by hand. Nothing to do here.
      taskLog(
        cDetail('✓ Repository $repoName is gone — no remote branch to delete.'),
      );
      continue;
    }

    try {
      await _deleteRemoteBranch(
        repoDir: repoDir,
        branchName: ticketName,
        ggLog: taskLog,
        processRunner: runner,
      );
    } catch (e) {
      allBranchesHandled = false;
      ggLog(
        cError('Failed to delete remote branch $ticketName for $repoName: $e'),
      );
    }
  }

  if (!allBranchesHandled) {
    ggLog(
      cWarn(
        'Ticket $ticketName was not moved to the trash because not every '
        'remote branch could be deleted. Fix the problem and retry, or '
        'use --no-delete-remote-branch.',
      ),
    );
    return;
  }

  // The workspace root is the grandparent of `<root>/tickets/<ticket>` —
  // resolved before the move, while the path still exists.
  final workspaceRoot = ticketDir.absolute.parent.parent.path;

  // Step 2: Move the whole folder in one go — everything the ticket holds
  // travels with it.
  try {
    final target = await Trash.moveTicketToTrash(ticketDir: ticketDir);
    // Where the ticket went — the user asked for the move, so this is a
    // detail, not a warning. It still goes to ggLog: a non-verbose run must
    // not swallow the one line that says where the work now lives. Normally
    // the ticket keeps its name inside the trash, so naming the trash folder
    // is enough; only a collision (an earlier ticket of the same name) makes
    // the full path worth printing.
    final movedTo = path.basename(target.path) == ticketName
        ? target.parent.path
        : target.path;
    ggLog(cDetail('Moved ticket $ticketName to $movedTo'));
  } catch (e) {
    ggLog(cError('Failed to move ticket $ticketName to the trash: $e'));
    return;
  }

  // The shell of the caller now sits inside a deleted folder — hand them
  // the way out.
  ggLog(cAction('\nChange to the workspace root with:'));
  ggLog(cCmd('  cd $workspaceRoot'));
}

/// Deletes the remote feature branch [branchName] for [repoDir].
Future<void> _deleteRemoteBranch({
  required Directory repoDir,
  required String branchName,
  required GgLog ggLog,
  required ProcessRunner processRunner,
}) async {
  final repoName = path.basename(repoDir.path);
  final result = await processRunner('git', <String>[
    'push',
    'origin',
    '--delete',
    branchName,
  ], workingDirectory: repoDir.path);

  if (result.exitCode != 0) {
    // The branch might have been deleted already, e.g. directly on GitHub.
    // Then there is nothing left to do and nothing to complain about.
    final stderr = '${result.stderr}';
    if (stderr.contains('remote ref does not exist')) {
      ggLog(
        cWarn('Remote branch $branchName for $repoName is already deleted.'),
      );
      return;
    }

    throw Exception(
      cError(
        'Failed to delete remote branch $branchName for $repoName: '
        '$stderr',
      ),
    );
  }

  ggLog(cDetail('Deleted remote branch $branchName for $repoName.'));
}

// coverage:ignore-end

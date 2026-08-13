// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_git/gg_git.dart';
import 'package:gg_log/gg_log.dart';
import 'package:path/path.dart' as path;

/// Why a repository was not brought to the state of its remote main branch.
///
/// Only some of these stop a run. A folder that carries **local work** must
/// not be updated behind the user's back and must not be reasoned about
/// either, so it ends the run and is named. A folder that simply has nothing
/// to update from carries no risk: it is reported and skipped.
enum RepoBlocker {
  /// The repository is checked out on a branch other than main or master.
  featureBranch('is on a feature branch'),

  /// The working tree carries changes that are not committed.
  uncommittedChanges('has uncommitted changes'),

  /// The repository holds stashes.
  stashedChanges('has stashed changes'),

  /// The current branch carries commits the remote does not have.
  unpushedCommits('has commits that are not pushed'),

  /// The folder holds a package but no git checkout.
  notAGitRepo('is no git repository', blocksTheRun: false),

  /// The current branch has no remote branch to be updated from.
  noUpstream('has no upstream branch', blocksTheRun: false);

  /// Constructor.
  const RepoBlocker(this.description, {this.blocksTheRun = true});

  /// What the blocker reads like in a report, e.g. `has uncommitted changes`.
  final String description;

  /// Whether a repository in this state ends the run instead of being
  /// skipped.
  final bool blocksTheRun;
}

/// Thrown when repositories could not be brought to their remote state.
///
/// Every blocked repository is named at once: fixing them one exception at a
/// time would cost the user a full run per repository.
class RepoFreshnessException implements Exception {
  /// Constructor.
  RepoFreshnessException(this.blocked);

  /// The blocked repositories and the reason each one is blocked.
  final Map<String, RepoBlocker> blocked;

  @override
  String toString() {
    final lines = <String>[
      'The following repositories are not on the state of their remote:',
      for (final entry in blocked.entries)
        '  ${entry.key} ${entry.value.description}',
      'Commit, push or stash the changes, then run the command again.',
    ];
    return cError(lines.join('\n'));
  }
}

/// Brings a repository to the state of the remote branch it tracks.
///
/// A workspace resolves dependencies out of the manifests its repositories
/// carry, so a checkout that lags behind its remote makes gg reason about a
/// package that has since been renamed, split or removed. Updating first turns
/// every complaint that follows into a real one.
///
/// Nothing is ever updated over local work: a repository that is on a feature
/// branch, dirty, stashed or ahead of its remote is reported as blocked and
/// left exactly as it is.
class RepoFreshness extends GgGitBase<RepoBlocker?> {
  /// Constructor.
  RepoFreshness({
    required super.ggLog,
    super.processWrapper,
    Fetch? fetch,
    IsCommitted? isCommitted,
    IsFeatureBranch? isFeatureBranch,
    UpstreamBranch? upstreamBranch,
  }) : _fetch = fetch ?? Fetch(ggLog: ggLog),
       _isCommitted = isCommitted ?? IsCommitted(ggLog: ggLog),
       _isFeatureBranch = isFeatureBranch ?? IsFeatureBranch(ggLog: ggLog),
       _upstreamBranch = upstreamBranch ?? UpstreamBranch(ggLog: ggLog),
       super(
         name: 'repo-freshness',
         description:
             'Fast-forwards a repository to the state of its remote branch.',
       );

  // ...........................................................................
  @override
  Future<RepoBlocker?> exec({
    required Directory directory,
    required GgLog ggLog,
    Map<String, dynamic> options = const {},
  }) async {
    final blocker = await get(directory: directory, ggLog: ggLog);
    ggLog(blocker == null ? 'up to date' : blocker.description);
    return blocker;
  }

  // ...........................................................................
  /// Fast-forwards [directory] to the branch it tracks.
  ///
  /// Returns null when the repository is on that state afterwards, or the
  /// reason it was left untouched.
  @override
  Future<RepoBlocker?> get({
    required GgLog ggLog,
    required Directory directory,
  }) async {
    // A workspace folder counts as a repository as soon as it holds a
    // manifest, so it may well have no git checkout at all. git itself is
    // asked, not the presence of a `.git` folder: a folder that merely looks
    // like a checkout is no checkout.
    final gitDir = await processWrapper.run('git', [
      'rev-parse',
      '--git-dir',
    ], workingDirectory: directory.path);
    if (gitDir.exitCode != 0) {
      return RepoBlocker.notAGitRepo;
    }

    if (await _isFeatureBranch.get(ggLog: ggLog, directory: directory)) {
      return RepoBlocker.featureBranch;
    }

    if (!await _isCommitted.get(ggLog: ggLog, directory: directory)) {
      return RepoBlocker.uncommittedChanges;
    }

    if ((await _git(directory, ['stash', 'list'])).isNotEmpty) {
      return RepoBlocker.stashedChanges;
    }

    await _fetch.get(ggLog: ggLog, directory: directory);

    final upstream = await _upstreamBranch.get(
      ggLog: ggLog,
      directory: directory,
    );
    if (upstream.isEmpty) {
      return RepoBlocker.noUpstream;
    }

    // »<upstream>...HEAD« counts both sides at once: what only the remote has
    // and what only the checkout has.
    final counts = await _git(directory, [
      'rev-list',
      '--left-right',
      '--count',
      '$upstream...HEAD',
    ]);
    final behindAhead = counts.split(RegExp(r'\s+'));
    final behind = int.parse(behindAhead.first);
    final ahead = int.parse(behindAhead.last);

    if (ahead > 0) {
      return RepoBlocker.unpushedCommits;
    }

    if (behind > 0) {
      await waitUntilUnlocked(directory: directory, ggLog: ggLog);
      await _git(directory, ['merge', '--ff-only', upstream]);
    }

    return null;
  }

  // ...........................................................................
  /// Fast-forwards every repository in [directories], at most [maxParallel] at
  /// a time, and throws a [RepoFreshnessException] naming each one that holds
  /// local work. A folder with nothing to update from is skipped silently.
  ///
  /// Paths are reported relative to [workspacePath] when it is given, so the
  /// report reads `ggsuite/dna_base` instead of an absolute path.
  Future<void> updateAll({
    required GgLog ggLog,
    required Iterable<Directory> directories,
    String? workspacePath,
    int maxParallel = 4,
  }) async {
    final repos = directories.toList();
    final blockers = List<RepoBlocker?>.filled(repos.length, null);

    await _runWithLimit(repos.length, maxParallel, (index) async {
      blockers[index] = await get(ggLog: ggLog, directory: repos[index]);
    });

    final blocked = <String, RepoBlocker>{};
    for (var i = 0; i < repos.length; i++) {
      final blocker = blockers[i];
      if (blocker != null && blocker.blocksTheRun) {
        blocked[_label(repos[i], workspacePath)] = blocker;
      }
    }

    if (blocked.isNotEmpty) {
      throw RepoFreshnessException(blocked);
    }
  }

  // ######################
  // Private
  // ######################

  final Fetch _fetch;
  final IsCommitted _isCommitted;
  final IsFeatureBranch _isFeatureBranch;
  final UpstreamBranch _upstreamBranch;

  // ...........................................................................
  /// Runs git with [args] in [directory] and returns its trimmed output.
  Future<String> _git(Directory directory, List<String> args) async {
    final result = await processWrapper.run(
      'git',
      args,
      workingDirectory: directory.path,
    );

    if (result.exitCode != 0) {
      throw Exception(
        cError(
          'Could not run "git ${args.join(' ')}" in '
          '"${path.basename(directory.path)}": '
          '${result.stderr.toString().trim()}',
        ),
      );
    }

    return result.stdout.toString().trim();
  }

  // ...........................................................................
  /// `<org>/<repo>` relative to [workspacePath], or the folder name.
  String _label(Directory directory, String? workspacePath) =>
      workspacePath == null
      ? path.basename(directory.path)
      : path.relative(directory.path, from: workspacePath);

  // ...........................................................................
  /// Runs [task] for every index below [count], [limit] of them at a time.
  Future<void> _runWithLimit(
    int count,
    int limit,
    Future<void> Function(int index) task,
  ) async {
    var next = 0;
    Future<void> worker() async {
      while (next < count) {
        await task(next++);
      }
    }

    await Future.wait(<Future<void>>[
      for (var i = 0; i < limit && i < count; i++) worker(),
    ]);
  }
}

/// Mocktail mock
class MockRepoFreshness extends MockDirCommand<RepoBlocker?>
    implements RepoFreshness {}

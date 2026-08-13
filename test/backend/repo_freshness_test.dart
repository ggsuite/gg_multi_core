// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_git/gg_git.dart';
import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_multi_core/src/backend/repo_freshness.dart';
import 'package:gg_process/gg_process.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory local;
  late Directory remote;
  late RepoFreshness repoFreshness;
  final messages = <String>[];
  void ggLog(String m) => messages.add(m);

  /// Runs git in [dir] and throws when it fails.
  Future<String> git(Directory dir, List<String> args) async {
    final result = await ggRunProcess('git', args, workingDirectory: dir.path);
    if (result.exitCode != 0) {
      throw Exception('git ${args.join(' ')}: ${result.stderr}');
    }
    return result.stdout.toString().trim();
  }

  /// A second checkout of [remote], used to publish commits the [local] one
  /// does not have yet.
  Future<Directory> cloneOfRemote() async {
    final dir = Directory.systemTemp.createTempSync('freshness_clone_');
    await ggRunProcess('git', ['clone', remote.path, dir.path]);
    return dir;
  }

  setUp(() async {
    messages.clear();
    (local, remote) = await initLocalAndRemoteGit();
    repoFreshness = RepoFreshness(ggLog: ggLog);

    await addAndCommitSampleFile(local);
    await pushLocalChangesUpstream(local, 'main');
  });

  tearDown(() {
    for (final dir in [local, remote]) {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  });

  group('RepoFreshness', () {
    group('get', () {
      test('leaves a repository that is already up to date alone', () async {
        final head = await git(local, ['rev-parse', 'HEAD']);

        expect(await repoFreshness.get(ggLog: ggLog, directory: local), isNull);
        expect(await git(local, ['rev-parse', 'HEAD']), head);
      });

      test('fast-forwards a repository that is behind', () async {
        // Somebody else pushes — exactly the case an ocean checkout is in
        // after a rename landed on main.
        final other = await cloneOfRemote();
        await addAndCommitSampleFile(other, fileName: 'other.txt');
        await git(other, ['push']);
        final expected = await git(other, ['rev-parse', 'HEAD']);
        other.deleteSync(recursive: true);

        expect(await repoFreshness.get(ggLog: ggLog, directory: local), isNull);
        expect(await git(local, ['rev-parse', 'HEAD']), expected);
        expect(File(path.join(local.path, 'other.txt')).existsSync(), isTrue);
      });

      test('reports a feature branch', () async {
        await createBranch(local, 'feature');

        expect(
          await repoFreshness.get(ggLog: ggLog, directory: local),
          RepoBlocker.featureBranch,
        );
      });

      test('reports uncommitted changes', () async {
        await updateSampleFileWithoutCommitting(local);

        expect(
          await repoFreshness.get(ggLog: ggLog, directory: local),
          RepoBlocker.uncommittedChanges,
        );
      });

      test('reports stashed changes', () async {
        await updateSampleFileWithoutCommitting(local);
        await git(local, ['stash']);

        expect(
          await repoFreshness.get(ggLog: ggLog, directory: local),
          RepoBlocker.stashedChanges,
        );
      });

      test('reports unpushed commits', () async {
        await updateAndCommitSampleFile(local);

        expect(
          await repoFreshness.get(ggLog: ggLog, directory: local),
          RepoBlocker.unpushedCommits,
        );
      });

      test('reports a branch without an upstream', () async {
        await git(local, ['branch', '--unset-upstream']);

        expect(
          await repoFreshness.get(ggLog: ggLog, directory: local),
          RepoBlocker.noUpstream,
        );
      });

      test('reports a folder that is no git repository', () async {
        final plain = Directory.systemTemp.createTempSync('freshness_plain_');
        addTearDown(() => plain.deleteSync(recursive: true));

        expect(
          await repoFreshness.get(ggLog: ggLog, directory: plain),
          RepoBlocker.notAGitRepo,
        );
      });

      test('throws when git fails', () async {
        final processWrapper = MockGgProcessWrapper();
        when(
          () => processWrapper.run(
            any(),
            any(),
            workingDirectory: any(named: 'workingDirectory'),
          ),
        ).thenAnswer((invocation) async {
          // The checkout is recognized, but everything after that fails.
          final args = invocation.positionalArguments[1] as List<String>;
          return args.first == 'rev-parse'
              ? ProcessResult(0, 0, '.git', '')
              : ProcessResult(0, 128, '', 'not a git repository');
        });

        late String message;
        try {
          await RepoFreshness(
            ggLog: ggLog,
            processWrapper: processWrapper,
            isFeatureBranch: _AlwaysFalse(ggLog: ggLog),
            isCommitted: _AlwaysTrue(ggLog: ggLog),
          ).get(ggLog: ggLog, directory: local);
        } catch (e) {
          message = e.toString();
        }

        expect(message, contains('Could not run "git stash list"'));
        expect(message, contains('not a git repository'));
      });
    });

    group('exec', () {
      test('reports that the repository is up to date', () async {
        await repoFreshness.exec(directory: local, ggLog: ggLog);
        expect(messages.last, 'up to date');
      });

      test('reports the blocker', () async {
        await updateSampleFileWithoutCommitting(local);
        await repoFreshness.exec(directory: local, ggLog: ggLog);
        expect(messages.last, 'has uncommitted changes');
      });
    });

    group('updateAll', () {
      test('updates every repository', () async {
        final other = await cloneOfRemote();
        addTearDown(() => other.deleteSync(recursive: true));

        await repoFreshness.updateAll(
          ggLog: ggLog,
          directories: [local, other],
        );
      });

      test('skips what has nothing to update from', () async {
        // A folder holding only a manifest, and one whose branch lost its
        // upstream: neither risks local work, so neither stops the run.
        final plain = Directory.systemTemp.createTempSync('freshness_plain_');
        addTearDown(() => plain.deleteSync(recursive: true));

        final detached = await cloneOfRemote();
        addTearDown(() => detached.deleteSync(recursive: true));
        await git(detached, ['branch', '--unset-upstream']);

        await repoFreshness.updateAll(
          ggLog: ggLog,
          directories: [local, plain, detached],
        );
      });

      test('names every blocked repository at once', () async {
        final other = await cloneOfRemote();
        addTearDown(() => other.deleteSync(recursive: true));

        await updateSampleFileWithoutCommitting(local);
        await createBranch(other, 'feature');

        late RepoFreshnessException exception;
        try {
          await repoFreshness.updateAll(
            ggLog: ggLog,
            directories: [local, other],
          );
        } on RepoFreshnessException catch (e) {
          exception = e;
        }

        expect(exception.blocked, {
          path.basename(local.path): RepoBlocker.uncommittedChanges,
          path.basename(other.path): RepoBlocker.featureBranch,
        });
        expect(
          exception.toString(),
          contains('are not on the state of their remote'),
        );
        expect(exception.toString(), contains('has uncommitted changes'));
        expect(
          exception.toString(),
          contains('Commit, push or stash the changes'),
        );
      });

      test('a dry run reports the blockers instead of throwing', () async {
        await updateSampleFileWithoutCommitting(local);
        final head = await git(local, ['rev-parse', 'HEAD']);

        await repoFreshness.updateAll(
          ggLog: ggLog,
          directories: [local],
          dryRun: true,
        );

        expect(
          messages.join('\n'),
          contains('are not on the state of their remote'),
        );
        expect(await git(local, ['rev-parse', 'HEAD']), head);
      });

      test('a dry run leaves a repository that is behind alone', () async {
        final other = await cloneOfRemote();
        addTearDown(() => other.deleteSync(recursive: true));
        await addAndCommitSampleFile(other, fileName: 'other.txt');
        await git(other, ['push']);

        final head = await git(local, ['rev-parse', 'HEAD']);

        await repoFreshness.updateAll(
          ggLog: ggLog,
          directories: [local],
          dryRun: true,
        );

        expect(await git(local, ['rev-parse', 'HEAD']), head);
      });

      test('labels the repositories relative to the workspace', () async {
        await updateSampleFileWithoutCommitting(local);

        late RepoFreshnessException exception;
        try {
          await repoFreshness.updateAll(
            ggLog: ggLog,
            directories: [local],
            workspacePath: local.parent.path,
          );
        } on RepoFreshnessException catch (e) {
          exception = e;
        }

        expect(exception.blocked.keys, [path.basename(local.path)]);
      });
    });
  });
}

/// An [IsFeatureBranch] that never sees a feature branch.
class _AlwaysFalse extends IsFeatureBranch {
  _AlwaysFalse({required super.ggLog});

  @override
  Future<bool> get({
    required GgLog ggLog,
    required Directory directory,
  }) async => false;
}

/// An [IsCommitted] that always finds a clean working tree.
class _AlwaysTrue extends IsCommitted {
  _AlwaysTrue({required super.ggLog});

  @override
  Future<bool> get({
    required GgLog ggLog,
    required Directory directory,
  }) async => true;
}

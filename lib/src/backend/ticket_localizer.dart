// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_git/gg_git.dart';
import 'package:gg_lang/gg_lang.dart' as gg_lang;
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_localize_refs/gg_localize_refs.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_multi_core/src/backend/graph_package_dirs.dart';
import 'package:gg_multi_core/src/backend/repo_dependencies.dart';
import 'package:gg_multi_core/src/backend/workspace_utils.dart';
import 'package:gg_one_core/gg_one_core.dart' as gg;
import 'package:mocktail/mocktail.dart' as mocktail;
import 'package:path/path.dart' as path;

/// What keeps the references of a ticket from pointing at its checkouts.
class TicketRefsStatus {
  /// Constructor.
  const TicketRefsStatus({
    this.unlocalized = const <String, List<UnlocalizedRef>>{},
    this.missingRepos = const <String>[],
  });

  /// The out-of-sync references per repo, keyed by its `Directory.path`.
  final Map<String, List<UnlocalizedRef>> unlocalized;

  /// Ocean repos between two ticket repos the ticket lacks, by folder name.
  final List<String> missingRepos;

  /// Whether every reference of the ticket points at its checkout.
  bool get isInSync => unlocalized.isEmpty && missingRepos.isEmpty;
}

/// What a ticket repo looked like before gg localized it.
class RepoBaseline {
  /// Constructor.
  const RepoBaseline({required this.dirtyPaths, required this.wasCommitted});

  /// The paths `git status` reported.
  final Set<String> dirtyPaths;

  /// Whether the recorded `doCommit` state matched the tree.
  final bool wasCommitted;
}

/// Keeps the references between the repositories of a ticket localized.
///
/// Shared by `do add`, `do localize`, `can commit`, `do commit`, `do push`.
class TicketLocalizer {
  /// Constructor.
  TicketLocalizer({
    required GgLog ggLog,
    ChangeRefsToLocal? localizeRefs,
    BackupPublishTo? backupPublishTo,
    UnlocalizedRefs? unlocalizedRefs,
    gg.GgSystemCommit? systemCommit,
    gg.GgState? ggState,
    Graph? graph,
    ProcessRunner? processRunner,
  }) : _changeRefsToLocal = localizeRefs ?? ChangeRefsToLocal(ggLog: ggLog),
       _backupPublishTo = backupPublishTo ?? BackupPublishTo(ggLog: ggLog),
       _refsCheck = unlocalizedRefs ?? UnlocalizedRefs(ggLog: ggLog),
       _systemCommit = systemCommit ?? gg.GgSystemCommit(ggLog: ggLog),
       _ggState = ggState ?? gg.GgState(ggLog: ggLog),
       _graph = graph ?? Graph(ggLog: ggLog),
       _processRunner = processRunner ?? defaultProcessRunner,
       _gitStatus = GitStatus(ggLog: ggLog);

  // ...........................................................................
  /// What is out of sync in [repos] of [ticketDir]: unlocalized references
  /// and repos missing between them. Read-only; the graphs' notes are dropped.
  Future<TicketRefsStatus> check({
    required Directory ticketDir,
    required List<Node> repos,
  }) => _check(ticketDir: ticketDir, repos: repos, findMissing: true);

  // ...........................................................................
  /// Warns about missing repos and throws, listing the unlocalized refs with
  /// the command that fixes them, when [repos] are out of sync. Read-only.
  Future<void> throwWhenOutOfSync({
    required Directory ticketDir,
    required List<Node> repos,
    required GgLog ggLog,
  }) async {
    final status = await check(ticketDir: ticketDir, repos: repos);
    _warnMissingRepos(status.missingRepos, ggLog);
    if (status.unlocalized.isEmpty) {
      return;
    }

    for (final MapEntry(key: repo, value: refs) in status.unlocalized.entries) {
      ggLog('\n${cH1(path.basename(repo))}');
      for (final ref in refs) {
        ggLog(cError('✗ $ref'));
      }
    }
    ggLog(
      cAction('\nPlease run ') +
          cCmd('gg do localize') +
          cAction(' (or ') +
          cCmd('gg do commit') +
          cAction(', which localizes itself).\n'),
    );
    final names = status.unlocalized.keys.map(path.basename).join(', ');
    throw Exception(cError('References not localized in $names.'));
  }

  // ...........................................................................
  /// What each git repo of [repoDirs] looks like now, keyed by its path —
  /// the baseline [commit] tells gg's own changes from the user's with.
  Future<Map<String, RepoBaseline>> baseline(List<Directory> repoDirs) async {
    return <String, RepoBaseline>{
      for (final dir in repoDirs.where(_isGitRepo))
        dir.path: RepoBaseline(
          dirtyPaths: await _dirtyPaths(dir),
          wasCommitted: await _wasCommitted(dir),
        ),
    };
  }

  // ...........................................................................
  /// Localizes the references of [repos] (in the given order) and resolves
  /// their dependencies again; [upgrade] runs `pub upgrade`.
  Future<void> localize({
    required List<Node> repos,
    required GgLog ggLog,
    bool upgrade = false,
  }) => _localize(
    repos: repos,
    ggLog: ggLog,
    installErrorLog: ggLog,
    upgrade: upgrade,
  );

  // ...........................................................................
  /// Commits the gg-owned files of [repoDirs] that changed since [baseline]
  /// as one `#gg:` commit per repo; see `CLAUDE.md` for the exact rules.
  /// [recordStateFor] (repo paths) records `doCommit` when left clean.
  Future<void> commit({
    required List<Directory> repoDirs,
    required Map<String, RepoBaseline> baseline,
    required GgLog ggLog,
    Set<String> recordStateFor = const <String>{},
    String message = '${gg.ggCommitPrefix}changed references to path',
  }) async {
    final recordable = recordStateFor.map(path.normalize).toSet();
    final failed = <String>[];
    for (final dir in repoDirs.where(_isGitRepo)) {
      // git refuses a partial commit here; the user's commit takes the refs.
      if (await _isPartialCommitBlocked(dir)) {
        continue;
      }
      try {
        await _commitRepo(
          dir: dir,
          before: baseline[dir.path],
          ggLog: ggLog,
          message: message,
          recordState: recordable.contains(path.normalize(dir.path)),
        );
      } catch (e) {
        ggLog(cError('Failed to commit ${path.basename(dir.path)}: $e'));
        failed.add(path.basename(dir.path));
      }
    }

    if (failed.isNotEmpty) {
      throw Exception(
        cError('Failed to commit the localized refs of ${failed.join(', ')}'),
      );
    }
  }

  // ...........................................................................
  /// Localizes the out-of-sync [repos] of [ticketDir], commits gg's changes
  /// and returns their names; details only on failure. Warns about missing
  /// repos unless [warnMissingRepos] is false (a later check warns).
  Future<List<String>> localizeUnlocalized({
    required Directory ticketDir,
    required List<Node> repos,
    required GgLog ggLog,
    bool warnMissingRepos = true,
  }) async {
    final status = await _check(
      ticketDir: ticketDir,
      repos: repos,
      findMissing: warnMissingRepos,
    );

    final outOfSync = [
      for (final repo in repos)
        if (status.unlocalized.containsKey(repo.directory.path)) repo,
    ];
    final names = [for (final r in outOfSync) path.basename(r.directory.path)];
    if (outOfSync.isNotEmpty) {
      final details = <String>[];
      try {
        // Localizing one repo also writes into the repos it depends on.
        final repoDirs = [for (final repo in repos) repo.directory];
        final before = await baseline(repoDirs);
        await _localize(
          repos: outOfSync,
          ggLog: details.add,
          installErrorLog: ggLog,
        );
        await commit(repoDirs: repoDirs, baseline: before, ggLog: details.add);
      } catch (_) {
        details.forEach(ggLog);
        rethrow;
      }
      for (final name in names) {
        ggLog(cDetail('✓ Localized the references of $name'));
      }
    }

    _warnMissingRepos(status.missingRepos, ggLog);
    return names;
  }

  // ######################
  // Private
  // ######################

  final ChangeRefsToLocal _changeRefsToLocal;
  final BackupPublishTo _backupPublishTo;
  final UnlocalizedRefs _refsCheck;
  final gg.GgSystemCommit _systemCommit;
  final gg.GgState _ggState;
  final Graph _graph;
  final ProcessRunner _processRunner;
  final GitStatus _gitStatus;

  /// Drops what the graphs note on the way; their errors are thrown.
  static void _quiet(String _) {}

  /// The git-dir entries of an operation that refuses a partial commit.
  static const List<String> _partialCommitBlockers = <String>[
    'MERGE_HEAD',
    'CHERRY_PICK_HEAD',
    'REVERT_HEAD',
    'rebase-merge',
    'rebase-apply',
  ];

  // ...........................................................................
  /// The status of [repos]; the missing repos only with [findMissing].
  Future<TicketRefsStatus> _check({
    required Directory ticketDir,
    required List<Node> repos,
    required bool findMissing,
  }) async {
    final unlocalized = <String, List<UnlocalizedRef>>{};
    for (final repo in repos) {
      final refs = await _refsCheck.get(
        directory: repo.directory,
        ggLog: _quiet,
      );
      if (refs.isNotEmpty) {
        unlocalized[repo.directory.path] = refs;
      }
    }
    return TicketRefsStatus(
      unlocalized: unlocalized,
      missingRepos: findMissing
          ? await _missingRepos(ticketDir)
          : const <String>[],
    );
  }

  // ...........................................................................
  /// Localizes [repos]; a failed install is logged to [installErrorLog].
  Future<void> _localize({
    required List<Node> repos,
    required GgLog ggLog,
    required GgLog installErrorLog,
    bool upgrade = false,
  }) async {
    for (final repo in repos) {
      final dir = repo.directory;
      final repoName = path.basename(dir.path);
      try {
        await _backupPublishTo.get(directory: dir, ggLog: ggLog);
        await _changeRefsToLocal.get(directory: dir, ggLog: ggLog);
      } catch (e) {
        ggLog(cError('Failed to localize refs for $repoName: $e'));
        throw Exception(cError('Failed to localize the refs of $repoName'));
      }

      await installRepoDependencies(
        dir: dir,
        repoName: repoName,
        ggLog: ggLog,
        processRunner: _processRunner,
        upgradeDart: upgrade,
        errorLog: installErrorLog,
      );
    }
  }

  // ...........................................................................
  /// The ocean repos between the repos of [ticketDir] in the ticket-shadowed
  /// graph. Nothing without an ocean or when the ocean graph is broken.
  Future<List<String>> _missingRepos(Directory ticketDir) async {
    final ticketPath = path.absolute(ticketDir.path);
    final oceanPath = WorkspaceUtils.defaultOceanWorkspacePath(
      workingDir: ticketPath,
    );
    if (!Directory(oceanPath).existsSync()) {
      return const <String>[];
    }

    final Map<String, Node> roots;
    try {
      roots = await _graph.get(
        directory: Directory(oceanPath),
        ggLog: _quiet,
        packageDirs: graphPackageDirs(
          oceanPath: oceanPath,
          ticketPath: ticketPath,
        ).dirs,
      );
    } catch (_) {
      // A cycle among unrelated ocean repos must not block the ticket.
      return const <String>[];
    }

    bool inTicket(Node node) => path.isWithin(ticketPath, node.directory.path);
    final nodes = <Node>{};
    final dependents = <Node, List<Node>>{};
    void collect(Node node) {
      if (!nodes.add(node)) {
        return;
      }
      for (final dep in _regularDependencies(node)) {
        (dependents[dep] ??= <Node>[]).add(node);
      }
      node.dependencies.values.forEach(collect);
    }

    roots.values.forEach(collect);
    final ticketNodes = nodes.where(inTicket).toList();
    final below = _reachable(ticketNodes, _regularDependencies);
    final above = _reachable(ticketNodes, (n) => dependents[n] ?? const []);
    return [
      for (final node in below.intersection(above))
        if (!inTicket(node)) path.basename(node.directory.path),
    ]..sort();
  }

  // ...........................................................................
  /// The dependencies of [node] pub resolves for a dependent: no dev ones.
  static Iterable<Node> _regularDependencies(Node node) => [
    for (final MapEntry(:key, :value) in node.dependencies.entries)
      if (!node.devOnlyDependencies.contains(key)) value,
  ];

  // ...........................................................................
  /// The nodes reachable from [starts] along [next], the starts included.
  static Set<Node> _reachable(
    List<Node> starts,
    Iterable<Node> Function(Node) next,
  ) {
    final seen = <Node>{...starts};
    final queue = <Node>[...starts];
    while (queue.isNotEmpty) {
      for (final node in next(queue.removeLast())) {
        if (seen.add(node)) {
          queue.add(node);
        }
      }
    }
    return seen;
  }

  // ...........................................................................
  /// Warns about [missingRepos] with the command adding them. Advisory: the
  /// ocean is not refreshed and can be stale.
  void _warnMissingRepos(List<String> missingRepos, GgLog ggLog) {
    if (missingRepos.isEmpty) {
      return;
    }
    ggLog(cWarn('\n⚠️ Repos between the ticket repos, but not in it:'));
    for (final name in missingRepos) {
      ggLog(cWarn('  - $name'));
    }
    ggLog(
      cAction('Run ') +
          cCmd('gg do add ${missingRepos.join(' ')}') +
          cAction(' to add them.\n'),
    );
  }

  // ...........................................................................
  /// The paths `git status` reports dirty in [dir]; a rename gives both.
  Future<Set<String>> _dirtyPaths(Directory dir) async => <String>{
    for (final entry in await _gitStatus.get(directory: dir, ggLog: _quiet))
      ...entry.paths,
  };

  // ...........................................................................
  /// Whether the recorded `doCommit` state of [dir] matches its tree; an
  /// unreadable one (e.g. git's EOL conversion still off) does not.
  Future<bool> _wasCommitted(Directory dir) async {
    try {
      return await _ggState.readSuccess(
        directory: dir,
        key: gg.GgState.doCommitKey,
        ggLog: _quiet,
      );
    } catch (_) {
      return false;
    }
  }

  // ...........................................................................
  /// Commits the gg changes of [dir] against [before] and records the
  /// `doCommit` state when nothing else is left and it may be recorded.
  Future<void> _commitRepo({
    required Directory dir,
    required RepoBaseline? before,
    required GgLog ggLog,
    required String message,
    required bool recordState,
  }) async {
    final dirtyBefore = before?.dirtyPaths ?? const <String>{};
    final entries = await _gitStatus.get(directory: dir, ggLog: ggLog);
    final ggEntries = entries
        .where((e) => _isGgChange(e, dirtyBefore))
        .toList();
    if (ggEntries.isEmpty) {
      return;
    }

    // Unchecked work must not look checked just because gg committed.
    final mayRecord = recordState || (before?.wasCommitted ?? false);
    await _systemCommit.commit(
      directory: dir,
      ggLog: ggLog,
      message: message,
      paths: [for (final entry in ggEntries) ...entry.paths],
      keepForeignChanges: true,
      stateKey: mayRecord && ggEntries.length == entries.length
          ? gg.GgState.doCommitKey
          : null,
    );
  }

  // ...........................................................................
  /// Whether [entry] is a change gg made, judged against [dirtyBefore].
  bool _isGgChange(GitStatusEntry entry, Set<String> dirtyBefore) =>
      entry.paths.every(
        (p) =>
            gg.isGgOwnedPath(p) && (!dirtyBefore.contains(p) || _isGgOutput(p)),
      );

  // ...........................................................................
  /// Whether gg alone writes [repoPath]: lock files and anything in `.gg/`.
  bool _isGgOutput(String repoPath) {
    final segments = repoPath.split('/');
    return segments.contains(gg.ggDirName) ||
        gg_lang.allLockFileNames.contains(segments.last);
  }

  // ...........................................................................
  /// Whether [dir] is a git checkout: a `.git` file (worktree) or a `.git`
  /// folder with a `HEAD`.
  bool _isGitRepo(Directory dir) =>
      File(path.join(dir.path, '.git')).existsSync() ||
      File(path.join(dir.path, '.git', 'HEAD')).existsSync();

  // ...........................................................................
  /// Whether git refuses a partial commit in [dir] (merge, rebase, …).
  Future<bool> _isPartialCommitBlocked(Directory dir) async {
    final result = await Process.run('git', [
      'rev-parse',
      '--git-dir',
    ], workingDirectory: dir.path);
    final gitDir = path.join(dir.path, result.stdout.toString().trim());
    return _partialCommitBlockers.any(
      (name) =>
          FileSystemEntity.typeSync(path.join(gitDir, name)) !=
          FileSystemEntityType.notFound,
    );
  }
}

/// Mocktail mock
class MockTicketLocalizer extends mocktail.Mock implements TicketLocalizer {}

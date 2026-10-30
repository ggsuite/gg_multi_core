// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_log/gg_log.dart';
import 'package:mocktail/mocktail.dart' as mocktail;
import 'package:path/path.dart' as path;

import 'package:gg_multi_core/src/backend/graph_package_dirs.dart';
import 'package:gg_multi_core/src/backend/organization_repo_lists.dart';

/// Finds the ocean repos a ticket lacks between its repos.
///
/// A repo M lies between when a ticket repo depends on it and it depends on a
/// ticket repo — following **regular** dependencies only: a dev dependency
/// never reaches the dependents of a package, so a release cannot strand it.
///
/// Such a repo matters only when the release below it **breaks**: then its
/// published constraint cannot take the new version, and a ticket repo above
/// it would resolve two incompatible versions. Any other release fits the
/// caret constraint it already has. [find] therefore asks about the repos
/// above the ticket repos in `from` — the ones whose release breaks — and only
/// a missing `from` asks about every ticket repo, as `gg do add transitive`
/// without `for` does.
///
/// Two walks over the graph decide it, the repos above `from` and the repos
/// below the ticket — no path is enumerated. The walk upwards stops at a
/// ticket repo that is not in `from`: its own release fits the constraints of
/// the repos above it, and it is released with the new version itself.
class ReposBetween {
  /// Constructor.
  ReposBetween({required GgLog ggLog, Graph? graph})
    : _graph = graph ?? Graph(ggLog: ggLog);

  final Graph _graph;

  // ...........................................................................
  /// The folder names of the ocean repos between the repos of [ticketPath]
  /// and those named in [from], sorted; every ticket repo counts when [from]
  /// is null. In the ticket-shadowed graph: a dependency only the ticket
  /// declares counts.
  ///
  /// `error` says why the ocean graph does not build; the names are empty
  /// then — a cycle among unrelated ocean repos must not block the ticket.
  Future<({List<String> names, String? error})> find({
    required String ticketPath,
    required String oceanPath,
    Set<String>? from,
  }) async {
    if (from != null && from.isEmpty) {
      return (names: const <String>[], error: null);
    }

    final Map<String, Node> roots;
    try {
      roots = await _graph.get(
        directory: Directory(oceanPath),
        // What the graph notes on the way is dropped; its errors returned.
        ggLog: (_) {},
        packageDirs: graphPackageDirs(
          oceanPath: oceanPath,
          ticketPath: ticketPath,
        ).dirs,
      );
    } catch (e) {
      return (names: const <String>[], error: plainError(e));
    }

    return (
      names: _namesIn(roots, ticketPath: ticketPath, from: from),
      error: null,
    );
  }

  // ...........................................................................
  /// What [find] answers for the graph of [roots].
  static List<String> _namesIn(
    Map<String, Node> roots, {
    required String ticketPath,
    Set<String>? from,
  }) {
    bool inTicket(Node node) => path.isWithin(ticketPath, node.directory.path);
    String folder(Node node) => path.basename(node.directory.path);

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
    bool releases(Node node) => from == null || from.contains(folder(node));
    final fromNodes = ticketNodes.where(releases).toList();

    final below = _reachable(ticketNodes, _regularDependencies);
    final above = _reachable(
      fromNodes,
      (n) => !inTicket(n) || releases(n) ? dependents[n] ?? const [] : const [],
    );
    return [
      for (final node in below.intersection(above))
        if (!inTicket(node)) folder(node),
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
}

// .............................................................................
/// Mock for [ReposBetween].
class MockReposBetween extends mocktail.Mock implements ReposBetween {}

// .............................................................................
/// Adds to the ticket in [ticketDir] the ocean repos between its repos and
/// the [releases] — what `gg do add transitive for <releases>` does — and
/// returns the folder names it added, sorted.
///
/// `gg do review` calls it for the repos whose release breaks. The command
/// lives in gg_multi_workspace, which gg_multi_commit does not depend on, so
/// gg_multi hands it over.
typedef AddReposBetween = Future<List<String>> Function({
  required Directory ticketDir,
  required Set<String> releases,
  required GgLog ggLog,
});

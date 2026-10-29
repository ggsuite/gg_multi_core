// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_multi_core/src/backend/graph_package_dirs.dart';
import 'package:gg_multi_core/src/backend/organization.dart';
import 'package:gg_multi_core/src/backend/organization_repo_lists.dart';
import 'package:gg_multi_core/src/backend/organization_utils.dart';
import 'package:gg_multi_core/src/backend/repo_folder_resolver.dart';
import 'package:gg_multi_core/src/backend/repository.dart';
import 'package:path/path.dart' as path;
import 'package:pubspec_parse/pubspec_parse.dart';

/// A repository of a known organization that a manifest depends on.
class OrganizationRepo {
  /// Constructor.
  const OrganizationRepo({required this.organization, required this.repo});

  /// The organization that offers [repo].
  final Organization organization;

  /// The repository as the platform lists it.
  final Repository repo;
}

/// A dependency the ocean lacks although a known organization offers it.
class MissingOceanRepo {
  /// Constructor.
  const MissingOceanRepo({
    required this.dependency,
    required this.manifestPath,
    required this.owners,
  });

  /// The dependency as the manifest writes it, e.g. `@tssuite/base-dna`.
  final String dependency;

  /// Absolute path of the first `pubspec.yaml` / `package.json` declaring it.
  final String manifestPath;

  /// The organizations offering a repository of that name, never empty.
  final List<OrganizationRepo> owners;

  /// The repository name under which the platform lists it.
  String get repoName => owners.first.repo.name;
}

/// What [MissingOceanRepos.find] found.
class MissingOceanReposReport {
  /// Constructor.
  const MissingOceanReposReport({
    this.missing = const <MissingOceanRepo>[],
    this.unchecked = const <Organization>[],
  });

  /// The dependencies to clone into the ocean, sorted by repository name.
  final List<MissingOceanRepo> missing;

  /// The organizations whose repositories could not be listed: a dependency
  /// they own cannot be told from a third-party package.
  final List<Organization> unchecked;
}

/// Finds the repositories the ticket depends on that a known organization
/// offers but the ocean does not hold.
///
/// The dependency graph `do add`, the localize checks and `do publish` reason
/// with is built from the ocean and the ticket. A repository missing from both
/// is invisible to it — and so is every path through it: a repo between two
/// ticket repos is then neither added nor reported, and the publish breaks
/// over versions it could not plan for.
///
/// Whether a dependency is a repository of the organization is decided by the
/// repository lists the platforms report ([OrganizationRepoLists]), not by
/// registry metadata: a package that is not published yet, or whose
/// `repository` field points elsewhere, is still found by its name.
class MissingOceanRepos {
  /// Constructor. [repoLists] lists the repositories of the organizations;
  /// share one instance per run so each organization is listed once.
  MissingOceanRepos({OrganizationRepoLists? repoLists})
    // coverage:ignore-start
    : _repoLists = repoLists ?? OrganizationRepoLists();
  // coverage:ignore-end

  // ...........................................................................
  /// The regular dependencies of the repos of [ticketPath] and of [roots],
  /// followed transitively through the ocean, that no repo of the ocean or
  /// the ticket provides but a known organization of [oceanPath] offers.
  ///
  /// Only regular dependencies count — the ones a dependent resolves, and so
  /// the only ones that can put a repo between two ticket repos. Asks the
  /// platforms only when a dependency is unresolved and an organization is
  /// known; without `.organizations` nothing leaves the machine.
  Future<MissingOceanReposReport> find({
    required String oceanPath,
    String? ticketPath,
    Iterable<Directory> roots = const <Directory>[],
  }) async {
    final orgs = OrganizationUtils.readOrganizations(oceanPath);
    if (orgs.isEmpty) {
      return const MissingOceanReposReport();
    }

    final orgNames = orgs.map((o) => o.name.toLowerCase()).toSet();
    final unresolved = _unresolvedDependencies(
      oceanPath: oceanPath,
      ticketPath: ticketPath,
      roots: roots,
      orgNames: orgNames,
    );
    if (unresolved.isEmpty) {
      return const MissingOceanReposReport();
    }

    final lists = await Future.wait(orgs.map(_repoLists.reposOf));
    final unchecked = <Organization>[
      for (var i = 0; i < orgs.length; i++)
        if (lists[i] == null) orgs[i],
    ];

    final missing = <MissingOceanRepo>[];
    for (final MapEntry(key: dependency, value: manifestPath)
        in unresolved.entries) {
      final repoName = _repoNameOf(dependency, orgNames);
      if (repoName == null) {
        continue;
      }
      final owners = <OrganizationRepo>[
        for (var i = 0; i < orgs.length; i++)
          for (final repo in lists[i] ?? const <Repository>[])
            if (_normalize(repo.name) == repoName)
              OrganizationRepo(organization: orgs[i], repo: repo),
      ];
      if (owners.isNotEmpty) {
        missing.add(
          MissingOceanRepo(
            dependency: dependency,
            manifestPath: manifestPath,
            owners: owners,
          ),
        );
      }
    }

    missing.sort((a, b) => a.repoName.compareTo(b.repoName));
    return MissingOceanReposReport(missing: missing, unchecked: unchecked);
  }

  // ######################
  // Private
  // ######################

  final OrganizationRepoLists _repoLists;

  // ...........................................................................
  /// The dependencies reachable from the ticket repos and [roots] that no repo
  /// provides, each with the first manifest declaring it.
  static Map<String, String> _unresolvedDependencies({
    required String oceanPath,
    required String? ticketPath,
    required Iterable<Directory> roots,
    required Set<String> orgNames,
  }) {
    // The ticket's checkouts shadow their ocean copies, as in the graph.
    final dirs = graphPackageDirs(
      oceanPath: oceanPath,
      ticketPath: ticketPath,
    ).dirs;
    final byName = <String, Directory>{};
    for (final dir in dirs) {
      for (final name in {
        path.basename(dir.path),
        ...RepoFolderResolver.packageNames(dir),
      }) {
        byName.putIfAbsent(_normalize(name), () => dir);
      }
    }

    final starts = <Directory>[
      if (ticketPath != null) ...RepoFolderResolver.repoDirs(ticketPath),
      for (final root in roots)
        byName[_normalize(path.basename(root.path))] ?? root,
    ];

    final unresolved = <String, String>{};
    final visited = <String>{};
    final queue = <Directory>[...starts];
    while (queue.isNotEmpty) {
      final dir = queue.removeLast();
      if (!visited.add(path.normalize(dir.path))) {
        continue;
      }
      for (final (:name, :manifestPath) in _regularDependencies(dir)) {
        // The scope is dropped only for an organization's own packages:
        // `@babel/core` is not the ocean's repo `core`.
        final provider =
            byName[_normalize(name)] ??
            (_hasOrgScope(name, orgNames)
                ? byName[_normalize(_bareName(name))]
                : null);
        if (provider != null) {
          queue.add(provider);
        } else {
          unresolved.putIfAbsent(name, () => manifestPath);
        }
      }
    }
    return unresolved;
  }

  // ...........................................................................
  /// The regular dependencies the manifests of [dir] declare: `dependencies`
  /// of `pubspec.yaml` (without SDK and path ones) and of `package.json`.
  static List<({String name, String manifestPath})> _regularDependencies(
    Directory dir,
  ) {
    final result = <({String name, String manifestPath})>[];

    final pubspecFile = File(path.join(dir.path, 'pubspec.yaml'));
    if (pubspecFile.existsSync()) {
      try {
        final pubspec = Pubspec.parse(
          pubspecFile.readAsStringSync(),
          lenient: true,
        );
        for (final MapEntry(:key, :value) in pubspec.dependencies.entries) {
          if (value is SdkDependency || value is PathDependency) {
            continue;
          }
          result.add((name: key, manifestPath: pubspecFile.path));
        }
      } catch (_) {
        // An unparseable manifest declares nothing that could be checked.
      }
    }

    final packageJsonFile = File(path.join(dir.path, 'package.json'));
    if (packageJsonFile.existsSync()) {
      try {
        final json = jsonDecode(packageJsonFile.readAsStringSync());
        final deps = json is Map<String, dynamic> ? json['dependencies'] : null;
        if (deps is Map<String, dynamic>) {
          for (final name in deps.keys) {
            result.add((name: name, manifestPath: packageJsonFile.path));
          }
        }
      } catch (_) {
        // See above.
      }
    }

    return result;
  }

  // ...........................................................................
  /// The normalized repository name [dependency] can stand for, or null when
  /// it cannot be one of the organizations' repositories: a scoped npm
  /// package (`@types/node`) only maps to a repository when its scope names a
  /// known organization.
  static String? _repoNameOf(String dependency, Set<String> orgNames) {
    if (dependency.startsWith('@') && !_hasOrgScope(dependency, orgNames)) {
      return null;
    }
    return _normalize(_bareName(dependency));
  }

  // ...........................................................................
  /// Whether [name] is an npm package `@<scope>/<name>` whose scope is one of
  /// [orgNames].
  static bool _hasOrgScope(String name, Set<String> orgNames) {
    if (!name.startsWith('@')) {
      return false;
    }
    final slash = name.indexOf('/');
    if (slash <= 1 || slash == name.length - 1) {
      return false;
    }
    return orgNames.contains(name.substring(1, slash).toLowerCase());
  }

  // ...........................................................................
  /// [name] without an npm scope.
  static String _bareName(String name) =>
      name.startsWith('@') && name.contains('/') ? name.split('/').last : name;

  // ...........................................................................
  /// Compares names the way the ecosystems treat them as one: case-insensitive,
  /// and a Dart package `gg_bridge` stands for the repository `gg-bridge`.
  static String _normalize(String name) =>
      name.toLowerCase().replaceAll('-', '_');
}

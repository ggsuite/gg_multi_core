// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gg_multi_core/src/backend/graph_package_dirs.dart';
import 'package:gg_multi_core/src/backend/organization.dart';
import 'package:gg_multi_core/src/backend/organization_repo_lists.dart';
import 'package:gg_multi_core/src/backend/organization_utils.dart';
import 'package:gg_multi_core/src/backend/repo_folder_resolver.dart';
import 'package:gg_multi_core/src/backend/repository.dart';
import 'package:gg_multi_core/src/backend/url_parser.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:yaml/yaml.dart';

/// Answers whether pub.dev hosts [package]: true or false, null when pub.dev
/// could not be asked.
typedef PubDevPackageExists = Future<bool?> Function(String package);

/// Asks the pub.dev API whether it hosts [package]; null when it does not
/// answer within five seconds or answers with anything but 200 or 404.
/// [get] replaces the request in tests.
Future<bool?> pubDevPackageExists(
  String package, {
  Future<http.Response> Function(Uri url) get = http.get,
}) async {
  try {
    final response = await get(
      Uri.parse('https://pub.dev/api/packages/$package'),
    ).timeout(const Duration(seconds: 5));
    return switch (response.statusCode) {
      200 => true,
      404 => false,
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

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

/// Why a dependency counts as one gg cannot see.
enum InaccessibleReason {
  /// A hosted Dart dependency pub.dev does not know: no third-party package,
  /// and no repository an organization lists either.
  notOnPubDev,

  /// A git dependency whose url points into a known organization that does
  /// not list the repository.
  gitUrlOfOrganization,

  /// An npm package scoped with a known organization that does not list the
  /// repository.
  organizationScope,
}

/// A dependency that is neither in the ocean nor a third-party package, and
/// that no organization lists — most likely a private repository the account
/// cannot see.
class InaccessibleDependency {
  /// Constructor.
  const InaccessibleDependency({
    required this.dependency,
    required this.manifestPath,
    required this.repoName,
    required this.reason,
    required this.organizations,
  });

  /// The dependency as the manifest writes it.
  final String dependency;

  /// Absolute path of the first manifest declaring it.
  final String manifestPath;

  /// The repository name it most likely has.
  final String repoName;

  /// What makes it look like a repository of an organization.
  final InaccessibleReason reason;

  /// The organizations it most likely belongs to: the one its url or scope
  /// names, else every organization that was listed.
  final List<Organization> organizations;
}

/// What [MissingOceanRepos.find] found.
class MissingOceanReposReport {
  /// Constructor.
  const MissingOceanReposReport({
    this.missing = const <MissingOceanRepo>[],
    this.unchecked = const <Organization>[],
    this.failures = const <String, String>{},
    this.inaccessible = const <InaccessibleDependency>[],
  });

  /// The dependencies to clone into the ocean, sorted by repository name.
  final List<MissingOceanRepo> missing;

  /// The organizations whose repositories could not be listed: a dependency
  /// they own cannot be told from a third-party package.
  final List<Organization> unchecked;

  /// Why each organization of [unchecked] could not be listed, by its name.
  final Map<String, String> failures;

  /// Why [org] could not be listed, as [failures] records it.
  String failureOf(Organization org) => failures[org.name] ?? 'no reason given';

  /// Dependencies that look like repositories of an organization the account
  /// cannot see, sorted by dependency.
  final List<InaccessibleDependency> inaccessible;
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
///
/// A list only names what the account may see, so a private repository it
/// has no access to is missing from it. Such a dependency is reported as
/// [InaccessibleDependency] when nothing else explains it.
class MissingOceanRepos {
  /// Constructor. [repoLists] lists the repositories of the organizations;
  /// share one instance per run so each organization is listed once.
  /// [pubDevPackageExists] asks pub.dev about a package no lock file knows.
  MissingOceanRepos({
    OrganizationRepoLists? repoLists,
    PubDevPackageExists? pubDevPackageExists,
    // coverage:ignore-start
  }) : _repoLists = repoLists ?? OrganizationRepoLists(),
       _pubDevPackageExists =
           pubDevPackageExists ?? _defaultPubDevPackageExists;
  // coverage:ignore-end

  // ...........................................................................
  /// The regular dependencies of the repos of [ticketPath] and of [roots],
  /// followed transitively through the ocean, that no repo of the ocean or
  /// the ticket provides but a known organization of [oceanPath] offers.
  ///
  /// Only regular dependencies count — the ones a dependent resolves, and so
  /// the only ones that can put a repo between two ticket repos. Asks the
  /// platforms only when a dependency is unresolved and an organization is
  /// known; without `.organizations` nothing leaves the machine. pub.dev is
  /// asked only about a hosted dependency no `pubspec.lock` of the walked
  /// repos resolved from it, once per package and instance.
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
    final walk = _walk(
      oceanPath: oceanPath,
      ticketPath: ticketPath,
      roots: roots,
      orgNames: orgNames,
    );
    if (walk.unresolved.isEmpty) {
      return const MissingOceanReposReport();
    }

    final lists = await Future.wait(orgs.map(_repoLists.reposOf));
    final unchecked = <Organization>[
      for (var i = 0; i < orgs.length; i++)
        if (lists[i] == null) orgs[i],
    ];
    final listed = <Organization>[
      for (var i = 0; i < orgs.length; i++)
        if (lists[i] != null) orgs[i],
    ];
    List<Repository>? listOf(Organization org) => lists[orgs.indexOf(org)];
    Organization? orgNamed(String? name) {
      final wanted = name?.toLowerCase();
      return orgs.where((o) => o.name.toLowerCase() == wanted).firstOrNull;
    }

    final missing = <MissingOceanRepo>[];
    final inaccessible = <InaccessibleDependency>[];
    final askPubDev = <String, _Unresolved>{};

    for (final MapEntry(key: dependency, value: info)
        in walk.unresolved.entries) {
      final gitTarget = info.gitUrl == null
          ? null
          : const UrlParser().parse(info.gitUrl!);
      final candidate = gitTarget?.repo ?? dependency;
      final repoName = _repoNameOf(candidate, orgNames);

      if (repoName != null) {
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
              manifestPath: info.manifestPath,
              owners: owners,
            ),
          );
          continue;
        }
      }

      // No organization lists it. Whatever names an organization it belongs
      // to is a repository the account cannot see; a list that could not be
      // fetched proves nothing, its organization is reported as unchecked.
      switch (info.kind) {
        case _Kind.git:
          final org = orgNamed(gitTarget?.org);
          if (org != null && listOf(org) != null) {
            inaccessible.add(
              InaccessibleDependency(
                dependency: dependency,
                manifestPath: info.manifestPath,
                repoName: candidate,
                reason: InaccessibleReason.gitUrlOfOrganization,
                organizations: [org],
              ),
            );
          }
        case _Kind.npm:
          final org = _hasOrgScope(dependency, orgNames)
              ? orgNamed(dependency.substring(1, dependency.indexOf('/')))
              : null;
          if (org != null && listOf(org) != null) {
            inaccessible.add(
              InaccessibleDependency(
                dependency: dependency,
                manifestPath: info.manifestPath,
                repoName: _bareName(dependency),
                reason: InaccessibleReason.organizationScope,
                organizations: [org],
              ),
            );
          }
        case _Kind.pubDev:
          if (!walk.lockedFromPubDev.contains(dependency)) {
            askPubDev[dependency] = info;
          }
        case _Kind.otherHosted:
          // A private package server: neither pub.dev nor the lists decide.
          break;
      }
    }

    final names = askPubDev.keys.toList();
    final answers = await Future.wait(names.map(_isOnPubDev));
    for (var i = 0; i < names.length; i++) {
      if (answers[i] == false) {
        inaccessible.add(
          InaccessibleDependency(
            dependency: names[i],
            manifestPath: askPubDev[names[i]]!.manifestPath,
            repoName: names[i],
            reason: InaccessibleReason.notOnPubDev,
            organizations: listed.isEmpty ? orgs : listed,
          ),
        );
      }
    }

    missing.sort((a, b) => a.repoName.compareTo(b.repoName));
    inaccessible.sort((a, b) => a.dependency.compareTo(b.dependency));
    return MissingOceanReposReport(
      missing: missing,
      unchecked: unchecked,
      failures: <String, String>{
        for (final org in unchecked)
          org.name: _repoLists.failureOf(org) ?? 'no reason given',
      },
      inaccessible: inaccessible,
    );
  }

  // ######################
  // Private
  // ######################

  final OrganizationRepoLists _repoLists;
  final PubDevPackageExists _pubDevPackageExists;
  final Map<String, Future<bool?>> _pubDevAnswers = {};

  // coverage:ignore-start
  static Future<bool?> _defaultPubDevPackageExists(String package) =>
      pubDevPackageExists(package);
  // coverage:ignore-end

  // ...........................................................................
  Future<bool?> _isOnPubDev(String package) =>
      _pubDevAnswers.putIfAbsent(package, () => _pubDevPackageExists(package));

  // ...........................................................................
  /// The dependencies reachable from the ticket repos and [roots] that no repo
  /// provides, each with the first manifest declaring it, and the packages
  /// the `pubspec.lock` files of the walked repos resolved from pub.dev.
  static ({Map<String, _Unresolved> unresolved, Set<String> lockedFromPubDev})
  _walk({
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

    final unresolved = <String, _Unresolved>{};
    final lockedFromPubDev = <String>{};
    final visited = <String>{};
    final queue = <Directory>[...starts];
    while (queue.isNotEmpty) {
      final dir = queue.removeLast();
      if (!visited.add(path.normalize(dir.path))) {
        continue;
      }
      lockedFromPubDev.addAll(_lockedFromPubDev(dir));
      for (final (:name, :info) in _regularDependencies(dir)) {
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
          unresolved.putIfAbsent(name, () => info);
        }
      }
    }
    return (unresolved: unresolved, lockedFromPubDev: lockedFromPubDev);
  }

  // ...........................................................................
  /// The regular dependencies the manifests of [dir] declare: `dependencies`
  /// of `pubspec.yaml` (without SDK and path ones) and of `package.json`.
  static List<({String name, _Unresolved info})> _regularDependencies(
    Directory dir,
  ) {
    final result = <({String name, _Unresolved info})>[];

    final pubspecFile = File(path.join(dir.path, 'pubspec.yaml'));
    if (pubspecFile.existsSync()) {
      try {
        final pubspec = Pubspec.parse(
          pubspecFile.readAsStringSync(),
          lenient: true,
        );
        for (final MapEntry(:key, :value) in pubspec.dependencies.entries) {
          final kind = switch (value) {
            GitDependency() => _Kind.git,
            HostedDependency(:final hosted)
                when _isPubDev(hosted?.url?.toString()) =>
              _Kind.pubDev,
            HostedDependency() => _Kind.otherHosted,
            _ => null,
          };
          if (kind == null) {
            continue;
          }
          result.add((
            name: key,
            info: _Unresolved(
              manifestPath: pubspecFile.path,
              kind: kind,
              gitUrl: value is GitDependency ? '${value.url}' : null,
            ),
          ));
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
            result.add((
              name: name,
              info: _Unresolved(
                manifestPath: packageJsonFile.path,
                kind: _Kind.npm,
              ),
            ));
          }
        }
      } catch (_) {
        // See above.
      }
    }

    return result;
  }

  // ...........................................................................
  /// The packages the `pubspec.lock` of [dir] resolved from pub.dev: they
  /// exist there, so pub.dev need not be asked about them.
  static Set<String> _lockedFromPubDev(Directory dir) {
    final lockFile = File(path.join(dir.path, 'pubspec.lock'));
    if (!lockFile.existsSync()) {
      return const <String>{};
    }
    try {
      final lock = loadYaml(lockFile.readAsStringSync());
      final packages = lock is YamlMap ? lock['packages'] : null;
      if (packages is! YamlMap) {
        return const <String>{};
      }
      return <String>{
        for (final MapEntry(:key, :value) in packages.entries)
          if (value is YamlMap &&
              value['source'] == 'hosted' &&
              _isPubDev((value['description'] as YamlMap?)?['url']?.toString()))
            '$key',
      };
    } catch (_) {
      return const <String>{};
    }
  }

  // ...........................................................................
  /// Whether [url] — a `hosted` url, null for the default — is pub.dev.
  static bool _isPubDev(String? url) =>
      url == null ||
      const [
        'https://pub.dev',
        'https://pub.dartlang.org',
      ].contains(url.replaceAll(RegExp(r'/+$'), ''));

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

/// Where an unresolved dependency comes from.
enum _Kind { pubDev, otherHosted, git, npm }

/// An unresolved dependency: the first manifest declaring it and its kind.
class _Unresolved {
  const _Unresolved({
    required this.manifestPath,
    required this.kind,
    this.gitUrl,
  });

  final String manifestPath;
  final _Kind kind;
  final String? gitUrl;
}

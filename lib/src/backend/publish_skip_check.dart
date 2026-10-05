// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

// ignore: lines_longer_than_80_chars
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_parse/pubspec_parse.dart';

import 'package:gg_git/gg_git.dart';
import 'package:gg_multi_core/src/backend/npm_version_range.dart';

/// The outcome of [PublishSkipCheck.get] for one ticket repository.
class PublishSkipDecision {
  /// Constructor.
  const PublishSkipDecision({required this.skip, required this.reason});

  /// Whether publishing the repository can be skipped.
  final bool skip;

  /// Why the repository can be skipped ([skip] is true) or why it has to be
  /// published ([skip] is false).
  final String reason;
}

/// The version constraint a repository publishes for one dependency, together
/// with the dialect it is written in — pub and npm read the same characters
/// differently (see [NpmVersionRange]).
class _PublishedConstraint {
  const _PublishedConstraint(this.constraint, {required this.isNpm});

  final VersionConstraint constraint;

  final bool isNpm;

  /// Whether a consumer resolving this constraint may receive [version].
  bool allows(Version version) => isNpm
      ? NpmVersionRange.allows(constraint, version)
      : constraint.allows(version);

  @override
  String toString() => constraint.toString();
}

/// Decides whether a ticket repository needs to be published at all.
///
/// Many repositories are only part of a ticket because they sit between two
/// changed packages in the dependency chain. Such a pass-through repository
/// does not need a release when
///
/// 1. no dependency published earlier in the run received a version its
///    already-published constraint cannot absorb (i.e. no breaking bump —
///    for versions >= 1.0.0 that is a whole-number/major increase, for 0.x
///    versions the minor position acts as the breaking one), and
/// 2. the repository carries no manual changes — the working tree is clean
///    and every commit this ticket *contributes* is gg's own bookkeeping,
///    which [gg.ContributedCommits] decides for this check and for
///    `gg do commit` alike.
///
/// Every situation that cannot be judged reliably (unknown dependency
/// version, unparsable constraint, missing git history, …) results in
/// »publish« — skipping is only ever chosen when it is provably safe.
class PublishSkipCheck {
  /// Constructor.
  PublishSkipCheck({
    ProcessRunner? processRunner,
    gg.ContributedCommits? contributedCommits,
  }) : _processRunner = processRunner ?? defaultProcessRunner,
       _contributedCommits =
           contributedCommits ??
           gg.ContributedCommits(
             processRunner: processRunner ?? defaultProcessRunner,
           );

  /// Runs the git commands used to inspect the repository history.
  final ProcessRunner _processRunner;

  /// Tells gg's own bookkeeping from manual work in the contributed commits.
  final gg.ContributedCommits _contributedCommits;

  /// Every commit message gg generates itself starts with this prefix.
  @Deprecated('Use ggCommitPrefix from package:gg_git/gg_git.dart')
  static const String ggCommitPrefix = gg.ggCommitPrefix;

  /// Commit subjects gg versions before the »#gg: « prefix created.
  @Deprecated('Use legacyGgCommitMessages from package:gg_git/gg_git.dart')
  static const Set<String> legacyGgCommitMessages = gg.legacyGgCommitMessages;

  /// The files gg's bookkeeping commits legitimately touch.
  ///
  /// Kept as the flat set it always was. The live check uses
  /// [gg.isGgOwnedPath], which additionally matches by basename, knows the
  /// `.gg` directory at any depth and recognizes the generated version
  /// files — use that instead of comparing against this set.
  @Deprecated('Use isGgOwnedPath from package:gg_one/gg_one.dart')
  static final Set<String> ggOwnedFiles = <String>{
    ...gg.ggOwnedFileNames,
    ...gg.ggOwnedRootFiles,
  };

  // ...........................................................................
  /// Returns the skip decision for [repo].
  ///
  /// [refVersions] maps the package names of the repositories processed
  /// earlier in this run to the version they now have (published repos carry
  /// their fresh version, skipped repos their unchanged one).
  Future<PublishSkipDecision> get({
    required Node repo,
    required Map<String, String> refVersions,
  }) async {
    final dependencyReason = _dependencyPublishReason(repo, refVersions);
    if (dependencyReason != null) {
      return PublishSkipDecision(skip: false, reason: dependencyReason);
    }

    final manualChangeReason = await _manualChangeReason(repo.directory);
    if (manualChangeReason != null) {
      return PublishSkipDecision(skip: false, reason: manualChangeReason);
    }

    return const PublishSkipDecision(
      skip: true,
      reason: 'Nothing changed. Skip publishing.',
    );
  }

  // ######################
  // Private
  // ######################

  // ...........................................................................
  /// Returns why a dependency forces a publish of [repo], or null when every
  /// dependency's new version is still covered by the constraint the
  /// repository publishes.
  String? _dependencyPublishReason(Node repo, Map<String, String> refVersions) {
    final regularDeps = _regularDependencyNames(repo.directory);
    final constraints = _declaredConstraints(repo.directory, regularDeps);

    for (final dep in repo.dependencies.values) {
      final names = <String>{dep.name, ...dep.aliases};
      final declaredNames = names.intersection(regularDeps);
      if (declaredNames.isEmpty) {
        // A dev-only dependency is invisible to consumers of the published
        // package, so its version never forces a release.
        continue;
      }

      final newVersionString = _newVersionOf(dep, refVersions);
      if (newVersionString == null) {
        return 'the version of dependency »${dep.name}« is unknown';
      }

      final Version newVersion;
      try {
        newVersion = Version.parse(newVersionString);
      } on FormatException {
        return 'the version »$newVersionString« of dependency '
            '»${dep.name}« is not a valid semver version';
      }

      for (final name in declaredNames) {
        final constraint = constraints[name];
        if (constraint == null) {
          return 'no version constraint for dependency »$name« '
              'could be determined';
        }
        if (!constraint.allows(newVersion)) {
          return 'dependency »$name« moved to $newVersion which is '
              'outside the published constraint »$constraint«';
        }
      }
    }

    return null;
  }

  // ...........................................................................
  /// Returns the new version of [dep] captured earlier in the run, looked up
  /// under any of its names (Dart name, npm name, directory name).
  String? _newVersionOf(Node dep, Map<String, String> refVersions) {
    for (final name in <String>{dep.name, ...dep.aliases}) {
      final version = refVersions[name];
      if (version != null) {
        return version;
      }
    }
    return null;
  }

  // ...........................................................................
  /// The names of the *regular* dependencies of the repo in [repoDir] —
  /// `dependencies` of pubspec.yaml plus `dependencies` of package.json.
  /// Dev dependencies are excluded on purpose: registries ignore them when
  /// resolving consumers of the published package.
  Set<String> _regularDependencyNames(Directory repoDir) {
    final result = _npmDependencyNames(repoDir);

    final pubspec = _parsedPubspec(repoDir);
    if (pubspec != null) {
      result.addAll(pubspec.dependencies.keys);
    }

    return result;
  }

  // ...........................................................................
  /// The version constraints [repoDir] publishes for [names].
  ///
  /// The specs backed up by gg_localize_refs come first — they hold the
  /// original refs while the manifest may be localized to path/git refs.
  /// A name without a backup entry, or with one that carries no version
  /// constraint, falls back to the constraint currently declared in the
  /// manifest. The second case is the rule for pnpm-managed TypeScript:
  /// its refs are redirected through the overrides of pnpm-workspace.yaml,
  /// so package.json keeps the published range the whole time, while a
  /// backup — if there is one at all — may hold nothing but a `link:` ref.
  /// A null value means the constraint could not be determined.
  Map<String, _PublishedConstraint?> _declaredConstraints(
    Directory repoDir,
    Set<String> names,
  ) {
    final manifest = _manifestConstraints(repoDir);
    final saved = _savedDependencySpecs(repoDir);
    final npmNames = _npmDependencyNames(repoDir);

    final result = <String, _PublishedConstraint?>{};
    for (final name in names) {
      final isNpm = npmNames.contains(name);
      final constraint =
          _constraintFromSpec(saved[name], isNpm: isNpm) ?? manifest[name];
      result[name] = constraint == null
          ? null
          : _PublishedConstraint(constraint, isNpm: isNpm);
    }
    return result;
  }

  // ...........................................................................
  /// The names [repoDir] declares as regular dependencies in package.json.
  /// Their constraints are npm ranges, whichever file they are read from.
  Set<String> _npmDependencyNames(Directory repoDir) {
    final npmDeps = _parsedPackageJson(repoDir)?['dependencies'];
    return npmDeps is Map<String, dynamic> ? npmDeps.keys.toSet() : <String>{};
  }

  // ...........................................................................
  /// The version constraints currently declared in the manifests of
  /// [repoDir]. Localized refs (path/git) yield no entry.
  Map<String, VersionConstraint> _manifestConstraints(Directory repoDir) {
    final result = <String, VersionConstraint>{};

    final pubspec = _parsedPubspec(repoDir);
    if (pubspec != null) {
      for (final entry in pubspec.dependencies.entries) {
        final dependency = entry.value;
        if (dependency is HostedDependency) {
          result[entry.key] = dependency.version;
        }
      }
    }

    final packageJson = _parsedPackageJson(repoDir);
    final npmDeps = packageJson?['dependencies'];
    if (npmDeps is Map<String, dynamic>) {
      for (final entry in npmDeps.entries) {
        final constraint = NpmVersionRange.tryParse(entry.value?.toString());
        if (constraint != null) {
          result[entry.key] = constraint;
        }
      }
    }

    return result;
  }

  // ...........................................................................
  /// The original dependency specs gg_localize_refs backed up before
  /// localizing the refs of [repoDir].
  ///
  /// Dart writes `.gg/gg_localize_refs_backup_dart.json` and TypeScript
  /// `.gg/gg_localize_refs_backup_ts.json` today. The older spellings — one
  /// shared name inside `.gg`, its hidden predecessor, and the hidden file
  /// TypeScript kept in the repo root — are still read so checkouts made
  /// before the renames keep working. Reading only a legacy name made every
  /// git-localized repo look constraint-less, which forced a publish for
  /// repos that carry nothing but gg's own commits.
  Map<String, dynamic> _savedDependencySpecs(Directory repoDir) {
    final result = <String, dynamic>{};
    final files = [
      File(path.join(repoDir.path, '.gg_localize_refs_backup.json')),
      File(path.join(repoDir.path, '.gg', '.gg_localize_refs_backup.json')),
      File(path.join(repoDir.path, '.gg', 'gg_localize_refs_backup.json')),
      File(path.join(repoDir.path, '.gg', 'gg_localize_refs_backup_dart.json')),
      File(path.join(repoDir.path, '.gg', 'gg_localize_refs_backup_ts.json')),
    ];
    for (final file in files) {
      if (!file.existsSync()) {
        continue;
      }
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map<String, dynamic>) {
          result.addAll(decoded);
        }
      } catch (_) {
        // An unreadable backup contributes nothing; affected dependencies
        // stay undetermined which makes the decision fall back to publish.
      }
    }
    return result;
  }

  // ...........................................................................
  /// Extracts the version constraint from a backed-up dependency [spec] —
  /// either a plain string (`^1.2.3`) or a map carrying a `version` key
  /// (git dependencies). [isNpm] selects the dialect the string is read in.
  /// Returns null when there is none or it is unparsable.
  VersionConstraint? _constraintFromSpec(dynamic spec, {required bool isNpm}) {
    final raw = spec is Map ? spec['version'] : spec;
    if (raw == null) {
      return null;
    }
    return isNpm
        ? NpmVersionRange.tryParse(raw.toString())
        : _tryParseConstraint(raw.toString());
  }

  // ...........................................................................
  /// Parses [raw] as version constraint, returning null when it is not one.
  VersionConstraint? _tryParseConstraint(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      return VersionConstraint.parse(raw.trim());
    } on FormatException {
      return null;
    }
  }

  // ...........................................................................
  /// The parsed pubspec.yaml of [repoDir], or null when absent/unparsable.
  Pubspec? _parsedPubspec(Directory repoDir) {
    final file = File(path.join(repoDir.path, 'pubspec.yaml'));
    if (!file.existsSync()) {
      return null;
    }
    try {
      return Pubspec.parse(file.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  // ...........................................................................
  /// The parsed package.json of [repoDir], or null when absent/unparsable.
  Map<String, dynamic>? _parsedPackageJson(Directory repoDir) {
    final file = File(path.join(repoDir.path, 'package.json'));
    if (!file.existsSync()) {
      return null;
    }
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  // ...........................................................................
  /// Returns why [repoDir] contains manual changes, or null when everything
  /// on top of the last release was generated by gg.
  ///
  /// The working tree is judged here; the commit history by the shared
  /// [gg.ContributedCommits] — `gg do commit` reads the very same answer, so
  /// the command that writes a CHANGELOG entry and the check that reads the
  /// history cannot disagree about what counts as a change. The dependency
  /// half of [get] is not part of that agreement: a repository whose
  /// contributed commits are all bookkeeping can still be forced to publish
  /// by a dependency that outgrew its constraint, and then releases whatever
  /// its »## Unreleased« section holds — nothing, unless someone wrote an
  /// entry with »gg do commit --force«.
  Future<String?> _manualChangeReason(Directory repoDir) async {
    try {
      final status = await _runGit(<String>[
        'status',
        '--porcelain',
      ], repoDir: repoDir);
      // A tree dirty in nothing but lock files carries no manual work: a
      // `pub get` — the Dart VS Code extension fires one whenever a manifest
      // is written — rewrites them behind everybody's back. Treating that as
      // a manual change would publish a repo nobody touched.
      if (status.isNotEmpty && !gg.isLockFileOnlyDrift(status)) {
        return 'the working tree has uncommitted changes';
      }
    } catch (e) {
      // A repository git cannot even report on cannot prove itself unchanged.
      return 'the git history could not be inspected ($e)';
    }

    return _contributedCommits.manualCommitReason(directory: repoDir);
  }

  // ...........................................................................
  /// Runs git with [args] in [repoDir] and returns the trimmed stdout.
  Future<String> _runGit(
    List<String> args, {
    required Directory repoDir,
    bool allowFailure = false,
  }) => runGit(
    _processRunner,
    args,
    repoDir: repoDir,
    allowFailure: allowFailure,
  );
}

/// Mock for [PublishSkipCheck]
class MockPublishSkipCheck extends Mock implements PublishSkipCheck {}

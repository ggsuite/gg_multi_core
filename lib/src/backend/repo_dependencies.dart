// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_git/gg_git.dart';
import 'package:gg_lang/gg_lang.dart' as gg_lang;
import 'package:gg_log/gg_log.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

/// Installs the dependencies of every package manager the repo [dir] uses;
/// [upgradeDart] runs `pub upgrade`, through `flutter` in a Flutter repo.
/// Failures are logged to [errorLog] (default [ggLog]), never thrown.
Future<void> installRepoDependencies({
  required Directory dir,
  required String repoName,
  required GgLog ggLog,
  required ProcessRunner processRunner,
  bool upgradeDart = false,
  GgLog? errorLog,
}) async {
  final commands = <List<String>>[];

  if (File(path.join(dir.path, 'pubspec.yaml')).existsSync()) {
    final isFlutter =
        gg_lang.detectProjectType(dir) == gg_lang.ProjectType.flutter;
    commands.add(<String>[
      isFlutter ? 'flutter' : 'dart',
      'pub',
      upgradeDart ? 'upgrade' : 'get',
    ]);
  }
  if (File(path.join(dir.path, 'package.json')).existsSync()) {
    final pm = gg.detectTypeScriptPackageManager(dir).executable;
    commands.add(<String>[pm, 'install']);
  }

  for (final command in commands) {
    final result = await processRunner(
      command.first,
      command.sublist(1),
      workingDirectory: dir.path,
      runInShell: true,
    );
    final cmd = command.join(' ');
    if (result.exitCode == 0) {
      ggLog(darkGray('Executed $cmd in $repoName.'));
    } else {
      (errorLog ?? ggLog)(
        cError('Failed to execute $cmd in $repoName: ${result.stderr}'),
      );
    }
  }
}

/// Installs the dependencies of every repo of [dirs], like
/// [installRepoDependencies] does for one — several repos at the same time
/// where that is safe, and logs them in the order of [dirs].
///
/// What is safe: Dart repos that resolve from the registry only. Their
/// installs share nothing but the pub cache, which takes a package that two
/// of them download at once. A repo with a git dependency fetches into a
/// git mirror of the pub cache, and two fetches into one mirror fail; a
/// package manager of the JavaScript world is not known to be safe either.
/// Such repos — and all of them with [upgradeDart], which asks every git
/// remote — wait for each other: only one of them installs at a time.
Future<void> installReposDependencies({
  required List<Directory> dirs,
  required GgLog ggLog,
  required ProcessRunner processRunner,
  bool upgradeDart = false,
  GgLog? errorLog,
}) => runInstalls<void>(
  dirs: dirs,
  ggLog: ggLog,
  oneAtATime: upgradeDart,
  install: (dir, ggLog) => installRepoDependencies(
    dir: dir,
    repoName: path.basename(dir.path),
    ggLog: ggLog,
    processRunner: processRunner,
    upgradeDart: upgradeDart,
    // Told apart by the caller, so it keeps its own log.
    errorLog: errorLog ?? ggLog,
  ),
);

/// Runs [install] for every repo of [dirs] and returns the results in their
/// order — several repos at the same time where that is safe, as
/// [installReposDependencies] describes, the others (all of them with
/// [oneAtATime]) one after the other. What an install logs reaches [ggLog]
/// in the order of [dirs].
///
/// When installs throw, the installs already running finish, no further one
/// starts, and the error of the first failed repo in the order of [dirs] is
/// thrown.
Future<List<T>> runInstalls<T>({
  required List<Directory> dirs,
  required GgLog ggLog,
  required Future<T> Function(Directory dir, GgLog ggLog) install,
  bool oneAtATime = false,
}) {
  // The one install at a time: each waits for the one before it.
  var turn = Future<void>.value();

  return gg.runInParallel<T>(
    count: dirs.length,
    // Measured: beyond eight installs at a time they only slow each other
    // down — each one resolves versions, which keeps a processor busy.
    maxParallel: min(gg.GgParallelism.light, 8),
    ggLog: ggLog,
    task: (index, ggLog) async {
      final dir = dirs[index];
      if (!oneAtATime && _installsFromRegistryOnly(dir)) {
        return install(dir, ggLog);
      }

      // Wait for the install before this one, whatever became of it, and
      // let the next one wait for this one.
      final before = turn;
      final done = Completer<void>();
      turn = done.future;
      await before;
      try {
        return await install(dir, ggLog);
      } finally {
        done.complete();
      }
    },
  );
}

/// Whether installing the dependencies of [dir] only reads the registry and
/// the pub cache: a Dart repo that names no git dependency, neither in its
/// manifests nor — for the dependencies of its dependencies — in its lock
/// file. Without a lock file nothing is known about those, so the answer is
/// no; anything unreadable is a no as well.
bool _installsFromRegistryOnly(Directory dir) {
  if (File(path.join(dir.path, 'package.json')).existsSync()) {
    return false;
  }

  final lock = File(path.join(dir.path, 'pubspec.lock'));
  if (!lock.existsSync()) {
    return false;
  }

  try {
    final sources = <String>[
      lock.readAsStringSync(),
      for (final name in const ['pubspec.yaml', 'pubspec_overrides.yaml'])
        if (File(path.join(dir.path, name)).existsSync())
          File(path.join(dir.path, name)).readAsStringSync(),
    ];
    return !sources.any(_mentionsGit.hasMatch);
  } catch (_) {
    return false;
  }
}

/// A git dependency in a manifest (`git:`) or a lock file (`source: git`).
final RegExp _mentionsGit = RegExp(
  r'^\s*(git\s*:|source\s*:\s*git\s*$)',
  multiLine: true,
);

/// Whether the dependencies of the repo [dir] must be installed again before
/// it builds against its checkouts: a package manager it uses never installed
/// them, or the Dart resolution ignores a `path` override of its
/// `pubspec_overrides.yaml` — the `pub get` after localizing failed or never
/// ran.
///
/// Reads files only. A resolution that merely predates an unchanged manifest
/// is not outdated: `pub get` leaves `package_config.json` untouched when
/// nothing changes, so its timestamp cannot tell.
bool repoDependenciesOutdated(Directory dir) {
  if (File(path.join(dir.path, 'pubspec.yaml')).existsSync() &&
      !_dartResolutionUsesPathOverrides(dir)) {
    return true;
  }
  return File(path.join(dir.path, 'package.json')).existsSync() &&
      !Directory(path.join(dir.path, 'node_modules')).existsSync();
}

/// Whether `.dart_tool/package_config.json` of [dir] exists and resolves
/// every `path` override of `pubspec_overrides.yaml` to that path. Anything
/// unreadable counts as not resolved — resolving once too often is cheap.
bool _dartResolutionUsesPathOverrides(Directory dir) {
  final config = File(path.join(dir.path, '.dart_tool', 'package_config.json'));
  if (!config.existsSync()) {
    return false;
  }
  try {
    final packages =
        (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
    // A rootUri is relative to the folder of package_config.json.
    final resolved = <String, String>{
      for (final package in packages.cast<Map<dynamic, dynamic>>())
        package['name'] as String: path.canonicalize(
          config.parent.uri.resolve('${package['rootUri']}').toFilePath(),
        ),
    };
    return _pathOverrides(dir).entries.every(
      (o) => resolved[o.key] == path.canonicalize(path.join(dir.path, o.value)),
    );
  } catch (_) {
    return false;
  }
}

/// The `path` overrides of `pubspec_overrides.yaml` in [dir], by package.
Map<String, String> _pathOverrides(Directory dir) {
  final file = File(path.join(dir.path, 'pubspec_overrides.yaml'));
  if (!file.existsSync()) {
    return const <String, String>{};
  }
  final overrides =
      (loadYaml(file.readAsStringSync()) as Map?)?['dependency_overrides'];
  return <String, String>{
    if (overrides is Map)
      for (final MapEntry(:key, :value) in overrides.entries)
        if (value is Map && value['path'] is String)
          '$key': value['path'] as String,
  };
}

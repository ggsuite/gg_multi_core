// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

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

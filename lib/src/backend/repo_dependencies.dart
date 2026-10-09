// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_git/gg_git.dart';
import 'package:gg_lang/gg_lang.dart' as gg_lang;
import 'package:gg_log/gg_log.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:path/path.dart' as path;

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

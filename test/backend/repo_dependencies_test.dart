// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_git/gg_git.dart';
import 'package:gg_multi_core/src/backend/repo_dependencies.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  final messages = <String>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('repo_dependencies_test');
    messages.clear();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Directory repoWith({bool pubspec = false, bool packageJson = false}) {
    final d = Directory(path.join(tmp.path, 'r'))..createSync(recursive: true);
    if (pubspec) {
      File(path.join(d.path, 'pubspec.yaml')).writeAsStringSync('name: x\n');
    }
    if (packageJson) {
      File(path.join(d.path, 'package.json')).writeAsStringSync('{}');
    }
    return d;
  }

  group('installRepoDependencies', () {
    final calls = <List<String>>[];

    ProcessRunner runner({int exitCode = 0}) =>
        (exe, args, {workingDirectory, runInShell = false, environment}) async {
          calls.add(<String>[exe, ...args]);
          return ProcessResult(0, exitCode, '', 'boom');
        };

    setUp(calls.clear);

    test('runs dart pub get and logs success', () async {
      await installRepoDependencies(
        dir: repoWith(pubspec: true),
        repoName: 'r',
        ggLog: messages.add,
        processRunner: runner(),
      );
      expect(calls, [
        ['dart', 'pub', 'get'],
      ]);
      expect(
        messages.any((m) => m.contains('Executed dart pub get in r.')),
        isTrue,
      );
    });

    test('uses dart pub upgrade when upgradeDart is true', () async {
      await installRepoDependencies(
        dir: repoWith(pubspec: true),
        repoName: 'r',
        ggLog: messages.add,
        processRunner: runner(),
        upgradeDart: true,
      );
      expect(calls, [
        ['dart', 'pub', 'upgrade'],
      ]);
    });

    test('resolves a Flutter repo through flutter', () async {
      final dir = repoWith();
      File(path.join(dir.path, 'pubspec.yaml')).writeAsStringSync(
        'name: x\ndependencies:\n  flutter:\n    sdk: flutter\n',
      );

      for (final upgradeDart in [false, true]) {
        await installRepoDependencies(
          dir: dir,
          repoName: 'r',
          ggLog: messages.add,
          processRunner: runner(),
          upgradeDart: upgradeDart,
        );
      }

      expect(calls, [
        ['flutter', 'pub', 'get'],
        ['flutter', 'pub', 'upgrade'],
      ]);
    });

    test('runs the TypeScript package manager install', () async {
      await installRepoDependencies(
        dir: repoWith(packageJson: true),
        repoName: 'r',
        ggLog: messages.add,
        processRunner: runner(),
      );
      expect(calls.single.last, 'install');
      expect(messages.any((m) => m.contains('install in r.')), isTrue);
    });

    test('logs a failure on a non-zero exit code', () async {
      await installRepoDependencies(
        dir: repoWith(pubspec: true),
        repoName: 'r',
        ggLog: messages.add,
        processRunner: runner(exitCode: 1),
      );
      expect(
        messages.any(
          (m) => m.contains('Failed to execute dart pub get in r: boom'),
        ),
        isTrue,
      );
    });

    test('logs a failure to the errorLog when given', () async {
      final errors = <String>[];
      await installRepoDependencies(
        dir: repoWith(pubspec: true),
        repoName: 'r',
        ggLog: messages.add,
        processRunner: runner(exitCode: 1),
        errorLog: errors.add,
      );
      expect(messages, isEmpty);
      expect(errors.single, contains('Failed to execute dart pub get in r'));
    });

    test('does nothing when neither manifest exists', () async {
      await installRepoDependencies(
        dir: repoWith(),
        repoName: 'r',
        ggLog: messages.add,
        processRunner: runner(),
      );
      expect(calls, isEmpty);
      expect(messages, isEmpty);
    });
  });
}

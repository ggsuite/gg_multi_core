// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_git/gg_git.dart';
import 'package:gg_multi_core/src/backend/repo_dependencies.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

// .............................................................................
/// A process runner whose commands end when the test says so.
class _GatedRunner {
  _GatedRunner({this.exitCode = 0});

  final int exitCode;

  /// The folder names of the commands in the order they were started.
  final List<String> started = [];

  /// The commands in the order they were started.
  final List<List<String>> commands = [];

  final Map<String, Completer<void>> _gates = {};

  Future<ProcessResult> call(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool runInShell = false,
  }) async {
    final repo = path.basename(workingDirectory!);
    started.add(repo);
    commands.add(<String>[executable, ...arguments]);
    await _gate(repo).future;
    return ProcessResult(0, exitCode, '', 'boom');
  }

  /// Lets the commands of [repo] end, also the ones started later.
  void finish(String repo) {
    if (!_gate(repo).isCompleted) {
      _gate(repo).complete();
    }
  }

  Completer<void> _gate(String repo) => _gates[repo] ??= Completer<void>();
}

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

  group('installReposDependencies', () {
    const hostedLock = 'packages:\n  args:\n    source: hosted\n';
    const gitLock = 'packages:\n  x:\n    source: git\n';
    late _GatedRunner runner;

    setUp(() => runner = _GatedRunner());

    /// A Dart repo [name] with the given files; null leaves a file out.
    Directory repo(
      String name, {
      String? lock = hostedLock,
      String pubspec = 'name: x\n',
      String? overrides,
      bool packageJson = false,
    }) {
      final dir = Directory(path.join(tmp.path, name))..createSync();
      void write(String file, String? content) {
        if (content != null) {
          File(path.join(dir.path, file)).writeAsStringSync(content);
        }
      }

      write('pubspec.yaml', pubspec);
      write('pubspec.lock', lock);
      write('pubspec_overrides.yaml', overrides);
      write('package.json', packageJson ? '{}' : null);
      return dir;
    }

    /// Installs [dirs] and returns once every install the runner can start
    /// has started; the installs wait for [_GatedRunner.finish].
    Future<({Future<void> done})> start(
      List<Directory> dirs, {
      bool upgradeDart = false,
      void Function(String)? errorLog,
    }) async {
      final done = installReposDependencies(
        dirs: dirs,
        ggLog: messages.add,
        processRunner: runner.call,
        upgradeDart: upgradeDart,
        errorLog: errorLog,
      );
      await Future<void>.delayed(Duration.zero);
      return (done: done);
    }

    test('does nothing without repos', () async {
      await installReposDependencies(
        dirs: [],
        ggLog: messages.add,
        processRunner: runner.call,
      );
      expect(runner.started, isEmpty);
    });

    test('installs repos that resolve from the registry at the same time, '
        'and logs them in their order', () async {
      final (:done) = await start([repo('a'), repo('b')]);
      expect(runner.started, ['a', 'b']);

      // The second one finishes first; the log keeps the order.
      runner.finish('b');
      runner.finish('a');
      await done;

      expect(messages.map(rmConsoleColors), [
        'Executed dart pub get in a.',
        'Executed dart pub get in b.',
      ]);
    });

    test('installs repos with a git dependency one after the other', () async {
      final (:done) = await start([
        repo('locked', lock: gitLock),
        repo('declared', pubspec: 'dependencies:\n  x:\n    git: url\n'),
        repo(
          'overridden',
          overrides: 'dependency_overrides:\n  x:\n    git:\n      url: u\n',
        ),
      ]);
      expect(runner.started, ['locked']);

      runner.finish('locked');
      await Future<void>.delayed(Duration.zero);
      expect(runner.started, ['locked', 'declared']);

      runner.finish('declared');
      await Future<void>.delayed(Duration.zero);
      expect(runner.started, ['locked', 'declared', 'overridden']);

      runner.finish('overridden');
      await done;
    });

    test('does not let a waiting repo hold up the others', () async {
      final (:done) = await start([
        repo('git1', lock: gitLock),
        repo('git2', lock: gitLock),
        repo('hosted'),
      ]);

      // git2 waits for git1; the registry-only repo does not.
      expect(runner.started, unorderedEquals(['git1', 'hosted']));

      runner
        ..finish('git1')
        ..finish('hosted');
      await Future<void>.delayed(Duration.zero);
      runner.finish('git2');
      await done;
      expect(runner.started.last, 'git2');
    });

    test('takes no chances: a repo without lock file, with a package.json '
        'or with an unreadable manifest waits its turn', () async {
      final unreadable = repo('unreadable');
      File(path.join(unreadable.path, 'pubspec_overrides.yaml'))
          .writeAsBytesSync([0xff, 0xfe, 0xfd]);

      final (:done) = await start([
        repo('unlocked', lock: null),
        repo('typescript', packageJson: true),
        unreadable,
      ]);
      expect(runner.started, ['unlocked']);

      runner.finish('unlocked');
      await Future<void>.delayed(Duration.zero);
      expect(runner.started, ['unlocked', 'typescript']);

      // A repo with both manifests installs twice: pub, then the node side.
      runner.finish('typescript');
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(runner.started, [
        'unlocked',
        'typescript',
        'typescript',
        'unreadable',
      ]);

      runner.finish('unreadable');
      await done;
    });

    test('lets the next repo install after one that threw', () async {
      Future<ProcessResult> throwing(
        String executable,
        List<String> arguments, {
        String? workingDirectory,
        Map<String, String>? environment,
        bool runInShell = false,
      }) {
        if (path.basename(workingDirectory!) == 'broken') {
          throw const ProcessException('dart', ['pub', 'get']);
        }
        return runner.call(
          executable,
          arguments,
          workingDirectory: workingDirectory,
        );
      }

      final done = installReposDependencies(
        dirs: [
          repo('broken', lock: gitLock),
          repo('next', lock: gitLock),
        ],
        ggLog: messages.add,
        processRunner: throwing,
      );
      runner.finish('next');

      await expectLater(done, throwsA(isA<ProcessException>()));
      expect(runner.started, ['next']);
    });

    test('upgrades one repo after the other', () async {
      final (:done) = await start([repo('a'), repo('b')], upgradeDart: true);
      expect(runner.started, ['a']);
      expect(runner.commands.single, ['dart', 'pub', 'upgrade']);

      runner
        ..finish('a')
        ..finish('b');
      await done;
      expect(runner.started, ['a', 'b']);
    });

    test('logs a failed install to the errorLog, or else to ggLog', () async {
      runner = _GatedRunner(exitCode: 1);
      final errors = <String>[];

      var (:done) = await start([repo('a')], errorLog: errors.add);
      runner.finish('a');
      await done;
      expect(errors.single, contains('Failed to execute dart pub get in a'));
      expect(messages, isEmpty);

      (:done) = await start([repo('b')]);
      runner.finish('b');
      await done;
      expect(messages.single, contains('Failed to execute dart pub get in b'));
    });
  });

  group('repoDependenciesOutdated', () {
    /// Writes [content] to [file] below the repo [dir].
    void write(Directory dir, String file, String content) =>
        File(path.join(dir.path, file))
          ..createSync(recursive: true)
          ..writeAsStringSync(content);

    /// A `package_config.json` resolving each of [rootUris] by package.
    String packageConfig(Map<String, String> rootUris) =>
        '{"configVersion": 2, "packages": ['
        '${rootUris.entries.map((e) => '{"name": "${e.key}", '
            '"rootUri": "${e.value}"}').join(', ')}]}';

    const overrides =
        'dependency_overrides:\n'
        '  sib:\n'
        '    path: ../sib\n'
        '  pinned: 1.0.0\n';

    test('is false for a repo without manifests', () {
      expect(repoDependenciesOutdated(repoWith()), isFalse);
    });

    test('is true for a Dart repo pub never resolved', () {
      expect(repoDependenciesOutdated(repoWith(pubspec: true)), isTrue);
    });

    test('is false for a resolved Dart repo without overrides', () {
      final dir = repoWith(pubspec: true);
      write(dir, '.dart_tool/package_config.json', packageConfig({}));

      expect(repoDependenciesOutdated(dir), isFalse);
    });

    test('is false when the resolution uses every path override', () {
      final dir = repoWith(pubspec: true);
      write(dir, 'pubspec_overrides.yaml', overrides);
      write(
        dir,
        '.dart_tool/package_config.json',
        packageConfig({'sib': '../../sib', 'x': '../'}),
      );

      expect(repoDependenciesOutdated(dir), isFalse);
    });

    test('accepts an absolute rootUri', () {
      final dir = repoWith(pubspec: true);
      write(dir, 'pubspec_overrides.yaml', overrides);
      final sib = Uri.directory(path.join(tmp.path, 'sib'));
      write(
        dir,
        '.dart_tool/package_config.json',
        packageConfig({'sib': '$sib'}),
      );

      expect(repoDependenciesOutdated(dir), isFalse);
    });

    test('is true when the resolution ignores a path override', () {
      final dir = repoWith(pubspec: true);
      write(dir, 'pubspec_overrides.yaml', overrides);
      write(
        dir,
        '.dart_tool/package_config.json',
        packageConfig({'sib': 'file:///pub-cache/hosted/sib-1.0.0/'}),
      );

      expect(repoDependenciesOutdated(dir), isTrue);
    });

    test('is true when the resolution lacks an overridden package', () {
      final dir = repoWith(pubspec: true);
      write(dir, 'pubspec_overrides.yaml', overrides);
      write(dir, '.dart_tool/package_config.json', packageConfig({}));

      expect(repoDependenciesOutdated(dir), isTrue);
    });

    test('is true for an unreadable package_config.json', () {
      final dir = repoWith(pubspec: true);
      write(dir, '.dart_tool/package_config.json', 'not json');

      expect(repoDependenciesOutdated(dir), isTrue);
    });

    test('is true for a TypeScript repo without node_modules', () {
      expect(repoDependenciesOutdated(repoWith(packageJson: true)), isTrue);
    });

    test('is false for an installed TypeScript repo', () {
      final dir = repoWith(packageJson: true);
      Directory(path.join(dir.path, 'node_modules')).createSync();

      expect(repoDependenciesOutdated(dir), isFalse);
    });

    test('is true for a bridge repo with only one side installed', () {
      final dir = repoWith(pubspec: true, packageJson: true);
      write(dir, '.dart_tool/package_config.json', packageConfig({}));

      expect(repoDependenciesOutdated(dir), isTrue);
    });
  });
}

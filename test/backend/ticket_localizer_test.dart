// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_localize_refs/gg_localize_refs.dart';
import 'package:gg_multi_core/src/backend/ticket_localizer.dart';
import 'package:gg_one_core/gg_one_core.dart' as gg;
import 'package:gg_process/gg_process.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Directory ticket;
  late Directory ocean;
  late List<List<String>> installs;
  late Set<String> failingInstalls;
  late TicketLocalizer localizer;
  final messages = <String>[];
  void ggLog(String m) => messages.add(rmControls(m));

  // ...........................................................................
  /// Records the install commands instead of resolving against the registry;
  /// the repos in [failingInstalls] fail.
  Future<ProcessResult> fakeRunner(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool runInShell = false,
  }) async {
    final repo = path.basename(workingDirectory!);
    installs.add(<String>[repo, executable, ...arguments]);
    return failingInstalls.contains(repo)
        ? ProcessResult(0, 1, '', 'offline')
        : ProcessResult(0, 0, '', '');
  }

  // ...........................................................................
  /// Runs git in [dir] and returns its trimmed stdout.
  Future<String> git(Directory dir, List<String> args) async {
    final result = await ggRunProcess('git', args, workingDirectory: dir.path);
    if (result.exitCode != 0) {
      throw Exception('git ${args.join(' ')}: ${result.stderr}');
    }
    return result.stdout.toString().trim();
  }

  // ...........................................................................
  /// Writes [content] to [file] below [dir], creating its folders.
  void write(Directory dir, String file, String content) {
    File(path.join(dir.path, file))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  // ...........................................................................
  /// A Dart pubspec of [name] depending on [deps] and [devDeps].
  String pubspec(
    String name, [
    List<String> deps = const <String>[],
    List<String> devDeps = const <String>[],
  ]) {
    final buffer = StringBuffer()
      ..writeln('name: $name')
      ..writeln('version: 1.0.0')
      ..writeln('environment:')
      ..writeln('  sdk: ">=3.0.0 <4.0.0"');
    for (final (section, names) in [
      ('dependencies', deps),
      ('dev_dependencies', devDeps),
    ]) {
      if (names.isNotEmpty) {
        buffer.writeln('$section:');
        for (final dep in names) {
          buffer.writeln('  $dep: ^1.0.0');
        }
      }
    }
    return buffer.toString();
  }

  // ...........................................................................
  /// A ticket repo [name] with [files], committed on main and checked out on
  /// a feature branch, unless [onMain].
  Future<Directory> repo(
    String name,
    Map<String, String> files, {
    bool onMain = false,
  }) async {
    final dir = Directory(path.join(ticket.path, name))..createSync();
    files.forEach((file, content) => write(dir, file, content));
    // gg commits only with git's EOL conversion on.
    write(dir, '.gitattributes', '* text=auto eol=lf');
    await git(dir, ['init', '--initial-branch', 'main']);
    await git(dir, ['config', 'user.email', 'test@example.com']);
    await git(dir, ['config', 'user.name', 'Test']);
    await git(dir, ['add', '.']);
    await git(dir, ['commit', '-m', 'Initial commit']);
    if (!onMain) {
      await git(dir, ['checkout', '-b', 'feat']);
    }
    return dir;
  }

  // ...........................................................................
  /// An ocean repo [name] depending on [deps] and [devDeps]; the ocean
  /// needs no git.
  void oceanRepo(
    String name, [
    List<String> deps = const <String>[],
    List<String> devDeps = const <String>[],
  ]) => write(
    Directory(path.join(ocean.path, 'org', name)),
    'pubspec.yaml',
    pubspec(name, deps, devDeps),
  );

  // ...........................................................................
  /// The ticket repos in dependency order, as gg sorts them.
  Future<List<Node>> nodes() =>
      SortedProcessingList(ggLog: ggLog).get(directory: ticket, ggLog: ggLog);

  // ...........................................................................
  /// The paths `git status` reports for [dir].
  Future<List<String>> status(Directory dir) async {
    final result = await ggRunProcess('git', [
      'status',
      '--porcelain',
      '-uall',
    ], workingDirectory: dir.path);
    return const LineSplitter()
        .convert(result.stdout.toString())
        .map((line) => line.substring(3))
        .toList();
  }

  // ...........................................................................
  /// The overrides file of [dir], or null.
  String? overridesOf(Directory dir) {
    final file = File(path.join(dir.path, 'pubspec_overrides.yaml'));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  // ...........................................................................
  /// Whether the recorded `doCommit` state of [dir] matches its tree.
  Future<bool> committed(Directory dir) => gg.GgState(ggLog: ggLog)
      .readSuccess(directory: dir, key: gg.GgState.doCommitKey, ggLog: ggLog);

  // ...........................................................................
  /// Records the `doCommit` state of [dir], as `gg do commit` does.
  Future<void> recordCommitted(Directory dir) =>
      gg.GgState(ggLog: ggLog)
          .writeSuccess(directory: dir, key: gg.GgState.doCommitKey);

  // ...........................................................................
  /// A ticket {a, b, d}: a depends on b (not localized) and on the ocean's c,
  /// which depends on d — so c is missing between a and d.
  Future<Directory> ticketMissingC() async {
    final a = await repo('a', {
      'pubspec.yaml': pubspec('a', ['b', 'c']),
    });
    await repo('b', {'pubspec.yaml': pubspec('b')});
    await repo('d', {'pubspec.yaml': pubspec('d')});
    oceanRepo('c', ['d']);
    return a;
  }

  /// The warning about [names] missing in the ticket.
  List<String> missingWarning(List<String> names) => [
    '\n⚠️ Repos between the ticket repos, but not in it:',
    for (final name in names) '  - $name',
    'Run gg do add ${names.join(' ')} to add them.\n',
  ];

  setUp(() {
    messages.clear();
    installs = <List<String>>[];
    failingInstalls = <String>{};
    tmp = Directory.systemTemp.createTempSync('ticket_localizer_test_');
    ocean = Directory(path.join(tmp.path, '.ocean'));
    ticket = Directory(path.join(tmp.path, 'ticket'))..createSync();
    write(ticket, 'ticket.json', '{"description": "Ticket description"}');
    localizer = TicketLocalizer(ggLog: ggLog, processRunner: fakeRunner);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('TicketLocalizer', () {
    // .........................................................................
    group('check', () {
      test('reports the unlocalized refs by repo path', () async {
        final a = await repo('a', {
          'pubspec.yaml': pubspec('a', ['b']),
        });
        await repo('b', {'pubspec.yaml': pubspec('b')});

        final result = await localizer.check(
          ticketDir: ticket,
          repos: await nodes(),
        );

        expect(result.isInSync, isFalse);
        expect(result.unlocalized.keys, [a.path]);
        final ref = result.unlocalized[a.path]!.single;
        expect(ref.dependency, 'b');
        expect(ref.kind, UnlocalizedRefKind.missing);
        expect(result.missingRepos, isEmpty);
      });

      test('is in sync once the refs are localized', () async {
        await repo('a', {
          'pubspec.yaml': pubspec('a', ['b']),
        });
        await repo('b', {'pubspec.yaml': pubspec('b')});
        await localizer.localize(repos: await nodes(), ggLog: ggLog);

        final result = await localizer.check(
          ticketDir: ticket,
          repos: await nodes(),
        );
        expect(result.isInSync, isTrue);
      });

      test('drops the notes of the graphs', () async {
        // A dev dependency closing a cycle is cut with a note.
        await repo('a', {
          'pubspec.yaml': pubspec('a', ['b']),
        });
        await repo('b', {
          'pubspec.yaml': pubspec('b', [], ['a']),
        });
        oceanRepo('x');
        final repos = await nodes();
        messages.clear();

        await localizer.check(ticketDir: ticket, repos: repos);

        expect(messages, isEmpty);
      });

      test('reports the ocean repos between the ticket repos', () async {
        await ticketMissingC();
        // Reached from a ticket repo, but not between two of them.
        oceanRepo('e');
        write(
          Directory(path.join(ticket.path, 'd')),
          'pubspec.yaml',
          pubspec('d', ['e']),
        );

        final result = await localizer.check(
          ticketDir: ticket,
          repos: await nodes(),
        );

        expect(result.missingRepos, ['c']);
      });

      test('follows no dev dependency edge', () async {
        // a -dev-> c -> d: a's tests resolve c, but pub never resolves the
        // dev dependencies of c, and c -dev-> e -> d neither.
        await repo('a', {
          'pubspec.yaml': pubspec('a', [], ['c']),
        });
        await repo('d', {'pubspec.yaml': pubspec('d')});
        oceanRepo('c', ['d']);
        await repo('f', {
          'pubspec.yaml': pubspec('f', ['g']),
        });
        oceanRepo('g', [], ['h']);
        oceanRepo('h', ['d']);

        final result = await localizer.check(
          ticketDir: ticket,
          repos: await nodes(),
        );

        expect(result.missingRepos, isEmpty);
      });

      test('reports every repo of a diamond and between several ticket '
          'repos, sorted by name', () async {
        // a -> {c, b} -> d -> e -> f; x hangs off a, y depends on f only.
        await repo('a', {
          'pubspec.yaml': pubspec('a', ['c', 'b', 'x']),
        });
        await repo('d', {
          'pubspec.yaml': pubspec('d', ['e']),
        });
        await repo('f', {'pubspec.yaml': pubspec('f')});
        oceanRepo('c', ['d']);
        oceanRepo('b', ['d']);
        oceanRepo('e', ['f']);
        oceanRepo('x');
        oceanRepo('y', ['f']);

        final result = await localizer.check(
          ticketDir: ticket,
          repos: await nodes(),
        );

        expect(result.missingRepos, ['b', 'c', 'e']);
      });

      test('reports no missing repos when the ocean graph is broken', () async {
        await ticketMissingC();
        oceanRepo('x', ['y']);
        oceanRepo('y', ['x']);

        final result = await localizer.check(
          ticketDir: ticket,
          repos: await nodes(),
        );

        expect(result.missingRepos, isEmpty);
      });
    });

    // .........................................................................
    group('throwWhenOutOfSync', () {
      test('passes silently for a ticket in sync', () async {
        await repo('a', {'pubspec.yaml': pubspec('a')});

        await localizer.throwWhenOutOfSync(
          ticketDir: ticket,
          repos: await nodes(),
          ggLog: ggLog,
        );

        expect(messages, isEmpty);
      });

      test('lists the refs per repo and fails with an action hint', () async {
        final a = await repo('a', {
          'pubspec.yaml': pubspec('a', ['b']),
        });
        await repo('b', {'pubspec.yaml': pubspec('b')});
        messages.clear();

        await expectLater(
          localizer.throwWhenOutOfSync(
            ticketDir: ticket,
            repos: await nodes(),
            ggLog: ggLog,
          ),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls('$e'),
              'message',
              'Exception: References not localized in a.',
            ),
          ),
        );
        expect(messages, [
          '\na',
          '✗ a uses the published b instead of its checkout',
          '\nPlease run gg do localize '
              '(or gg do commit, which localizes itself).\n',
        ]);

        // Read-only: nothing was written.
        expect(await status(a), isEmpty);
      });

      test(
        'warns about missing repos first, then fails for the refs only',
        () async {
          await ticketMissingC();
          messages.clear();

          await expectLater(
            localizer.throwWhenOutOfSync(
              ticketDir: ticket,
              repos: await nodes(),
              ggLog: ggLog,
            ),
            throwsA(
              isA<Exception>().having(
                (e) => rmControls('$e'),
                'message',
                'Exception: References not localized in a.',
              ),
            ),
          );
          expect(messages.take(3), missingWarning(['c']));
          expect(messages.skip(3).first, '\na');
        },
      );

      test('only warns when nothing but repos are missing', () async {
        await ticketMissingC();
        await localizer.localize(repos: await nodes(), ggLog: ggLog);
        messages.clear();

        await localizer.throwWhenOutOfSync(
          ticketDir: ticket,
          repos: await nodes(),
          ggLog: ggLog,
        );

        expect(messages, missingWarning(['c']));
      });
    });

    // .........................................................................
    group('baseline', () {
      test('records the dirty paths and the commit state of each git repo, '
          'keyed by its path', () async {
        final a = await repo('a', {'pubspec.yaml': pubspec('a')});
        final b = await repo('b', {'pubspec.yaml': pubspec('b')});
        final noGit = Directory(path.join(ticket.path, 'x'))..createSync();
        await recordCommitted(b);
        write(a, 'pubspec.yaml', pubspec('a', ['b']));
        write(a, 'lib/new/wip.dart', '');

        final result = await localizer.baseline([a, b, noGit]);

        expect(result.keys, [a.path, b.path]);
        expect(result[a.path]!.dirtyPaths, {
          'pubspec.yaml',
          'lib/new/wip.dart',
        });
        expect(result[a.path]!.wasCommitted, isFalse);
        expect(result[b.path]!.dirtyPaths, isEmpty);
        expect(result[b.path]!.wasCommitted, isTrue);
      });

      test('does not count an unreadable state as committed', () async {
        // Without EOL conversion git's hash of the tree cannot be taken.
        final a = await repo('a', {'pubspec.yaml': pubspec('a')});
        await recordCommitted(a);
        File(path.join(a.path, '.gitattributes')).deleteSync();

        final result = await localizer.baseline([a]);

        expect(result[a.path]!.dirtyPaths, {'.gitattributes'});
        expect(result[a.path]!.wasCommitted, isFalse);
      });
    });

    // .........................................................................
    group('localize', () {
      test('localizes every repo and resolves it in the given order', () async {
        final a = await repo('a', {
          'pubspec.yaml': pubspec('a', ['b']),
        });
        final b = await repo('b', {
          'pubspec.yaml': pubspec('b', ['c']),
        });
        await repo('c', {'pubspec.yaml': pubspec('c')});

        await localizer.localize(repos: await nodes(), ggLog: ggLog);

        // Pub reads overrides from the root only: a needs c as well.
        expect(overridesOf(a), contains('path: ../b'));
        expect(overridesOf(a), contains('path: ../c'));
        expect(overridesOf(b), contains('path: ../c'));
        expect(installs, [
          ['c', 'dart', 'pub', 'get'],
          ['b', 'dart', 'pub', 'get'],
          ['a', 'dart', 'pub', 'get'],
        ]);
      });

      test('upgrades the Dart dependencies with upgrade: true', () async {
        await repo('a', {'pubspec.yaml': pubspec('a')});

        await localizer.localize(
          repos: await nodes(),
          ggLog: ggLog,
          upgrade: true,
        );

        expect(installs, [
          ['a', 'dart', 'pub', 'upgrade'],
        ]);
      });

      test('repairs a legacy npm link a moved folder broke', () async {
        // The backup keeps the original registry spec.
        final x = await repo('x', {
          'package.json': jsonEncode({
            'name': 'x',
            'version': '1.0.0',
            'dependencies': {'y': 'link:../org/y'},
          }),
          '.gg/gg_localize_refs_backup_ts.json': '{"y": "^1.0.0"}',
        });
        await repo('y', {'package.json': '{"name": "y", "version": "1.0.0"}'});

        await localizer.localize(repos: await nodes(), ggLog: ggLog);

        final manifest = jsonDecode(
          File(path.join(x.path, 'package.json')).readAsStringSync(),
        ) as Map<String, dynamic>;
        expect(manifest['dependencies'], {'y': 'link:../y'});
        expect(installs.map((i) => i.take(2).join(' ')), ['y npm', 'x npm']);
      });

      test('throws and installs nothing when localizing fails', () async {
        final a = await repo('a', {
          'pubspec.yaml': pubspec('a', ['b']),
        });
        await repo('b', {'pubspec.yaml': pubspec('b')});
        write(a, 'pubspec_overrides.yaml', 'dependency_overrides: [');

        await expectLater(
          localizer.localize(repos: await nodes(), ggLog: ggLog),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('Failed to localize the refs of a'),
            ),
          ),
        );
        expect(messages.last, contains('Failed to localize refs for a'));
        expect(installs, [
          ['b', 'dart', 'pub', 'get'],
        ]);
      });
    });

    // .........................................................................
    group('commit', () {
      test('commits gg\'s changes; recordStateFor records the clean state of '
          'the repos it names', () async {
        final a = await repo('a', {
          'pubspec.yaml': pubspec('a', ['b']),
        });
        final b = await repo('b', {'pubspec.yaml': pubspec('b')});
        final baseline = await localizer.baseline([a, b]);

        await localizer.localize(repos: await nodes(), ggLog: ggLog);
        await localizer.commit(
          repoDirs: [a, b],
          baseline: baseline,
          ggLog: ggLog,
          recordStateFor: {a.path},
        );

        for (final dir in [a, b]) {
          expect(await status(dir), isEmpty);
        }
        expect(await committed(a), isTrue);
        // b was not checked before and is not named.
        expect(await committed(b), isFalse);
        final log = await git(a, ['log', '--format=%s']);
        expect(const LineSplitter().convert(log).take(2), [
          '#gg: changed references to path',
          'Initial commit',
        ]);
        final changed = await git(a, ['show', '--name-only', '--format=']);
        expect(changed, contains('pubspec_overrides.yaml'));
      });

      test('does not mark unchecked work as committed', () async {
        // The user commits a new dependency with plain git, unchecked.
        final a = await repo('a', {'pubspec.yaml': pubspec('a')});
        await repo('b', {'pubspec.yaml': pubspec('b')});
        await recordCommitted(a);
        write(a, 'pubspec.yaml', pubspec('a', ['b']));
        await git(a, ['commit', '-am', 'Use b']);
        final baseline = await localizer.baseline([a]);

        await localizer.localize(repos: await nodes(), ggLog: ggLog);
        await localizer.commit(repoDirs: [a], baseline: baseline, ggLog: ggLog);

        expect(await status(a), isEmpty);
        expect(
          await git(a, ['log', '-1', '--format=%s']),
          '#gg: changed references to path',
        );
        // gg do commit still runs the checks and writes the CHANGELOG entry.
        expect(await committed(a), isFalse);
      });

      test('keeps a checked state valid', () async {
        final a = await repo('a', {
          'pubspec.yaml': pubspec('a', ['b']),
        });
        await repo('b', {'pubspec.yaml': pubspec('b')});
        await recordCommitted(a);
        final baseline = await localizer.baseline([a]);

        await localizer.localize(repos: await nodes(), ggLog: ggLog);
        await localizer.commit(repoDirs: [a], baseline: baseline, ggLog: ggLog);

        expect(await status(a), isEmpty);
        expect(await committed(a), isTrue);
      });

      test('leaves the user\'s work and manifest edits uncommitted', () async {
        // The user adds a dependency by hand while working on a feature.
        final a = await repo('a', {
          'pubspec.yaml': pubspec('a'),
          'pubspec.lock': '# old lock\n',
          'pubspec_overrides.yaml': 'dependency_overrides:\n',
        });
        await repo('b', {'pubspec.yaml': pubspec('b')});
        write(a, 'pubspec.yaml', pubspec('a', ['b']));
        write(a, 'pubspec.lock', '# resolved by the user\n');
        write(a, 'pubspec_overrides.yaml', '# edited by hand\n');
        write(a, 'lib/wip.dart', '');
        final baseline = await localizer.baseline([a]);
        final head = await git(a, ['rev-parse', 'HEAD']);

        await localizer.localize(repos: await nodes(), ggLog: ggLog);
        await localizer.commit(
          repoDirs: [a],
          baseline: baseline,
          ggLog: ggLog,
          recordStateFor: {a.path},
        );

        // One gg commit right on top: no prefix-less commit of the WIP.
        expect(await git(a, ['rev-parse', 'HEAD~1']), head);
        expect(await git(a, ['log', '-1', '--format=%s']), contains('#gg: '));
        final changed = const LineSplitter().convert(
          await git(a, ['show', '--name-only', '--format=']),
        );
        // A lock file is gg's output even when it was dirty before; an
        // overrides file edited by hand is not.
        expect(changed, unorderedEquals(['.gitignore', 'pubspec.lock']));
        expect(
          await status(a),
          unorderedEquals([
            'pubspec.yaml',
            'pubspec_overrides.yaml',
            'lib/wip.dart',
          ]),
        );
        expect(await committed(a), isFalse);
      });

      test('does nothing for a repo without gg changes', () async {
        final a = await repo('a', {'pubspec.yaml': pubspec('a')});
        write(a, 'lib/wip.dart', '');
        final head = await git(a, ['rev-parse', 'HEAD']);

        await localizer.commit(
          repoDirs: [a],
          baseline: await localizer.baseline([a]),
          ggLog: ggLog,
        );

        expect(await git(a, ['rev-parse', 'HEAD']), head);
      });

      test('skips a folder without git and a repo in the middle of a '
          'merge', () async {
        final a = await repo('a', {'pubspec.yaml': pubspec('a')});
        // A folder that merely holds an empty `.git` counts as none.
        final noGit = Directory(path.join(ticket.path, 'x'))..createSync();
        Directory(path.join(noGit.path, '.git')).createSync();
        write(a, 'pubspec_overrides.yaml', 'dependency_overrides:\n');
        write(noGit, 'pubspec_overrides.yaml', 'dependency_overrides:\n');
        // git refuses a partial commit until the merge is concluded.
        final head = await git(a, ['rev-parse', 'HEAD']);
        write(a, '.git/MERGE_HEAD', '$head\n');

        await localizer.commit(
          repoDirs: [a, noGit],
          baseline: const {},
          ggLog: ggLog,
        );

        expect(await git(a, ['rev-parse', 'HEAD']), head);
        expect(await status(a), ['pubspec_overrides.yaml']);
      });

      test(
        'commits every repo it can, then throws naming the failed ones',
        () async {
          // gg commits exist on feature branches only.
          final a = await repo('a', {
            'pubspec.yaml': pubspec('a'),
          }, onMain: true);
          final b = await repo('b', {'pubspec.yaml': pubspec('b')});
          write(a, 'pubspec_overrides.yaml', 'dependency_overrides:\n');
          write(b, 'pubspec_overrides.yaml', 'dependency_overrides:\n');

          await expectLater(
            localizer.commit(repoDirs: [a, b], baseline: {}, ggLog: ggLog),
            throwsA(
              isA<Exception>().having(
                (e) => e.toString(),
                'message',
                contains('Failed to commit the localized refs of a'),
              ),
            ),
          );
          expect(messages, contains(contains('Failed to commit a: ')));
          expect(await status(a), ['pubspec_overrides.yaml']);
          expect(await status(b), isEmpty);
        },
      );
    });

    // .........................................................................
    group('localizeUnlocalized', () {
      test('leaves a ticket in sync untouched', () async {
        final a = await repo('a', {'pubspec.yaml': pubspec('a')});
        final head = await git(a, ['rev-parse', 'HEAD']);

        final localized = await localizer.localizeUnlocalized(
          ticketDir: ticket,
          repos: await nodes(),
          ggLog: ggLog,
        );

        expect(localized, isEmpty);
        expect(installs, isEmpty);
        expect(messages, isEmpty);
        expect(await git(a, ['rev-parse', 'HEAD']), head);
      });

      test('localizes only the out-of-sync repos, keeps the manifest edit '
          'of the user and reports nothing but the result', () async {
        final a = await repo('a', {'pubspec.yaml': pubspec('a')});
        final b = await repo('b', {'pubspec.yaml': pubspec('b')});
        final headB = await git(b, ['rev-parse', 'HEAD']);
        write(a, 'pubspec.yaml', pubspec('a', ['b']));
        messages.clear();

        final localized = await localizer.localizeUnlocalized(
          ticketDir: ticket,
          repos: await nodes(),
          ggLog: ggLog,
        );

        expect(localized, ['a']);
        expect(messages, ['✓ Localized the references of a']);
        expect(installs.map((i) => i.first), ['a']);
        expect(overridesOf(a), contains('path: ../b'));
        expect(
          await git(a, ['log', '-1', '--format=%s']),
          '#gg: changed references to path',
        );
        expect(await status(a), ['pubspec.yaml']);
        expect(await git(b, ['rev-parse', 'HEAD']), headB);
      });

      test('reports a failed install', () async {
        await repo('a', {
          'pubspec.yaml': pubspec('a', ['b']),
        });
        await repo('b', {'pubspec.yaml': pubspec('b')});
        failingInstalls.add('a');
        messages.clear();

        await localizer.localizeUnlocalized(
          ticketDir: ticket,
          repos: await nodes(),
          ggLog: ggLog,
        );

        expect(messages, [
          'Failed to execute dart pub get in a: offline',
          '✓ Localized the references of a',
        ]);
      });

      test('prints the details when localizing fails', () async {
        // gg commits exist on feature branches only.
        await repo('a', {
          'pubspec.yaml': pubspec('a', ['b']),
        }, onMain: true);
        await repo('b', {'pubspec.yaml': pubspec('b')});
        final repos = await nodes();
        messages.clear();

        await expectLater(
          localizer.localizeUnlocalized(
            ticketDir: ticket,
            repos: repos,
            ggLog: ggLog,
          ),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('Failed to commit the localized refs of a'),
            ),
          ),
        );
        expect(messages, contains('Executed dart pub get in a.'));
        expect(messages.last, startsWith('Failed to commit a: '));
      });

      test('localizes and warns about missing repos at the end', () async {
        final a = await ticketMissingC();
        messages.clear();

        final localized = await localizer.localizeUnlocalized(
          ticketDir: ticket,
          repos: await nodes(),
          ggLog: ggLog,
        );

        expect(localized, ['a']);
        expect(overridesOf(a), contains('path: ../b'));
        expect(messages, [
          '✓ Localized the references of a',
          ...missingWarning(['c']),
        ]);
      });

      test(
        'does not look for missing repos with warnMissingRepos: false',
        () async {
          await ticketMissingC();
          messages.clear();

          await localizer.localizeUnlocalized(
            ticketDir: ticket,
            repos: await nodes(),
            ggLog: ggLog,
            warnMissingRepos: false,
          );

          expect(messages, ['✓ Localized the references of a']);
        },
      );
    });
  });
}

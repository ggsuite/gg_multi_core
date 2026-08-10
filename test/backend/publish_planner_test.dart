// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

// ignore: lines_longer_than_80_chars
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_multi_core/src/backend/message_editor_theme.dart';
import 'package:gg_multi_core/src/backend/publish_planner.dart';
import 'package:gg_multi_core/src/backend/publish_skip_check.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_publish/gg_publish.dart' show PublishedVersion;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:gg_lang/gg_lang.dart' as gg_lang;
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:test/test.dart';

class MockPublishedVersion extends Mock implements PublishedVersion {}

class FakeDirectory extends Fake implements Directory {}

class FakeNode extends Fake implements Node {}

/// A deterministic [gg.InteractAdapter] returning queued indices and
/// capturing the option lists it was shown.
class _StubAdapter implements gg.InteractAdapter {
  _StubAdapter(this._indices);

  final List<int> _indices;
  int _call = 0;
  final List<List<String>> capturedOptions = [];

  @override
  Future<int> choose({
    required String message,
    required List<String> options,
  }) async {
    capturedOptions.add(options);
    final index = _indices[_call % _indices.length];
    _call++;
    return index;
  }
}

void main() {
  late Directory tempDir;
  late Directory ticketDir;
  final messages = <String>[];
  final seeds = <String>[];

  void ggLog(String msg) => messages.add(msg);

  setUpAll(() {
    registerFallbackValue(FakeDirectory());
    registerFallbackValue(FakeNode());
    registerFallbackValue(<String, String>{});
  });

  setUp(() {
    messages.clear();
    seeds.clear();
    tempDir = Directory.systemTemp.createTempSync('publish_planner_test_');
    ticketDir = Directory(path.join(tempDir.path, 'tickets', 'TICK'))
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  // ...........................................................................
  /// A ticket repo folder named [name].
  Directory repoDir(String name) =>
      Directory(path.join(ticketDir.path, name))..createSync(recursive: true);

  /// A dependency-list node for the ticket repo [name].
  Node node(String name) => Node(
    name: name,
    directory: repoDir(name),
    manifest: DartPackageManifest(pubspec: Pubspec(name)),
  );

  /// A skip check answering `skip` for every repo named in [skipped].
  MockPublishSkipCheck skipCheck(Set<String> skipped) {
    final mock = MockPublishSkipCheck();
    when(
      () => mock.get(
        repo: any(named: 'repo'),
        refVersions: any(named: 'refVersions'),
      ),
    ).thenAnswer((invocation) async {
      final repo = invocation.namedArguments[#repo] as Node;
      return skipped.contains(repo.name)
          ? const PublishSkipDecision(
              skip: true,
              reason: 'Nothing changed. Skip publishing.',
            )
          : const PublishSkipDecision(
              skip: false,
              reason: 'the repo contains the manual commit »Fix bug«',
            );
    });
    return mock;
  }

  /// A planner with every collaborator stubbed deterministically.
  PublishPlanner makePlanner({
    Set<String> skipped = const <String>{},
    List<int> increments = const [0],
    String baseline = '1.2.3',
    bool baselineThrows = false,
    bool hasTerminal = true,
    _StubAdapter? adapter,
    EditMessage? editMessage,
    ReadManifestVersion? readManifestVersion,
    PublishSkipCheck? check,
  }) {
    final publishedVersion = MockPublishedVersion();
    if (baselineThrows) {
      when(
        () => publishedVersion.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenThrow(ArgumentError('not a git repository'));
    } else {
      when(
        () => publishedVersion.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => Version.parse(baseline));
    }

    return PublishPlanner(
      ggLog: ggLog,
      publishSkipCheck: check ?? skipCheck(skipped),
      publishedVersion: publishedVersion,
      readManifestVersion: readManifestVersion ?? (_) async => '9.9.9',
      versionSelector: gg.VersionSelector(
        adapter: adapter ?? _StubAdapter(increments),
      ),
      editMessage:
          editMessage ??
          (initial) async {
            seeds.add(initial);
            return initial;
          },
      hasTerminal: () => hasTerminal,
    );
  }

  // ###########################################################################
  group('publishConfigFileFor', () {
    test('points at <ticket>/.gg/gg-publish.json', () {
      expect(
        publishConfigFileFor(ticketDir).path,
        path.join(ticketDir.path, '.gg', 'gg-publish.json'),
      );
    });
  });

  // ###########################################################################
  group('repoHasPublishStepProgress', () {
    test('is false without a repo-level config file', () {
      expect(repoHasPublishStepProgress(repoDir('A')), isFalse);
    });

    test('is false for a config file without done steps', () {
      final dir = repoDir('A');
      gg.DoConfigurePublish.configFileFor(dir)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"version_increment": "patch"}');
      expect(repoHasPublishStepProgress(dir), isFalse);
    });

    test('is true once a step was recorded', () {
      final dir = repoDir('A');
      gg.DoConfigurePublish.configFileFor(dir)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"done_steps": ["merge"]}');
      expect(repoHasPublishStepProgress(dir), isTrue);
    });

    test('is false for an unreadable file — it cannot prove progress', () {
      final dir = repoDir('A');
      gg.DoConfigurePublish.configFileFor(dir)
        ..createSync(recursive: true)
        ..writeAsStringSync('{ not json');
      expect(repoHasPublishStepProgress(dir), isFalse);
    });
  });

  // ###########################################################################
  group('defaultReadManifestVersion', () {
    test('reads the version of a Dart package', () async {
      final dir = repoDir('A');
      File(
        path.join(dir.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: a\nversion: 4.5.6\n');
      expect(await defaultReadManifestVersion(dir), '4.5.6');
    });

    test('answers null for a folder without a manifest', () async {
      expect(await defaultReadManifestVersion(repoDir('A')), isNull);
    });
  });

  // ###########################################################################
  group('seedMessageFor', () {
    test('prefers an explicit message over the ticket description', () {
      File(
        path.join(ticketDir.path, '.ticket'),
      ).writeAsStringSync('{"description": "Ticket desc"}');
      expect(
        PublishPlanner.seedMessageFor(
          ticketDir: ticketDir,
          defaultMergeMessage: '  From -m  ',
        ),
        'From -m',
      );
    });

    test('falls back to the ticket description', () {
      File(
        path.join(ticketDir.path, '.ticket'),
      ).writeAsStringSync('{"description": "Ticket desc"}');
      expect(
        PublishPlanner.seedMessageFor(
          ticketDir: ticketDir,
          defaultMergeMessage: '   ',
        ),
        'Ticket desc',
      );
    });

    test('is empty when neither exists', () {
      expect(PublishPlanner.seedMessageFor(ticketDir: ticketDir), '');
    });
  });

  // ###########################################################################
  group('configureRepo', () {
    test('asks the increment and the merge message', () async {
      final adapter = _StubAdapter([1]); // minor
      final planner = makePlanner(baseline: '2.5.0', adapter: adapter);

      final answer = await planner.configureRepo(
        repoDir: repoDir('A'),
        seedMessage: 'Seed',
      );

      expect(answer.override.versionIncrement, 'minor');
      expect(answer.override.mergeMessage, 'Seed');
      expect(answer.baseline, Version(2, 5, 0));
      // The preview is calculated from the published version.
      expect(adapter.capturedOptions.single.first, contains('2.5.0 -> 2.5.1'));
    });

    test('asks no increment in a merge-only run', () async {
      // The empty index list would throw if the selector were asked.
      final planner = makePlanner(increments: const []);

      final answer = await planner.configureRepo(
        repoDir: repoDir('A'),
        seedMessage: 'Seed',
        mergeOnly: true,
      );

      expect(answer.override.versionIncrement, isNull);
      expect(answer.override.mergeMessage, 'Seed');
    });

    test('falls back to the seed when the edit is cleared', () async {
      final planner = makePlanner(editMessage: (_) async => '   ');
      final answer = await planner.configureRepo(
        repoDir: repoDir('A'),
        seedMessage: 'Seed',
      );
      expect(answer.override.mergeMessage, 'Seed');
    });

    test('falls back to »Publish <repo>« when nothing seeds it', () async {
      final planner = makePlanner(editMessage: (_) async => null);
      final answer = await planner.configureRepo(
        repoDir: repoDir('A'),
        seedMessage: '',
      );
      expect(answer.override.mergeMessage, 'Publish A');
    });

    test('assumes 0.0.0 and warns when the baseline cannot be read', () async {
      // Not even an Error may fail the run around a version preview.
      final adapter = _StubAdapter([0]);
      final planner = makePlanner(baselineThrows: true, adapter: adapter);

      final answer = await planner.configureRepo(
        repoDir: repoDir('A'),
        seedMessage: 'Seed',
      );

      expect(answer.baseline, Version(0, 0, 0));
      expect(
        messages.join('\n'),
        contains('Could not determine the published version'),
      );
    });
  });

  // ###########################################################################
  group('publishedNames', () {
    test('reports the pub.dev name of a Dart package', () async {
      final dir = repoDir('folder-name');
      File(
        path.join(dir.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: a_package\nversion: 1.0.0\n');

      final names = await makePlanner().publishedNames(dir, 'folder-name');
      expect(names[gg_lang.PublishTarget.pubDev], 'a_package');
    });

    test('reads the manifest name of a repo without a registry', () async {
      // »publish_to: none« leaves no registry target, but the version still
      // has to reach the dependents' constraints under the package's name.
      final dir = repoDir('private-folder');
      File(path.join(dir.path, 'pubspec.yaml')).writeAsStringSync(
        'name: a_private_package\nversion: 1.0.0\npublish_to: none\n',
      );

      final names = await makePlanner().publishedNames(dir, 'private-folder');
      expect(names[gg_lang.PublishTarget.pubDev], 'a_private_package');
    });

    test('falls back to the folder name without a manifest', () async {
      final dir = repoDir('git-only');
      final names = await makePlanner().publishedNames(dir, 'git-only');
      expect(names[gg_lang.PublishTarget.pubDev], 'git-only');
    });
  });

  // ###########################################################################
  group('PublishPlan', () {
    PublishPlanEntry entry(String name, {required bool publishes}) =>
        PublishPlanEntry(
          name: name,
          directory: repoDir(name),
          publishes: publishes,
          reason: publishes ? 'changed' : 'unchanged',
          alreadyPublished: false,
        );

    test('answers which repos publish', () {
      final plan = PublishPlan(
        entries: [entry('A', publishes: true), entry('B', publishes: false)],
        config: gg.PublishConfig(),
      );

      expect(plan.publishes, {'A'});
      expect(plan.anyPublishes, isTrue);
      expect(plan.entryFor('B')!.reason, 'unchanged');
      expect(plan.entryFor('nope'), isNull);
    });

    test('anyPublishes is false when every repo is skipped', () {
      final plan = PublishPlan(
        entries: [entry('A', publishes: false)],
        config: gg.PublishConfig(),
      );
      expect(plan.anyPublishes, isFalse);
      expect(plan.publishes, isEmpty);
    });
  });

  // ###########################################################################
  group('plan', () {
    test('asks the questions of a publishing repo and skips the '
        'rest', () async {
      final planner = makePlanner(skipped: {'B'}, increments: [2]);

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A'), node('B')],
        ggLog: ggLog,
        defaultMergeMessage: 'The change',
      );

      expect(plan.publishes, {'A'});
      expect(seeds, ['The change']);
      expect(plan.config.repos['A']!.versionIncrement, 'major');
      expect(plan.config.repos['A']!.mergeMessage, 'The change');
      expect(plan.config.repos, isNot(contains('B')));

      // Both verdicts are reported per repo.
      expect(
        messages.join('\n'),
        contains('Not published. Nothing changed. Skip publishing.'),
      );
    });

    test('--publish-unchanged publishes every repo', () async {
      final planner = makePlanner(skipped: {'A', 'B'});

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A'), node('B')],
        ggLog: ggLog,
        publishUnchanged: true,
      );

      expect(plan.publishes, {'A', 'B'});
      expect(plan.entryFor('A')!.reason, '--publish-unchanged');
    });

    test('never skips a repo that already started publishing', () async {
      final dir = repoDir('A');
      gg.DoConfigurePublish.configFileFor(dir)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"done_steps": ["prepare_version"]}');
      final planner = makePlanner(skipped: {'A'});

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
      );

      expect(plan.publishes, {'A'});
      expect(
        plan.entryFor('A')!.reason,
        'a previous run already started publishing it',
      );
    });

    test('treats a repo the resume marks published as done', () async {
      final planner = makePlanner(increments: const []);
      final config = gg.PublishConfig(
        repos: {'A': gg.RepoOverride(status: 'published')},
      );

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
        config: config,
        continueRun: true,
      );

      expect(plan.publishes, isEmpty);
      expect(plan.entryFor('A')!.alreadyPublished, isTrue);
      // Nothing is reported: the loop says »already published« itself.
      expect(messages.join('\n'), isNot(contains('Not published')));
    });

    test('asks nothing the configuration already answers', () async {
      final planner = makePlanner(increments: const []);
      final config = gg.PublishConfig(
        versionIncrement: 'minor',
        mergeMessage: 'from the config',
      );

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
        config: config,
      );

      expect(seeds, isEmpty);
      expect(plan.entryFor('A')!.versionIncrement, 'minor');
      expect(plan.entryFor('A')!.mergeMessage, 'from the config');
      // The top-level defaults survive the merge.
      expect(plan.config.versionIncrement, 'minor');
      expect(plan.config.mergeMessage, 'from the config');
    });

    test('a merge-only run needs no increment to be covered', () async {
      final planner = makePlanner(increments: const []);
      final config = gg.PublishConfig(mergeMessage: 'just merge');

      await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
        config: config,
        mergeOnly: true,
      );

      expect(seeds, isEmpty);
    });

    test('keeps the status and channel a resume depends on', () async {
      final planner = makePlanner();
      final config = gg.PublishConfig(
        channel: 'stable',
        repos: {'A': gg.RepoOverride(channel: 'rc', status: 'failed')},
      );

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
        config: config,
      );

      expect(plan.config.repos['A']!.status, 'failed');
      expect(plan.config.repos['A']!.channel, 'rc');
      expect(plan.config.repos['A']!.versionIncrement, 'patch');
    });

    test('ask: false decides without asking anything', () async {
      final planner = makePlanner(increments: const []);

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
        ask: false,
      );

      expect(seeds, isEmpty);
      expect(plan.publishes, {'A'});
      expect(plan.entryFor('A')!.versionIncrement, isNull);
    });

    test('leaves a question unanswered when nobody can be asked', () async {
      final planner = makePlanner(hasTerminal: false, increments: const []);

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
        requireAnswers: false,
      );

      expect(seeds, isEmpty);
      expect(plan.entryFor('A')!.mergeMessage, isNull);
    });

    test('fails with an actionable message when an answer is '
        'required', () async {
      final planner = makePlanner(hasTerminal: false, increments: const []);

      await expectLater(
        () => planner.plan(
          ticketDir: ticketDir,
          subs: [node('A')],
          ggLog: ggLog,
          wording: PublishPlanWording.merge,
        ),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            allOf(
              contains('A needs a merge'),
              contains('gg do configure-publish'),
              contains('gg do publish --merge-only --config <file>'),
            ),
          ),
        ),
      );
    });

    group('the version dependents are judged against', () {
      /// Plans A → B and returns the refVersions B was judged with. The skip
      /// check is the capture point: it sees exactly what the pass predicted
      /// for every repo before it.
      Future<Map<String, String>> refVersionsOfB({
        Set<String> skipped = const <String>{},
        List<int> increments = const [0],
        String baseline = '1.2.3',
        bool baselineThrows = false,
        ReadManifestVersion? readManifestVersion,
        gg.PublishConfig? config,
        bool mergeOnly = false,
      }) async {
        final captured = <Map<String, String>>[];
        final check = MockPublishSkipCheck();
        when(
          () => check.get(
            repo: any(named: 'repo'),
            refVersions: any(named: 'refVersions'),
          ),
        ).thenAnswer((invocation) async {
          final repo = invocation.namedArguments[#repo] as Node;
          captured.add(
            Map<String, String>.from(
              invocation.namedArguments[#refVersions] as Map<String, String>,
            ),
          );
          return skipped.contains(repo.name)
              ? const PublishSkipDecision(skip: true, reason: 'unchanged')
              : const PublishSkipDecision(skip: false, reason: 'changed');
        });

        await makePlanner(
          check: check,
          increments: increments,
          baseline: baseline,
          baselineThrows: baselineThrows,
          readManifestVersion: readManifestVersion,
        ).plan(
          ticketDir: ticketDir,
          subs: [node('A'), node('B')],
          ggLog: ggLog,
          config: config,
          mergeOnly: mergeOnly,
        );
        return captured.last;
      }

      /// Gives repo A a manifest, so its published name is »a«.
      void manifestOfA(String version) => File(
        path.join(repoDir('A').path, 'pubspec.yaml'),
      ).writeAsStringSync('name: a\nversion: $version\n');

      test('is the incremented registry version of a publishing '
          'repo', () async {
        manifestOfA('0.0.1');
        expect(
          await refVersionsOfB(baseline: '1.2.3', increments: [1]),
          containsPair('a', '1.3.0'),
        );
      });

      test('is the manifest version of a skipped repo', () async {
        manifestOfA('0.9.0');
        expect(
          await refVersionsOfB(
            skipped: {'A'},
            readManifestVersion: (_) async => '0.9.0',
          ),
          containsPair('a', '0.9.0'),
        );
      });

      test('is unknown for a release candidate', () async {
        manifestOfA('0.0.1');
        final refVersions = await refVersionsOfB(
          config: gg.PublishConfig(channel: 'rc'),
        );
        expect(refVersions, isNot(contains('a')));
      });

      test('falls back to 0.0.0 when the registry lookup fails', () async {
        manifestOfA('0.0.1');
        expect(
          await refVersionsOfB(baselineThrows: true),
          containsPair('a', '0.0.1'),
        );
      });

      test('a merge changes no version at all', () async {
        manifestOfA('7.7.7');
        expect(
          await refVersionsOfB(
            increments: const [],
            readManifestVersion: (_) async => '7.7.7',
            mergeOnly: true,
          ),
          containsPair('a', '7.7.7'),
        );
      });

      test('is unknown when the manifest carries no version', () async {
        manifestOfA('0.0.1');
        expect(
          await refVersionsOfB(
            skipped: {'A'},
            readManifestVersion: (_) async => null,
          ),
          isEmpty,
        );
      });
    });
  });

  // ###########################################################################
  group('PublishPlanWording', () {
    test('carries one wording per flow', () {
      expect(PublishPlanWording.publish.done, 'published');
      expect(PublishPlanWording.merge.action, 'merge');
      expect(PublishPlanWording.merge.command, 'gg do publish --merge-only');
      expect(
        PublishPlanWording.review.skipPrefix,
        'Not published — no pull request.',
      );
    });
  });

  // ###########################################################################
  group('MockPublishPlanner', () {
    test('can be constructed', () {
      expect(MockPublishPlanner(), isA<PublishPlanner>());
    });
  });

  // ###########################################################################
  group('the default collaborators', () {
    test('are constructed when none are injected', () {
      expect(PublishPlanner(ggLog: ggLog), isA<PublishPlanner>());
    });
  });

  // ###########################################################################
  group('an unreadable ticket description', () {
    test('does not crash the seed', () {
      File(
        path.join(ticketDir.path, '.ticket'),
      ).writeAsStringSync(jsonEncode(<String>[]));
      expect(PublishPlanner.seedMessageFor(ticketDir: ticketDir), '');
    });
  });
}

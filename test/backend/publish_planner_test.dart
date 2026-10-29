// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

// ignore: lines_longer_than_80_chars
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_multi_core/src/backend/message_editor_theme.dart';
import 'package:gg_multi_core/src/backend/publish_config_io.dart';
import 'package:gg_multi_core/src/backend/publish_planner.dart';
import 'package:gg_multi_core/src/backend/ticket_json.dart';
import 'package:gg_multi_core/src/backend/publish_skip_check.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_publish/gg_publish.dart'
    show PublishedVersion, VersionIncrement;
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
  final List<int> capturedInitialIndices = [];

  @override
  Future<int> choose({
    required String message,
    required List<String> options,
    int initialIndex = 0,
  }) async {
    capturedOptions.add(options);
    capturedInitialIndices.add(initialIndex);
    final index = _indices[_call % _indices.length];
    _call++;
    return index;
  }
}

/// A skip check that skips B exactly when A — known by its folder name, as it
/// has no manifest — is predicted as [version]; every other repo publishes.
MockPublishSkipCheck _skipBWhenAIs(String version) {
  final check = MockPublishSkipCheck();
  when(
    () => check.get(
      repo: any(named: 'repo'),
      refVersions: any(named: 'refVersions'),
    ),
  ).thenAnswer((invocation) async {
    final repo = invocation.namedArguments[#repo] as Node;
    final refs = invocation.namedArguments[#refVersions] as Map<String, String>;
    final skip = repo.name == 'B' && refs['A'] == version;
    return PublishSkipDecision(skip: skip, reason: 'decided');
  });
  return check;
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
    gg.EditText? editText,
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
      // No editor unless a test brings one: the questions are then asked one
      // by one, by the stubs above.
      editText:
          editText ??
          ({required prompt, required text, required fileName}) async => null,
      hasTerminal: () => hasTerminal,
    );
  }

  // ###########################################################################
  group('legacyTicketPublishConfigFile', () {
    test('points at <ticket>/.gg/gg-publish.json', () {
      expect(
        legacyTicketPublishConfigFile(ticketDir).path,
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
      gg.repoPublishConfigFile(dir)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"publishConfig":{"versionIncrement":"patch"}}');
      expect(repoHasPublishStepProgress(dir), isFalse);
    });

    test('is true once a step was recorded', () {
      final dir = repoDir('A');
      gg.publishStateFile(dir)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"doneSteps": ["merge"]}');
      expect(repoHasPublishStepProgress(dir), isTrue);
    });

    test('is false for an unreadable file — it cannot prove progress', () {
      final dir = repoDir('A');
      gg.publishStateFile(dir)
        ..createSync(recursive: true)
        ..writeAsStringSync('{ not json');
      expect(repoHasPublishStepProgress(dir), isFalse);
    });
  });

  // ###########################################################################
  group('defaultReadManifestVersion', () {
    test('reads the version of a Dart package', () async {
      final dir = repoDir('A');
      File(path.join(dir.path, 'pubspec.yaml'))
          .writeAsStringSync('name: a\nversion: 4.5.6\n');
      expect(await defaultReadManifestVersion(dir), '4.5.6');
    });

    test('answers null for a folder without a manifest', () async {
      expect(await defaultReadManifestVersion(repoDir('A')), isNull);
    });
  });

  // ###########################################################################
  group('seedMessageFor', () {
    test('prefers an explicit message over the ticket description', () {
      File(path.join(ticketDir.path, ticketJsonFileName))
          .writeAsStringSync('{"description": "Ticket desc"}');
      expect(
        PublishPlanner.seedMessageFor(
          ticketDir: ticketDir,
          defaultMergeMessage: '  From -m  ',
        ),
        'From -m',
      );
    });

    test('falls back to the ticket description', () {
      File(path.join(ticketDir.path, ticketJsonFileName))
          .writeAsStringSync('{"description": "Ticket desc"}');
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

      expect(answer.config.versionIncrement, VersionIncrement.minor);
      expect(answer.config.mergeMessage, 'Seed');
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

      expect(answer.config.versionIncrement, isNull);
      expect(answer.config.mergeMessage, 'Seed');
    });

    test('falls back to the seed when the edit is cleared', () async {
      final planner = makePlanner(editMessage: (_) async => '   ');
      final answer = await planner.configureRepo(
        repoDir: repoDir('A'),
        seedMessage: 'Seed',
      );
      expect(answer.config.mergeMessage, 'Seed');
    });

    test('falls back to »Publish <repo>« when nothing seeds it', () async {
      final planner = makePlanner(editMessage: (_) async => null);
      final answer = await planner.configureRepo(
        repoDir: repoDir('A'),
        seedMessage: '',
      );
      expect(answer.config.mergeMessage, 'Publish A');
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
      File(path.join(dir.path, 'pubspec.yaml'))
          .writeAsStringSync('name: a_package\nversion: 1.0.0\n');

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
        configs: const {},
      );

      expect(plan.publishes, {'A'});
      expect(plan.anyPublishes, isTrue);
      expect(plan.entryFor('B')!.reason, 'unchanged');
      expect(plan.entryFor('nope'), isNull);
    });

    test('anyPublishes is false when every repo is skipped', () {
      final plan = PublishPlan(
        entries: [entry('A', publishes: false)],
        configs: const {},
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
      expect(plan.configs['A']!.versionIncrement, VersionIncrement.major);
      expect(plan.configs['A']!.mergeMessage, 'The change');
      // B was skipped, so nothing was asked and nothing recorded for it.
      expect(plan.configs['B']!.mergeMessage, isNull);

      // Both verdicts are reported per repo.
      expect(
        messages.join('\n'),
        contains('✓ Nothing changed. Skip publishing.'),
      );
      expect(messages.join('\n'), isNot(contains('Not published.')));
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
      gg.publishStateFile(dir)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"doneSteps": ["prepare_version"]}');
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
      await gg.PublishState(status: 'published')
          .save(file: gg.publishStateFile(repoDir('A')));

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
        continueRun: true,
      );

      expect(plan.publishes, isEmpty);
      expect(plan.entryFor('A')!.alreadyPublished, isTrue);
      // Nothing is reported: the loop says »already published« itself.
      expect(messages.join('\n'), isNot(contains('Not published')));
    });

    test('asks nothing a previous pass already answered', () async {
      // The regression this guards: `gg do review` answers the questions,
      // and the `gg do publish` right after it must not ask them again.
      final adapter = _StubAdapter([1]);
      final planner = makePlanner(adapter: adapter);
      await gg.RepoPublishConfig(
        versionIncrement: VersionIncrement.minor,
        mergeMessage: 'from the review',
      ).save(file: gg.repoPublishConfigFile(repoDir('A')));

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
      );

      expect(adapter.capturedOptions, isEmpty);
      expect(seeds, isEmpty);
      expect(plan.entryFor('A')!.versionIncrement, 'minor');
      expect(plan.entryFor('A')!.mergeMessage, 'from the review');
    });

    test('asks what the recorded answers leave open', () async {
      // Only the merge message is recorded, so only the increment is asked.
      final adapter = _StubAdapter([2]);
      final planner = makePlanner(adapter: adapter);
      await gg.RepoPublishConfig(mergeMessage: 'from the review')
          .save(file: gg.repoPublishConfigFile(repoDir('A')));

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
      );

      expect(adapter.capturedOptions, hasLength(1));
      expect(plan.entryFor('A')!.versionIncrement, 'major');
    });

    test('reconfigure asks again, with the recorded answers '
        'pre-selected', () async {
      // The heart of the reconfigure requirement: an answer on disk is a
      // default, never a reason to skip the question.
      final adapter = _StubAdapter([1]);
      final planner = makePlanner(adapter: adapter);
      await gg.RepoPublishConfig(
        versionIncrement: VersionIncrement.minor,
        mergeMessage: 'from the config',
      ).save(file: gg.repoPublishConfigFile(repoDir('A')));

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
        reconfigure: true,
      );

      expect(adapter.capturedInitialIndices, [1]);
      expect(seeds, ['from the config']);
      expect(plan.entryFor('A')!.versionIncrement, 'minor');
      expect(plan.entryFor('A')!.mergeMessage, 'from the config');
    });

    test('a recorded answer keeps a headless merge-only run going', () async {
      final planner = makePlanner(hasTerminal: false, increments: const []);
      await gg.RepoPublishConfig(mergeMessage: 'just merge')
          .save(file: gg.repoPublishConfigFile(repoDir('A')));

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
        mergeOnly: true,
      );

      expect(seeds, isEmpty);
      expect(plan.entryFor('A')!.mergeMessage, 'just merge');
    });

    test('a headless run uses a fully answered config as it is', () async {
      final planner = makePlanner(hasTerminal: false, increments: const []);
      await gg.RepoPublishConfig(
        versionIncrement: VersionIncrement.major,
        mergeMessage: 'from the config',
      ).save(file: gg.repoPublishConfigFile(repoDir('A')));

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
      );

      expect(seeds, isEmpty);
      expect(plan.entryFor('A')!.versionIncrement, 'major');
    });

    test('carries the recorded commits into the pull-request body', () async {
      final planner = makePlanner();
      await gg.RepoPublishConfig(
        commits: [
          gg.CommitMessage(firstLine: 'Add tracking', details: ['d']),
        ],
      ).save(file: gg.repoPublishConfigFile(repoDir('A')));

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
      );

      expect(plan.entryFor('A')!.pullRequestBody, '- Add tracking\n  - d');
      // The answers the questions do not touch survive them.
      expect(plan.configs['A']!.commits.single.firstLine, 'Add tracking');
    });

    test('reads the answers of a legacy ticket-level config', () async {
      final planner = makePlanner(increments: const [], hasTerminal: false);
      legacyTicketPublishConfigFile(ticketDir)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '{"version_increment":"minor","merge_message":"legacy"}',
        );

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
      );

      expect(seeds, isEmpty);
      expect(plan.entryFor('A')!.versionIncrement, 'minor');
      expect(plan.entryFor('A')!.mergeMessage, 'legacy');
    });

    test('save() writes one publish_config.json per repo', () async {
      final planner = makePlanner(increments: [0]);

      final plan = await planner.plan(
        ticketDir: ticketDir,
        subs: [node('A')],
        ggLog: ggLog,
        defaultMergeMessage: 'The change',
      );
      await plan.save();

      final reloaded = gg.RepoPublishConfig.tryLoad(repoDir('A'))!;
      expect(reloaded.mergeMessage, 'The change');
      expect(reloaded.versionIncrement, VersionIncrement.patch);
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

    group('with an editor', () {
      late List<String> sheets;

      /// An editor answering every sheet with [answer] of what it was shown.
      gg.EditText editor(String Function(String text) answer) =>
          ({required prompt, required text, required fileName}) async {
            expect(prompt, 'gg do review');
            expect(fileName, 'TICK_publish.jsonc');
            sheets.add(text);
            return answer(text);
          };

      setUp(() => sheets = []);

      test('asks every repository on one sheet', () async {
        final adapter = _StubAdapter(const []);
        final planner = makePlanner(
          adapter: adapter,
          editText: editor(
            (_) =>
                '{"A": {"versionIncrement": "minor", "mergeMessage": ["MA"]},'
                ' "B": {"versionIncrement": "major", '
                '"mergeMessage": ["MB", "Body"]}}',
          ),
        );

        final plan = await planner.plan(
          ticketDir: ticketDir,
          subs: [node('A'), node('B')],
          ggLog: ggLog,
          defaultMergeMessage: 'The change',
          wording: PublishPlanWording.review,
        );

        // Neither the select nor the line editor was used.
        expect(adapter.capturedOptions, isEmpty);
        expect(seeds, isEmpty);
        expect(sheets, hasLength(1));
        expect(sheets.single, contains('"A": {'));
        expect(sheets.single, contains('"B": {'));
        expect(sheets.single, contains('"mergeMessage": ["The change"]'));
        expect(sheets.single, contains('"versionIncrement": "patch"'));
        expect(sheets.single, contains('1.2.3 → patch 1.2.4'));
        expect(plan.configs['A']!.versionIncrement, VersionIncrement.minor);
        expect(plan.configs['A']!.mergeMessage, 'MA');
        expect(plan.configs['B']!.versionIncrement, VersionIncrement.major);
        expect(plan.entryFor('B')!.mergeMessage, 'MB\nBody');
      });

      test('shows the recorded answers next to the open ones', () async {
        await gg.RepoPublishConfig(
          versionIncrement: VersionIncrement.minor,
          mergeMessage: 'recorded',
          commits: [gg.CommitMessage(firstLine: 'kept')],
        ).save(file: gg.repoPublishConfigFile(repoDir('A')));

        final plan = await makePlanner(editText: editor((text) => text)).plan(
          ticketDir: ticketDir,
          subs: [node('A'), node('B')],
          ggLog: ggLog,
          wording: PublishPlanWording.review,
        );

        expect(sheets.single, contains('"versionIncrement": "minor"'));
        expect(sheets.single, contains('"mergeMessage": ["recorded"]'));
        // B had nothing recorded and no ticket description to start from.
        expect(sheets.single, contains('"mergeMessage": ["Publish B"]'));
        expect(plan.configs['A']!.commits.single.firstLine, 'kept');
        expect(plan.configs['B']!.mergeMessage, 'Publish B');
        expect(plan.configs['B']!.versionIncrement, VersionIncrement.patch);
      });

      test('opens no sheet when every answer is recorded', () async {
        await gg.RepoPublishConfig(
          versionIncrement: VersionIncrement.minor,
          mergeMessage: 'recorded',
        ).save(file: gg.repoPublishConfigFile(repoDir('A')));

        await makePlanner(editText: editor((text) => text))
            .plan(ticketDir: ticketDir, subs: [node('A')], ggLog: ggLog);

        expect(sheets, isEmpty);
      });

      test('drops a repository an answer puts back in range, and keeps what '
          'it had recorded', () async {
        // B publishes only while A is predicted as anything but 1.2.4. A's
        // recorded major puts B on the sheet; answering patch drops it — the
        // pass runs again without asking anything twice, and B's answers on
        // the sheet are not taken over: B is not released.
        await gg.RepoPublishConfig(
          versionIncrement: VersionIncrement.major,
          mergeMessage: 'recorded A',
        ).save(file: gg.repoPublishConfigFile(repoDir('A')));
        await gg.RepoPublishConfig(
          versionIncrement: VersionIncrement.minor,
          mergeMessage: 'recorded B',
          commits: [gg.CommitMessage(firstLine: 'B work')],
        ).save(file: gg.repoPublishConfigFile(repoDir('B')));
        final bBefore = gg
            .repoPublishConfigFile(repoDir('B'))
            .readAsStringSync();

        final plan =
            await makePlanner(
              check: _skipBWhenAIs('1.2.4'),
              editText: editor(
                (_) =>
                    '{"A": {"versionIncrement": "patch"},'
                    ' "B": {"versionIncrement": "major", '
                    '"mergeMessage": ["changed B"]}}',
              ),
            ).plan(
              ticketDir: ticketDir,
              subs: [node('A'), node('B')],
              ggLog: ggLog,
              reconfigure: true,
              wording: PublishPlanWording.review,
            );

        expect(sheets, hasLength(1));
        expect(sheets.single, contains('"B": {'));
        expect(plan.publishes, {'A'});
        expect(plan.configs['A']!.versionIncrement, VersionIncrement.patch);
        expect(plan.configs['B']!.mergeMessage, 'recorded B');
        expect(plan.configs['B']!.versionIncrement, VersionIncrement.minor);
        expect(plan.entryFor('B')!.mergeMessage, 'recorded B');
        expect(messages.join('\n'), contains('decided'));

        await plan.save();
        expect(
          gg.repoPublishConfigFile(repoDir('B')).readAsStringSync(),
          bBefore,
        );
      });

      test('judges the dependents of an open repository by the increment '
          'its question starts with', () async {
        // A is unanswered. Predicting it as unknown would put B on the sheet
        // only to drop it afterwards; its patch default keeps B in range.
        final plan =
            await makePlanner(
              check: _skipBWhenAIs('1.2.4'),
              editText: editor((text) => text),
            ).plan(
              ticketDir: ticketDir,
              subs: [node('A'), node('B')],
              ggLog: ggLog,
              wording: PublishPlanWording.review,
            );

        expect(sheets, hasLength(1));
        expect(sheets.single, isNot(contains('"B"')));
        expect(plan.publishes, {'A'});
        expect(plan.configs['B']!.mergeMessage, isNull);
      });

      test('asks a repository on a second sheet when an answer makes it '
          'publish', () async {
        final plan =
            await makePlanner(
              check: _skipBWhenAIs('1.2.4'),
              editText: editor(
                (text) => text.contains('"A"')
                    ? '{"A": {"versionIncrement": "major"}}'
                    : text,
              ),
            ).plan(
              ticketDir: ticketDir,
              subs: [node('A'), node('B')],
              ggLog: ggLog,
              wording: PublishPlanWording.review,
            );

        expect(sheets, hasLength(2));
        expect(sheets[0], isNot(contains('"B"')));
        // A was asked already — only B is on the second sheet.
        expect(sheets[1], contains('"B": {'));
        expect(sheets[1], isNot(contains('"A"')));
        expect(plan.publishes, {'A', 'B'});
        expect(plan.configs['A']!.versionIncrement, VersionIncrement.major);
        expect(plan.configs['B']!.versionIncrement, VersionIncrement.patch);
      });

      test('shows what alsoShow repos recorded, not the -m of the open '
          'ones', () async {
        await gg.RepoPublishConfig(
          versionIncrement: VersionIncrement.minor,
          mergeMessage: 'recorded A',
        ).save(file: gg.repoPublishConfigFile(repoDir('A')));

        final plan = await makePlanner(editText: editor((text) => text)).plan(
          ticketDir: ticketDir,
          subs: [node('A'), node('B')],
          ggLog: ggLog,
          defaultMergeMessage: 'From -m',
          wording: PublishPlanWording.review,
        );

        expect(sheets.single, contains('"mergeMessage": ["recorded A"]'));
        expect(sheets.single, contains('"mergeMessage": ["From -m"]'));
        expect(plan.configs['A']!.mergeMessage, 'recorded A');
        expect(plan.configs['B']!.mergeMessage, 'From -m');
      });

      test('keeps the recorded increments in a merge-only run', () async {
        await gg.RepoPublishConfig(
          versionIncrement: VersionIncrement.minor,
          mergeMessage: 'recorded A',
        ).save(file: gg.repoPublishConfigFile(repoDir('A')));
        await gg.RepoPublishConfig(versionIncrement: VersionIncrement.major)
            .save(file: gg.repoPublishConfigFile(repoDir('B')));

        final plan = await makePlanner(editText: editor((text) => text)).plan(
          ticketDir: ticketDir,
          subs: [node('A'), node('B')],
          ggLog: ggLog,
          mergeOnly: true,
          wording: PublishPlanWording.review,
        );

        expect(sheets.single, contains('"A": {'));
        expect(plan.configs['A']!.versionIncrement, VersionIncrement.minor);
        expect(plan.configs['A']!.mergeMessage, 'recorded A');
        expect(plan.configs['B']!.versionIncrement, VersionIncrement.major);
        expect(plan.configs['B']!.mergeMessage, 'Publish B');
      });

      test('asks no increment in a merge-only run', () async {
        final plan = await makePlanner(editText: editor((text) => text)).plan(
          ticketDir: ticketDir,
          subs: [node('A')],
          ggLog: ggLog,
          mergeOnly: true,
          wording: PublishPlanWording.review,
        );

        expect(sheets.single, isNot(contains('"versionIncrement"')));
        expect(plan.configs['A']!.versionIncrement, isNull);
        expect(plan.configs['A']!.mergeMessage, 'Publish A');
      });

      test('falls back to one prompt per repository when the editor '
          'fails', () async {
        var opened = 0;
        final plan =
            await makePlanner(
              increments: [1],
              editText: ({required prompt, required text, required fileName}) {
                opened++;
                throw Exception('code exited with 1');
              },
            ).plan(
              ticketDir: ticketDir,
              subs: [node('A'), node('B')],
              ggLog: ggLog,
              defaultMergeMessage: 'The change',
            );

        // The editor is not tried again for B.
        expect(opened, 1);
        expect(seeds, ['The change', 'The change']);
        expect(plan.configs['A']!.versionIncrement, VersionIncrement.minor);
        expect(plan.configs['B']!.versionIncrement, VersionIncrement.minor);
        expect(
          messages.join('\n'),
          contains('Could not edit the messages in the editor'),
        );
      });
    });

    group('without an editor', () {
      test('looks the registry version up once per repository', () async {
        // The sheet looked it up before the editor turned out to be missing;
        // the prompt reuses that lookup instead of failing a second time.
        await makePlanner(baselineThrows: true)
            .plan(ticketDir: ticketDir, subs: [node('A')], ggLog: ggLog);

        expect(
          messages.where(
            (m) => m.contains('Could not determine the published version'),
          ),
          hasLength(1),
        );
      });

      test('asks a dependent nothing when the answer before it keeps it in '
          'range', () async {
        // The old order: A is asked first, and B is judged by that answer.
        final plan = await makePlanner(check: _skipBWhenAIs('1.2.4')).plan(
          ticketDir: ticketDir,
          subs: [node('A'), node('B')],
          ggLog: ggLog,
          defaultMergeMessage: 'The change',
        );

        expect(seeds, ['The change']);
        expect(plan.publishes, {'A'});
      });

      test('asks one repository at a time, so an answer can drop the '
          'next', () async {
        // A's recorded major makes B publish — until A is answered with
        // patch. B is never prompted, and keeps its file as it was.
        await gg.RepoPublishConfig(versionIncrement: VersionIncrement.major)
            .save(file: gg.repoPublishConfigFile(repoDir('A')));
        await gg.RepoPublishConfig(mergeMessage: 'recorded B')
            .save(file: gg.repoPublishConfigFile(repoDir('B')));

        final adapter = _StubAdapter([0]); // patch
        final plan =
            await makePlanner(
              adapter: adapter,
              check: _skipBWhenAIs('1.2.4'),
            ).plan(
              ticketDir: ticketDir,
              subs: [node('A'), node('B')],
              ggLog: ggLog,
              defaultMergeMessage: 'The change',
            );

        expect(seeds, ['The change']);
        expect(adapter.capturedOptions, hasLength(1));
        expect(plan.publishes, {'A'});
        expect(plan.configs['B']!.mergeMessage, 'recorded B');
        expect(plan.configs['B']!.versionIncrement, isNull);
      });

      test('asks nothing when everything is recorded', () async {
        // The old path: no editor, recorded answers, no reconfigure.
        await gg.RepoPublishConfig(
          versionIncrement: VersionIncrement.minor,
          mergeMessage: 'recorded A',
        ).save(file: gg.repoPublishConfigFile(repoDir('A')));
        await gg.RepoPublishConfig(
          versionIncrement: VersionIncrement.patch,
          mergeMessage: 'recorded B',
        ).save(file: gg.repoPublishConfigFile(repoDir('B')));
        final bBefore = gg
            .repoPublishConfigFile(repoDir('B'))
            .readAsStringSync();

        final adapter = _StubAdapter(const []);
        final plan =
            await makePlanner(
              adapter: adapter,
              check: _skipBWhenAIs('1.3.0'),
            ).plan(
              ticketDir: ticketDir,
              subs: [node('A'), node('B')],
              ggLog: ggLog,
            );
        await plan.save();

        expect(seeds, isEmpty);
        expect(adapter.capturedOptions, isEmpty);
        expect(plan.publishes, {'A'});
        expect(
          gg.repoPublishConfigFile(repoDir('B')).readAsStringSync(),
          bBefore,
        );
      });
    });

    group('--no-interactive', () {
      test('takes the ticket description as merge message', () async {
        File(path.join(ticketDir.path, 'ticket.json'))
            .writeAsStringSync('{"description": "Ticket desc"}');

        final plan = await makePlanner(increments: const []).plan(
          ticketDir: ticketDir,
          subs: [node('A')],
          ggLog: ggLog,
          interactive: false,
          requireAnswers: false,
        );

        expect(seeds, isEmpty);
        expect(plan.entryFor('A')!.mergeMessage, 'Ticket desc');
        expect(plan.entryFor('A')!.versionIncrement, isNull);
        expect(plan.defaultedMessages, {'A'});
      });

      test('save can leave the defaulted messages out', () async {
        // A headless review must not record a default as an answer: the
        // `-m` of the publish after it would no longer win.
        await gg.RepoPublishConfig(
          versionIncrement: VersionIncrement.minor,
          commits: [gg.CommitMessage(firstLine: 'A work')],
        ).save(file: gg.repoPublishConfigFile(repoDir('A')));
        await gg.RepoPublishConfig(mergeMessage: 'recorded B')
            .save(file: gg.repoPublishConfigFile(repoDir('B')));

        final plan = await makePlanner(increments: const []).plan(
          ticketDir: ticketDir,
          subs: [node('A'), node('B')],
          ggLog: ggLog,
          interactive: false,
          requireAnswers: false,
          defaultMergeMessage: 'From -m',
        );
        expect(plan.configs['A']!.mergeMessage, 'From -m');
        expect(plan.defaultedMessages, {'A'});

        await plan.save(keepDefaultedMessages: false);
        final a = gg.RepoPublishConfig.tryLoad(repoDir('A'))!;
        expect(a.mergeMessage, isNull);
        expect(a.versionIncrement, VersionIncrement.minor);
        expect(a.commits.single.firstLine, 'A work');
        expect(
          gg.RepoPublishConfig.tryLoad(repoDir('B'))!.mergeMessage,
          'recorded B',
        );

        // `gg do publish` records them: the release reads them back.
        await plan.save();
        expect(
          gg.RepoPublishConfig.tryLoad(repoDir('A'))!.mergeMessage,
          'From -m',
        );
      });

      test('fails a run that needs a missing increment', () async {
        await expectLater(
          () => makePlanner(increments: const []).plan(
            ticketDir: ticketDir,
            subs: [node('A')],
            ggLog: ggLog,
            interactive: false,
            defaultMergeMessage: 'msg',
          ),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('A needs a publish'),
            ),
          ),
        );
      });
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
        String? channel,
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

        if (channel != null) {
          await gg.PublishState(channel: channel)
              .save(file: gg.publishStateFile(repoDir('A')));
        }

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
          mergeOnly: mergeOnly,
        );
        return captured.last;
      }

      /// Gives repo A a manifest, so its published name is »a«.
      void manifestOfA(String version) =>
          File(path.join(repoDir('A').path, 'pubspec.yaml'))
              .writeAsStringSync('name: a\nversion: $version\n');

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
        final refVersions = await refVersionsOfB(channel: 'rc');
        expect(refVersions, isNot(contains('a')));
      });

      test('is unknown when the registry lookup fails', () async {
        // The 0.0.0 the increment preview assumes is no version to judge a
        // dependent against.
        manifestOfA('0.0.1');
        expect(
          await refVersionsOfB(baselineThrows: true),
          isNot(contains('a')),
        );
      });

      test('is unknown when the lookup for the sheet failed', () async {
        manifestOfA('0.0.1');
        final captured = <Map<String, String>>[];
        final check = MockPublishSkipCheck();
        when(
          () => check.get(
            repo: any(named: 'repo'),
            refVersions: any(named: 'refVersions'),
          ),
        ).thenAnswer((invocation) async {
          captured.add(
            Map<String, String>.from(
              invocation.namedArguments[#refVersions] as Map<String, String>,
            ),
          );
          return const PublishSkipDecision(skip: false, reason: 'changed');
        });
        final sheets = <String>[];

        await makePlanner(
          check: check,
          baselineThrows: true,
          editText:
              ({required prompt, required text, required fileName}) async {
                sheets.add(text);
                return text;
              },
        ).plan(
          ticketDir: ticketDir,
          subs: [node('A'), node('B')],
          ggLog: ggLog,
        );

        expect(sheets, hasLength(1));
        // No preview without a baseline …
        expect(sheets.single, isNot(contains('→ patch')));
        // … and no prediction either.
        expect(captured.last, isNot(contains('a')));
        expect(
          messages.join('\n'),
          contains('Could not determine the published version of A'),
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
      expect(PublishPlanWording.publish.skipPrefix, isEmpty);
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
      File(path.join(ticketDir.path, ticketJsonFileName))
          .writeAsStringSync(jsonEncode(<String>[]));
      expect(PublishPlanner.seedMessageFor(ticketDir: ticketDir), '');
    });
  });
}

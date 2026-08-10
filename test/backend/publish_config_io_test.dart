// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_core/src/backend/publish_config_io.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_publish/gg_publish.dart' show VersionIncrement;
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory ticketDir;

  setUp(() async {
    ticketDir = await Directory.systemTemp.createTemp('publish_config_io_');
  });

  tearDown(() async {
    await ticketDir.delete(recursive: true);
  });

  Directory repoDir(String name) =>
      Directory(path.join(ticketDir.path, name))..createSync(recursive: true);

  void writeTicketLegacy(String content) =>
      legacyTicketPublishConfigFile(ticketDir)
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  gg.RepoPublishFiles load(Directory repo) =>
      loadTicketRepoPublishFiles(repoDir: repo, ticketDir: ticketDir);

  group('legacyTicketPublishConfigFile()', () {
    test('names <ticket>/.gg/gg-publish.json', () {
      expect(
        legacyTicketPublishConfigFile(ticketDir).path,
        path.join(ticketDir.path, '.gg', 'gg-publish.json'),
      );
    });
  });

  group('loadTicketRepoPublishFiles()', () {
    test('returns empty halves when nothing was recorded anywhere', () {
      final files = load(repoDir('A'));
      expect(files.config.mergeMessage, isNull);
      expect(files.state.status, isNull);
    });

    test('prefers the repo files over the ticket-level legacy one', () async {
      final repo = repoDir('A');
      writeTicketLegacy('{"merge_message":"legacy"}');
      await gg.RepoPublishConfig(
        mergeMessage: 'own',
      ).save(file: gg.repoPublishConfigFile(repo));

      expect(load(repo).config.mergeMessage, 'own');
    });

    test(
      'a repo that recorded only commits counts as its own answer',
      () async {
        final repo = repoDir('A');
        writeTicketLegacy('{"merge_message":"legacy"}');
        await gg.RepoPublishConfig(
          commits: [gg.CommitMessage(firstLine: 'Add tracking')],
        ).save(file: gg.repoPublishConfigFile(repo));

        final files = load(repo);
        expect(files.config.commits.single.firstLine, 'Add tracking');
        expect(files.config.mergeMessage, isNull);
      },
    );

    test('a repo that recorded only a proposal counts as its own '
        'answer', () async {
      final repo = repoDir('A');
      writeTicketLegacy('{"merge_message":"legacy"}');
      await gg.RepoPublishConfig(
        nextCommitMessage: gg.CommitMessage(firstLine: 'Next'),
      ).save(file: gg.repoPublishConfigFile(repo));

      expect(load(repo).config.mergeMessage, isNull);
    });

    test('a repo that recorded only an increment counts as its own '
        'answer', () async {
      final repo = repoDir('A');
      writeTicketLegacy('{"merge_message":"legacy"}');
      await gg.RepoPublishConfig(
        versionIncrement: VersionIncrement.major,
      ).save(file: gg.repoPublishConfigFile(repo));

      expect(load(repo).config.mergeMessage, isNull);
    });

    test('resolves the two halves independently', () async {
      // A repo that recorded its own progress but no answers still gets the
      // answers of the ticket-level leftover — writing one half must not
      // hide the other.
      final repo = repoDir('A');
      writeTicketLegacy('{"merge_message":"legacy","channel":"rc"}');
      await gg.PublishState(
        doneSteps: ['merge'],
      ).save(file: gg.publishStateFile(repo));

      expect(load(repo).config.mergeMessage, 'legacy');
      expect(load(repo).state.doneSteps, ['merge']);
      // The repo's own state answers for the state half — the legacy
      // channel does not leak into it.
      expect(load(repo).state.channel, isNull);
    });

    test('own answers keep the legacy run state visible', () async {
      final repo = repoDir('A');
      writeTicketLegacy('{"merge_message":"legacy","channel":"rc"}');
      await gg.RepoPublishConfig(
        mergeMessage: 'own',
      ).save(file: gg.repoPublishConfigFile(repo));

      expect(load(repo).config.mergeMessage, 'own');
      expect(load(repo).state.channel, 'rc');
    });

    test('falls back to the ticket-level legacy config', () {
      writeTicketLegacy('''
{
  "version_increment": "patch",
  "merge_message": "top",
  "repos": {
    "A": {
      "version_increment": "major",
      "merge_message": "mine",
      "status": "published"
    }
  }
}
''');

      final files = load(repoDir('A'));
      expect(files.config.mergeMessage, 'mine');
      expect(files.config.versionIncrement, VersionIncrement.major);
      expect(files.state.status, 'published');

      // A repo the legacy file does not mention gets the top-level default.
      final other = load(repoDir('B'));
      expect(other.config.mergeMessage, 'top');
      expect(other.config.versionIncrement, VersionIncrement.patch);
    });

    test('a repo-level legacy file wins over the ticket-level one', () {
      final repo = repoDir('A');
      writeTicketLegacy('{"merge_message":"ticket"}');
      File(path.join(repo.path, '.gg', 'gg-publish.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"merge_message":"repo"}');

      expect(load(repo).config.mergeMessage, 'repo');
    });

    test('an unreadable repo file falls back to the ticket-level one', () {
      final repo = repoDir('A');
      writeTicketLegacy('{"merge_message":"legacy"}');
      File(path.join(repo.path, '.gg', 'gg-publish.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{ not json');

      // The repo cannot answer, so the ticket-level leftover does.
      expect(load(repo).config.mergeMessage, 'legacy');
    });

    test('an unreadable repo file without a ticket fallback is empty', () {
      final repo = repoDir('A');
      File(path.join(repo.path, '.gg', 'gg-publish.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{ not json');

      expect(load(repo).config.mergeMessage, isNull);
    });

    test('a malformed legacy file does not fail the run', () {
      writeTicketLegacy('{"merge_message": 42}');
      expect(load(repoDir('A')).config.mergeMessage, isNull);
    });
  });

  group('loadTicketPublishState()', () {
    test('is empty when nothing was recorded', () {
      expect(loadTicketPublishState(ticketDir).deleteTicket, isNull);
    });

    test('prefers the ticket state file', () async {
      writeTicketLegacy('{"delete_ticket":true}');
      await gg.PublishState(
        deleteTicket: false,
      ).save(file: gg.publishStateFile(ticketDir));

      expect(loadTicketPublishState(ticketDir).deleteTicket, isFalse);
    });

    test('falls back to the legacy ticket config', () {
      writeTicketLegacy('{"delete_ticket":true}');
      expect(loadTicketPublishState(ticketDir).deleteTicket, isTrue);
    });

    test('a malformed legacy file yields an empty state', () {
      writeTicketLegacy('{"delete_ticket": 42}');
      expect(loadTicketPublishState(ticketDir).deleteTicket, isNull);
    });
  });

  group('anyRepoHasAnswers()', () {
    test('is false when no repo recorded an answer', () {
      expect(
        anyRepoHasAnswers(
          repoDirs: [repoDir('A'), repoDir('B')],
          ticketDir: ticketDir,
        ),
        isFalse,
      );
    });

    test('is true for a recorded merge message', () async {
      final b = repoDir('B');
      await gg.RepoPublishConfig(
        mergeMessage: 'answered',
      ).save(file: gg.repoPublishConfigFile(b));

      expect(
        anyRepoHasAnswers(repoDirs: [repoDir('A'), b], ticketDir: ticketDir),
        isTrue,
      );
    });

    test('is true for a recorded increment alone', () async {
      final a = repoDir('A');
      await gg.RepoPublishConfig(
        versionIncrement: VersionIncrement.minor,
      ).save(file: gg.repoPublishConfigFile(a));

      expect(anyRepoHasAnswers(repoDirs: [a], ticketDir: ticketDir), isTrue);
    });

    test('sees the answers of a legacy ticket-level config', () {
      writeTicketLegacy('{"merge_message":"legacy"}');
      expect(
        anyRepoHasAnswers(repoDirs: [repoDir('A')], ticketDir: ticketDir),
        isTrue,
      );
    });
  });

  group('anyRepoHasStatus()', () {
    test('is false when no repo carries a status', () {
      expect(
        anyRepoHasStatus(
          repoDirs: [repoDir('A'), repoDir('B')],
          ticketDir: ticketDir,
        ),
        isFalse,
      );
    });

    test('is true as soon as one repo carries one', () async {
      final b = repoDir('B');
      await gg.PublishState(
        status: 'pending',
      ).save(file: gg.publishStateFile(b));

      expect(
        anyRepoHasStatus(repoDirs: [repoDir('A'), b], ticketDir: ticketDir),
        isTrue,
      );
    });
  });
}

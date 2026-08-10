// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_core/src/backend/ticket_json.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ticket_json_test');
  });

  tearDown(() {
    if (tmp.existsSync()) {
      tmp.deleteSync(recursive: true);
    }
  });

  Directory makeDir(String name) =>
      Directory(path.join(tmp.path, name))..createSync(recursive: true);

  group('TicketRepo', () {
    test('fromJson reads name and url', () {
      final repo = TicketRepo.fromJson(<String, dynamic>{
        'name': 'gg_one',
        'url': 'git@example.com:org/gg_one.git',
      });
      expect(repo.name, 'gg_one');
      expect(repo.url, 'git@example.com:org/gg_one.git');
    });

    test('fromJson defaults to empty strings when fields are missing', () {
      final repo = TicketRepo.fromJson(const <String, dynamic>{});
      expect(repo.name, '');
      expect(repo.url, '');
    });

    test('toJson serializes name and url', () {
      const repo = TicketRepo(name: 'a', url: 'b');
      expect(repo.toJson(), <String, String>{'name': 'a', 'url': 'b'});
    });
  });

  group('TicketJson', () {
    test('fromJsonString parses a full marker, filtering bad repo entries', () {
      const source = '''
{
  "issue_id": "feat_x",
  "description": "desc",
  "repositories": [
    { "name": "gg_one", "url": "u1" },
    "not-an-object",
    { "name": "gg_multi", "url": "u2" }
  ]
}
''';
      final ticket = TicketJson.fromJsonString(source);
      expect(ticket.issueId, 'feat_x');
      expect(ticket.description, 'desc');
      expect(ticket.repositories.length, 2);
      expect(ticket.repositories.first.name, 'gg_one');
      expect(ticket.repositories.last.url, 'u2');
    });

    test('fromJsonString defaults fields and tolerates non-list repos', () {
      final ticket = TicketJson.fromJsonString('{"repositories": 42}');
      expect(ticket.issueId, '');
      expect(ticket.description, '');
      expect(ticket.repositories, isEmpty);
    });

    test('fromJsonString throws on a non-object source', () {
      expect(
        () => TicketJson.fromJsonString('[1, 2, 3]'),
        throwsA(isA<FormatException>()),
      );
    });

    test('toPrettyJson is multi-line, indented and newline-terminated', () {
      const ticket = TicketJson(
        issueId: 'feat_x',
        description: 'desc',
        repositories: [TicketRepo(name: 'gg_one', url: 'u1')],
      );
      final json = ticket.toPrettyJson();
      expect(json.endsWith('\n'), isTrue);
      expect(json.split('\n').length, greaterThan(3));
      expect(json, contains('  "issue_id": "feat_x"'));

      // Round-trips back to an equivalent marker.
      final parsed = TicketJson.fromJsonString(json);
      expect(parsed.issueId, 'feat_x');
      expect(parsed.repositories.single.url, 'u1');
    });

    group('gg_version', () {
      final originalGgCliVersion = ggCliVersion;

      tearDown(() {
        ggCliVersion = originalGgCliVersion;
      });

      test('toPrettyJson serializes gg_version', () {
        ggCliVersion = '2.0.0';
        const ticket = TicketJson(
          issueId: 'feat_x',
          description: 'desc',
          repositories: [],
          ggVersion: '1.2.3',
        );
        expect(ticket.toPrettyJson(), contains('"gg_version": "1.2.3"'));
        expect(
          TicketJson.fromJsonString(ticket.toPrettyJson()).ggVersion,
          '1.2.3',
        );
      });

      test('fromJsonString accepts markers without gg_version', () {
        final ticket = TicketJson.fromJsonString('{"issue_id": "x"}');
        expect(ticket.ggVersion, '');
      });

      test(
        'fromJsonString accepts markers with an older or equal gg_version',
        () {
          ggCliVersion = '2.0.0';
          expect(
            TicketJson.fromJsonString('{"gg_version": "1.9.9"}').ggVersion,
            '1.9.9',
          );
          expect(
            TicketJson.fromJsonString('{"gg_version": "2.0.0"}').ggVersion,
            '2.0.0',
          );
        },
      );

      test('fromJsonString throws when the marker needs a newer gg', () {
        ggCliVersion = '2.0.0';
        expect(
          () => TicketJson.fromJsonString('{"gg_version": "2.0.1"}'),
          throwsA(
            predicate<Exception>(
              (e) =>
                  e.toString().contains('written with gg 2.0.1') &&
                  e.toString().contains('gg 2.0.0 is installed') &&
                  e.toString().contains('dart pub global activate gg'),
            ),
          ),
        );
      });

      test('fromJsonString ignores unparseable versions', () {
        ggCliVersion = '2.0.0';
        expect(
          TicketJson.fromJsonString(
            '{"gg_version": "not-a-version"}',
          ).ggVersion,
          'not-a-version',
        );
        ggCliVersion = 'broken';
        expect(
          TicketJson.fromJsonString('{"gg_version": "99.0.0"}').ggVersion,
          '99.0.0',
        );
      });
    });
  });

  group('buildTicketJson', () {
    test('derives issue id, description and repo list with urls', () {
      final ticketDir = makeDir('my_ticket');
      File(
        path.join(ticketDir.path, ticketJsonFileName),
      ).writeAsStringSync('{"issue_id":"my_ticket","description":"the desc"}');

      // One repo with a remote, one without.
      final withRemote = makeDir('repo_a');
      Directory(path.join(withRemote.path, '.git')).createSync();
      File(path.join(withRemote.path, '.git', 'config')).writeAsStringSync(
        '[remote "origin"]\n\turl = git@example.com:org/repo_a.git\n',
      );
      final withoutRemote = makeDir('repo_b');

      final ticket = buildTicketJson(
        ticketDir: ticketDir,
        repoDirs: [withRemote, withoutRemote],
      );

      expect(ticket.issueId, 'my_ticket');
      expect(ticket.description, 'the desc');
      expect(ticket.repositories.length, 2);
      expect(ticket.repositories[0].name, 'repo_a');
      expect(ticket.repositories[0].url, 'git@example.com:org/repo_a.git');
      expect(ticket.repositories[1].name, 'repo_b');
      expect(ticket.repositories[1].url, '');
      expect(ticket.ggVersion, ggCliVersion);
    });

    test('uses an empty description when ticket.json is absent', () {
      final ticketDir = makeDir('no_ticket_file');
      final ticket = buildTicketJson(
        ticketDir: ticketDir,
        repoDirs: const <Directory>[],
      );
      expect(ticket.description, '');
      expect(ticket.repositories, isEmpty);
    });

    test('uses an empty description when ticket.json lacks the field', () {
      final ticketDir = makeDir('partial_ticket');
      File(
        path.join(ticketDir.path, ticketJsonFileName),
      ).writeAsStringSync('{"issue_id":"x"}');
      final ticket = buildTicketJson(
        ticketDir: ticketDir,
        repoDirs: const <Directory>[],
      );
      expect(ticket.description, '');
    });

    test('uses an empty description when ticket.json is malformed', () {
      final ticketDir = makeDir('broken_ticket');
      File(
        path.join(ticketDir.path, ticketJsonFileName),
      ).writeAsStringSync('not json');
      final ticket = buildTicketJson(
        ticketDir: ticketDir,
        repoDirs: const <Directory>[],
      );
      expect(ticket.description, '');
    });

    test('uses an empty description when ticket.json is not an object', () {
      final ticketDir = makeDir('array_ticket');
      File(
        path.join(ticketDir.path, ticketJsonFileName),
      ).writeAsStringSync('[1,2]');
      final ticket = buildTicketJson(
        ticketDir: ticketDir,
        repoDirs: const <Directory>[],
      );
      expect(ticket.description, '');
    });
  });

  group('writeTicketJson', () {
    const ticket = TicketJson(
      issueId: 'feat_x',
      description: 'desc',
      repositories: [TicketRepo(name: 'r', url: 'u')],
    );

    File fileOf(Directory ticketDir) =>
        File(path.join(ticketDir.path, ticketJsonFileName));

    test('writes the pretty ticket.json into the ticket folder', () {
      final ticketDir = makeDir('fresh');
      writeTicketJson(ticketDir, ticket);
      expect(fileOf(ticketDir).readAsStringSync(), ticket.toPrettyJson());
    });

    test('creates the ticket folder when it does not exist yet', () {
      final ticketDir = Directory(path.join(tmp.path, 'not_yet'));
      writeTicketJson(ticketDir, ticket);
      expect(fileOf(ticketDir).existsSync(), isTrue);
    });

    test('overwrites an existing ticket.json', () {
      final ticketDir = makeDir('again');
      fileOf(ticketDir).writeAsStringSync('stale');
      writeTicketJson(ticketDir, ticket);
      expect(fileOf(ticketDir).readAsStringSync(), ticket.toPrettyJson());
    });

    test('writes nothing into the repositories of the ticket', () {
      final ticketDir = makeDir('no_repo_marker');
      final repo = Directory(path.join(ticketDir.path, 'org', 'repo'))
        ..createSync(recursive: true);
      writeTicketJson(ticketDir, ticket);
      expect(Directory(path.join(repo.path, '.gg')).existsSync(), isFalse);
    });
  });

  group('readTicketJson', () {
    test('reads back what writeTicketJson wrote', () {
      final ticketDir = makeDir('roundtrip');
      const written = TicketJson(
        issueId: 'feat_x',
        description: 'desc',
        repositories: [TicketRepo(name: 'r', url: 'u')],
      );
      writeTicketJson(ticketDir, written);

      final read = readTicketJson(ticketDir)!;
      expect(read.issueId, 'feat_x');
      expect(read.description, 'desc');
      expect(read.repositories.single.name, 'r');
      expect(read.repositories.single.url, 'u');
    });

    test('returns null when there is no ticket.json', () {
      expect(readTicketJson(makeDir('empty')), isNull);
    });

    test('returns null when the ticket.json is malformed', () {
      final ticketDir = makeDir('broken');
      File(
        path.join(ticketDir.path, ticketJsonFileName),
      ).writeAsStringSync('{not json');
      expect(readTicketJson(ticketDir), isNull);
    });

    test('returns null when the ticket.json is not an object', () {
      final ticketDir = makeDir('array');
      File(
        path.join(ticketDir.path, ticketJsonFileName),
      ).writeAsStringSync('[1,2]');
      expect(readTicketJson(ticketDir), isNull);
    });

    test('throws when the ticket.json needs a newer gg', () {
      final ticketDir = makeDir('too_new');
      writeTicketJson(
        ticketDir,
        const TicketJson(
          issueId: 'x',
          description: '',
          repositories: [],
          ggVersion: '9999.0.0',
        ),
      );
      expect(() => readTicketJson(ticketDir), throwsA(isA<Exception>()));
    });
  });
}

// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_git/gg_git.dart';
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_multi_core/src/backend/ticket_state.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:test/test.dart';

class _MockLastChangesHash extends Mock implements LastChangesHash {}

class _FakeDirectory extends Fake implements Directory {}

void main() {
  late Directory tempDir;
  late Directory ticketDir;
  late _MockLastChangesHash hash;
  late TicketState state;
  final messages = <String>[];

  setUpAll(() {
    registerFallbackValue(_FakeDirectory());
  });

  Node node(String name) => Node(
    name: name,
    directory: Directory(path.join(ticketDir.path, name))
      ..createSync(recursive: true),
    manifest: DartPackageManifest(pubspec: Pubspec(name)),
  );

  void mockHashForRepo(String repoName, int value) {
    when(
      () => hash.get(
        directory: any(
          named: 'directory',
          that: predicate<Directory>((d) => path.basename(d.path) == repoName),
        ),
        ggLog: any(named: 'ggLog'),
        ignoreFiles: any(named: 'ignoreFiles'),
        ignoreUnstaged: any(named: 'ignoreUnstaged'),
      ),
    ).thenAnswer((_) async => value);
  }

  setUp(() {
    messages.clear();
    tempDir = Directory.systemTemp.createTempSync('ticket_state_test_');
    ticketDir = Directory(path.join(tempDir.path, 'TICKR'))..createSync();
    hash = _MockLastChangesHash();
    state = TicketState(ggLog: messages.add, lastChangesHash: hash);
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('TicketState', () {
    test('uses a default LastChangesHash when none is injected', () {
      expect(() => TicketState(ggLog: messages.add), returnsNormally);
    });

    group('currentHash', () {
      test('folds per-repo hashes deterministically', () async {
        mockHashForRepo('A', 11);
        mockHashForRepo('B', 22);

        final subs = [node('A'), node('B')];
        final firstRun = await state.currentHash(subs: subs);
        final secondRun = await state.currentHash(subs: subs);

        expect(firstRun, secondRun);
      });

      test('is independent of input order', () async {
        mockHashForRepo('A', 11);
        mockHashForRepo('B', 22);

        final h1 = await state.currentHash(subs: [node('A'), node('B')]);
        final h2 = await state.currentHash(subs: [node('B'), node('A')]);

        expect(h1, h2);
      });

      test('changes when any per-repo hash changes', () async {
        mockHashForRepo('A', 11);
        mockHashForRepo('B', 22);
        final subs = [node('A'), node('B')];
        final before = await state.currentHash(subs: subs);

        reset(hash);
        mockHashForRepo('A', 11);
        mockHashForRepo('B', 99);
        final after = await state.currentHash(subs: subs);

        expect(before, isNot(equals(after)));
      });

      test('passes ignoreFiles and ignoreUnstaged through', () async {
        mockHashForRepo('A', 1);
        await state.currentHash(subs: [node('A')], ignoreUnstaged: true);

        verify(
          () => hash.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            ignoreFiles: TicketState.ignoreFiles,
            ignoreUnstaged: true,
          ),
        ).called(1);
      });
    });

    group('readSuccess', () {
      test('returns false when .gg.json is missing', () async {
        mockHashForRepo('A', 1);
        final result = await state.readSuccess(
          ticketDir: ticketDir,
          subs: [node('A')],
          key: 'canReview',
        );
        expect(result, isFalse);
      });

      test('returns false when key is absent', () async {
        mockHashForRepo('A', 1);
        File(path.join(ticketDir.path, '.gg.json')).writeAsStringSync(
          jsonEncode(<String, dynamic>{'other': <String, dynamic>{}}),
        );

        final result = await state.readSuccess(
          ticketDir: ticketDir,
          subs: [node('A')],
          key: 'canReview',
        );
        expect(result, isFalse);
      });

      test('returns true after writeSuccess with same state', () async {
        mockHashForRepo('A', 1);
        final subs = [node('A')];

        await state.writeSuccess(
          ticketDir: ticketDir,
          subs: subs,
          key: 'canReview',
        );

        final result = await state.readSuccess(
          ticketDir: ticketDir,
          subs: subs,
          key: 'canReview',
        );
        expect(result, isTrue);
      });

      test('returns false after a repo hash changes', () async {
        mockHashForRepo('A', 1);
        final subs = [node('A')];
        await state.writeSuccess(
          ticketDir: ticketDir,
          subs: subs,
          key: 'canReview',
        );

        reset(hash);
        mockHashForRepo('A', 2);

        final result = await state.readSuccess(
          ticketDir: ticketDir,
          subs: subs,
          key: 'canReview',
        );
        expect(result, isFalse);
      });
    });

    group('writeSuccess', () {
      test('preserves other keys', () async {
        File(path.join(ticketDir.path, '.gg.json')).writeAsStringSync(
          jsonEncode({
            'canPublish': {
              'success': {'hash': 42},
            },
          }),
        );

        mockHashForRepo('A', 1);
        await state.writeSuccess(
          ticketDir: ticketDir,
          subs: [node('A')],
          key: 'canReview',
        );

        final raw = File(
          path.join(ticketDir.path, '.gg.json'),
        ).readAsStringSync();
        final data = jsonDecode(raw) as Map<String, dynamic>;
        expect(data['canPublish'], isNotNull);
        expect(data['canReview'], isNotNull);
      });
    });

    group('reset', () {
      test('clears the file when present', () async {
        mockHashForRepo('A', 1);
        await state.writeSuccess(
          ticketDir: ticketDir,
          subs: [node('A')],
          key: 'canReview',
        );

        await state.reset(ticketDir: ticketDir);

        final raw = File(
          path.join(ticketDir.path, '.gg.json'),
        ).readAsStringSync();
        expect(raw, '{}');
      });

      test('does nothing if no file exists', () async {
        await state.reset(ticketDir: ticketDir);
        expect(
          File(path.join(ticketDir.path, '.gg.json')).existsSync(),
          isFalse,
        );
      });
    });
  });
}

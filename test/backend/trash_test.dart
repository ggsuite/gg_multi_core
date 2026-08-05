// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_core/src/backend/trash.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

class MockDirectory extends Mock implements Directory {}

void main() {
  late Directory root;
  late Directory ticketDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('trash_test_');
    ticketDir = Directory(path.join(root.path, 'tickets', 'T1'))
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory repo(String org, String name) {
    final dir = Directory(path.join(ticketDir.path, org, name))
      ..createSync(recursive: true);
    File(path.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: $name');
    return dir;
  }

  group('Trash', () {
    test('dirFor returns <root>/.trash', () {
      expect(Trash.dirFor(root.path).path, path.join(root.path, '.trash'));
    });

    test('dirForTicket returns <root>/.trash/<ticket>', () {
      expect(
        Trash.dirForTicket(ticketDir).path,
        path.join(root.path, '.trash', 'T1'),
      );
    });

    group('createDirForTicket', () {
      test('creates the folder', () {
        final dir = Trash.createDirForTicket(ticketDir);
        expect(dir.existsSync(), isTrue);
        expect(dir.path, path.join(root.path, '.trash', 'T1'));
      });

      test('is a no-op when the folder already exists', () {
        final first = Trash.createDirForTicket(ticketDir);
        File(path.join(first.path, 'keep.txt')).writeAsStringSync('keep');
        final second = Trash.createDirForTicket(ticketDir);
        expect(
          File(path.join(second.path, 'keep.txt')).readAsStringSync(),
          'keep',
        );
      });
    });

    group('moveFromTicket', () {
      test('moves a repo, keeping its <org>/<repo> path', () async {
        final dir = repo('ggsuite', 'gg_multi');

        final target = await Trash.moveFromTicket(
          source: dir,
          ticketDir: ticketDir,
        );

        expect(
          target,
          path.join(root.path, '.trash', 'T1', 'ggsuite', 'gg_multi'),
        );
        expect(dir.existsSync(), isFalse);
        expect(
          File(path.join(target, 'pubspec.yaml')).readAsStringSync(),
          'name: gg_multi',
        );
      });

      test('moves a file', () async {
        final file = File(path.join(ticketDir.path, 'T1.code-workspace'))
          ..writeAsStringSync('{}');

        final target = await Trash.moveFromTicket(
          source: file,
          ticketDir: ticketDir,
        );

        expect(
          target,
          path.join(root.path, '.trash', 'T1', 'T1.code-workspace'),
        );
        expect(file.existsSync(), isFalse);
        expect(File(target).readAsStringSync(), '{}');
      });

      test('never overwrites an already trashed copy', () async {
        final first = repo('ggsuite', 'gg_multi');
        await Trash.moveFromTicket(source: first, ticketDir: ticketDir);

        final second = repo('ggsuite', 'gg_multi');
        File(
          path.join(second.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: second');
        final target = await Trash.moveFromTicket(
          source: second,
          ticketDir: ticketDir,
        );

        expect(path.basename(target), 'gg_multi (2)');
        expect(
          File(path.join(target, 'pubspec.yaml')).readAsStringSync(),
          'name: second',
        );

        // A third one gets the next free suffix.
        final third = repo('ggsuite', 'gg_multi');
        final thirdTarget = await Trash.moveFromTicket(
          source: third,
          ticketDir: ticketDir,
        );
        expect(path.basename(thirdTarget), 'gg_multi (3)');
      });

      test('a taken file name is suffixed before its extension', () async {
        File(
          path.join(ticketDir.path, 'T1.code-workspace'),
        ).writeAsStringSync('first');
        await Trash.moveFromTicket(
          source: File(path.join(ticketDir.path, 'T1.code-workspace')),
          ticketDir: ticketDir,
        );

        File(
          path.join(ticketDir.path, 'T1.code-workspace'),
        ).writeAsStringSync('second');
        final target = await Trash.moveFromTicket(
          source: File(path.join(ticketDir.path, 'T1.code-workspace')),
          ticketDir: ticketDir,
        );

        expect(path.basename(target), 'T1 (2).code-workspace');
        expect(File(target).readAsStringSync(), 'second');
      });

      test('falls back to copy + delete when rename fails', () async {
        // A rename across volumes throws; the content must survive anyway.
        final dir = repo('ggsuite', 'gg_multi');
        Directory(path.join(dir.path, 'lib')).createSync();
        File(path.join(dir.path, 'lib', 'a.dart')).writeAsStringSync('a');
        Link(
          path.join(dir.path, 'link.dart'),
        ).createSync(path.join('lib', 'a.dart'));

        final source = MockDirectory();
        when(() => source.path).thenReturn(dir.path);
        when(
          () => source.rename(any()),
        ).thenThrow(const FileSystemException('cross device'));
        when(() => source.delete(recursive: true)).thenAnswer((_) async {
          dir.deleteSync(recursive: true);
          return dir;
        });

        final target = await Trash.moveFromTicket(
          source: source,
          ticketDir: ticketDir,
        );

        expect(dir.existsSync(), isFalse);
        expect(
          File(path.join(target, 'lib', 'a.dart')).readAsStringSync(),
          'a',
        );
        expect(
          Link(path.join(target, 'link.dart')).targetSync(),
          path.join('lib', 'a.dart'),
        );
      });
    });

    group('moveFromOcean', () {
      Directory oceanRepo(String org, String name) {
        final dir = Directory(path.join(root.path, '.ocean', org, name))
          ..createSync(recursive: true);
        File(
          path.join(dir.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: $name');
        return dir;
      }

      test('moves a repo to <root>/.trash/.ocean/<org>/<repo>', () async {
        final dir = oceanRepo('ggsuite', 'gg_multi');

        final target = await Trash.moveFromOcean(
          source: dir,
          rootPath: root.path,
        );

        expect(
          target,
          path.join(root.path, '.trash', '.ocean', 'ggsuite', 'gg_multi'),
        );
        expect(dir.existsSync(), isFalse);
        expect(
          File(path.join(target, 'pubspec.yaml')).readAsStringSync(),
          'name: gg_multi',
        );
      });

      test('relates a repo of a legacy ».master« run to that base', () async {
        // A run that fell back to the legacy folder (rename not possible)
        // hands in sources below ».master« — the trash target is still
        // the forward-looking .trash/.ocean.
        final legacyDir = Directory(
          path.join(root.path, '.master', 'ggsuite', 'gg_multi'),
        )..createSync(recursive: true);

        final target = await Trash.moveFromOcean(
          source: legacyDir,
          rootPath: root.path,
        );

        expect(
          target,
          path.join(root.path, '.trash', '.ocean', 'ggsuite', 'gg_multi'),
        );
      });

      test('never overwrites an already trashed copy', () async {
        await Trash.moveFromOcean(
          source: oceanRepo('ggsuite', 'gg_multi'),
          rootPath: root.path,
        );
        final second = oceanRepo('ggsuite', 'gg_multi');
        File(
          path.join(second.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: second');

        final target = await Trash.moveFromOcean(
          source: second,
          rootPath: root.path,
        );

        expect(path.basename(target), 'gg_multi (2)');
        expect(
          File(path.join(target, 'pubspec.yaml')).readAsStringSync(),
          'name: second',
        );
      });
    });

    group('moveTicketToTrash', () {
      test('moves the whole ticket folder with everything in it', () async {
        repo('ggsuite', 'gg_multi');
        File(
          path.join(ticketDir.path, 'ticket.json'),
        ).writeAsStringSync('{"issue_id":"T1"}');
        File(
          path.join(ticketDir.path, '.ticket'),
        ).writeAsStringSync('{"issue_id":"T1"}');
        File(
          path.join(ticketDir.path, 'T1.code-workspace'),
        ).writeAsStringSync('{}');
        Directory(path.join(ticketDir.path, '.gg')).createSync();
        File(
          path.join(ticketDir.path, '.gg', '.gg.json'),
        ).writeAsStringSync('{}');

        final target = await Trash.moveTicketToTrash(ticketDir: ticketDir);

        expect(target.path, path.join(root.path, '.trash', 'T1'));
        expect(ticketDir.existsSync(), isFalse);
        // Everything travelled — repos and the ticket's own metadata.
        expect(
          Directory(path.join(target.path, 'ggsuite', 'gg_multi')).existsSync(),
          isTrue,
        );
        expect(
          File(path.join(target.path, 'ticket.json')).existsSync(),
          isTrue,
        );
        expect(File(path.join(target.path, '.ticket')).existsSync(), isTrue);
        expect(
          File(path.join(target.path, 'T1.code-workspace')).existsSync(),
          isTrue,
        );
        expect(
          File(path.join(target.path, '.gg', '.gg.json')).existsSync(),
          isTrue,
        );
      });

      test(
        'takes the place of the empty folder do create ticket made',
        () async {
          // `do create ticket` pre-creates .trash/<ticket> — the empty
          // placeholder must not push the ticket into a » (2)« variant.
          Trash.createDirForTicket(ticketDir);
          repo('ggsuite', 'gg_multi');

          final target = await Trash.moveTicketToTrash(ticketDir: ticketDir);

          expect(target.path, path.join(root.path, '.trash', 'T1'));
          expect(
            Directory(
              path.join(target.path, 'ggsuite', 'gg_multi'),
            ).existsSync(),
            isTrue,
          );
        },
      );

      test(
        'never overwrites a ticket of the same name closed earlier',
        () async {
          final earlier = Directory(path.join(root.path, '.trash', 'T1'))
            ..createSync(recursive: true);
          File(path.join(earlier.path, 'keep.txt')).writeAsStringSync('keep');
          File(
            path.join(ticketDir.path, 'ticket.json'),
          ).writeAsStringSync('{"issue_id":"second"}');

          final target = await Trash.moveTicketToTrash(ticketDir: ticketDir);

          expect(path.basename(target.path), 'T1 (2)');
          expect(
            File(path.join(target.path, 'ticket.json')).readAsStringSync(),
            '{"issue_id":"second"}',
          );
          // The earlier trash content is untouched.
          expect(
            File(path.join(earlier.path, 'keep.txt')).readAsStringSync(),
            'keep',
          );
        },
      );
    });
  });
}

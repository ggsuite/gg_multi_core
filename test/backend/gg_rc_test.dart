// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_multi_core/src/backend/gg_rc.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late File file;
  final messages = <String>[];
  void ggLog(String m) => messages.add(rmControls(m));

  const transitive = <String>['do', 'add', 'transitive'];

  setUp(() {
    messages.clear();
    tmp = Directory.systemTemp.createTempSync('gg_rc_test_');
    file = File(path.join(tmp.path, GgRc.fileName));
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('GgRc', () {
    group('defaultFile', () {
      test('is the file \$GG_RC names', () {
        final result = GgRc.defaultFile(
          environment: {'GG_RC': '/x/rc.json', 'HOME': '/home/me'},
        );
        expect(result!.path, '/x/rc.json');
      });

      test('is .gg_rc in HOME, then in USERPROFILE', () {
        expect(
          GgRc.defaultFile(environment: {'GG_RC': '', 'HOME': '/home/me'})!
              .path,
          path.join('/home/me', '.gg_rc'),
        );
        expect(
          GgRc.defaultFile(environment: {'USERPROFILE': r'C:\Users\me'})!.path,
          path.join(r'C:\Users\me', '.gg_rc'),
        );
      });

      test('is null without a home directory', () {
        expect(GgRc.defaultFile(environment: {'HOME': ''}), isNull);
        expect(GgRc.defaultFile(environment: const {}), isNull);
      });

      test('reads the process environment by default', () {
        // Wherever the tests run, a home directory or GG_RC is known.
        expect(GgRc.defaultFile(), isNotNull);
      });
    });

    group('load', () {
      test('writes the defaults when the file is missing', () {
        final rc = GgRc.load(ggLog: ggLog, file: file);

        expect(jsonDecode(file.readAsStringSync()), GgRc.builtInDefaults);
        expect(file.readAsStringSync(), endsWith('}\n'));
        expect(rc.file, file);
        expect(rc.values, isEmpty);
        expect(rc.flag(transitive), isTrue);
        expect(messages.single, startsWith('✓ Created ${file.path}'));
      });

      test('warns and uses the defaults when the file cannot be written', () {
        final missingFolder = File(path.join(tmp.path, 'missing', '.gg_rc'));

        final rc = GgRc.load(ggLog: ggLog, file: missingFolder);

        expect(missingFolder.existsSync(), isFalse);
        expect(rc.flag(transitive), isTrue);
        expect(messages.single, startsWith('⚠️ Could not create'));
        expect(messages.single, contains(r'$GG_RC'));
      });

      test('reads an existing file and never rewrites it', () {
        const content = '{"do": {"add": {"transitive": false}}}';
        file.writeAsStringSync(content);

        final rc = GgRc.load(ggLog: ggLog, file: file);

        expect(rc.flag(transitive), isFalse);
        expect(rc.isSet(transitive), isTrue);
        expect(file.readAsStringSync(), content);
        expect(messages, isEmpty);
      });

      test('takes the default for what the file leaves out', () {
        file.writeAsStringSync('{"do": {}}');

        final rc = GgRc.load(ggLog: ggLog, file: file);

        expect(rc.isSet(transitive), isFalse);
        expect(rc.flag(transitive), isTrue);
      });

      test('fails every setting of invalid JSON, saying how to repair '
          'it', () {
        file.writeAsStringSync('{"do": ');

        // Loading works: a run that reads no setting is not stopped.
        final rc = GgRc.load(ggLog: ggLog, file: file);
        expect(rc.isSet(transitive), isFalse);
        expect(rc.error, isNotNull);
        expect(
          () => rc.flag(transitive),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls('$e'),
              'message',
              allOf(
                contains('${file.path} is no valid JSON'),
                contains('delete it and gg writes a fresh one'),
              ),
            ),
          ),
        );
      });

      test('fails every setting of JSON that is no object', () {
        file.writeAsStringSync('[true]');

        expect(
          () => GgRc.load(ggLog: ggLog, file: file).flag(transitive),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls('$e'),
              'message',
              contains('${file.path} must hold one JSON object'),
            ),
          ),
        );
      });

      test('reads the file \$GG_RC names', () {
        file.writeAsStringSync('{"do": {"add": {"transitive": false}}}');

        final rc = GgRc.load(ggLog: ggLog, environment: {'GG_RC': file.path});

        expect(rc.file!.path, file.path);
        expect(rc.flag(transitive), isFalse);
      });

      test('uses the defaults when no file can be determined', () {
        final rc = GgRc.load(ggLog: ggLog, environment: const {});

        expect(rc.file, isNull);
        expect(rc.values, isEmpty);
        expect(rc.flag(transitive), isTrue);
        expect(messages, isEmpty);
      });
    });

    group('flag', () {
      test('fails for a value that is no boolean', () {
        final rc = GgRc(
          values: const {
            'do': {
              'add': {'transitive': 'no'},
            },
          },
          file: file,
        );

        expect(
          () => rc.flag(transitive),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls('$e'),
              'message',
              contains(
                '"do.add.transitive" in ${file.path} must be true or false, '
                'not "no".',
              ),
            ),
          ),
        );
      });

      test('names .gg_rc for a value without a file', () {
        const rc = GgRc(
          values: {
            'do': {'add': 1},
          },
        );

        expect(
          () => rc.flag(['do', 'add']),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls('$e'),
              'message',
              contains('"do.add" in .gg_rc must be true or false, not 1.'),
            ),
          ),
        );
      });

      test('fails for a setting gg does not know', () {
        expect(
          () => const GgRc.defaults().flag(['do', 'nothing']),
          throwsArgumentError,
        );
      });

      test('ignores a path that runs through a value', () {
        const rc = GgRc(values: {'do': true});
        expect(rc.isSet(transitive), isFalse);
        expect(rc.flag(transitive), isTrue);
      });
    });

    test('keyPath joins the keys with dots', () {
      expect(GgRc.keyPath(transitive), 'do.add.transitive');
    });
  });
}

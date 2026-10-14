// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_core/src/backend/graph_package_dirs.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String oceanPath;
  late String ticketPath;

  void repo(String parent, String name) {
    final dir = Directory(path.join(parent, name))..createSync(recursive: true);
    File(path.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: $name');
  }

  List<String> relative(List<Directory> dirs) => [
    for (final d in dirs) path.relative(d.path, from: tmp.path),
  ];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('graph_package_dirs_test');
    oceanPath = path.join(tmp.path, '.ocean');
    ticketPath = path.join(tmp.path, 'T1');
    repo(path.join(oceanPath, 'org'), 'a');
    repo(path.join(oceanPath, 'org'), 'b');
    repo(oceanPath, 'c');
    repo(ticketPath, 'b');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('graphPackageDirs', () {
    test('lists the ticket repos first, shadowing their ocean copies', () {
      final result = graphPackageDirs(
        oceanPath: oceanPath,
        ticketPath: ticketPath,
      );

      expect(relative(result.dirs), [
        path.join('T1', 'b'),
        path.join('.ocean', 'c'),
        path.join('.ocean', 'org', 'a'),
      ]);
      expect(result.ticketNames, {'b'});
    });

    test('lists the whole ocean outside a ticket', () {
      final result = graphPackageDirs(oceanPath: oceanPath, ticketPath: null);

      expect(relative(result.dirs), [
        path.join('.ocean', 'c'),
        path.join('.ocean', 'org', 'a'),
        path.join('.ocean', 'org', 'b'),
      ]);
      expect(result.ticketNames, isEmpty);
    });
  });
}

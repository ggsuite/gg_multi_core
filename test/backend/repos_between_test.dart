// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_core/src/backend/repos_between.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String ticket;
  late String ocean;
  late ReposBetween reposBetween;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('repos_between_test_');
    ticket = path.join(tmp.path, 'ticket');
    ocean = path.join(tmp.path, '.ocean');
    reposBetween = ReposBetween(ggLog: (_) {});
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  /// A Dart package [name] in [folder] depending on [deps] and [devDeps].
  void package(
    String folder,
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
    File(path.join(folder, name, 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(buffer.toString());
  }

  void ticketRepo(String name, [List<String> deps = const <String>[]]) =>
      package(ticket, name, deps);

  void oceanRepo(
    String name, [
    List<String> deps = const <String>[],
    List<String> devDeps = const <String>[],
  ]) => package(path.join(ocean, 'org'), name, deps, devDeps);

  Future<({List<String> names, String? error})> find([Set<String>? from]) =>
      reposBetween.find(ticketPath: ticket, oceanPath: ocean, from: from);

  group('ReposBetween', () {
    group('find', () {
      test('names the ocean repos above a release and below the ticket, '
          'sorted', () async {
        // t -> {n, m} -> x; y depends on x, but no ticket repo on y.
        ticketRepo('t', ['n', 'm']);
        ticketRepo('x');
        oceanRepo('n', ['x']);
        oceanRepo('m', ['x']);
        oceanRepo('y', ['x']);

        final result = await find({'x'});

        expect(result.names, ['m', 'n']);
        expect(result.error, isNull);
      });

      test('names none above a release nothing in the ticket depends on '
          'through the ocean', () async {
        ticketRepo('t', ['m']);
        ticketRepo('x');
        oceanRepo('m', ['x']);

        expect((await find({'t'})).names, isEmpty);
      });

      test('asks about every ticket repo without from', () async {
        // t -> m -> x -> k -> z: m and k lie between ticket repos.
        ticketRepo('t', ['m']);
        ticketRepo('x', ['k']);
        ticketRepo('z');
        oceanRepo('m', ['x']);
        oceanRepo('k', ['z']);

        expect((await find()).names, ['k', 'm']);
        // x does not break: m keeps the x it accepts.
        expect((await find({'z'})).names, ['k']);
        expect((await find({'x'})).names, ['m']);
      });

      test('stops above a ticket repo whose release does not break', () async {
        // a -> m1 -> c -> m2 -> d, only d breaks: c is released against the
        // new d itself, and m1 takes the new c with the constraint it has.
        ticketRepo('a', ['m1']);
        ticketRepo('c', ['m2']);
        ticketRepo('d');
        oceanRepo('m1', ['c']);
        oceanRepo('m2', ['d']);

        expect((await find({'d'})).names, ['m2']);
        expect((await find({'c', 'd'})).names, ['m1', 'm2']);
      });

      test('follows no dev dependency', () async {
        // t -dev-> m -> x, and t -> n -dev-> x.
        ticketRepo('x');
        package(ticket, 't', ['n'], ['m']);
        oceanRepo('m', ['x']);
        oceanRepo('n', [], ['x']);

        expect((await find({'x'})).names, isEmpty);
      });

      test('drops the notes of the graph', () async {
        // The dev dependency y -> x closes a cycle, which the graph cuts
        // with a note.
        final notes = <String>[];
        reposBetween = ReposBetween(ggLog: notes.add);
        ticketRepo('x', ['y']);
        oceanRepo('y', [], ['x']);

        final result = await find();

        expect(result.error, isNull);
        expect(notes, isEmpty);
      });

      test('names none for no release, without building the graph', () async {
        // No ocean at all: the graph would fail to build.
        ticketRepo('t');

        final result = await find(<String>{});

        expect(result.names, isEmpty);
        expect(result.error, isNull);
      });

      test('reports why the ocean graph does not build', () async {
        ticketRepo('t');
        oceanRepo('a', ['b']);
        oceanRepo('b', ['a']);

        final result = await find();

        expect(result.names, isEmpty);
        expect(result.error, isNotNull);
      });
    });

    test('MockReposBetween can be constructed', () {
      expect(MockReposBetween(), isA<ReposBetween>());
    });
  });
}

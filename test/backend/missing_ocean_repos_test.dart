// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_multi_core/gg_multi_core.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

class MockGitHubPlatform extends Mock implements GitHubPlatform {}

void main() {
  late Directory tmp;
  late String oceanPath;
  late String ticketPath;
  late MockGitHubPlatform gitHub;
  late MissingOceanRepos missingOceanRepos;

  /// Writes a Dart repo [name] into [parent] depending on [deps] (hosted,
  /// unless the value is a map) and on the dev dependencies [devDeps].
  Directory dartRepo(
    String parent,
    String name, {
    Map<String, Object> deps = const {},
    List<String> devDeps = const [],
  }) {
    final dir = Directory(path.join(parent, name))..createSync(recursive: true);
    final lines = <String>['name: $name', 'version: 1.0.0', 'dependencies:'];
    for (final MapEntry(:key, :value) in deps.entries) {
      if (value is Map<String, String>) {
        lines.add('  $key:');
        for (final MapEntry(key: k, value: v) in value.entries) {
          lines.add('    $k: $v');
        }
      } else {
        lines.add('  $key: $value');
      }
    }
    lines.add('dev_dependencies:');
    for (final dep in devDeps) {
      lines.add('  $dep: ^1.0.0');
    }
    File(path.join(dir.path, 'pubspec.yaml'))
        .writeAsStringSync('${lines.join('\n')}\n');
    return dir;
  }

  /// Writes a TypeScript repo [name] into [parent].
  Directory tsRepo(
    String parent,
    String name, {
    Map<String, String> deps = const {},
    Map<String, String> devDeps = const {},
  }) {
    final dir = Directory(path.join(parent, name))..createSync(recursive: true);
    File(path.join(dir.path, 'package.json')).writeAsStringSync(
      jsonEncode({
        'name': name,
        'version': '1.0.0',
        'dependencies': deps,
        'devDependencies': devDeps,
      }),
    );
    return dir;
  }

  void organizations(List<String> names) {
    File(path.join(oceanPath, '.organizations')).writeAsStringSync(
      jsonEncode([
        for (final name in names)
          Organization(name: name, url: 'https://github.com/$name/').toMap(),
      ]),
    );
  }

  void offers(String org, List<String> repos) {
    when(() => gitHub.fetchOrgRepos(org)).thenAnswer(
      (_) async => [
        for (final name in repos)
          Repository(
            name: name,
            httpsUrl: 'https://github.com/$org/$name',
            sshUrl: 'git@github.com:$org/$name.git',
          ),
      ],
    );
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('missing_ocean_repos_test');
    oceanPath = path.join(tmp.path, '.ocean');
    ticketPath = path.join(tmp.path, 'T1');
    Directory(oceanPath).createSync(recursive: true);
    Directory(ticketPath).createSync(recursive: true);
    OrganizationUtils.clearCache();
    gitHub = MockGitHubPlatform();
    missingOceanRepos = MissingOceanRepos(
      repoLists: OrganizationRepoLists(gitHubPlatform: gitHub),
    );
  });

  tearDown(() {
    OrganizationUtils.clearCache();
    tmp.deleteSync(recursive: true);
  });

  Future<MissingOceanReposReport> find({
    Iterable<Directory> roots = const [],
  }) => missingOceanRepos.find(
    oceanPath: oceanPath,
    ticketPath: ticketPath,
    roots: roots,
  );

  group('MissingOceanRepos', () {
    group('find', () {
      test('reports an organization repo a ticket repo depends on', () async {
        organizations(['org']);
        offers('org', ['a', 'b']);
        dartRepo(path.join(oceanPath, 'org'), 'a');
        dartRepo(ticketPath, 'a', deps: {'b': '^1.0.0', 'path': '^1.9.0'});

        final report = await find();

        expect(report.missing.map((m) => m.repoName), ['b']);
        final missing = report.missing.single;
        expect(missing.dependency, 'b');
        expect(
          missing.manifestPath,
          path.join(ticketPath, 'a', 'pubspec.yaml'),
        );
        expect(missing.owners.single.organization.name, 'org');
        expect(missing.owners.single.repo.cloneUrl, 'git@github.com:org/b.git');
        expect(report.unchecked, isEmpty);
      });

      test('follows the ocean repos the ticket reaches', () async {
        // a (ticket) -> m (ocean) -> x (missing): x can sit between ticket
        // repos, although no ticket repo names it.
        organizations(['org']);
        offers('org', ['a', 'm', 'x']);
        dartRepo(ticketPath, 'a', deps: {'m': '^1.0.0'});
        dartRepo(path.join(oceanPath, 'org'), 'm', deps: {'x': '^1.0.0'});

        final report = await find();

        expect(report.missing.map((m) => m.repoName), ['x']);
        expect(
          report.missing.single.manifestPath,
          path.join(oceanPath, 'org', 'm', 'pubspec.yaml'),
        );
      });

      test('starts from the roots too', () async {
        organizations(['org']);
        offers('org', ['r', 'x']);
        final root = dartRepo(
          path.join(oceanPath, 'org'),
          'r',
          deps: {'x': '^1.0.0'},
        );

        final report = await find(roots: [root]);

        expect(report.missing.map((m) => m.repoName), ['x']);
      });

      test('reads the ticket checkout instead of its ocean copy', () async {
        organizations(['org']);
        offers('org', ['a', 'new_dep', 'old_dep']);
        dartRepo(path.join(oceanPath, 'org'), 'a', deps: {'old_dep': '^1.0.0'});
        dartRepo(ticketPath, 'a', deps: {'new_dep': '^1.0.0'});

        final report = await find();

        expect(report.missing.map((m) => m.repoName), ['new_dep']);
      });

      test('ignores dev, SDK and path dependencies', () async {
        organizations(['org']);
        offers('org', ['dev_only', 'local']);
        dartRepo(
          ticketPath,
          'a',
          deps: {
            'flutter': {'sdk': 'flutter'},
            'local': {'path': '../local'},
          },
          devDeps: ['dev_only'],
        );

        final report = await find();

        expect(report.missing, isEmpty);
      });

      test('matches names case-insensitively and - with _', () async {
        organizations(['org']);
        offers('org', ['Gg-Bridge']);
        dartRepo(ticketPath, 'a', deps: {'gg_bridge': '^1.0.0'});

        final report = await find();

        expect(report.missing.single.repoName, 'Gg-Bridge');
        expect(report.missing.single.dependency, 'gg_bridge');
      });

      test('maps npm packages of an organization scope', () async {
        organizations(['tssuite']);
        offers('tssuite', ['base-dna', 'node']);
        tsRepo(
          ticketPath,
          'a',
          deps: {'@tssuite/base-dna': '^1.0.0', '@types/node': '^20.0.0'},
          devDeps: {'@tssuite/dev-only': '^1.0.0'},
        );

        final report = await find();

        expect(report.missing.map((m) => m.repoName), ['base-dna']);
        expect(report.missing.single.dependency, '@tssuite/base-dna');
      });

      test('follows a foreign npm scope to no ocean repo', () async {
        // @babel/core is not the ocean's repo core, whose dependency x the
        // ocean lacks; @tssuite/base is the ocean's base.
        organizations(['tssuite']);
        offers('tssuite', ['core', 'base', 'x', 'y']);
        tsRepo(path.join(oceanPath, 'tssuite'), 'core', deps: {'x': '^1.0.0'});
        tsRepo(path.join(oceanPath, 'tssuite'), 'base', deps: {'y': '^1.0.0'});
        tsRepo(
          ticketPath,
          'a',
          deps: {'@babel/core': '^7.0.0', '@tssuite/base': '^1.0.0'},
        );

        final report = await find();

        expect(report.missing.map((m) => m.repoName), ['y']);
      });

      test('lists every organization offering the repo', () async {
        organizations(['one', 'two']);
        offers('one', ['x']);
        offers('two', ['x']);
        dartRepo(ticketPath, 'a', deps: {'x': '^1.0.0'});

        final report = await find();

        expect(report.missing.single.owners.map((o) => o.organization.name), [
          'one',
          'two',
        ]);
      });

      test('reports the organizations it could not list', () async {
        organizations(['one', 'two']);
        offers('one', ['x']);
        when(() => gitHub.fetchOrgRepos('two'))
            .thenThrow(Exception('gh not authenticated'));
        dartRepo(ticketPath, 'a', deps: {'x': '^1.0.0', 'y': '^1.0.0'});

        final report = await find();

        expect(report.missing.map((m) => m.repoName), ['x']);
        expect(report.unchecked.map((o) => o.name), ['two']);
      });

      test('asks no platform without organizations', () async {
        dartRepo(ticketPath, 'a', deps: {'x': '^1.0.0'});

        final report = await find();

        expect(report.missing, isEmpty);
        verifyNever(() => gitHub.fetchOrgRepos(any()));
      });

      test('asks no platform when every dependency is local', () async {
        organizations(['org']);
        dartRepo(path.join(oceanPath, 'org'), 'b');
        dartRepo(ticketPath, 'a', deps: {'b': '^1.0.0'});

        final report = await find();

        expect(report.missing, isEmpty);
        verifyNever(() => gitHub.fetchOrgRepos(any()));
      });

      test('skips manifests it cannot parse', () async {
        organizations(['org']);
        offers('org', ['x']);
        final broken = Directory(path.join(ticketPath, 'broken'))..createSync();
        File(path.join(broken.path, 'pubspec.yaml')).writeAsStringSync('[');
        File(path.join(broken.path, 'package.json')).writeAsStringSync('{');
        dartRepo(ticketPath, 'a', deps: {'x': '^1.0.0'});

        final report = await find();

        expect(report.missing.map((m) => m.repoName), ['x']);
      });

      test('ignores malformed npm scopes', () async {
        organizations(['org']);
        offers('org', ['x']);
        tsRepo(ticketPath, 'a', deps: {'@/x': '1', '@org/': '1'});

        final report = await find();

        expect(report.missing, isEmpty);
      });
    });
  });
}

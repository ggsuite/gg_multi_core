// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_core/src/backend/repo_identity.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory workspace;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('repo_identity_test_');
  });

  tearDown(() {
    if (workspace.existsSync()) {
      workspace.deleteSync(recursive: true);
    }
  });

  // Creates a repo folder with optional manifests and git remote.
  Directory makeRepo(
    String folderName, {
    String? pubspec,
    String? packageJson,
    String? remoteUrl,
  }) {
    final dir = Directory(path.join(workspace.path, folderName))
      ..createSync(recursive: true);
    if (pubspec != null) {
      File(path.join(dir.path, 'pubspec.yaml')).writeAsStringSync(pubspec);
    }
    if (packageJson != null) {
      File(path.join(dir.path, 'package.json')).writeAsStringSync(packageJson);
    }
    if (remoteUrl != null) {
      final gitDir = Directory(path.join(dir.path, '.git'))..createSync();
      File(
        path.join(gitDir.path, 'config'),
      ).writeAsStringSync('[remote "origin"]\n\turl = $remoteUrl\n');
    }
    return dir;
  }

  group('RepoIdentity', () {
    group('of', () {
      test('reads the repository a pubspec declares', () {
        final dir = makeRepo(
          'dna_base',
          pubspec:
              'name: dna_base\n'
              'repository: https://github.com/ggsuite/dna_base.git\n',
        );

        final identity = RepoIdentity.of(dir);

        expect(identity.directory.path, dir.path);
        expect(identity.packageNames, {'dna_base'});
        expect(identity.declaredUrl, 'https://github.com/ggsuite/dna_base.git');
        expect(identity.declaredIdentity, 'ggsuite/dna_base');
        expect(identity.declaredRepoName, 'dna_base');
        expect(identity.sitsInDeclaredRepoFolder, isTrue);
      });

      test('falls back to the homepage of a pubspec', () {
        final dir = makeRepo(
          'helix',
          pubspec:
              'name: helix\n'
              'homepage: https://github.com/ggsuite/helix\n',
        );

        expect(RepoIdentity.of(dir).declaredIdentity, 'ggsuite/helix');
      });

      test('reads the repository object of a package.json', () {
        final dir = makeRepo(
          'helix-js',
          packageJson:
              '{"name":"@tssuite/helix-js","repository":'
              '{"type":"git","url":"https://github.com/tssuite/helix-js.git"}}',
        );

        final identity = RepoIdentity.of(dir);

        expect(identity.packageNames, {'@tssuite/helix-js', 'helix-js'});
        expect(identity.declaredIdentity, 'tssuite/helix-js');
        expect(identity.sitsInDeclaredRepoFolder, isTrue);
      });

      test('falls back to the homepage of a package.json', () {
        final dir = makeRepo(
          'golden',
          packageJson:
              '{"name":"@tssuite/golden",'
              '"homepage":"https://github.com/tssuite/golden"}',
        );

        expect(RepoIdentity.of(dir).declaredIdentity, 'tssuite/golden');
      });

      test('prefers the pubspec over the package.json', () {
        final dir = makeRepo(
          'dna_base',
          pubspec:
              'name: dna_base\n'
              'repository: https://github.com/ggsuite/dna_base.git\n',
          packageJson:
              '{"name":"@tssuite/dna-base",'
              '"repository":"https://github.com/tssuite/elsewhere.git"}',
        );

        final identity = RepoIdentity.of(dir);

        expect(identity.declaredIdentity, 'ggsuite/dna_base');
        expect(identity.packageNames, {
          'dna_base',
          '@tssuite/dna-base',
          'dna-base',
        });
      });

      test('reads the git remote', () {
        final dir = makeRepo(
          'base_dna',
          pubspec: 'name: dna_base\n',
          remoteUrl: 'https://github.com/ggsuite/base_dna.git',
        );

        final identity = RepoIdentity.of(dir);

        expect(identity.remoteUrl, 'https://github.com/ggsuite/base_dna.git');
        expect(identity.remoteIdentity, 'ggsuite/base_dna');
      });

      test('declares nothing when no manifest names a repository', () {
        final dir = makeRepo('gg_foo', pubspec: 'name: gg_foo\n');

        final identity = RepoIdentity.of(dir);

        expect(identity.declaredUrl, isNull);
        expect(identity.declaredIdentity, isNull);
        expect(identity.declaredRepoName, isNull);
        expect(identity.remoteIdentity, isNull);
        expect(identity.sitsInDeclaredRepoFolder, isFalse);
      });

      test('declares nothing when the package.json is broken', () {
        final dir = makeRepo('gg_foo', packageJson: '{ invalid json');

        expect(RepoIdentity.of(dir).declaredUrl, isNull);
      });

      test('declares nothing when the repository field is empty', () {
        final dir = makeRepo(
          'gg_foo',
          packageJson: '{"name":"gg_foo","repository":{"type":"git"}}',
        );

        expect(RepoIdentity.of(dir).declaredUrl, isNull);
      });
    });

    group('sitsInDeclaredRepoFolder', () {
      test('is false for the folder a rename left behind', () {
        // The platform still redirects `base_dna`, so this clone succeeded —
        // but the package inside publishes as `dna_base`.
        final dir = makeRepo(
          'base_dna',
          pubspec:
              'name: dna_base\n'
              'repository: https://github.com/ggsuite/dna_base.git\n',
        );

        expect(RepoIdentity.of(dir).sitsInDeclaredRepoFolder, isFalse);
      });
    });

    group('isSameRepoAs', () {
      test('is true when both declare the same repository', () {
        const pubspec =
            'name: dna_base\n'
            'repository: https://github.com/ggsuite/dna_base.git\n';

        final stale = RepoIdentity.of(makeRepo('base_dna', pubspec: pubspec));
        final current = RepoIdentity.of(makeRepo('dna_base', pubspec: pubspec));

        expect(stale.isSameRepoAs(current), isTrue);
        expect(current.isSameRepoAs(stale), isTrue);
      });

      test('is false when they declare different repositories', () {
        final a = RepoIdentity.of(
          makeRepo(
            'a',
            pubspec: 'name: a\nrepository: https://github.com/ggsuite/a.git\n',
          ),
        );
        final b = RepoIdentity.of(
          makeRepo(
            'b',
            pubspec: 'name: b\nrepository: https://github.com/ggsuite/b.git\n',
          ),
        );

        expect(a.isSameRepoAs(b), isFalse);
      });

      test('is false when one of them declares nothing', () {
        // Sharing a package name is not proof: the price of getting this
        // wrong is a checkout being moved away that belongs where it is.
        final declaring = RepoIdentity.of(
          makeRepo(
            'gg_foo',
            pubspec:
                'name: gg_foo\n'
                'repository: https://github.com/ggsuite/gg_foo.git\n',
          ),
        );
        final silent = RepoIdentity.of(
          makeRepo('gg_foo_copy', pubspec: 'name: gg_foo\n'),
        );

        expect(declaring.isSameRepoAs(silent), isFalse);
        expect(silent.isSameRepoAs(declaring), isFalse);
      });

      test('is false when neither declares nor shares a name', () {
        final a = RepoIdentity.of(makeRepo('a', pubspec: 'name: a\n'));
        final b = RepoIdentity.of(makeRepo('b', pubspec: 'name: b\n'));

        expect(a.isSameRepoAs(b), isFalse);
      });
    });
  });
}

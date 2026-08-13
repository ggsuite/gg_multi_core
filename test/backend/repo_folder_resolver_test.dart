// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_core/src/backend/repo_folder_resolver.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory workspace;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('repo_resolver_test_');
  });

  tearDown(() {
    if (workspace.existsSync()) {
      workspace.deleteSync(recursive: true);
    }
  });

  // Creates a repo folder with optional pubspec/package.json/git remote.
  Directory makeRepo(
    String folderName, {
    String? pubspecName,
    bool flutter = false,
    String? packageJsonName,
    bool tsconfig = false,
    String? remoteUrl,
  }) {
    final dir = Directory(path.join(workspace.path, folderName))
      ..createSync(recursive: true);
    if (pubspecName != null) {
      final flutterBlock = flutter
          ? '\nflutter:\n  uses-material-design: true'
          : '';
      File(
        path.join(dir.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: $pubspecName\nversion: 1.0.0$flutterBlock\n');
    }
    if (packageJsonName != null) {
      File(
        path.join(dir.path, 'package.json'),
      ).writeAsStringSync('{"name": "$packageJsonName"}');
    }
    if (tsconfig) {
      File(path.join(dir.path, 'tsconfig.json')).writeAsStringSync('{}');
    }
    if (remoteUrl != null) {
      final gitDir = Directory(path.join(dir.path, '.git'))..createSync();
      File(
        path.join(gitDir.path, 'config'),
      ).writeAsStringSync('[remote "origin"]\n\turl = $remoteUrl\n');
    }
    return dir;
  }

  group('RepoFolderResolver', () {
    group('resolve', () {
      test('matches the exact folder name first', () {
        final dir = makeRepo('gg_foo', pubspecName: 'gg_foo');
        final result = RepoFolderResolver.resolve(
          workspacePath: workspace.path,
          repoName: 'gg_foo',
        );
        expect(result?.path, dir.path);
      });

      test('matches via the pubspec package name of a prefixed folder', () {
        final dir = makeRepo('ggsuite_gg_foo', pubspecName: 'gg_foo');
        final result = RepoFolderResolver.resolve(
          workspacePath: workspace.path,
          repoName: 'gg_foo',
        );
        expect(result?.path, dir.path);
      });

      test('matches via the npm name of a repo that also has a pubspec', () {
        // A dependency written `@tssuite/dna-base` resolves to the folder the
        // Dart side calls `dna_base` — one repository, two package names.
        final dir = makeRepo(
          'dna_base',
          pubspecName: 'dna_base',
          packageJsonName: '@tssuite/dna-base',
        );
        expect(
          RepoFolderResolver.resolve(
            workspacePath: workspace.path,
            repoName: 'dna-base',
          )?.path,
          dir.path,
        );
        expect(
          RepoFolderResolver.resolve(
            workspacePath: workspace.path,
            repoName: '@tssuite/dna-base',
          )?.path,
          dir.path,
        );
      });

      test('matches via a scoped package.json name', () {
        final dir = makeRepo(
          'tssuite-ts_foo',
          packageJsonName: '@tssuite/ts_foo',
          tsconfig: true,
        );
        final result = RepoFolderResolver.resolve(
          workspacePath: workspace.path,
          repoName: 'ts_foo',
        );
        expect(result?.path, dir.path);
      });

      test('returns null when no folder matches', () {
        makeRepo('ggsuite_other', pubspecName: 'other');
        final result = RepoFolderResolver.resolve(
          workspacePath: workspace.path,
          repoName: 'gg_foo',
        );
        expect(result, isNull);
      });

      test('returns null when the workspace does not exist', () {
        final result = RepoFolderResolver.resolve(
          workspacePath: path.join(workspace.path, 'nope'),
          repoName: 'gg_foo',
        );
        expect(result, isNull);
      });
    });

    group('resolveByRemoteUrl', () {
      test('matches a prefixed folder across url schemes', () {
        // Stored remote is https; query is the ssh form of the same repo.
        final dir = makeRepo(
          'ggsuite_gg_foo',
          pubspecName: 'gg_foo',
          remoteUrl: 'https://github.com/ggsuite/gg_foo.git',
        );
        final result = RepoFolderResolver.resolveByRemoteUrl(
          workspacePath: workspace.path,
          repoUrl: 'git@github.com:ggsuite/gg_foo.git',
        );
        expect(result?.path, dir.path);
      });

      test('returns null when the query url has no identity', () {
        makeRepo(
          'ggsuite_gg_foo',
          pubspecName: 'gg_foo',
          remoteUrl: 'https://github.com/ggsuite/gg_foo.git',
        );
        final result = RepoFolderResolver.resolveByRemoteUrl(
          workspacePath: workspace.path,
          repoUrl: 'foo',
        );
        expect(result, isNull);
      });

      test('returns null when no remote matches', () {
        makeRepo(
          'ggsuite_other',
          pubspecName: 'other',
          remoteUrl: 'https://github.com/ggsuite/other.git',
        );
        final result = RepoFolderResolver.resolveByRemoteUrl(
          workspacePath: workspace.path,
          repoUrl: 'https://github.com/ggsuite/gg_foo.git',
        );
        expect(result, isNull);
      });
    });

    group('packageName', () {
      test('reads the pubspec name', () {
        final dir = makeRepo('x', pubspecName: 'gg_foo');
        expect(RepoFolderResolver.packageName(dir), 'gg_foo');
      });

      test('returns null when pubspec has no name', () {
        final dir = Directory(path.join(workspace.path, 'x'))..createSync();
        File(
          path.join(dir.path, 'pubspec.yaml'),
        ).writeAsStringSync('version: 1.0.0\n');
        expect(RepoFolderResolver.packageName(dir), isNull);
      });

      test('returns null when pubspec cannot be decoded', () {
        final dir = Directory(path.join(workspace.path, 'x'))..createSync();
        // Invalid UTF-8 bytes make readAsStringSync throw.
        File(
          path.join(dir.path, 'pubspec.yaml'),
        ).writeAsBytesSync(<int>[0xC3, 0x28]);
        expect(RepoFolderResolver.packageName(dir), isNull);
      });

      test('reads an unscoped package.json name', () {
        final dir = makeRepo('x', packageJsonName: 'ts_foo');
        expect(RepoFolderResolver.packageName(dir), 'ts_foo');
      });

      test('strips the npm scope from a package.json name', () {
        final dir = makeRepo('x', packageJsonName: '@tssuite/ts_foo');
        expect(RepoFolderResolver.packageName(dir), 'ts_foo');
      });

      test('returns null when package.json has no name', () {
        final dir = Directory(path.join(workspace.path, 'x'))..createSync();
        File(path.join(dir.path, 'package.json')).writeAsStringSync('{}');
        expect(RepoFolderResolver.packageName(dir), isNull);
      });

      test('returns null when package.json is invalid', () {
        final dir = Directory(path.join(workspace.path, 'x'))..createSync();
        File(
          path.join(dir.path, 'package.json'),
        ).writeAsStringSync('{not json');
        expect(RepoFolderResolver.packageName(dir), isNull);
      });

      test('returns null when no manifest is present', () {
        final dir = Directory(path.join(workspace.path, 'x'))..createSync();
        expect(RepoFolderResolver.packageName(dir), isNull);
      });
    });

    group('packageNames', () {
      test('collects the Dart and the npm name of one repo', () {
        // What `dna_base` looks like: one repository, two package names.
        final dir = makeRepo(
          'dna_base',
          pubspecName: 'dna_base',
          packageJsonName: '@tssuite/dna-base',
        );
        expect(RepoFolderResolver.packageNames(dir), {
          'dna_base',
          '@tssuite/dna-base',
          'dna-base',
        });
      });

      test('keeps an unscoped npm name as it is', () {
        final dir = makeRepo('x', packageJsonName: 'ts_foo');
        expect(RepoFolderResolver.packageNames(dir), {'ts_foo'});
      });

      test('is empty when no manifest is present', () {
        final dir = Directory(path.join(workspace.path, 'x'))..createSync();
        expect(RepoFolderResolver.packageNames(dir), isEmpty);
      });

      test('is empty when the pubspec has no name', () {
        final dir = Directory(path.join(workspace.path, 'x'))..createSync();
        File(
          path.join(dir.path, 'pubspec.yaml'),
        ).writeAsStringSync('version: 1.0.0\n');
        expect(RepoFolderResolver.packageNames(dir), isEmpty);
      });

      test('keeps what it read when a manifest is unreadable', () {
        final dir = makeRepo('x', pubspecName: 'gg_foo');
        File(
          path.join(dir.path, 'package.json'),
        ).writeAsStringSync('{not json');
        expect(RepoFolderResolver.packageNames(dir), {'gg_foo'});
      });

      test('is empty when the package.json has no name', () {
        final dir = Directory(path.join(workspace.path, 'x'))..createSync();
        File(path.join(dir.path, 'package.json')).writeAsStringSync('{}');
        expect(RepoFolderResolver.packageNames(dir), isEmpty);
      });
    });

    group('remoteUrl', () {
      test('returns null when there is no git config', () {
        final dir = Directory(path.join(workspace.path, 'x'))..createSync();
        expect(RepoFolderResolver.remoteUrl(dir), isNull);
      });

      test('returns null when the config has no url line', () {
        final dir = Directory(path.join(workspace.path, 'x'))..createSync();
        final gitDir = Directory(path.join(dir.path, '.git'))..createSync();
        File(path.join(gitDir.path, 'config')).writeAsStringSync('[core]\n');
        expect(RepoFolderResolver.remoteUrl(dir), isNull);
      });

      test('keeps an url value that itself contains "="', () {
        final dir = makeRepo('x', remoteUrl: 'https://host/r.git?a=b');
        expect(RepoFolderResolver.remoteUrl(dir), 'https://host/r.git?a=b');
      });
    });

    group('urlIdentity', () {
      test('is scheme independent and lower-cased', () {
        final ssh = RepoFolderResolver.urlIdentity(
          'git@github.com:Ggsuite/Gg_Foo.git',
        );
        final https = RepoFolderResolver.urlIdentity(
          'https://github.com/ggsuite/gg_foo',
        );
        expect(ssh, https);
        expect(ssh, 'ggsuite/gg_foo');
      });

      test('returns null when the url carries no org', () {
        expect(RepoFolderResolver.urlIdentity('gg_foo'), isNull);
      });
    });

    group('organization folders', () {
      // Creates `<workspace>/<org>/<repo>` with a git remote of that org.
      Directory makeOrgRepo(String org, String repo, {String? pubspecName}) =>
          makeRepo(
            path.join(org, repo),
            pubspecName: pubspecName,
            remoteUrl: 'https://github.com/$org/$repo.git',
          );

      group('repoDirs', () {
        test('lists the repos of every organization folder', () {
          final a = makeOrgRepo('ggsuite', 'gg_foo', pubspecName: 'gg_foo');
          final b = makeOrgRepo('tssuite', 'ts_foo', pubspecName: 'ts_foo');

          expect(
            RepoFolderResolver.repoDirs(workspace.path).map((d) => d.path),
            <String>[a.path, b.path],
          );
        });

        test('lists repos that still sit directly in the workspace', () {
          final flat = makeRepo('gg_flat', pubspecName: 'gg_flat');
          final nested = makeOrgRepo('ggsuite', 'gg_foo');

          expect(
            RepoFolderResolver.repoDirs(workspace.path).map((d) => d.path),
            unorderedEquals(<String>[flat.path, nested.path]),
          );
        });

        test('does not descend into a repository', () {
          // A package inside a repo (`example/`) is no workspace repo.
          final repo = makeRepo('gg_foo', pubspecName: 'gg_foo');
          makeRepo(path.join('gg_foo', 'example'), pubspecName: 'gg_foo_ex');

          expect(
            RepoFolderResolver.repoDirs(workspace.path).map((d) => d.path),
            <String>[repo.path],
          );
        });

        test('skips hidden folders', () {
          makeRepo(path.join('.gg', 'cached'), pubspecName: 'cached');
          expect(RepoFolderResolver.repoDirs(workspace.path), isEmpty);
        });

        test('returns an empty list when the workspace does not exist', () {
          expect(
            RepoFolderResolver.repoDirs(path.join(workspace.path, 'nope')),
            isEmpty,
          );
        });
      });

      group('resolve', () {
        test('finds a repo inside its organization folder', () {
          final dir = makeOrgRepo('ggsuite', 'gg_foo', pubspecName: 'gg_foo');
          expect(
            RepoFolderResolver.resolve(
              workspacePath: workspace.path,
              repoName: 'gg_foo',
            )?.path,
            dir.path,
          );
        });

        test('finds a repo by its package name inside an org folder', () {
          final dir = makeOrgRepo(
            'ggsuite',
            'ggsuite_gg_foo',
            pubspecName: 'gg_foo',
          );
          expect(
            RepoFolderResolver.resolve(
              workspacePath: workspace.path,
              repoName: 'gg_foo',
            )?.path,
            dir.path,
          );
        });

        test('never returns an organization folder', () {
          // An organization whose name is also a repo name of another org.
          makeOrgRepo('ggsuite', 'gg_foo');
          final repo = makeOrgRepo('other', 'ggsuite');
          expect(
            RepoFolderResolver.resolve(
              workspacePath: workspace.path,
              repoName: 'ggsuite',
            )?.path,
            repo.path,
          );
        });
      });

      test('resolveByRemoteUrl finds a repo inside an org folder', () {
        final dir = makeOrgRepo('ggsuite', 'gg_foo');
        expect(
          RepoFolderResolver.resolveByRemoteUrl(
            workspacePath: workspace.path,
            repoUrl: 'git@github.com:ggsuite/gg_foo.git',
          )?.path,
          dir.path,
        );
      });

      group('destination', () {
        test('puts a repo into the folder of its organization', () {
          expect(
            RepoFolderResolver.destination(
              workspacePath: workspace.path,
              repoUrl: 'https://github.com/ggsuite/gg_foo.git',
              repoName: 'gg_foo',
            ),
            path.join(workspace.path, 'ggsuite', 'gg_foo'),
          );
        });

        test('uses the project of an Azure url, not the account', () {
          // Azure DevOps scopes repo names to the project, so the project is
          // the folder that keeps two same-named repos apart.
          expect(
            RepoFolderResolver.destination(
              workspacePath: workspace.path,
              repoUrl: 'git@ssh.dev.azure.com:v3/myorg/myproj/repo.git',
              repoName: 'repo',
            ),
            path.join(workspace.path, 'myproj', 'repo'),
          );
        });

        test('uses the project of an Azure clone url', () {
          expect(
            RepoFolderResolver.destination(
              workspacePath: workspace.path,
              repoUrl: 'https://dev.azure.com/myorg/myproj/_git/repo',
              repoName: 'repo',
            ),
            path.join(workspace.path, 'myproj', 'repo'),
          );
        });

        test('keeps a repo flat when the url names no organization', () {
          // A single path segment is the repository, not an organization.
          expect(
            RepoFolderResolver.destination(
              workspacePath: workspace.path,
              repoUrl: 'https://host/gg_foo.git',
              repoName: 'gg_foo',
            ),
            path.join(workspace.path, 'gg_foo'),
          );
        });
      });

      group('removeEmptyOrgFolder', () {
        test('deletes the organization folder when it became empty', () {
          final repo = makeOrgRepo('ggsuite', 'gg_foo');
          repo.deleteSync(recursive: true);

          RepoFolderResolver.removeEmptyOrgFolder(
            workspacePath: workspace.path,
            repoDir: repo,
          );

          expect(
            Directory(path.join(workspace.path, 'ggsuite')).existsSync(),
            isFalse,
          );
        });

        test('keeps the organization folder while it holds repos', () {
          final repo = makeOrgRepo('ggsuite', 'gg_foo');
          makeOrgRepo('ggsuite', 'gg_bar');
          repo.deleteSync(recursive: true);

          RepoFolderResolver.removeEmptyOrgFolder(
            workspacePath: workspace.path,
            repoDir: repo,
          );

          expect(
            Directory(path.join(workspace.path, 'ggsuite')).existsSync(),
            isTrue,
          );
        });

        test('does nothing for a repo directly in the workspace', () {
          final repo = makeRepo('gg_foo', pubspecName: 'gg_foo');
          repo.deleteSync(recursive: true);

          RepoFolderResolver.removeEmptyOrgFolder(
            workspacePath: workspace.path,
            repoDir: repo,
          );

          expect(workspace.existsSync(), isTrue);
        });

        test('does nothing when the organization folder is gone', () {
          final repo = makeOrgRepo('ggsuite', 'gg_foo');
          Directory(
            path.join(workspace.path, 'ggsuite'),
          ).deleteSync(recursive: true);

          RepoFolderResolver.removeEmptyOrgFolder(
            workspacePath: workspace.path,
            repoDir: repo,
          );

          expect(workspace.existsSync(), isTrue);
        });
      });

      group('ticketDestination', () {
        test('is the flat folder of an empty ticket', () {
          expect(
            RepoFolderResolver.ticketDestination(
              ticketPath: workspace.path,
              repoUrl: 'https://github.com/ggsuite/gg_foo.git',
              repoName: 'gg_foo',
            ),
            path.join(workspace.path, 'gg_foo'),
          );
        });

        test('is the folder a repo of that remote already occupies', () {
          // Placed in an organization folder by an older gg — adding it
          // again must not create a second copy beside it.
          final existing = makeRepo(
            path.join('ggsuite', 'gg_foo'),
            pubspecName: 'gg_foo',
            remoteUrl: 'git@github.com:ggsuite/gg_foo.git',
          );

          expect(
            RepoFolderResolver.ticketDestination(
              ticketPath: workspace.path,
              repoUrl: 'https://github.com/ggsuite/gg_foo.git',
              repoName: 'gg_foo',
            ),
            existing.path,
          );
        });

        test('is the org folder when the flat name is taken', () {
          makeRepo(
            'gg_foo',
            pubspecName: 'gg_foo',
            remoteUrl: 'https://github.com/ggsuite/gg_foo.git',
          );

          expect(
            RepoFolderResolver.ticketDestination(
              ticketPath: workspace.path,
              repoUrl: 'https://github.com/other/gg_foo.git',
              repoName: 'gg_foo',
            ),
            path.join(workspace.path, 'other', 'gg_foo'),
          );
        });

        test('is the flat folder when it holds no repository', () {
          // An empty folder of that name is no collision.
          Directory(path.join(workspace.path, 'gg_foo')).createSync();

          expect(
            RepoFolderResolver.ticketDestination(
              ticketPath: workspace.path,
              repoUrl: 'https://github.com/other/gg_foo.git',
              repoName: 'gg_foo',
            ),
            path.join(workspace.path, 'gg_foo'),
          );
        });

        test('is the flat folder when the url names no organization', () {
          makeRepo(
            'gg_foo',
            pubspecName: 'gg_foo',
            remoteUrl: 'https://github.com/ggsuite/gg_foo.git',
          );

          expect(
            RepoFolderResolver.ticketDestination(
              ticketPath: workspace.path,
              repoUrl: 'https://example.com/gg_foo.git',
              repoName: 'gg_foo',
            ),
            path.join(workspace.path, 'gg_foo'),
          );
        });
      });

      test('relativePath is the location within the workspace', () {
        final nested = makeOrgRepo('ggsuite', 'gg_foo');
        final flat = makeRepo('gg_flat', pubspecName: 'gg_flat');

        expect(
          RepoFolderResolver.relativePath(
            workspacePath: workspace.path,
            repoDir: nested,
          ),
          path.join('ggsuite', 'gg_foo'),
        );
        expect(
          RepoFolderResolver.relativePath(
            workspacePath: workspace.path,
            repoDir: flat,
          ),
          'gg_flat',
        );
      });
    });
  });
}

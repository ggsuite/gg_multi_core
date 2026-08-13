// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_multi_core/src/backend/git_platform.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockProcessRunner extends Mock {
  Future<ProcessResult> call(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool? runInShell,
  });
}

void main() {
  group('GitHubPlatform', () {
    test('buildRepoUrl returns correct URL', () {
      final platform = GitHubPlatform();
      final url = platform.buildRepoUrl('myorg', 'myrepo');
      expect(url, equals('https://github.com/myorg/myrepo.git'));
    });

    test(
      'fetchOrgRepos lists repos via the GitHub CLI and parses JSON',
      () async {
        final mockRunner = MockProcessRunner();
        when(() => mockRunner('gh', any())).thenAnswer(
          (_) async => ProcessResult(
            1,
            0,
            jsonEncode([
              {
                'name': 'repo1',
                'sshUrl': 'git@github.com:myorg/repo1.git',
                'url': 'https://github.com/myorg/repo1',
              },
              {
                'name': 'repo2',
                'sshUrl': 'git@github.com:myorg/repo2.git',
                'url': 'https://github.com/myorg/repo2',
              },
            ]),
            '',
          ),
        );
        final platform = GitHubPlatform(processRunner: mockRunner.call);
        final repos = await platform.fetchOrgRepos('myorg');
        expect(repos.length, 2);
        expect(repos[0].name, 'repo1');
        // Cloning prefers the ssh url so the configured ssh key is used.
        expect(repos[0].cloneUrl, 'git@github.com:myorg/repo1.git');
        expect(repos[1].httpsUrl, 'https://github.com/myorg/repo2');
        verify(
          () => mockRunner('gh', [
            'repo',
            'list',
            'myorg',
            '--limit',
            '1000',
            '--json',
            'name,sshUrl,url',
          ]),
        ).called(1);
      },
    );

    test(
      'fetchOrgRepos falls back to https url when sshUrl is empty',
      () async {
        final mockRunner = MockProcessRunner();
        when(() => mockRunner('gh', any())).thenAnswer(
          (_) async => ProcessResult(
            1,
            0,
            jsonEncode([
              {
                'name': 'repo',
                'sshUrl': '',
                'url': 'https://github.com/myorg/repo',
              },
            ]),
            '',
          ),
        );
        final platform = GitHubPlatform(processRunner: mockRunner.call);
        final repos = await platform.fetchOrgRepos('myorg');
        expect(repos.length, 1);
        // An empty sshUrl must not drop the repo: cloneUrl falls back to https.
        expect(repos.first.cloneUrl, 'https://github.com/myorg/repo');
      },
    );

    test('fetchOrgRepos throws on non-zero exit code', () async {
      final mockRunner = MockProcessRunner();
      when(() => mockRunner('gh', any()))
          .thenAnswer((_) async => ProcessResult(3, 1, '', 'gh error message'));
      when(() => mockRunner('gh', ['--version']))
          .thenAnswer((_) async => ProcessResult(2, 0, 'gh version 2.0.0', ''));
      final platform = GitHubPlatform(processRunner: mockRunner.call);
      await expectLater(
        platform.fetchOrgRepos('myorg'),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            'Exception: Failed to fetch repositories for organization myorg: '
                'gh error message',
          ),
        ),
      );
    });

    test('fetchOrgRepos throws on invalid JSON', () async {
      final mockRunner = MockProcessRunner();
      when(() => mockRunner('gh', any()))
          .thenAnswer((_) async => ProcessResult(3, 0, 'invalid json', ''));
      final platform = GitHubPlatform(processRunner: mockRunner.call);
      await expectLater(
        platform.fetchOrgRepos('myorg'),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Failed to parse GitHub CLI output'),
          ),
        ),
      );
    });

    test('fetchOrgRepos throws when gh is not installed', () async {
      final mockRunner = MockProcessRunner();
      when(() => mockRunner('gh', ['--version']))
          .thenAnswer((_) async => ProcessResult(4, 1, '', 'gh not found'));
      final platform = GitHubPlatform(processRunner: mockRunner.call);
      await expectLater(
        platform.fetchOrgRepos('myorg'),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Bitte installiere die GitHub CLI'),
          ),
        ),
      );
      // The main repo-list call must not run when gh is missing.
      verifyNever(() => mockRunner('gh', any(that: contains('repo'))));
    });

    test('extractOrgFromUrl returns Organization for GitHub URL', () {
      final platform = GitHubPlatform();
      final org = platform.extractOrgFromUrl(
        'https://github.com/myorg/myrepo.git',
      );
      expect(org?.name, 'myorg');
      expect(org?.url, 'https://github.com/myorg/');
    });

    test('extractOrgFromUrl returns null for non-GitHub URL', () {
      final platform = GitHubPlatform();
      final org = platform.extractOrgFromUrl(
        'https://dev.azure.com/myorg/myrepo.git',
      );
      expect(org, isNull);
    });

    test('buildBaseUrl returns correct base URL', () {
      final platform = GitHubPlatform();
      final base = platform.buildBaseUrl('myorg');
      expect(base, 'https://github.com/myorg/');
    });

    test('fetchOrgRepos ignores project parameter', () async {
      final mockRunner = MockProcessRunner();
      when(() => mockRunner('gh', any())).thenAnswer(
        (_) async => ProcessResult(
          1,
          0,
          jsonEncode([
            {
              'name': 'repo',
              'sshUrl': 'git@github.com:myorg/repo.git',
              'url': 'https://github.com/myorg/repo',
            },
          ]),
          '',
        ),
      );
      final platform = GitHubPlatform(processRunner: mockRunner.call);
      final repos = await platform.fetchOrgRepos('testorg', project: 'ignored');
      expect(repos.length, 1);
      expect(repos.first.name, 'repo');
      expect(repos.first.httpsUrl, 'https://github.com/myorg/repo');
    });
  });

  group('AzureDevOpsPlatform', () {
    test('buildRepoUrl returns correct URL with project', () {
      final platform = AzureDevOpsPlatform();
      final url = platform.buildRepoUrl('myorg', 'myrepo', 'myproj');
      expect(url, 'https://ssh.dev.azure.com:v3/myorg/myproj/myrepo.git');
    });

    test('buildRepoUrl throws without project', () {
      final platform = AzureDevOpsPlatform();
      expect(
        () => platform.buildRepoUrl('myorg', 'myrepo'),
        throwsArgumentError,
      );
    });

    test('fetchOrgRepos throws without project', () async {
      final platform = AzureDevOpsPlatform();
      await expectLater(platform.fetchOrgRepos('myorg'), throwsArgumentError);
    });

    test('fetchOrgRepos executes CLI and parses JSON', () async {
      final mockRunner = MockProcessRunner();
      when(() => mockRunner('az', any())).thenAnswer(
        (_) async => ProcessResult(
          1,
          0,
          jsonEncode([
            {'name': 'repo1', 'sshUrl': 'ssh1', 'remoteUrl': 'https1'},
            {'name': 'repo2', 'sshUrl': 'ssh2', 'remoteUrl': 'https2'},
          ]),
          '',
        ),
      );
      final platform = AzureDevOpsPlatform(processRunner: mockRunner.call);
      final repos = await platform.fetchOrgRepos('myorg', project: 'myproj');
      expect(repos.length, 2);
      expect(repos[0].name, 'repo1');
      expect(repos[0].cloneUrl, 'ssh1');
      verify(
        () => mockRunner('az', [
          'repos',
          'list',
          '--organization',
          'https://dev.azure.com/myorg',
          '--project',
          'myproj',
        ]),
      ).called(1);
    });

    test('fetchOrgRepos throws on non-zero exit code', () async {
      final mockRunner = MockProcessRunner();
      when(() => mockRunner('az', any()))
          .thenAnswer((_) async => ProcessResult(2, 1, '', 'CLI error'));
      final platform = AzureDevOpsPlatform(processRunner: mockRunner.call);
      await expectLater(
        platform.fetchOrgRepos('myorg', project: 'myproj'),
        throwsA(isA<Exception>()),
      );
    });

    test('fetchOrgRepos throws on invalid JSON', () async {
      final mockRunner = MockProcessRunner();
      when(() => mockRunner('az', any()))
          .thenAnswer((_) async => ProcessResult(3, 0, 'invalid json', ''));
      final platform = AzureDevOpsPlatform(processRunner: mockRunner.call);
      await expectLater(
        platform.fetchOrgRepos('myorg', project: 'myproj'),
        throwsA(isA<Exception>()),
      );
    });

    test('fetchOrgRepos throws when az is not installed', () async {
      final mockRunner = MockProcessRunner();
      // First call: az --version fails
      when(() => mockRunner('az', ['--version']))
          .thenAnswer((_) async => ProcessResult(4, 1, '', 'az not found'));
      final platform = AzureDevOpsPlatform(processRunner: mockRunner.call);
      await expectLater(
        platform.fetchOrgRepos('myorg', project: 'myproj'),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Bitte installiere die Azure CLI'),
          ),
        ),
      );
      // Main az repos list should not be called
      verifyNever(() => mockRunner('az', any(that: contains('repos'))));
    });

    test('extractOrgFromUrl returns Organization for Azure URL', () {
      final platform = AzureDevOpsPlatform();
      final org = platform.extractOrgFromUrl(
        'git@ssh.dev.azure.com:v3/myorg/myproj/myrepo.git',
      );
      expect(org?.name, 'myorg');
      expect(org?.projectName, 'myproj');
      expect(org?.url, 'https://ssh.dev.azure.com:v3/myorg/myproj/');
    });

    test('extractOrgFromUrl returns null for non-Azure URL', () {
      final platform = AzureDevOpsPlatform();
      final org = platform.extractOrgFromUrl(
        'https://github.com/myorg/myrepo.git',
      );
      expect(org, isNull);
    });

    test('buildBaseUrl returns correct base with project', () {
      final platform = AzureDevOpsPlatform();
      final base = platform.buildBaseUrl('myorg', 'myproj');
      expect(base, 'https://ssh.dev.azure.com:v3/myorg/myproj/');
    });

    test('buildBaseUrl returns correct base without project', () {
      final platform = AzureDevOpsPlatform();
      final base = platform.buildBaseUrl('myorg');
      expect(base, 'https://ssh.dev.azure.com:v3/myorg/');
    });

    test(
      'fetchOrgRepos throws with correct message on non-zero exit code',
      () async {
        final mockRunner = MockProcessRunner();
        when(
          () => mockRunner('az', any()),
        ).thenAnswer((_) async => ProcessResult(3, 1, '', 'CLI error message'));
        when(
          () => mockRunner('az', ['--version']),
        ).thenAnswer((_) async => ProcessResult(2, 0, '', 'azure-cli 2.75.0'));
        final platform = AzureDevOpsPlatform(processRunner: mockRunner.call);
        await expectLater(
          platform.fetchOrgRepos('myorg', project: 'myproj'),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              'Exception: Failed to fetch repositories for organization myorg, '
                  'project myproj: CLI error message',
            ),
          ),
        );
      },
    );
  });
}

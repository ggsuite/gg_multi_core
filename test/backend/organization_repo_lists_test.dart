// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_multi_core/gg_multi_core.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockGitHubPlatform extends Mock implements GitHubPlatform {}

class MockAzureDevOpsPlatform extends Mock implements AzureDevOpsPlatform {}

void main() {
  late MockGitHubPlatform gitHub;
  late MockAzureDevOpsPlatform azure;
  late OrganizationRepoLists lists;

  final ggsuite = Organization(
    id: '1',
    name: 'ggsuite',
    url: 'https://github.com/ggsuite/',
  );
  final ggdna = Organization(
    id: '2',
    name: 'ggdna',
    url: 'https://github.com/ggdna/',
  );
  final azureOrg = Organization(
    id: '3',
    name: 'myorg',
    url: 'https://ssh.dev.azure.com:v3/myorg/myproject/',
    projectName: 'myproject',
  );

  Repository repo(String name) =>
      Repository(name: name, httpsUrl: 'https://example.com/$name.git');

  setUp(() {
    gitHub = MockGitHubPlatform();
    azure = MockAzureDevOpsPlatform();
    lists = OrganizationRepoLists(
      gitHubPlatform: gitHub,
      azureDevOpsPlatform: azure,
    );
  });

  group('OrganizationRepoLists', () {
    group('reposOf', () {
      test('lists a GitHub organization via the GitHub platform', () async {
        when(() => gitHub.fetchOrgRepos('ggsuite'))
            .thenAnswer((_) async => [repo('gg_one'), repo('gg')]);

        final repos = await lists.reposOf(ggsuite);

        expect(repos?.map((r) => r.name), ['gg_one', 'gg']);
        verifyNever(
          () => azure.fetchOrgRepos(any(), project: any(named: 'project')),
        );
      });

      test('lists an Azure DevOps organization with its project via the '
          'Azure platform', () async {
        when(() => azure.fetchOrgRepos('myorg', project: 'myproject'))
            .thenAnswer((_) async => [repo('backend')]);

        final repos = await lists.reposOf(azureOrg);

        expect(repos?.map((r) => r.name), ['backend']);
        verifyNever(() => gitHub.fetchOrgRepos(any()));
      });

      test('is null for an organization on an unknown platform', () async {
        final unknown = Organization(
          id: '9',
          name: 'somewhere',
          url: 'https://git.example.com/somewhere/',
        );

        expect(await lists.reposOf(unknown), isNull);
        verifyNever(() => gitHub.fetchOrgRepos(any()));
      });

      test('is null when the platform cannot be asked', () async {
        when(() => gitHub.fetchOrgRepos('ggsuite'))
            .thenThrow(Exception('gh is not installed'));

        expect(await lists.reposOf(ggsuite), isNull);
      });

      test('asks each organization once, however often it is needed', () async {
        when(() => gitHub.fetchOrgRepos('ggsuite'))
            .thenAnswer((_) async => [repo('gg_one')]);

        // The `.organizations` file is re-read per call, so the same
        // organization arrives as a new instance with a new id.
        final again = Organization(
          id: '99',
          name: 'ggsuite',
          url: 'https://github.com/ggsuite/',
        );

        await lists.reposOf(ggsuite);
        await lists.reposOf(again);
        await lists.owns(ggsuite, 'gg_one');

        verify(() => gitHub.fetchOrgRepos('ggsuite')).called(1);
      });

      test('remembers a failure so a broken CLI is not retried', () async {
        when(() => gitHub.fetchOrgRepos('ggsuite'))
            .thenThrow(Exception('gh is not installed'));

        await lists.reposOf(ggsuite);
        await lists.reposOf(ggsuite);

        verify(() => gitHub.fetchOrgRepos('ggsuite')).called(1);
      });

      test('keeps organizations apart', () async {
        when(() => gitHub.fetchOrgRepos('ggsuite'))
            .thenAnswer((_) async => [repo('gg_one')]);
        when(() => gitHub.fetchOrgRepos('ggdna'))
            .thenAnswer((_) async => [repo('helix')]);

        expect((await lists.reposOf(ggsuite))?.single.name, 'gg_one');
        expect((await lists.reposOf(ggdna))?.single.name, 'helix');
      });
    });

    group('owns', () {
      test('is true when the list names the repository', () async {
        when(() => gitHub.fetchOrgRepos('ggdna'))
            .thenAnswer((_) async => [repo('helix')]);

        expect(await lists.owns(ggdna, 'helix'), isTrue);
      });

      test('is false when the list does not name it', () async {
        // The repository was transferred to another organization; its former
        // url may still answer, but the list is what counts.
        when(() => gitHub.fetchOrgRepos('ggsuite'))
            .thenAnswer((_) async => [repo('gg_one')]);

        expect(await lists.owns(ggsuite, 'helix'), isFalse);
      });

      test('compares names case-insensitively', () async {
        when(() => gitHub.fetchOrgRepos('ggsuite'))
            .thenAnswer((_) async => [repo('Gg_One')]);

        expect(await lists.owns(ggsuite, 'gg_one'), isTrue);
      });

      test('is null when the platform cannot be asked', () async {
        when(() => gitHub.fetchOrgRepos('ggsuite'))
            .thenThrow(Exception('gh is not installed'));

        expect(await lists.owns(ggsuite, 'gg_one'), isNull);
      });
    });

    group('failureOf', () {
      test('is the error of the platform', () async {
        when(() => gitHub.fetchOrgRepos('ggsuite')).thenThrow(
          Exception('\x1B[31mgh: not logged in\x1B[0m\nrun gh auth login'),
        );

        await lists.reposOf(ggsuite);

        expect(lists.failureOf(ggsuite), 'gh: not logged in run gh auth login');
      });

      test('names an organization of another platform', () async {
        final gitLab = Organization(
          id: '4',
          name: 'lab',
          url: 'https://gitlab.com/lab/',
        );

        await lists.reposOf(gitLab);

        expect(
          lists.failureOf(gitLab),
          'only GitHub and Azure DevOps organizations can be listed, '
          'not https://gitlab.com/lab/',
        );
      });

      test('is null for a listed organization', () async {
        when(() => gitHub.fetchOrgRepos('ggsuite'))
            .thenAnswer((_) async => [repo('gg')]);

        await lists.reposOf(ggsuite);

        expect(lists.failureOf(ggsuite), isNull);
      });
    });
  });

  group('plainError', () {
    test('drops the prefix, the colors and the line breaks', () {
      expect(
        plainError(Exception('\x1B[31mfailed\x1B[0m\r\n\n  because\n')),
        'failed because',
      );
      expect(plainError('plain'), 'plain');
    });
  });
}

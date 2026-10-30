// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_multi_core/gg_multi_core.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:test/test.dart';

void main() {
  final gitHubOrg = Organization(name: 'org', url: 'https://github.com/org/');
  final azureOrg = Organization(
    name: 'carat',
    url: 'https://dev.azure.com/carat/',
    projectName: 'p',
  );
  final otherOrg = Organization(name: 'lab', url: 'https://gitlab.com/lab/');

  /// [lines] as logged, without colors.
  String plain(List<String> lines) => lines.map(rmControls).join('\n');

  InaccessibleDependency dependency(
    InaccessibleReason reason,
    List<Organization> orgs,
  ) => InaccessibleDependency(
    dependency: 'secret',
    manifestPath: '/t/a/pubspec.yaml',
    repoName: 'secret',
    reason: reason,
    organizations: orgs,
  );

  group('uncheckedOrganizationReport', () {
    test('tells a GitHub user to check the GitHub CLI', () {
      final text = plain(uncheckedOrganizationReport(gitHubOrg, 'boom'));

      expect(text, contains('Could not list the repositories of org: boom'));
      expect(text, contains('goes unnoticed'));
      expect(text, contains('GitHub CLI is not installed, not logged in'));
      expect(text, contains('gh auth status'));
      expect(text, contains('gh auth login'));
    });

    test('tells an Azure user to check the Azure CLI', () {
      final text = plain(uncheckedOrganizationReport(azureOrg, 'boom'));

      expect(text, contains('Azure CLI is not installed or not logged in'));
      expect(text, contains('az login'));
      expect(text, contains('az extension add --name azure-devops'));
    });

    test('points at the organization file for other platforms', () {
      final text = plain(uncheckedOrganizationReport(otherOrg, 'boom'));

      expect(text, contains('.ocean/.organizations'));
      expect(text, contains('only GitHub and Azure DevOps'));
    });
  });

  group('inaccessibleDependencyReport', () {
    test('explains a package pub.dev does not know', () {
      final text = plain(
        inaccessibleDependencyReport(
          dependency(InaccessibleReason.notOnPubDev, [gitHubOrg, otherOrg]),
        ),
      );

      expect(
        text,
        contains(
          'secret (in /t/a/pubspec.yaml) is not in the ocean: pub.dev does '
          'not know it, and no repository list of org, lab names it.',
        ),
      );
      expect(text, contains('private repository your account cannot see'));
      expect(text, contains('gh repo view <org>/secret'));
      expect(text, contains('fix the dependency in /t/a/pubspec.yaml'));
    });

    test('names the repository a git url points to', () {
      final text = plain(
        inaccessibleDependencyReport(
          dependency(InaccessibleReason.gitUrlOfOrganization, [gitHubOrg]),
        ),
      );

      expect(text, contains('its git url points to org'));
      expect(text, contains('gh repo view org/secret'));
      expect(text, contains('Could not resolve'));
    });

    test('names the organization of an npm scope', () {
      final text = plain(
        inaccessibleDependencyReport(
          dependency(InaccessibleReason.organizationScope, [azureOrg]),
        ),
      );

      expect(text, contains('its scope is the organization carat'));
      expect(text, contains('gh repo view <org>/secret'));
    });
  });

  test('missingFromOceanReport clones into the ocean only', () {
    final text = plain(
      missingFromOceanReport([
        MissingOceanRepo(
          dependency: 'x',
          manifestPath: '/t/a/pubspec.yaml',
          owners: [
            OrganizationRepo(
              organization: gitHubOrg,
              repo: const Repository(name: 'x', httpsUrl: 'https://x'),
            ),
          ],
        ),
      ], '/ws'),
    );

    expect(text, contains('  - x (x in /t/a/pubspec.yaml)'));
    expect(text, contains('added to the organization after the ocean'));
    expect(
      text,
      contains('Run gg do add x in /ws to clone them into the ocean.'),
    );
  });

  test('missingBetweenReport names the breaking releases and the command', () {
    final text = plain(missingBetweenReport(['c', 'd'], breaking: ['f', 'e']));

    expect(text, contains('  - c\n  - d'));
    expect(text, contains('They depend on e f, whose next release breaks'));
    expect(text, contains('two incompatible ones'));
    expect(text, contains('Run gg do add transitive for e f to add them.'));
  });

  test('brokenGraphReport points at the graph', () {
    final text = plain(brokenGraphReport('cycle a -> b -> a'));

    expect(text, contains('does not build: cycle a -> b -> a'));
    expect(text, contains('dependency cycle'));
    expect(text, contains('gg do create graph'));
  });

  test('staleOceanReport tells to clean the ocean copy', () {
    final text = plain(staleOceanReport('c has uncommitted changes'));

    expect(text, contains('Could not refresh the ocean copies checked above'));
    expect(text, contains('c has uncommitted changes'));
    expect(text, contains('gg do upgrade ocean'));
  });

  test('cloneFailedReport tells how to check the access', () {
    final text = plain(
      cloneFailedReport(
        repoName: 'x',
        url: 'git@github.com:org/x.git',
        dependency: 'x',
        manifestPath: '/t/a/pubspec.yaml',
        error: 'Permission denied',
      ),
    );

    expect(
      text,
      contains(
        'Failed to clone x, which x in /t/a/pubspec.yaml needs: '
        'Permission denied',
      ),
    );
    expect(text, contains('no access to the repository'));
    expect(text, contains('git ls-remote git@github.com:org/x.git'));
  });
}

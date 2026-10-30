// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_multi_core/src/backend/missing_ocean_repos.dart';
import 'package:gg_multi_core/src/backend/organization.dart';
import 'package:gg_multi_core/src/backend/url_parser.dart';

// The reports about repos gg cannot see or the ticket lacks. Each one says
// what happened, what most likely caused it and what to run or try next —
// shared by `do add`, the localize checks and the publish gate, so the same
// situation always reads the same.

// .............................................................................
/// The report about [org], whose repositories could not be listed because
/// of [reason].
List<String> uncheckedOrganizationReport(Organization org, String reason) {
  final platform = const UrlParser().parse(org.url).platformType;
  return <String>[
    cWarn('\n⚠️ Could not list the repositories of ${org.name}: $reason'),
    cDetail(
      '  A repository of ${org.name} the ocean lacks goes unnoticed until '
      'this works.',
    ),
    ...switch (platform) {
      'github' => <String>[
        cDetail(
          '  Probably the GitHub CLI is not installed, not logged in, or '
          'cannot reach github.com.',
        ),
        cAction('  Check: ') +
            cCmd('gh auth status') +
            cAction(', then ') +
            cCmd('gh auth login') +
            cAction(' or check the network.'),
      ],
      'azure' => <String>[
        cDetail(
          '  Probably the Azure CLI is not installed or not logged in, or its '
          'azure-devops extension is missing.',
        ),
        cAction('  Check: ') +
            cCmd('az login') +
            cAction(' and ') +
            cCmd('az extension add --name azure-devops') +
            cAction('.'),
      ],
      _ => <String>[
        cAction('  Check the url of ${org.name} in ') +
            cCmd('.ocean/.organizations') +
            cAction(': only GitHub and Azure DevOps can be listed.'),
      ],
    },
  ];
}

// .............................................................................
/// The report about [dependency], which gg cannot see.
List<String> inaccessibleDependencyReport(InaccessibleDependency dependency) {
  final orgs = dependency.organizations.map((o) => o.name).join(', ');
  final why = switch (dependency.reason) {
    InaccessibleReason.notOnPubDev =>
      'pub.dev does not know it, and no repository list of $orgs names it.',
    InaccessibleReason.gitUrlOfOrganization =>
      'its git url points to $orgs, which does not list '
          '${dependency.repoName}.',
    InaccessibleReason.organizationScope =>
      'its scope is the organization $orgs, which does not list '
          '${dependency.repoName}.',
  };

  final org = dependency.organizations.length == 1
      ? dependency.organizations.single
      : null;
  final isGitHub =
      org != null && const UrlParser().parse(org.url).platformType == 'github';

  return <String>[
    cWarn(
      '\n⚠️ ${dependency.dependency} (in ${dependency.manifestPath}) is not '
      'in the ocean: $why',
    ),
    cDetail(
      '  Probably a private repository your account cannot see, or a '
      'renamed or not yet published package.',
    ),
    if (isGitHub)
      cAction('  Check the access: ') +
          cCmd('gh repo view ${org.name}/${dependency.repoName}') +
          cAction(' — »Could not resolve« means no access or no repository.')
    else
      cAction('  Check the access: ') +
          cCmd('gh repo view <org>/${dependency.repoName}') +
          cAction(' for the organization it belongs to.'),
    cAction(
      '  No access: ask an owner of the organization for it. Wrong name: '
      'fix the dependency in ${dependency.manifestPath}.',
    ),
  ];
}

// .............................................................................
/// The report about [repos], which the ticket depends on but the ocean
/// lacks; [workspaceRoot] is where `gg do add` clones into the ocean only.
List<String> missingFromOceanReport(
  List<MissingOceanRepo> repos,
  String workspaceRoot,
) {
  final names = repos.map((r) => r.repoName).toSet().toList();
  return <String>[
    cWarn('\n⚠️ Repos the ticket depends on, but not in the ocean:'),
    for (final repo in repos)
      cWarn(
        '  - ${repo.repoName} (${repo.dependency} in ${repo.manifestPath})',
      ),
    cDetail(
      '  Probably added to the organization after the ocean was set up. '
      'Until they are in the ocean, gg cannot see the repos between the '
      'ticket repos that lead through them.',
    ),
    cAction('Run ') +
        cCmd('gg do add ${names.join(' ')}') +
        cAction(' in ') +
        cCmd(workspaceRoot) +
        cAction(' to clone them into the ocean.\n'),
  ];
}

// .............................................................................
/// The report about [names], ocean repos the ticket lacks between its repos
/// and the [breaking] ones, whose release breaks its dependents.
List<String> missingBetweenReport(
  List<String> names, {
  required Iterable<String> breaking,
}) {
  final releases = (breaking.toList()..sort()).join(' ');
  return <String>[
    cWarn('\n⚠️ Repos between the ticket repos, but not in it:'),
    for (final name in names) cWarn('  - $name'),
    cDetail(
      '  They depend on $releases, whose next release breaks its '
      'dependents, and a ticket repo depends on them. Released without '
      'them, they keep the old version and the ticket repos above resolve '
      'two incompatible ones.',
    ),
    cAction('Run ') +
        cCmd('gg do add transitive for $releases') +
        cAction(' to add them.\n'),
  ];
}

// .............................................................................
/// The report about an ocean dependency graph that does not build.
List<String> brokenGraphReport(String error) => <String>[
  cWarn('\n⚠️ The dependency graph of the ocean does not build: $error'),
  cDetail(
    '  Probably a dependency cycle between ocean repos. Until it builds, '
    'repos between the ticket repos go unnoticed.',
  ),
  cAction('  See the edges with ') +
      cCmd('gg do create graph') +
      cAction(' in the workspace root and break the cycle.'),
];

// .............................................................................
/// The report about ocean repos that could not be brought to their remote
/// state because of [error] — their outdated manifests may report repos as
/// between that are not any more.
List<String> staleOceanReport(String error) => <String>[
  cWarn('\n⚠️ Could not refresh the ocean copies checked above: $error'),
  cDetail(
    '  Probably they hold local work. Their manifests may be outdated, so a '
    'repo reported between the ticket repos may not be any more.',
  ),
  cAction('  Commit or stash the work in the ocean copy, then run ') +
      cCmd('gg do upgrade ocean') +
      cAction(' and check again.'),
];

// .............................................................................
/// The report about [repoName], which `gg do add` could not clone from
/// [url] because of [error]; [dependency] in [manifestPath] needs it.
List<String> cloneFailedReport({
  required String repoName,
  required String url,
  required String dependency,
  required String manifestPath,
  required String error,
}) => <String>[
  cError(
    'Failed to clone $repoName, which $dependency in $manifestPath needs: '
    '$error',
  ),
  cDetail(
    '  Probably your SSH key or account has no access to the repository, or '
    'the network is down.',
  ),
  cAction('  Check with ') +
      cCmd('git ls-remote $url') +
      cAction('; without access, ask an owner of the organization for it.'),
];

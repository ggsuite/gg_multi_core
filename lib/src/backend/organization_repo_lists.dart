// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_multi_core/src/backend/git_platform.dart';
import 'package:gg_multi_core/src/backend/organization.dart';
import 'package:gg_multi_core/src/backend/repository.dart';
import 'package:gg_multi_core/src/backend/url_parser.dart';

/// The repositories the registered organizations currently offer, asked for
/// once per organization and run.
///
/// Whether an organization *owns* a repository is decided by the list the
/// platform reports — the same list `gg do upgrade ocean` syncs the ocean
/// against — and not by whether its url answers. A url keeps answering long
/// after the repository is gone: GitHub redirects a renamed or transferred
/// repository from its former name, so `git ls-remote` on the old
/// organization still succeeds. Deciding by that url is what made
/// `gg do add <name>` offer a repository under an organization the sync had
/// just moved it out of.
///
/// One `gg do add` may ask about many names — every missing transitive
/// dependency is looked up the same way — so the lists are memoized: each
/// organization is asked once, however many names are checked against it.
class OrganizationRepoLists {
  /// Constructor.
  ///
  /// [gitHubPlatform] and [azureDevOpsPlatform] list the repositories of the
  /// organizations on their platform.
  OrganizationRepoLists({
    GitHubPlatform? gitHubPlatform,
    AzureDevOpsPlatform? azureDevOpsPlatform,
    // coverage:ignore-start
  }) : _gitHubPlatform = gitHubPlatform ?? GitHubPlatform(),
       _azureDevOpsPlatform = azureDevOpsPlatform ?? AzureDevOpsPlatform();
  // coverage:ignore-end

  /// The repositories [org] offers, or null when the platform cannot say —
  /// its CLI is missing or unauthenticated, or the platform is unknown.
  ///
  /// Null is "unknown", not "none": the caller decides on a fallback. The
  /// answer is memoized per organization, a failure included, so a broken
  /// CLI is not retried for every name of the same run.
  Future<List<Repository>?> reposOf(Organization org) =>
      _lists.putIfAbsent(_keyOf(org), () => _fetch(org));

  /// Whether [org] currently offers a repository named [repoName], or null
  /// when the platform cannot say (see [reposOf]).
  ///
  /// Names are compared case-insensitively: GitHub treats `Gg_One` and
  /// `gg_one` as the same repository, and so does Azure DevOps.
  Future<bool?> owns(Organization org, String repoName) async {
    final repos = await reposOf(org);
    if (repos == null) {
      return null;
    }
    final wanted = repoName.toLowerCase();
    return repos.any((repo) => repo.name.toLowerCase() == wanted);
  }

  // ######################
  // Private
  // ######################

  final GitHubPlatform _gitHubPlatform;
  final AzureDevOpsPlatform _azureDevOpsPlatform;
  final Map<String, Future<List<Repository>?>> _lists = {};

  // ...........................................................................
  /// Identifies [org] across `Organization` instances that name the same one:
  /// the `.organizations` file is re-read per call, so instances differ while
  /// the organization does not.
  static String _keyOf(Organization org) =>
      '${org.url.toLowerCase()}|${org.projectName?.toLowerCase() ?? ''}';

  // ...........................................................................
  Future<List<Repository>?> _fetch(Organization org) async {
    try {
      switch (const UrlParser().parse(org.url).platformType) {
        case 'github':
          return await _gitHubPlatform.fetchOrgRepos(org.name);
        case 'azure':
          return await _azureDevOpsPlatform.fetchOrgRepos(
            org.name,
            project: org.projectName,
          );
        default:
          return null;
      }
    } catch (_) {
      // The platform could not be asked — nothing here may end a run that
      // has a fallback for exactly this case.
      return null;
    }
  }
}

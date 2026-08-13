// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_multi_core/src/backend/git_platform.dart';

/// Result of URL parsing.
class ParseResult {
  /// The organization name
  final String? org;

  /// The repository name
  final String? repo;

  /// The project name (Azure)
  final String? project;

  /// The platform type
  final String platformType;

  /// Constructor
  ParseResult({this.org, this.repo, this.project, required this.platformType});
}

/// Unified URL parser for different git platforms.
class UrlParser {
  /// Constructor
  const UrlParser();

  /// Parses the given targetArg and returns ParseResult
  ParseResult parse(String targetArg) {
    // Clean trailing '/' and '#'
    var cleaned = targetArg;
    while (cleaned.endsWith('/') || cleaned.endsWith('#')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }

    // Detect platform based on format
    if (cleaned.startsWith('git@$_azureSshHost:')) {
      return parseAzure(cleaned);
    } else if (cleaned.startsWith('git@')) {
      return parseGitHubSsh(cleaned);
    } else if (Uri.tryParse(cleaned)?.scheme.startsWith('http') ?? false) {
      return parseHttp(cleaned);
    } else if (cleaned.contains(_azureSshHost)) {
      // `https://ssh.dev.azure.com:v3/<org>/<project>/<repo>` — the form gg
      // builds itself. Its `:v3` is no port, so it never parses as a Uri and
      // would otherwise fall through to the plain-name branch.
      return parseAzure(cleaned);
    } else if (cleaned.contains('/')) {
      return parseUsernameRepo(cleaned);
    } else {
      return parsePlainRepo(cleaned);
    }
  }

  /// The host of the Azure DevOps git endpoint.
  static const String _azureSshHost = 'ssh.dev.azure.com';

  /// The pages GitHub serves under `/orgs/<org>/…`. None of them is a
  /// repository, so a URL ending in one names the organization alone.
  static const Set<String> _githubOrgTabs = {
    'audit-log',
    'billing',
    'dashboard',
    'discussions',
    'insights',
    'invitations',
    'members',
    'packages',
    'people',
    'projects',
    'repositories',
    'security',
    'settings',
    'sso',
    'teams',
  };

  /// Internal helper to parse Azure URLs. Not intended for external use.
  ///
  /// Handles `git@ssh.dev.azure.com:v3/<org>/<project>/<repo>` and the
  /// `https://ssh.dev.azure.com:v3/<org>/<project>/<repo>` form gg builds
  /// itself. Everything after the host is read as
  /// `v3 / <org> / <project> / <repo>`; without a project the URL names no
  /// repository location and is reported as unknown.
  ParseResult parseAzure(String url) {
    final afterHost = url.split(_azureSshHost).last;
    final segments = afterHost
        .split(RegExp(r'[:/]'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.length >= 3) {
      return ParseResult(
        org: segments[1],
        project: segments[2],
        repo: segments.length > 3 ? _withoutGitSuffix(segments[3]) : null,
        platformType: 'azure',
      );
    }
    return ParseResult(platformType: 'unknown');
  }

  /// Internal helper to parse Azure DevOps web URLs. Not for external use.
  ///
  /// Covers every shape Azure DevOps hands out:
  /// * `dev.azure.com/<org>/<project>` — the project overview,
  /// * `dev.azure.com/<org>/<project>/_git/<repo>` — the clone URL,
  /// * `dev.azure.com/v3/<org>/<project>/<repo>`,
  /// * `<org>.visualstudio.com/<project>/_git/<repo>` — the legacy host, which
  ///   carries the organization in its subdomain,
  /// * `dev.azure.com/<org>/_git/<repo>` — the shortcut Azure accepts when the
  ///   project is named like the repository, so both are that one name.
  ///
  /// `_git` is the marker Azure puts between the project and the repository;
  /// what follows it is therefore the repository, never the project.
  ParseResult _parseAzureHttp(Uri uri, List<String> segments) {
    final host = uri.host.toLowerCase();
    const legacyHostSuffix = '.visualstudio.com';
    final orgFromHost = host.endsWith(legacyHostSuffix)
        ? host.substring(0, host.length - legacyHostSuffix.length)
        : null;

    var rest = segments;
    if (rest.isNotEmpty && (rest.first == 'v3' || rest.first == 'v4')) {
      rest = rest.sublist(1);
    }

    String? org = orgFromHost;
    if (org == null && rest.isNotEmpty) {
      org = rest.first;
      rest = rest.sublist(1);
    }

    final gitIndex = rest.indexOf('_git');
    if (gitIndex >= 0) {
      final repo = gitIndex + 1 < rest.length
          ? _withoutGitSuffix(rest[gitIndex + 1])
          : null;
      return ParseResult(
        org: org,
        // Nothing in front of `_git` means the shortcut form, where the
        // project carries the name of the repository.
        project: gitIndex > 0 ? rest[gitIndex - 1] : repo,
        repo: repo,
        platformType: 'azure',
      );
    }

    return ParseResult(
      org: org,
      project: rest.isNotEmpty ? rest.first : null,
      repo: rest.length > 1 ? _withoutGitSuffix(rest[1]) : null,
      platformType: 'azure',
    );
  }

  /// Returns [segment] without a trailing `.git`. Only the suffix is removed,
  /// so a repository whose name contains `.git` keeps it.
  static String _withoutGitSuffix(String segment) => segment.endsWith('.git')
      ? segment.substring(0, segment.length - '.git'.length)
      : segment;

  /// Internal helper to parse GitHub SSH URLs. Not intended for external use.
  ParseResult parseGitHubSsh(String url) {
    final sshRegex = RegExp(r'^git@[^:]+:([^/]+)/(.+?)(?:\.git)?$');
    final match = sshRegex.firstMatch(url);
    if (match != null) {
      return ParseResult(
        org: match.group(1),
        repo: match.group(2)!.replaceAll('.git', ''),
        platformType: 'github',
      );
    }
    return ParseResult(platformType: 'unknown');
  }

  /// Internal helper to parse HTTP URLs. Not intended for external use.
  ParseResult parseHttp(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return ParseResult(platformType: 'unknown');
    final host = uri.host.toLowerCase();
    // `visualstudio.com` is the legacy host of Azure DevOps.
    final platform = host.contains('azure') || host.endsWith('visualstudio.com')
        ? 'azure'
        : (host.contains('github') ? 'github' : 'unknown');
    final segments = uri.pathSegments
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (platform == 'azure') {
      return _parseAzureHttp(uri, segments);
    }
    if (segments.isEmpty) return ParseResult(platformType: platform);
    // GitHub organization URL: `github.com/orgs/<org>` points at an
    // organization, not a repository (`orgs` is a reserved GitHub path and
    // can never be an account name). Report it as an org without a repo so
    // callers treat it like the bare `github.com/<org>` form.
    //
    // A third segment is the repository — `github.com/orgs/<org>/<repo>` is
    // the form users produce by pasting an org page and appending a repo, and
    // reading it as the bare org would clone the whole organization. Only
    // GitHub's own org tabs (`/orgs/<org>/repositories`, `/people`, …) keep
    // naming no repository.
    if (platform == 'github' && segments[0] == 'orgs') {
      final org = segments.length > 1 ? segments[1] : null;
      final third = segments.length > 2 ? segments[2] : null;
      return ParseResult(
        org: org,
        repo: third == null || _githubOrgTabs.contains(third.toLowerCase())
            ? null
            : _withoutGitSuffix(third),
        platformType: platform,
      );
    }
    return ParseResult(
      org: segments[0],
      repo: segments.length > 1 ? _withoutGitSuffix(segments[1]) : null,
      platformType: platform,
    );
  }

  /// Internal helper to parse username/repo format. Not intended for external use.
  ParseResult parseUsernameRepo(String target) {
    final parts = target.split('/');
    if (parts.length == 2) {
      return ParseResult(
        org: parts[0],
        repo: parts[1],
        platformType: 'github', // Assume GitHub as default
      );
    }
    return ParseResult(platformType: 'unknown');
  }

  /// Internal helper to parse plain repo names. Not intended for external use.
  ParseResult parsePlainRepo(String repo) {
    if (repo.contains('/') || repo.contains(':')) {
      // Invalid plain repo format
      return ParseResult(platformType: 'unknown');
    }
    return ParseResult(org: null, repo: repo, platformType: 'unknown');
  }

  /// Returns the platform instance based on type.
  GitPlatform getPlatform(String type) {
    switch (type) {
      case 'github':
        return GitHubPlatform();
      case 'azure':
        return AzureDevOpsPlatform();
      default:
        throw ArgumentError('Unknown platform: $type');
    }
  }
}

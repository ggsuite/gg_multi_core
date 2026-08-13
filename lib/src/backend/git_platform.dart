// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_multi_core/src/backend/organization.dart';
import 'package:gg_multi_core/src/backend/url_parser.dart';
import 'package:http/http.dart' as http;

import 'package:gg_multi_core/src/backend/repository.dart';
import 'package:gg_git/gg_git.dart';

/// Interface for Git platforms like GitHub, Azure DevOps, GitLab.
abstract class GitPlatform {
  /// Builds the full clone URL for a repository.
  String buildRepoUrl(String org, String repo, [String? project]);

  /// Fetches the list of repositories for an organization.
  Future<List<Repository>> fetchOrgRepos(
    String org, {
    String? project,
    http.Client? client,
  });

  /// Extracts organization information from a URL.
  Organization? extractOrgFromUrl(String url);

  /// Builds the base URL for the organization.
  String buildBaseUrl(String org, [String? project]);
}

/// GitHub implementation of GitPlatform.
class GitHubPlatform implements GitPlatform {
  /// Constructor accepts an optional process runner for testing.
  GitHubPlatform({ProcessRunner? processRunner})
    : _processRunner = processRunner ?? defaultProcessRunner;

  final ProcessRunner _processRunner;

  @override
  String buildRepoUrl(String org, String repo, [String? project]) {
    return 'https://github.com/$org/$repo.git';
  }

  @override
  Future<List<Repository>> fetchOrgRepos(
    String org, {
    String? project,
    http.Client? client,
  }) async {
    // The organization's repositories are listed via the GitHub CLI so the
    // caller's existing `gh` authentication is reused. This is what makes
    // private organizations work: an unauthenticated REST call only ever
    // sees public repositories. Cloning itself still uses each repository's
    // ssh url and therefore the configured ssh key.
    await _checkGhInstalled();
    final result = await _processRunner('gh', [
      'repo',
      'list',
      org,
      '--limit',
      '1000',
      '--json',
      'name,sshUrl,url',
    ]);
    if (result.exitCode != 0) {
      throw Exception(
        cError(
          'Failed to fetch repositories for organization $org: '
          '${result.stderr}',
        ),
      );
    }
    final jsonOutput = result.stdout.toString();
    try {
      final repos = jsonDecode(jsonOutput) as List<dynamic>;
      return repos
          .map((repo) {
            final repoMap = repo as Map<String, dynamic>;
            final ssh = (repoMap['sshUrl'] ?? '').toString();
            return Repository(
              name: (repoMap['name'] ?? '').toString(),
              httpsUrl: (repoMap['url'] ?? '').toString(),
              // Keep null (not '') when absent so Repository.cloneUrl can fall
              // back to the https url instead of yielding an empty clone url.
              sshUrl: ssh.isEmpty ? null : ssh,
            );
          })
          .where((r) => r.name.isNotEmpty && r.cloneUrl.isNotEmpty)
          .toList();
    } catch (e) {
      throw Exception(cError('Failed to parse GitHub CLI output: $e'));
    }
  }

  /// Checks if the GitHub CLI is installed by running 'gh --version'.
  /// Throws an exception with installation instructions if not installed.
  Future<void> _checkGhInstalled() async {
    try {
      final result = await _processRunner('gh', ['--version']);
      if (result.exitCode != 0) {
        throw Exception(cError(result.stderr.toString()));
      }
    } catch (e) {
      throw Exception(
        cError(
          'Bitte installiere die GitHub CLI und melde dich an: \n'
          '    winget install --exact --id GitHub.cli \n'
          '    gh auth login',
        ),
      );
    }
  }

  @override
  Organization? extractOrgFromUrl(String url) {
    final parsed = const UrlParser().parse(url);
    if (parsed.platformType != 'github') return null;
    return Organization(
      name: parsed.org ?? '',
      url: buildBaseUrl(parsed.org ?? ''),
    );
  }

  @override
  String buildBaseUrl(String org, [String? project]) {
    return 'https://github.com/$org/';
  }
}

/// Azure DevOps implementation of GitPlatform.
class AzureDevOpsPlatform implements GitPlatform {
  /// Constructor accepts an optional process runner for testing.
  AzureDevOpsPlatform({ProcessRunner? processRunner})
    : _processRunner = processRunner ?? defaultProcessRunner;

  final ProcessRunner _processRunner;

  @override
  String buildRepoUrl(String org, String repo, [String? project]) {
    if (project == null) {
      throw ArgumentError('Project name is required for Azure DevOps.');
    }
    return 'https://ssh.dev.azure.com:v3/$org/$project/$repo.git';
  }

  @override
  Future<List<Repository>> fetchOrgRepos(
    String org, {
    String? project,
    http.Client? client,
  }) async {
    if (project == null) {
      throw ArgumentError('Project name is required for Azure DevOps.');
    }
    await _checkAzInstalled();
    final result = await _processRunner('az', [
      'repos',
      'list',
      '--organization',
      'https://dev.azure.com/$org',
      '--project',
      project,
    ]);
    if (result.exitCode != 0) {
      throw Exception(
        cError(
          'Failed to fetch repositories for organization $org, '
          'project $project: ${result.stderr}',
        ),
      );
    }
    final jsonOutput = result.stdout.toString();
    try {
      final repos = jsonDecode(jsonOutput) as List<dynamic>;
      return repos
          .map((repo) {
            final repoMap = repo as Map<String, dynamic>;
            return Repository(
              name: (repoMap['name'] ?? '').toString(),
              httpsUrl: (repoMap['remoteUrl'] ?? '').toString(),
              sshUrl: (repoMap['sshUrl'] ?? '').toString(),
            );
          })
          .where((r) => r.name.isNotEmpty && r.cloneUrl.isNotEmpty)
          .toList();
    } catch (e) {
      throw Exception(cError('Failed to parse Azure CLI output: $e'));
    }
  }

  /// Checks if az CLI is installed by running 'az --version'.
  /// Throws an exception with installation instructions if not installed.
  Future<void> _checkAzInstalled() async {
    try {
      final result = await _processRunner('az', ['--version']);
      if (result.exitCode != 0) {
        throw Exception(cError(result.stderr.toString()));
      }
    } catch (e) {
      throw Exception(
        cError(
          'Bitte installiere die Azure CLI mit folgenden Befehlen: \n'
          '    winget install --exact --id Microsoft.AzureCLI \n'
          '    az extension add --name azure-devops',
        ),
      );
    }
  }

  @override
  Organization? extractOrgFromUrl(String url) {
    final parsed = const UrlParser().parse(url);
    if (parsed.platformType != 'azure') return null;
    return Organization(
      name: parsed.org ?? '',
      url: buildBaseUrl(parsed.org ?? '', parsed.project),
      projectName: parsed.project,
    );
  }

  @override
  String buildBaseUrl(String org, [String? project]) {
    return project != null
        ? 'https://ssh.dev.azure.com:v3/$org/$project/'
        : 'https://ssh.dev.azure.com:v3/$org/';
  }
}

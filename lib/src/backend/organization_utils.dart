// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'package:gg_multi_core/src/backend/organization.dart';

/// A utility class to manage organizations
/// associated with the ocean. Caches entries in a buffer.
class OrganizationUtils {
  static List<Organization>? _cache;
  static String? _cachePath;

  /// Returns all organizations (from cache or file).
  static List<Organization> readOrganizations(String workspacePath) {
    if (_cache != null && _cachePath == workspacePath) {
      return _cache!;
    }
    final organizationsFile = File(path.join(workspacePath, '.organizations'));
    if (!organizationsFile.existsSync()) {
      _cachePath = workspacePath;
      _cache = <Organization>[];
      return _cache!;
    }
    try {
      final content = organizationsFile.readAsStringSync();
      final decoded = jsonDecode(content);
      if (decoded is List) {
        _cachePath = workspacePath;
        _cache = decoded
            .map((e) => Organization.fromMap(e as Map<String, dynamic>))
            .toList();
        return _cache!;
      } else if (decoded is Map) {
        // Legacy: Map<String, String> → List<Organization>
        final List<Organization> legacyOrgs = [];
        decoded.forEach((name, url) {
          legacyOrgs.add(
            Organization(name: name as String, url: url.toString()),
          );
        });
        _cachePath = workspacePath;
        _cache = legacyOrgs;
        return _cache!;
      }
      // Malformed
    } catch (_) {
      // Failure reading/parsing
    }
    _cachePath = workspacePath;
    _cache = <Organization>[];
    return _cache!;
  }

  /// Writes the given organizations to file and updates the buffer.
  static void writeOrganizations(
    String workspacePath,
    List<Organization> orgs,
  ) {
    final organizationsFile = File(path.join(workspacePath, '.organizations'));
    final list = orgs.map((o) => o.toMap()).toList();
    organizationsFile.writeAsStringSync(jsonEncode(list), flush: true);
    _cachePath = workspacePath;
    _cache = orgs;
  }

  /// Adds an organization if not present by name. Updates disk and cache.
  static void addOrganization(String workspacePath, Organization org) {
    final orgs = List<Organization>.from(readOrganizations(workspacePath));
    if (orgs.any((o) => o.name == org.name)) {
      return;
    }
    orgs.add(org);
    writeOrganizations(workspacePath, orgs);
  }

  /// Finds organization by name.
  static Organization? getOrganizationByName(
    String workspacePath,
    String name,
  ) {
    return readOrganizations(workspacePath)
        .where((org) => org.name == name)
        .cast<Organization?>()
        .firstWhere((o) => o != null, orElse: () => null);
  }

  /// Finds organization by a repo URL
  static Organization? getOrganizationByRepoUrl(
    String workspacePath,
    String repoUrl,
  ) {
    final extracted = extractOrganizationFromUrl(repoUrl);
    if (extracted == null) return null;
    return getOrganizationByName(workspacePath, extracted.name);
  }

  /// Appends a new organization (if not present) for a given repo URL.
  /// Calls addOrganization and thus writeOrganizations.
  static void appendOrganization(String workspacePath, String repoUrl) {
    final org = extractOrganizationFromUrl(repoUrl);
    if (org == null) {
      return;
    }
    addOrganization(workspacePath, org);
  }

  /// Extracts the organization from a git repo URL (SSH or HTTP).
  /// Only accepts names with [a-z0-9_-]. Returns null for other patterns.
  static Organization? extractOrganizationFromUrl(String url) {
    // Normalize URL: remove trailing "/" and "#"
    var cleanedUrl = url;
    while (cleanedUrl.endsWith('#') || cleanedUrl.endsWith('/')) {
      cleanedUrl = cleanedUrl.substring(0, cleanedUrl.length - 1);
    }

    // 1. Azure SSH: git@ssh.dev.azure.com:v3/<org>/<project>/<repo>(.git)
    final azSsh = RegExp(
      r'^git@ssh\.dev\.azure\.com:v3/([a-zA-Z0-9_-]+)/([a-zA-Z0-9_-]+)(?:/[^/]+)?(?:\.git)?$',
    );
    final azSshMatch = azSsh.firstMatch(cleanedUrl);
    if (azSshMatch != null) {
      final orgName = azSshMatch.group(1)!;
      final projectName = azSshMatch.group(2)!;
      if (_isValidOrgName(orgName)) {
        final baseUrl = buildBaseUrl(url, orgName, projectName);
        return Organization(
          name: orgName,
          url: baseUrl,
          projectName: projectName,
        );
      }
    }
    // 2. Azure HTTP: https://ssh.dev.azure.com:v3/<org>/<project>/...
    final azHttp = RegExp(
      r'^https?://ssh\.dev\.azure\.com[:/]+v3/([a-zA-Z0-9_-]+)/([a-zA-Z0-9_-]+)(?:/[^/]+)?(?:\.git)?$',
    );
    final azHttpMatch = azHttp.firstMatch(cleanedUrl);
    if (azHttpMatch != null) {
      final orgName = azHttpMatch.group(1)!;
      final projectName = azHttpMatch.group(2)!;
      if (_isValidOrgName(orgName)) {
        final baseUrl = buildBaseUrl(url, orgName, projectName);
        return Organization(
          name: orgName,
          url: baseUrl,
          projectName: projectName,
        );
      }
    }
    // 3. GitHub SSH: git@github.com:org/repo.git
    final sshRegex = RegExp(r'^git@[^:]+:([^/]+)/[^/]+(?:\.git)?');
    final sshMatch = sshRegex.firstMatch(url);
    if (sshMatch != null) {
      final orgName = sshMatch.group(1);
      if (_isValidOrgName(orgName)) {
        final baseUrl = buildBaseUrl(url, orgName!);
        return Organization(name: orgName, url: baseUrl);
      }
    }
    // 4. GitHub HTTPS or generic: https://github.com/org/[repo]...
    try {
      final uri = Uri.parse(cleanedUrl);

      if (uri.pathSegments.isNotEmpty &&
          uri.pathSegments.first.trim().isNotEmpty) {
        final orgName = uri.pathSegments.first.trim();
        if (_isValidOrgName(orgName)) {
          final baseUrl = buildBaseUrl(url, orgName);
          return Organization(name: orgName, url: baseUrl);
        }
      }
    } catch (_) {
      // Ignore parse errors
    }
    return null; // Not a recognized format
  }

  /// Returns true if name is valid organization name: [a-z0-9_-] only.
  static bool _isValidOrgName(String? name) =>
      name != null && RegExp(r'^[a-z0-9_-]+').hasMatch(name);

  /// Builds the base URL for an organization
  static String buildBaseUrl(String repoUrl, String org, [String? project]) {
    // Azure DevOps specific
    if (repoUrl.contains('ssh.dev.azure.com')) {
      if (project != null) {
        return 'https://ssh.dev.azure.com:v3/$org/$project/';
      } else {
        return 'https://ssh.dev.azure.com:v3/$org/';
      }
    }
    if (repoUrl.startsWith('git@')) {
      // Assume github for classic SSH
      return 'https://github.com/$org/';
    }
    final uri = Uri.parse(repoUrl);
    // Only accept hostnames that are valid domain names
    // (letters, digits, hyphens, periods)
    if (uri.host.isEmpty || !RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(uri.host)) {
      // Host is not a valid domain, fallback to github
      return 'https://github.com/$org/';
    }
    return '${uri.scheme}://${uri.host}/$org/';
  }

  /// For tests only: clear the cache.
  static void clearCache() {
    _cache = null;
    _cachePath = null;
  }
}

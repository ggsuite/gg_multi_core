// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'package:gg_multi_core/src/backend/url_parser.dart';

/// Resolves repository folders in a workspace. A folder is matched by its
/// exact name, then by its manifest package name (for cross-language bridge
/// repos whose folder name differs from the package name), then by its git
/// remote url.
///
/// The **ocean** groups its repositories in folders named after the
/// organization they belong to (`<ocean>/<org>/<repo>`), so that two
/// organizations can own a repository of the same name — see [destination]
/// and `workspace_migration.dart` for the step that moves an old flat ocean
/// into that layout. A **ticket** holds its repositories flat and only falls
/// back to an organization folder on an actual name collision — see
/// [ticketDestination].
///
/// Both layouts are read by the same members here: a repository is found
/// whether it lies flat in the workspace or inside an organization folder.
class RepoFolderResolver {
  /// Returns the folder of [repoName] inside [workspacePath] or null,
  /// matching the exact folder name first, then the manifest package name.
  static Directory? resolve({
    required String workspacePath,
    required String repoName,
  }) {
    final exact = Directory(path.join(workspacePath, repoName));
    if (exact.existsSync() && !isOrgFolder(exact)) {
      return exact;
    }
    final dirs = repoDirs(workspacePath);
    for (final dir in dirs) {
      if (path.basename(dir.path) == repoName) {
        return dir;
      }
    }
    for (final dir in dirs) {
      if (packageNames(dir).contains(repoName)) {
        return dir;
      }
    }
    return null;
  }

  /// Returns the folder whose git remote matches [repoUrl] or null.
  static Directory? resolveByRemoteUrl({
    required String workspacePath,
    required String repoUrl,
  }) {
    final wanted = urlIdentity(repoUrl);
    if (wanted == null) {
      return null;
    }
    for (final dir in repoDirs(workspacePath)) {
      final url = remoteUrl(dir);
      if (url != null && urlIdentity(url) == wanted) {
        return dir;
      }
    }
    return null;
  }

  /// Returns all repository folders of [workspacePath]: the children of every
  /// organization folder, plus the repositories that still sit directly in
  /// the workspace.
  ///
  /// A direct child is an organization folder when it is no repository itself
  /// but holds at least one — a repository is therefore never descended into,
  /// so packages nested inside one (`example/`, test fixtures) stay invisible.
  /// Hidden folders (`.gg`, `.dart_tool`, …) are skipped.
  static List<Directory> repoDirs(String workspacePath) {
    final result = <Directory>[];
    for (final dir in _subDirs(workspacePath)) {
      if (path.basename(dir.path).startsWith('.')) {
        continue;
      }
      if (isOrgFolder(dir)) {
        result.addAll(_subDirs(dir.path).where(isRepoDir));
      } else {
        result.add(dir);
      }
    }
    return result..sort((a, b) => a.path.compareTo(b.path));
  }

  /// Returns true when [dir] groups repositories instead of being one, i.e.
  /// when it is an organization folder.
  static bool isOrgFolder(Directory dir) =>
      !isRepoDir(dir) && _subDirs(dir.path).any(isRepoDir);

  /// Returns true when [dir] holds a repository: a git checkout or at least
  /// one package manifest.
  static bool isRepoDir(Directory dir) =>
      Directory(path.join(dir.path, '.git')).existsSync() ||
      File(path.join(dir.path, 'pubspec.yaml')).existsSync() ||
      File(path.join(dir.path, 'package.json')).existsSync();

  /// Returns the path of [repoDir] relative to [workspacePath], i.e.
  /// `<org>/<repo>` or just `<repo>` for a repository that was not moved into
  /// an organization folder yet.
  static String relativePath({
    required String workspacePath,
    required Directory repoDir,
  }) => path.relative(repoDir.path, from: workspacePath);

  /// Returns the folder a repository named [repoName] and cloned from
  /// [repoUrl] belongs to inside [workspacePath]: `<workspace>/<org>/<repo>`,
  /// or `<workspace>/<repo>` when the URL carries no organization.
  static String destination({
    required String workspacePath,
    required String repoUrl,
    required String repoName,
  }) {
    final org = organizationOf(repoUrl);
    return org == null
        ? path.join(workspacePath, repoName)
        : path.join(workspacePath, org, repoName);
  }

  /// Returns the folder a repository named [repoName] and cloned from
  /// [repoUrl] belongs to inside the **ticket** [ticketPath].
  ///
  /// A ticket is a workbench, not an archive: it holds a handful of repos the
  /// user works on, so they lie flat in it (`<ticket>/<repo>`) and every path
  /// the user types stays short. The organization folders the ocean needs to
  /// keep two same-named repos apart are only created here when that
  /// collision actually happens: when `<ticket>/<repo>` is already taken by a
  /// repository of *another* organization, the newcomer goes to
  /// `<ticket>/<org>/<repo>` instead. The repo that was there first stays
  /// where it is — moving it would break the relative references the other
  /// ticket repos hold to it.
  ///
  /// A repository that is already in the ticket — flat or in an organization
  /// folder — resolves to the folder it occupies, so adding it twice is a
  /// no-op. It is recognized by its git remote, not by its name.
  static String ticketDestination({
    required String ticketPath,
    required String repoUrl,
    required String repoName,
  }) {
    final existing = resolveByRemoteUrl(
      workspacePath: ticketPath,
      repoUrl: repoUrl,
    );
    if (existing != null) {
      return existing.path;
    }

    final flat = Directory(path.join(ticketPath, repoName));
    if (!flat.existsSync() || !isRepoDir(flat)) {
      return flat.path;
    }

    // Taken by a repository of another organization — the check above already
    // ruled out that it is this one. Without a known organization there is no
    // folder to move into, so the collision is left to the caller's
    // »already exists« handling.
    final org = organizationOf(repoUrl);
    return org == null ? flat.path : path.join(ticketPath, org, repoName);
  }

  /// Returns the organization folder [repoUrl] belongs to, or null when the
  /// URL names none.
  ///
  /// A repository must be present: a URL like `https://host/repo.git` carries
  /// a single path segment, and that segment is the repository, not an
  /// organization.
  ///
  /// On Azure DevOps the folder is the **project**, not the account Azure
  /// calls the organization: repository names are unique per project, so two
  /// projects of one account can each own a `common` repo — exactly the
  /// collision the folders exist to prevent. Everywhere else the folder is
  /// the organization.
  static String? organizationOf(String repoUrl) {
    final parsed = const UrlParser().parse(repoUrl);
    if (parsed.repo == null) {
      return null;
    }
    return parsed.project ?? parsed.org;
  }

  /// Deletes the organization folder [repoDir] was located in when the
  /// removal of [repoDir] left it empty. Does nothing when the repository sat
  /// directly in [workspacePath].
  static void removeEmptyOrgFolder({
    required String workspacePath,
    required Directory repoDir,
  }) {
    final orgDir = repoDir.parent;
    if (path.equals(orgDir.path, workspacePath) || !orgDir.existsSync()) {
      return;
    }
    if (orgDir.listSync().isEmpty) {
      orgDir.deleteSync();
    }
  }

  /// Every name the package in [dir] can be referred to by: the Dart package
  /// name and the npm package name, the latter both with and without its
  /// scope.
  ///
  /// A repository that ships a `pubspec.yaml` *and* a `package.json` is one
  /// package under two names — `dna_base` to Dart, `@tssuite/dna-base` to npm.
  /// [packageName] answers with the primary one only, so a dependency written
  /// the other way round would look like a package nobody owns.
  static Set<String> packageNames(Directory dir) {
    final result = <String>{};

    try {
      final pubspec = File(path.join(dir.path, 'pubspec.yaml'));
      if (pubspec.existsSync()) {
        final match = RegExp(
          r'^name:\s*(\S+)',
          multiLine: true,
        ).firstMatch(pubspec.readAsStringSync());
        final name = match?.group(1);
        if (name != null) {
          result.add(name);
        }
      }

      final packageJson = File(path.join(dir.path, 'package.json'));
      if (packageJson.existsSync()) {
        final json = jsonDecode(packageJson.readAsStringSync());
        final name = (json as Map<String, dynamic>)['name']?.toString();
        if (name != null) {
          result.add(name);
          if (name.startsWith('@')) {
            result.add(name.split('/').last);
          }
        }
      }
    } catch (_) {
      return result;
    }

    return result;
  }

  /// Package name from pubspec.yaml or package.json (npm scope stripped).
  static String? packageName(Directory dir) {
    try {
      final pubspec = File(path.join(dir.path, 'pubspec.yaml'));
      if (pubspec.existsSync()) {
        final match = RegExp(
          r'^name:\s*(\S+)',
          multiLine: true,
        ).firstMatch(pubspec.readAsStringSync());
        return match?.group(1);
      }
      final packageJson = File(path.join(dir.path, 'package.json'));
      if (packageJson.existsSync()) {
        final json = jsonDecode(packageJson.readAsStringSync());
        final name = (json as Map<String, dynamic>)['name']?.toString();
        if (name == null) {
          return null;
        }
        return name.startsWith('@') ? name.split('/').last : name;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// First remote URL found in the folder's .git/config or null.
  static String? remoteUrl(Directory dir) {
    final config = File(path.join(dir.path, '.git', 'config'));
    if (!config.existsSync()) {
      return null;
    }
    final urlLine = config.readAsLinesSync().firstWhere(
      (line) => line.trim().startsWith('url ='),
      orElse: () => '',
    );
    final parts = urlLine.split('=');
    if (parts.length < 2) {
      return null;
    }
    return parts.sublist(1).join('=').trim();
  }

  /// `<org>/<repo>` identity of [url] for remote comparison, or null.
  static String? urlIdentity(String url) {
    final parsed = const UrlParser().parse(url);
    if (parsed.org == null || parsed.repo == null) {
      return null;
    }
    return '${parsed.org}/${parsed.repo}'.toLowerCase();
  }

  // ######################
  // Private
  // ######################

  // ...........................................................................
  /// Lists the direct subdirectories of [workspacePath].
  static List<Directory> _subDirs(String workspacePath) {
    final workspace = Directory(workspacePath);
    if (!workspace.existsSync()) {
      return const <Directory>[];
    }
    return workspace.listSync(recursive: false).whereType<Directory>().toList();
  }
}

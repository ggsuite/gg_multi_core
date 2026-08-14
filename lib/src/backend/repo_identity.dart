// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'package:gg_multi_core/src/backend/repo_folder_resolver.dart';
import 'package:gg_multi_core/src/backend/url_parser.dart';

/// What a checkout says it is, independent of the folder it lies in.
///
/// The two can disagree. A platform keeps redirecting the old name of a
/// renamed repository, so cloning that name still succeeds — and leaves a
/// second folder holding the very same repository, named after a repository
/// that does not exist any more. The manifests inside know better: they still
/// carry the repository url the package publishes under.
class RepoIdentity {
  /// Constructor.
  RepoIdentity({
    required this.directory,
    required this.packageNames,
    this.declaredUrl,
    this.remoteUrl,
  });

  /// Reads the identity of the checkout in [dir].
  factory RepoIdentity.of(Directory dir) => RepoIdentity(
    directory: dir,
    packageNames: RepoFolderResolver.packageNames(dir),
    declaredUrl: _declaredUrl(dir),
    remoteUrl: RepoFolderResolver.remoteUrl(dir),
  );

  /// The folder the checkout lies in.
  final Directory directory;

  /// Every name the package can be referred to by — see
  /// [RepoFolderResolver.packageNames].
  final Set<String> packageNames;

  /// The repository url the manifests declare, or null when they declare none.
  final String? declaredUrl;

  /// The url of the git remote, or null when there is none.
  final String? remoteUrl;

  /// `<org>/<repo>` of [declaredUrl], or null.
  ///
  /// This is the identity two folders of a renamed repository agree on, while
  /// their remotes still disagree — which is what makes them recognizable as
  /// one repository.
  String? get declaredIdentity =>
      declaredUrl == null ? null : RepoFolderResolver.urlIdentity(declaredUrl!);

  /// `<org>/<repo>` of [remoteUrl], or null.
  String? get remoteIdentity =>
      remoteUrl == null ? null : RepoFolderResolver.urlIdentity(remoteUrl!);

  /// The repository name the manifests declare, or null.
  String? get declaredRepoName =>
      declaredUrl == null ? null : const UrlParser().parse(declaredUrl!).repo;

  /// Whether the folder is named after the repository the manifests declare.
  ///
  /// False when they declare none: a checkout that says nothing about itself
  /// cannot confirm where it belongs.
  bool get sitsInDeclaredRepoFolder {
    final declared = declaredRepoName;
    return declared != null && declared == path.basename(directory.path);
  }

  /// Whether [other] is a checkout of the same repository.
  ///
  /// Only what the manifests declare counts. Two packages that merely share a
  /// name are a different problem — two organizations may each own a `gg_foo`
  /// — and treating them as one repository would throw a checkout away that
  /// belongs where it is. A checkout that declares no repository is therefore
  /// never the same as any other.
  bool isSameRepoAs(RepoIdentity other) {
    final mine = declaredIdentity;
    return mine != null && mine == other.declaredIdentity;
  }

  // ######################
  // Private
  // ######################

  // ...........................................................................
  /// The repository url declared by the manifests in [dir].
  ///
  /// `pubspec.yaml` wins over `package.json` the way it does everywhere else
  /// in the workspace; `homepage` serves as fallback for both, because a
  /// package that omits `repository` usually points its homepage at the repo.
  static String? _declaredUrl(Directory dir) {
    try {
      final pubspec = File(path.join(dir.path, 'pubspec.yaml'));
      if (pubspec.existsSync()) {
        final content = pubspec.readAsStringSync();
        final url =
            _yamlValue(content, 'repository') ??
            _yamlValue(content, 'homepage');
        if (url != null) {
          return url;
        }
      }

      final packageJson = File(path.join(dir.path, 'package.json'));
      if (packageJson.existsSync()) {
        final json =
            jsonDecode(packageJson.readAsStringSync()) as Map<String, dynamic>;
        return _jsonUrl(json['repository']) ?? _jsonUrl(json['homepage']);
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  // ...........................................................................
  /// The value of the top level [key] of a pubspec, or null.
  static String? _yamlValue(String content, String key) {
    final match = RegExp(
      '^$key:\\s*(\\S+)',
      multiLine: true,
    ).firstMatch(content);
    final value = match?.group(1);
    return value == null || value.isEmpty ? null : value;
  }

  // ...........................................................................
  /// The url out of an npm `repository` or `homepage` field, or null.
  ///
  /// npm writes `repository` either as a plain string or as an object
  /// carrying the url.
  static String? _jsonUrl(dynamic value) {
    if (value is String && value.isNotEmpty) {
      return value;
    }
    if (value is Map<String, dynamic>) {
      final url = value['url'];
      if (url is String && url.isNotEmpty) {
        return url;
      }
    }
    return null;
  }
}

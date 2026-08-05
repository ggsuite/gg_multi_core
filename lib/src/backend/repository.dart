// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// Represents a repository entry provided by a Git platform.
///
/// Contains the repository [name] and a [httpsUrl] that can be used
/// for cloning (e.g. HTTPS or SSH URL).
class Repository {
  /// Creates a repository description with [name] and [httpsUrl].
  const Repository({required this.name, required this.httpsUrl, this.sshUrl});

  /// The repository name.
  final String name;

  /// HTTP(S) URL for cloning the repository.
  final String httpsUrl;

  /// SSH URL
  final String? sshUrl;

  /// Returns the URL that can be used to clone the repository.
  String get cloneUrl => sshUrl ?? httpsUrl;
}

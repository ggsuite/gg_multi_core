// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_lang/gg_lang.dart' show hasNpmManifest;
import 'package:gg_publish/gg_publish.dart' show VersionIncrement;
import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';

import 'package:gg_multi_core/src/backend/npm_version_range.dart';
import 'package:gg_multi_core/src/backend/publish_config_io.dart';
import 'package:gg_multi_core/src/backend/publish_planner.dart';
import 'package:gg_multi_core/src/backend/publish_skip_check.dart';

/// Whether releasing [repoDir] with [increment] on top of [base] breaks its
/// dependents: the new version leaves the caret range of [base] — the range
/// a dependent's `^` constraint was written for, and the one
/// [PublishSkipCheck] judges it by.
///
/// The range is npm's for a repository with an npm manifest — stricter below
/// 0.1.0, where `^0.0.3` admits `0.0.3` only — and pub's otherwise, where the
/// minor position breaks below 1.0.0. A Dart + TypeScript repository takes
/// npm's, the stricter of the two.
///
/// No [increment] breaks nothing. An unknown [base] — a registry lookup that
/// failed — breaks only with a major increment: a review would otherwise add
/// repositories for every network hiccup.
bool releaseBreaks(
  VersionIncrement? increment, {
  required Version? base,
  required Directory repoDir,
}) {
  if (increment == null || base == null) {
    return increment == VersionIncrement.major;
  }
  final next = switch (increment) {
    VersionIncrement.major => base.nextMajor,
    VersionIncrement.minor => base.nextMinor,
    VersionIncrement.patch => base.nextPatch,
  };
  final npmCaret = hasNpmManifest(repoDir)
      ? NpmVersionRange.tryParse('^$base')
      : null;
  return npmCaret != null
      ? !NpmVersionRange.allows(npmCaret, next)
      : !VersionConstraint.compatibleWith(base).allows(next);
}

/// The folder names of the [repoDirs] whose recorded release breaks its
/// dependents ([releaseBreaks]): the increment `gg do review` stored in the
/// repository's `publish_config.json`, applied to the version its manifest
/// declares.
///
/// The manifest is the right base here: `do push` merged the main branch in,
/// so it declares the version that was released last.
Future<Set<String>> recordedBreakingRepos({
  required Iterable<Directory> repoDirs,
  required Directory ticketDir,
  ReadManifestVersion readManifestVersion = defaultReadManifestVersion,
}) async {
  final result = <String>{};
  for (final repoDir in repoDirs) {
    final increment = loadTicketRepoPublishFiles(
      repoDir: repoDir,
      ticketDir: ticketDir,
    ).config.versionIncrement;
    // Most repos record no increment at all — they need no manifest read.
    if (increment == null) {
      continue;
    }
    final base = _parse(await readManifestVersion(repoDir));
    if (releaseBreaks(increment, base: base, repoDir: repoDir)) {
      result.add(path.basename(repoDir.path));
    }
  }
  return result;
}

/// [version] parsed, or null when it is unknown or no version at all.
Version? _parse(String? version) {
  try {
    return version == null ? null : Version.parse(version);
  } on FormatException {
    return null;
  }
}

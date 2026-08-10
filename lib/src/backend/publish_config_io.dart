// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_one/gg_one.dart' as gg;
import 'package:path/path.dart' as path;

// .............................................................................
/// The legacy ticket-level publish configuration of [ticketDir] —
/// `<ticket>/.gg/gg-publish.json`, or the even older `<ticket>/.gg-publish.json`
/// when only that one exists.
///
/// Written by gg versions before the per-repo split, when one file carried the
/// answers of every repository of a ticket. It is still **read** so a ticket
/// that was in flight across the upgrade keeps its answers, and never written
/// again.
File legacyTicketPublishConfigFile(Directory ticketDir) {
  final file = File(path.join(ticketDir.path, '.gg', 'gg-publish.json'));
  if (file.existsSync()) {
    return file;
  }
  final older = File(path.join(ticketDir.path, '.gg-publish.json'));
  return older.existsSync() ? older : file;
}

// .............................................................................
/// Reads the publish files of [repoDir], falling back to what the ticket in
/// [ticketDir] recorded before the per-repo split.
///
/// The layers, newest first:
/// 1. `<repo>/.gg/publish_config.json` + `<repo>/.gg/publish_state.json`
/// 2. `<repo>/.gg/gg-publish.json` (legacy, per repo)
/// 3. `<ticket>/.gg/gg-publish.json` (legacy, ticket-wide)
///
/// Reading is layered, writing is not: only the two new files are ever
/// written. A legacy file is left untouched, so a `--continue` performed by an
/// older gg still finds what it expects.
///
/// The two halves fall back **independently**: a repository that already
/// carries its own answers must still find the run state the ticket-level
/// file recorded — writing the answers must not hide the progress.
gg.RepoPublishFiles loadTicketRepoPublishFiles({
  required Directory repoDir,
  required Directory ticketDir,
}) {
  gg.RepoPublishFiles own;
  var readable = true;
  try {
    own = gg.loadRepoPublishFiles(repoDir);
  } on FormatException {
    // A hand-edited leftover in one repository must not fail a run that can
    // answer the question from somewhere else — the ticket-level file below
    // still gets its chance.
    own = gg.emptyRepoPublishFiles;
    readable = false;
  }
  // The repo answers for itself as soon as it has a readable file of its own
  // — an empty file is an answer too (»nothing recorded yet«), not a reason
  // to reach back to the ticket-wide leftover.
  final hasRepoLegacy =
      readable && gg.legacyPublishConfigFile(repoDir).existsSync();
  final hasOwnAnswers =
      readable &&
      (gg.repoPublishConfigFile(repoDir).existsSync() || hasRepoLegacy);
  final hasOwnState =
      readable && (gg.publishStateFile(repoDir).existsSync() || hasRepoLegacy);
  if (hasOwnAnswers && hasOwnState) {
    return own;
  }

  final legacy = legacyTicketPublishConfigFile(ticketDir);
  if (!legacy.existsSync()) {
    return own;
  }
  final gg.RepoPublishFiles fallback;
  try {
    fallback = gg.PublishConfig.load(
      configArg: legacy.path,
      fallbackDir: ticketDir.path,
    ).legacySplit(path.basename(repoDir.path));
  } on FormatException {
    // A hand-edited leftover must not fail a run that no longer needs it.
    return own;
  }
  return (
    config: hasOwnAnswers ? own.config : fallback.config,
    state: hasOwnState ? own.state : fallback.state,
  );
}

// .............................................................................
/// The ticket-wide run state of [ticketDir] — currently the
/// delete-the-ticket answer, which belongs to no single repository.
///
/// `<ticket>/.gg/publish_state.json` wins; a legacy ticket-level
/// `gg-publish.json` fills in, so a run that asked the question before the
/// split does not ask it again.
gg.PublishState loadTicketPublishState(Directory ticketDir) {
  final own = gg.PublishState.tryLoad(ticketDir);
  if (own != null) {
    return own;
  }
  final legacy = legacyTicketPublishConfigFile(ticketDir);
  if (!legacy.existsSync()) {
    return gg.PublishState();
  }
  try {
    return gg.PublishConfig.load(
      configArg: legacy.path,
      fallbackDir: ticketDir.path,
    ).legacySplit(path.basename(ticketDir.path)).state;
  } on FormatException {
    return gg.PublishState();
  }
}

// .............................................................................
/// Whether any repository of the ticket carries the given [status].
///
/// The per-repo replacement of the ticket-wide `repos.<name>.status` scan:
/// `gg do review` refuses to re-plan while a publish is unfinished, and
/// `gg do publish` names the ticket rather than one path when it does.
bool anyRepoHasStatus({
  required Iterable<Directory> repoDirs,
  required Directory ticketDir,
}) => repoDirs.any(
  (repoDir) =>
      loadTicketRepoPublishFiles(
        repoDir: repoDir,
        ticketDir: ticketDir,
      ).state.status !=
      null,
);

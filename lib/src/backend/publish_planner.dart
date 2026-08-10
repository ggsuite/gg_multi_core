// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_lang/gg_lang.dart' as gg_lang;
// ignore: lines_longer_than_80_chars
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_publish/gg_publish.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';

import 'package:gg_multi_core/src/backend/message_editor_theme.dart';
import 'package:gg_multi_core/src/backend/publish_config_io.dart';
import 'package:gg_multi_core/src/backend/publish_skip_check.dart';
import 'package:gg_multi_core/src/backend/ticket_json.dart';

// .............................................................................
/// Whether [repoDir]'s own `.gg/publish_state.json` records completed publish
/// steps — i.e. `gg do publish` already did irreversible work in that repo.
///
/// Such a repository is never skipped: its version is bumped and possibly
/// uploaded, so leaving it out would strand a prepared release forever.
bool repoHasPublishStepProgress(Directory repoDir) {
  try {
    return gg.loadRepoPublishFiles(repoDir).state.hasStepProgress;
  } catch (_) {
    // An unreadable file cannot prove progress.
    return false;
  }
}

// .............................................................................
/// Reads the version [repoDir] currently declares in its manifest, or null
/// when it declares none.
typedef ReadManifestVersion = Future<String?> Function(Directory repoDir);

// .............................................................................
/// The default [ReadManifestVersion] — asks gg_lang for whichever manifest the
/// repository carries. Returns null when there is none, or none with a
/// version.
Future<String?> defaultReadManifestVersion(Directory repoDir) async {
  try {
    final catalog = await gg_lang.LanguageCatalog.load();
    return await gg_lang.Manifest.detect(
      repoDir,
      catalog,
      treatBridgeAsTypeScript: true,
    ).readVersionString();
  } catch (_) {
    return null;
  }
}

// .............................................................................
/// The answers [PublishPlanner.configureRepo] collected for one repository,
/// plus the registry baseline its increment preview was based on.
class RepoPublishPlan {
  /// Constructor
  const RepoPublishPlan({required this.config, required this.baseline});

  /// The repository's answers — including the commit history the AI and
  /// `gg do commit` maintain, which the questions never touch.
  final gg.RepoPublishConfig config;

  /// The version the repository last published to its registry — the base
  /// the chosen increment is applied to.
  final Version baseline;
}

// .............................................................................
/// The user-facing wording of a planning pass.
///
/// The pass is shared by `gg do review`, `gg do publish` and
/// `gg do publish --merge-only`, which differ only in the words they put
/// around the very same decisions.
class PublishPlanWording {
  /// Constructor
  const PublishPlanWording({
    required this.action,
    required this.done,
    required this.command,
    required this.skipPrefix,
  });

  /// The noun of the run — `publish` or `merge`.
  final String action;

  /// The past participle of the run — `published` or `merged`.
  final String done;

  /// The command the user would re-run, named in the »nobody can be asked«
  /// error.
  final String command;

  /// How the per-repo skip line starts, before the reason.
  final String skipPrefix;

  /// Wording of a regular `gg do publish` run.
  static const PublishPlanWording publish = PublishPlanWording(
    action: 'publish',
    done: 'published',
    command: 'gg do publish',
    skipPrefix: 'Not published.',
  );

  /// Wording of a `gg do publish --merge-only` run.
  static const PublishPlanWording merge = PublishPlanWording(
    action: 'merge',
    done: 'merged',
    command: 'gg do publish --merge-only',
    skipPrefix: 'Not merged.',
  );

  /// Wording of the planning pass `gg do review` runs — a repository that
  /// needs no release gets no pull request either.
  static const PublishPlanWording review = PublishPlanWording(
    action: 'publish',
    done: 'published',
    command: 'gg do review',
    skipPrefix: 'Not published — no pull request.',
  );
}

// .............................................................................
/// What a publish run will do with one repository of a ticket.
class PublishPlanEntry {
  /// Constructor
  const PublishPlanEntry({
    required this.name,
    required this.directory,
    required this.publishes,
    required this.reason,
    required this.alreadyPublished,
    this.versionIncrement,
    this.mergeMessage,
    this.pullRequestBody,
  });

  /// The repository's folder name — the key of its `.gg-publish.json` entry.
  final String name;

  /// The repository's folder.
  final Directory directory;

  /// Whether the repository needs a release.
  final bool publishes;

  /// Why it needs one — or why it does not.
  final String reason;

  /// Whether an earlier run of the same publish already released it.
  final bool alreadyPublished;

  /// The increment it will be published with, or null when unknown.
  final String? versionIncrement;

  /// The merge message it will be published with, or null when unknown.
  /// `gg do review` uses it as the title of the repository's pull request.
  final String? mergeMessage;

  /// The description of the repository's pull request — the commits recorded
  /// in its `publish_config.json`, or null when it recorded none.
  final String? pullRequestBody;
}

// .............................................................................
/// The outcome of [PublishPlanner.plan].
class PublishPlan {
  /// Constructor
  const PublishPlan({required this.entries, required this.configs});

  /// One entry per ticket repository, in dependency order.
  final List<PublishPlanEntry> entries;

  /// The answers the run publishes with, per repository name — the ones that
  /// were loaded, extended by the answers the pass collected.
  final Map<String, gg.RepoPublishConfig> configs;

  /// Writes every repository's answers to its own `publish_config.json`.
  ///
  /// The hand-over between `gg do review` and `gg do publish`: whoever runs
  /// second finds the answers pre-selected instead of unanswered.
  Future<void> save() async {
    for (final entry in entries) {
      final config = configs[entry.name];
      if (config == null) continue;
      await config.save(file: gg.repoPublishConfigFile(entry.directory));
    }
  }

  /// The names of the repositories that need a release.
  Set<String> get publishes => <String>{
    for (final entry in entries)
      if (entry.publishes) entry.name,
  };

  /// Whether any repository needs a release at all.
  bool get anyPublishes => entries.any((entry) => entry.publishes);

  /// The entry of [name], or null when the ticket has no such repository.
  PublishPlanEntry? entryFor(String name) {
    for (final entry in entries) {
      if (entry.name == name) {
        return entry;
      }
    }
    return null;
  }
}

// .............................................................................
/// Decides what a ticket's publish run does with each of its repositories,
/// and collects the answers the run needs — in one pass, in dependency order.
///
/// Per repository the pass
///
/// 1. decides whether a release is needed ([PublishSkipCheck], unless
///    `publishUnchanged` forces one or the repository already carries publish
///    step progress),
/// 2. asks the version increment and the merge message — but **only** for a
///    repository that publishes, and only when the configuration does not
///    already answer them, and
/// 3. predicts the version the repositories after it resolve against: a
///    skipped one contributes its unchanged manifest version, a publishing one
///    the version its increment will produce.
///
/// One pass suffices because the repositories arrive in dependency order: a
/// repository's decision depends only on its own state and on the versions of
/// the dependencies before it, which are final by the time it is reached.
/// Everything undecidable predicts null, which makes dependents publish rather
/// than resolve against a guess.
///
/// `gg do review` runs the pass to learn which repositories get a pull request
/// — and to ask the questions there instead of at publish time; `gg do publish`
/// runs it to plan the release. Both write their answers into the ticket's
/// `.gg/gg-publish.json`, so whoever runs second asks nothing again.
class PublishPlanner {
  /// Constructor
  PublishPlanner({
    required this.ggLog,
    PublishSkipCheck? publishSkipCheck,
    PublishedVersion? publishedVersion,
    ReadManifestVersion? readManifestVersion,
    gg.VersionSelector? versionSelector,
    EditMessage? editMessage,
    gg.HasTerminal? hasTerminal,
  }) : _publishSkipCheck = publishSkipCheck ?? PublishSkipCheck(),
       _publishedVersion = publishedVersion ?? PublishedVersion(ggLog: ggLog),
       _readManifestVersion = readManifestVersion ?? defaultReadManifestVersion,
       _versionSelector = versionSelector ?? gg.VersionSelector(),
       _editMessage = editMessage ?? _defaultEditMessage,
       _hasTerminal = hasTerminal ?? gg.defaultHasTerminal;

  /// The log function
  final GgLog ggLog;

  /// Decides whether an unchanged repository needs to be published at all.
  final PublishSkipCheck _publishSkipCheck;

  /// Reads the version a repository last published to its registry.
  final PublishedVersion _publishedVersion;

  /// Reads the version a repository currently declares in its manifest.
  final ReadManifestVersion _readManifestVersion;

  /// Lets the user pick the version increment (patch/minor/major) per repo.
  final gg.VersionSelector _versionSelector;

  /// Opens an interactive editor for a repository's merge message.
  final EditMessage _editMessage;

  /// Whether stdin is a terminal — without one nobody can answer a prompt.
  final gg.HasTerminal _hasTerminal;

  // ...........................................................................
  /// Plans the run for the repositories [subs] of the ticket in [ticketDir].
  ///
  /// [config] is whatever configuration the files already supply; its answers
  /// are reused and never asked again. [continueRun] makes a repository marked
  /// `published` count as done, [publishUnchanged] releases every repository,
  /// [mergeOnly] asks for no version increment because a merge releases
  /// nothing. [defaultMergeMessage] (`-m`) seeds the merge-message prompt.
  ///
  /// [ask] turns the questions off altogether — the pass then only decides
  /// which repositories publish. [requireAnswers] decides what happens when a
  /// repository needs an answer and stdin is no terminal: `gg do publish`
  /// fails (it cannot release without an increment), `gg do review` passes
  /// false and leaves the question to the publish — its own job, filtering the
  /// pull requests, needs no answer.
  Future<PublishPlan> plan({
    required Directory ticketDir,
    required List<Node> subs,
    required GgLog ggLog,
    bool continueRun = false,
    bool publishUnchanged = false,
    bool mergeOnly = false,
    bool ask = true,
    bool requireAnswers = true,
    String? defaultMergeMessage,
    PublishPlanWording wording = PublishPlanWording.publish,
  }) async {
    final explicitMessage = defaultMergeMessage?.trim();
    final hasExplicitMessage =
        explicitMessage != null && explicitMessage.isNotEmpty;
    final ticketSeed = seedMessageFor(ticketDir: ticketDir);

    // The versions later repos are judged against. A skipped repo contributes
    // its unchanged manifest version, a publishing one the version its chosen
    // increment will produce — computed exactly like gg_one computes it, from
    // the version last seen on the registry.
    final refVersions = <String, String>{};
    final configs = <String, gg.RepoPublishConfig>{};
    final entries = <PublishPlanEntry>[];

    for (final repo in subs) {
      final repoDir = repo.directory;
      final repoName = path.basename(repoDir.path);
      final files = loadTicketRepoPublishFiles(
        repoDir: repoDir,
        ticketDir: ticketDir,
      );
      var repoConfig = files.config;
      configs[repoName] = repoConfig;

      final alreadyPublished =
          continueRun && (files.state.status == 'published');

      final bool doesPublish;
      final String reason;
      if (alreadyPublished) {
        doesPublish = false;
        reason = 'already ${wording.done}';
      } else if (publishUnchanged) {
        doesPublish = true;
        reason = '--publish-unchanged';
      } else if (repoHasPublishStepProgress(repoDir)) {
        doesPublish = true;
        reason = 'a previous run already started publishing it';
      } else {
        final decision = await _publishSkipCheck.get(
          repo: repo,
          refVersions: refVersions,
        );
        doesPublish = !decision.skip;
        reason = decision.reason;
      }

      Version? baseline;

      if (doesPublish) {
        // The questions are asked EVERY time, with the recorded answers
        // pre-selected — a choice made in an earlier run stays correctable.
        // Only a run nobody can answer (no terminal) falls back to what is on
        // disk, and only when that actually answers everything.
        if (_canAsk(
          repoName: repoName,
          wording: wording,
          ask: ask,
          must: requireAnswers,
          hasAnswers: _configAnswers(repoConfig, mergeOnly),
        )) {
          ggLog('\n${cH1(repoName)}');
          // An explicit `-m` is an instruction for this run and beats what
          // an earlier one recorded; without it the recorded answer is the
          // default, and the ticket description the last resort.
          final asked = await configureRepo(
            repoDir: repoDir,
            seedMessage: hasExplicitMessage
                ? explicitMessage
                : repoConfig.mergeMessage ?? ticketSeed,
            existing: repoConfig,
            mergeOnly: mergeOnly,
          );
          repoConfig = asked.config;
          configs[repoName] = repoConfig;
          baseline = asked.baseline;
        }
      } else if (!alreadyPublished) {
        ggLog(
          [
            '\n${cH1(repoName)}',
            cDetail('✓ ${wording.skipPrefix} $reason'),
          ].join('\n'),
        );
      }

      final increment = repoConfig.versionIncrement?.name;
      entries.add(
        PublishPlanEntry(
          name: repoName,
          directory: repoDir,
          publishes: doesPublish,
          reason: reason,
          alreadyPublished: alreadyPublished,
          versionIncrement: increment,
          mergeMessage: repoConfig.mergeMessage,
          pullRequestBody: repoConfig.pullRequestBody,
        ),
      );

      // Predict what later repos will resolve against.
      final predicted = await _predictedVersion(
        repoDir: repoDir,
        doesPublish: doesPublish,
        mergeOnly: mergeOnly,
        increment: increment,
        channel: files.state.channel,
        baseline: baseline,
      );

      for (final name in (await publishedNames(repoDir, repoName)).values) {
        if (predicted != null && predicted.isNotEmpty) {
          refVersions[name] = predicted;
        } else {
          // Unknown beats a guess: a dependent then publishes rather than
          // resolving against a version that may never exist.
          refVersions.remove(name);
        }
      }
    }

    return PublishPlan(entries: entries, configs: configs);
  }

  // ...........................................................................
  /// The merge-message seed of a ticket: an explicit `-m` wins, otherwise the
  /// ticket description.
  ///
  /// It pre-fills the per-repo prompt and is the fallback when the user clears
  /// it — the config model rejects an empty merge message.
  static String seedMessageFor({
    required Directory ticketDir,
    String? defaultMergeMessage,
  }) {
    final trimmed = defaultMergeMessage?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
    return readTicketDescription(ticketDir) ?? '';
  }

  // ...........................................................................
  /// Asks the publish questions for the single repository [repoDir] and
  /// returns the answers plus the registry baseline the increment preview was
  /// calculated from.
  ///
  /// The baseline travels with the answers so the caller can predict the
  /// version this repo will publish — without a second registry lookup.
  ///
  /// No repository header is logged here; the caller owns it, because it
  /// alone knows whether it has something to say about this repo at all.
  Future<RepoPublishPlan> configureRepo({
    required Directory repoDir,
    required String seedMessage,
    gg.RepoPublishConfig? existing,
    bool mergeOnly = false,
  }) async {
    final repoName = path.basename(repoDir.path);
    final baseline = await _baselineVersion(repoDir);

    // A merge-only run releases nothing — no version bump, no changelog
    // heading, no tag. Asking for an increment would offer a version that
    // is never created, so the prompt is skipped and none is stored.
    final increment = mergeOnly
        ? null
        : await _versionSelector.selectIncrement(
            currentVersion: baseline,
            preselect: existing?.versionIncrement,
          );

    // The seed pre-fills the editor. The caller resolved it — an explicit
    // `-m` beats a recorded answer, which beats the ticket description — so
    // only a caller that supplies none falls back to the recorded answer
    // here. A merge message must never be empty, so an empty edit falls back
    // to the same seed and finally to a generic default.
    final seed = seedMessage.isEmpty
        ? (existing?.mergeMessage ?? '')
        : seedMessage;
    var message = (await _editMessage(seed) ?? '').trim();
    if (message.isEmpty) {
      message = seed;
    }
    if (message.isEmpty) {
      message = 'Publish $repoName';
    }

    return RepoPublishPlan(
      // Built explicitly rather than via copyWith: a merge-only run must
      // clear a recorded increment, not inherit it. The AI-maintained halves
      // (nextCommitMessage, commits) are carried over untouched.
      config: gg.RepoPublishConfig(
        mergeMessage: message,
        versionIncrement: increment,
        nextCommitMessage: existing?.nextCommitMessage,
        commits: existing?.commits,
      ),
      baseline: baseline,
    );
  }

  // ...........................................................................
  /// The names [repoDir] is known under on the registries it publishes to.
  ///
  /// A hybrid is `base_dna` to its Dart dependents and `@tssuite/base-dna` to
  /// its npm ones, so each ecosystem's constraint is updated separately. Falls
  /// back to a single entry named after the manifest — or after [fallback],
  /// the repository directory — when no registry is configured: a git-only
  /// repo has none, but its dependents still resolve it by name.
  Future<Map<gg_lang.PublishTarget, String>> publishedNames(
    Directory repoDir,
    String fallback,
  ) async {
    final result = <gg_lang.PublishTarget, String>{};
    try {
      final catalog = await gg_lang.LanguageCatalog.load();
      final targets = await gg_lang.publishTargetsOf(repoDir, catalog: catalog);
      for (final target in targets.ordered) {
        result[target] = await target.manifestIn(repoDir, catalog).readName();
      }
      // coverage:ignore-start
    } catch (_) {
      return <gg_lang.PublishTarget, String>{
        gg_lang.PublishTarget.pubDev: fallback,
      };
    }
    // coverage:ignore-end

    if (result.isEmpty) {
      result[gg_lang.PublishTarget.pubDev] = await _manifestNameOf(
        repoDir,
        fallback,
      );
    }
    return result;
  }

  // ######################
  // Private
  // ######################

  // ...........................................................................
  /// Reads the package name from whichever manifest [repoDir] carries.
  Future<String> _manifestNameOf(Directory repoDir, String fallback) async {
    try {
      final catalog = await gg_lang.LanguageCatalog.load();
      return await gg_lang.Manifest.detect(
        repoDir,
        catalog,
        treatBridgeAsTypeScript: true,
      ).readName();
    } catch (_) {
      return fallback;
    }
  }

  // ...........................................................................
  /// Whether [config] already answers every question a run needs.
  ///
  /// Only consulted for the headless path — an interactive run asks anyway,
  /// with these very values pre-selected.
  bool _configAnswers(gg.RepoPublishConfig config, bool mergeOnly) =>
      config.mergeMessage != null &&
      (mergeOnly || config.versionIncrement != null);

  // ...........................................................................
  /// Whether the questions for [repoName] can be asked at all.
  ///
  /// An interactive run always asks — the recorded answers become the
  /// pre-selected defaults, so a choice made earlier stays correctable.
  /// Without a terminal the recorded answers are used as they are
  /// ([hasAnswers]); only when they do not cover the run and it cannot go on
  /// without them ([must]) does this throw. Returns false when the caller
  /// turned the questions off ([ask]) or can live without them.
  bool _canAsk({
    required String repoName,
    required PublishPlanWording wording,
    required bool ask,
    required bool must,
    required bool hasAnswers,
  }) {
    if (!ask) {
      return false;
    }
    if (_hasTerminal()) {
      return true;
    }
    // Nobody can be asked. A configuration that answers everything — a
    // `--config` run, CI — is exactly what this case is for.
    if (hasAnswers) {
      return false;
    }
    if (!must) {
      return false;
    }
    throw Exception(
      cError(
        '$repoName needs a ${wording.action}, but no version increment / '
        'merge message is configured and stdin is no terminal.\n'
        'Provide one of:\n'
        '  - ${cCmd('gg do configure-publish')} (interactively, then re-run)\n'
        '  - ${cCmd('${wording.command} --config <file>')}',
      ),
    );
  }

  // ...........................................................................
  /// The version later repos will resolve this repository against.
  ///
  /// A repo that does not publish keeps its manifest version — that is exact.
  /// A publishing one gets [baseline] plus the chosen increment, the same
  /// arithmetic gg_one performs. Everything undecidable answers null, which
  /// makes dependents publish instead of trusting a guess.
  Future<String?> _predictedVersion({
    required Directory repoDir,
    required bool doesPublish,
    required bool mergeOnly,
    required String? increment,
    required String? channel,
    required Version? baseline,
  }) async {
    // A merge releases nothing, so no version changes.
    if (!doesPublish || mergeOnly) {
      return _readManifestVersion(repoDir);
    }

    // A release candidate carries a suffix this arithmetic does not model.
    if (channel != null && channel != 'stable') {
      return null;
    }

    try {
      final base =
          baseline ??
          await _publishedVersion.get(directory: repoDir, ggLog: (_) {});
      return switch (increment) {
        'major' => base.nextMajor.toString(),
        'minor' => base.nextMinor.toString(),
        'patch' => base.nextPatch.toString(),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  // ...........................................................................
  /// Returns the baseline the increment preview is calculated from: the
  /// version [repoDir] last published to its registry (pub.dev / npm), with
  /// the git version tag as fallback for private and manifest-less repos.
  ///
  /// The manifest is deliberately *not* used. `gg do publish` bumps from the
  /// published version, so a `pubspec.yaml` that lags behind the registry —
  /// which is the normal state after a publish, since only main carries the
  /// released version — would preview a version the publish never creates.
  ///
  /// Defaults to 0.0.0 when nothing can be determined (e.g. a repo without a
  /// version). A failing lookup (e.g. the registry is unreachable) is reported
  /// instead of being swallowed, so a network hiccup does not silently look
  /// like a repo that was never published.
  ///
  /// *Every* failure lands here, not just `Exception`s: a folder that is no
  /// git repository makes the tag fallback throw an `ArgumentError`, and no
  /// lookup for a version preview may ever fail the run around it.
  Future<Version> _baselineVersion(Directory repoDir) async {
    try {
      return await _publishedVersion.get(directory: repoDir, ggLog: ggLog);
    } catch (e) {
      ggLog(
        cWarn(
          '⚠️ Could not determine the published version, assuming 0.0.0: $e',
        ),
      );
      return Version(0, 0, 0);
    }
  }

  // ...........................................................................
  /// Opens the shared message editor for the merge message.
  // coverage:ignore-start
  static Future<String?> _defaultEditMessage(String initialMessage) =>
      editMessage(
        initialMessage,
        prompt: 'Edit merge message:',
        subject: 'the merge message prompt',
        hint: 'pass -m <message> or provide a config file via --config',
      );
  // coverage:ignore-end
}

// .............................................................................
/// Mock for [PublishPlanner]
class MockPublishPlanner extends Mock implements PublishPlanner {}

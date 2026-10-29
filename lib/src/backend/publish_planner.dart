// @license
// Copyright (c) ggsuite
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

  /// How the per-repo skip line starts, before the reason. Empty when the
  /// reason alone says it all.
  final String skipPrefix;

  /// Wording of a regular `gg do publish` run.
  static const PublishPlanWording publish = PublishPlanWording(
    action: 'publish',
    done: 'published',
    command: 'gg do publish',
    skipPrefix: '',
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
  const PublishPlan({
    required this.entries,
    required this.configs,
    this.defaultedMessages = const <String>{},
  });

  /// One entry per ticket repository, in dependency order.
  final List<PublishPlanEntry> entries;

  /// The answers the run publishes with, per repository name — the ones that
  /// were loaded, extended by the answers the pass collected.
  final Map<String, gg.RepoPublishConfig> configs;

  /// The repositories whose merge message in [configs] nobody gave: nobody
  /// could be asked, so it took its default — `-m` or the ticket description.
  final Set<String> defaultedMessages;

  /// Writes every repository's answers to its own `publish_config.json`.
  ///
  /// The hand-over between `gg do review` and `gg do publish`: whoever runs
  /// second finds the answers pre-selected instead of unanswered.
  ///
  /// [keepDefaultedMessages] false leaves the [defaultedMessages] out. A
  /// headless `gg do review` passes it: a recorded message counts as answered,
  /// so the default would beat the `-m` of the `gg do publish` that follows —
  /// which derives the very same default itself when it is given none.
  Future<void> save({bool keepDefaultedMessages = true}) async {
    for (final entry in entries) {
      var config = configs[entry.name];
      if (config == null) continue;
      if (!keepDefaultedMessages && defaultedMessages.contains(entry.name)) {
        config = gg.RepoPublishConfig(
          versionIncrement: config.versionIncrement,
          nextCommitMessage: config.nextCommitMessage,
          commits: config.commits,
        );
      }
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
    gg.EditText? editText,
    gg.HasTerminal? hasTerminal,
  }) : _publishSkipCheck = publishSkipCheck ?? PublishSkipCheck(),
       _publishedVersion = publishedVersion ?? PublishedVersion(ggLog: ggLog),
       _readManifestVersion = readManifestVersion ?? defaultReadManifestVersion,
       _versionSelector = versionSelector ?? gg.VersionSelector(),
       _editMessage = editMessage ?? _defaultEditMessage,
       _editText = editText ?? gg.defaultEditText,
       _hasTerminal = hasTerminal ?? gg.stdioHasTerminal;

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

  /// Opens the questions of all repositories as one sheet in the editor.
  final gg.EditText _editText;

  /// Whether stdin and stdout are a terminal — else nobody can answer.
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
  /// [reconfigure] makes the pass ask **every** question again, with what is
  /// recorded as the pre-selected default — the behavior of `gg do review`
  /// and `gg do configure-publish`, where re-running IS the way to correct an
  /// earlier answer. Without it only unanswered questions are asked, so a
  /// `gg do publish` after a review asks nothing again.
  ///
  /// The questions of all repositories are shown at once, as one sheet in the
  /// editor, next to the recorded answers of the other publishing
  /// repositories. Without an editor — or when it fails — they are asked one
  /// by one, a repository at a time, in dependency order.
  ///
  /// [ask] turns the questions off altogether — the pass then only decides
  /// which repositories publish. [interactive] false (`--no-interactive`)
  /// asks nothing either, but behaves like a run without a terminal: a merge
  /// message nobody recorded takes its default, a missing increment fails a
  /// run that needs one. [requireAnswers] decides what happens when a
  /// repository needs an answer and there is no terminal: `gg do publish`
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
    bool interactive = true,
    bool reconfigure = false,
    bool requireAnswers = true,
    String? defaultMergeMessage,
    PublishPlanWording wording = PublishPlanWording.publish,
  }) async {
    final explicitMessage = defaultMergeMessage?.trim();
    final hasExplicitMessage =
        explicitMessage != null && explicitMessage.isNotEmpty;
    final ticketSeed = seedMessageFor(ticketDir: ticketDir);

    final run = _PlanRun(
      ticketDir: ticketDir,
      subs: subs,
      continueRun: continueRun,
      publishUnchanged: publishUnchanged,
      mergeOnly: mergeOnly,
      ask: ask,
      talks: ask && interactive && _hasTerminal(),
      reconfigure: reconfigure,
      requireAnswers: requireAnswers,
      // An explicit `-m` is an instruction for this run and beats what an
      // earlier one recorded; without it the recorded answer is the default,
      // and the ticket description the last resort.
      seedFor: (config) => hasExplicitMessage
          ? explicitMessage
          : config.mergeMessage ?? ticketSeed,
      wording: wording,
    );

    // The answers change what a pass decides: an increment that breaks the
    // dependents makes them publish too. So the pass runs again after every
    // round of questions, until it finds nothing new to ask. Each repository
    // is asked at most once.
    _run = run;
    try {
      while (true) {
        final pass = await _pass(run);
        if (pass.toAsk.isEmpty) {
          pass.logs.forEach(ggLog);
          // A repository asked in an earlier round may have dropped out since
          // — an answer before it changed what it is judged against. It is
          // not released, so it keeps exactly what it had recorded.
          for (final entry in pass.entries) {
            if (!entry.publishes) {
              run.configs[entry.name] = run.files[entry.name]!.config;
            }
          }
          return PublishPlan(
            entries: pass.entries,
            configs: run.configs,
            defaultedMessages: run.defaulted,
          );
        }
        await _ask(run, pass);
      }
    } finally {
      _run = null;
    }
  }

  /// The [plan] call in progress — [configureRepo] reuses its registry
  /// lookups instead of repeating them.
  _PlanRun? _run;

  // ...........................................................................
  /// Decides for every repository whether it publishes, and which of the
  /// publishing ones still have to be asked — without asking anything.
  Future<_PlanPass> _pass(_PlanRun run) async {
    // The versions later repos are judged against. A skipped repo contributes
    // its unchanged manifest version, a publishing one the version its chosen
    // increment will produce — computed exactly like gg_one computes it, from
    // the version last seen on the registry.
    final refVersions = <String, String>{};
    final pass = _PlanPass();

    for (final repo in run.subs) {
      final repoDir = repo.directory;
      final repoName = path.basename(repoDir.path);
      final files = run.files.putIfAbsent(
        repoName,
        () => loadTicketRepoPublishFiles(
          repoDir: repoDir,
          ticketDir: run.ticketDir,
        ),
      );
      var repoConfig = run.configs.putIfAbsent(repoName, () => files.config);

      final alreadyPublished =
          run.continueRun && (files.state.status == 'published');

      final bool doesPublish;
      final String reason;
      if (alreadyPublished) {
        doesPublish = false;
        reason = 'already ${run.wording.done}';
      } else if (run.publishUnchanged) {
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

      if (!doesPublish) {
        // Whatever an earlier round answered for it is not released.
        repoConfig = files.config;
        if (!alreadyPublished) {
          pass.logs.add(
            [
              '\n${cH1(repoName)}',
              cDetail('✓ ${'${run.wording.skipPrefix} $reason'.trim()}'),
            ].join('\n'),
          );
        }
      } else if (!run.asked.contains(repoName)) {
        // Nobody to ask, or nobody who wants to be asked: the merge message
        // takes its default instead of staying open.
        final seed = run.seedFor(repoConfig);
        if (!run.talks && repoConfig.mergeMessage == null && seed.isNotEmpty) {
          repoConfig = repoConfig.copyWith(mergeMessage: seed);
          run.configs[repoName] = repoConfig;
          run.defaulted.add(repoName);
        }

        // A reconfiguring pass asks EVERY time, with the recorded answers
        // pre-selected — that is what `gg do review --reask-version` and
        // `gg do configure-publish` mean. Every other pass asks only what the
        // configuration leaves open, so a `gg do publish` right after a review
        // does not ask the very questions the review just answered.
        final answered = _configAnswers(repoConfig, run.mergeOnly);
        if (_canAsk(run, repoName: repoName, hasAnswers: answered)) {
          pass.shown.add(repo);
          if (run.reconfigure || !answered) {
            pass.toAsk.add(repo);
          }
        }
      }

      pass.entries.add(
        PublishPlanEntry(
          name: repoName,
          directory: repoDir,
          publishes: doesPublish,
          reason: reason,
          alreadyPublished: alreadyPublished,
          versionIncrement: repoConfig.versionIncrement?.name,
          mergeMessage: repoConfig.mergeMessage,
          pullRequestBody: repoConfig.pullRequestBody,
        ),
      );

      // Predict what later repos will resolve against. A repository about to
      // be asked is predicted with the increment its question starts with, so
      // its dependents are judged as they will most likely be — not as if
      // its version were unknown, which would ask them for nothing.
      final predicted = await _predictedVersion(
        run,
        repoDir: repoDir,
        repoName: repoName,
        doesPublish: doesPublish,
        increment:
            repoConfig.versionIncrement ??
            (pass.toAsk.contains(repo) ? VersionIncrement.patch : null),
        channel: files.state.channel,
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

    return pass;
  }

  // ...........................................................................
  /// Asks the open questions of [pass] — on one sheet in the editor, next to
  /// the recorded answers of the other publishing repositories, so the user
  /// sees every release of the ticket at once.
  ///
  /// Without an editor, or when it fails, only the first open repository is
  /// asked, one prompt per question: its answer may change whether the ones
  /// after it publish at all, so they wait for the next pass.
  Future<void> _ask(_PlanRun run, _PlanPass pass) async {
    if (run.sheet) {
      try {
        if (await _askOnSheet(run, pass)) {
          return;
        }
      } catch (e) {
        ggLog(cWarn('⚠️ Could not edit the messages in the editor: $e'));
      }
      // The editor does not come back within this run.
      run.sheet = false;
    }

    final repo = pass.toAsk.first;
    final repoName = path.basename(repo.directory.path);
    run.asked.add(repoName);

    ggLog('\n${cH1(repoName)}');
    final config = run.configs[repoName]!;
    final asked = await configureRepo(
      repoDir: repo.directory,
      seedMessage: run.seedFor(config),
      existing: config,
      mergeOnly: run.mergeOnly,
    );
    run.configs[repoName] = asked.config;
  }

  // ...........................................................................
  /// Shows the repositories of [pass] on one sheet and takes over what the
  /// user saved. False when no editor can be opened.
  Future<bool> _askOnSheet(_PlanRun run, _PlanPass pass) async {
    if (!run.mergeOnly) {
      for (final repo in pass.shown) {
        await _lookUpBaseline(
          run,
          path.basename(repo.directory.path),
          repo.directory,
        );
      }
    }

    final edited =
        await gg.MessageSheet(
          entries: [
            for (final repo in pass.shown)
              _sheetEntry(run, repo, open: pass.toAsk.contains(repo)),
          ],
        ).edit(
          title: run.wording.command,
          fileName: '${path.basename(run.ticketDir.path)}_publish.jsonc',
          editText: _editText,
        );
    if (edited == null) {
      return false;
    }

    for (final entry in edited) {
      run.asked.add(entry.repo);
      // A field the sheet does not show — the increment of a merge-only run —
      // keeps what is recorded. The recorded answers of the repositories
      // shown for the overview come back as they were, unless edited.
      run.configs[entry.repo] = run.configs[entry.repo]!.copyWith(
        mergeMessage: entry.mergeMessage,
        versionIncrement: entry.versionIncrement,
      );
    }
    return true;
  }

  /// The sheet entry of [repo]. An [open] one starts with the defaults of its
  /// questions; one shown only for the overview with exactly what it has
  /// recorded, so saving the sheet unchanged changes nothing for it — not
  /// even when `-m` seeds the open ones.
  gg.MessageSheetEntry _sheetEntry(
    _PlanRun run,
    Node repo, {
    required bool open,
  }) {
    final repoName = path.basename(repo.directory.path);
    final config = run.configs[repoName]!;
    final seed = open ? run.seedFor(config) : config.mergeMessage!;
    return gg.MessageSheetEntry(
      repo: repoName,
      mergeMessage: seed.isEmpty ? 'Publish $repoName' : seed,
      versionIncrement: run.mergeOnly
          ? null
          : config.versionIncrement ?? VersionIncrement.patch,
      baseline: run.baselines[repoName],
    );
  }

  /// Looks the registry version of [repoName] up once per run. A failed
  /// lookup is remembered as null: it only costs the preview, and makes the
  /// prediction unknown instead of a guess based on 0.0.0.
  Future<void> _lookUpBaseline(
    _PlanRun run,
    String repoName,
    Directory repoDir,
  ) async {
    if (!run.baselines.containsKey(repoName)) {
      run.baselines[repoName] = await _registryVersion(repoDir);
    }
  }

  /// The version the increment preview of [repoDir] starts from — looked up
  /// once per [plan] call, 0.0.0 when it cannot be determined.
  Future<Version> _previewBaseline(Directory repoDir) async {
    final run = _run;
    if (run == null) {
      return await _registryVersion(repoDir) ?? Version(0, 0, 0);
    }
    final repoName = path.basename(repoDir.path);
    await _lookUpBaseline(run, repoName, repoDir);
    return run.baselines[repoName] ?? Version(0, 0, 0);
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
  /// Within [plan] the lookup is shared with the sheet and the predictions.
  ///
  /// A merge-only run asks no increment and keeps the recorded one: a merge
  /// releases nothing, and the answer stays for a later release.
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
    final base = await _previewBaseline(repoDir);

    // A merge-only run releases nothing — no version bump, no changelog
    // heading, no tag. Asking for an increment would offer a version that
    // is never created, so the prompt is skipped.
    final increment = mergeOnly
        ? null
        : await _versionSelector.selectIncrement(
            currentVersion: base,
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

    // The AI-maintained halves (nextCommitMessage, commits) are carried over
    // untouched.
    return RepoPublishPlan(
      config: (existing ?? gg.RepoPublishConfig()).copyWith(
        mergeMessage: message,
        versionIncrement: increment,
      ),
      baseline: base,
    );
  }

  // ...........................................................................
  /// The names [repoDir] is known under on the registries it publishes to.
  ///
  /// A hybrid is `dart_dna` to its Dart dependents and `@tssuite/base-dna` to
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
  /// A run that talks always asks — the recorded answers become the
  /// pre-selected defaults, so a choice made earlier stays correctable.
  /// Without a terminal the recorded answers are used as they are
  /// ([hasAnswers]); only when they do not cover the run and it cannot go on
  /// without them does this throw. Returns false when the caller turned the
  /// questions off or can live without them.
  bool _canAsk(
    _PlanRun run, {
    required String repoName,
    required bool hasAnswers,
  }) {
    if (run.talks) {
      return true;
    }
    // Nobody can be asked. A configuration that answers everything — a
    // `--config` run, CI — is exactly what this case is for.
    if (!run.ask || hasAnswers || !run.requireAnswers) {
      return false;
    }
    final wording = run.wording;
    throw Exception(
      cError(
        '$repoName needs a ${wording.action}, but no version increment / '
        'merge message is configured and stdin or stdout is no terminal.\n'
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
  /// A publishing one gets its registry version plus [increment], the same
  /// arithmetic gg_one performs. Everything undecidable answers null — also a
  /// registry lookup that failed —, which makes dependents publish instead of
  /// trusting a guess.
  Future<String?> _predictedVersion(
    _PlanRun run, {
    required Directory repoDir,
    required String repoName,
    required bool doesPublish,
    required VersionIncrement? increment,
    required String? channel,
  }) async {
    // A merge releases nothing, so no version changes.
    if (!doesPublish || run.mergeOnly) {
      return _readManifestVersion(repoDir);
    }

    // A release candidate carries a suffix this arithmetic does not model.
    if (channel != null && channel != 'stable') {
      return null;
    }

    try {
      final base = run.baselines.containsKey(repoName)
          ? run.baselines[repoName]
          : await _publishedVersion.get(directory: repoDir, ggLog: (_) {});
      if (base == null) {
        return null;
      }
      return switch (increment) {
        VersionIncrement.major => base.nextMajor.toString(),
        VersionIncrement.minor => base.nextMinor.toString(),
        VersionIncrement.patch => base.nextPatch.toString(),
        null => null,
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
  /// Null when nothing can be determined. A failing lookup (e.g. the registry
  /// is unreachable) is reported instead of being swallowed, so a network
  /// hiccup does not silently look like a repo that was never published.
  ///
  /// *Every* failure lands here, not just `Exception`s: a folder that is no
  /// git repository makes the tag fallback throw an `ArgumentError`, and no
  /// lookup for a version preview may ever fail the run around it.
  Future<Version?> _registryVersion(Directory repoDir) async {
    try {
      return await _publishedVersion.get(directory: repoDir, ggLog: ggLog);
    } catch (e) {
      ggLog(
        cWarn(
          '⚠️ Could not determine the published version of '
          '${path.basename(repoDir.path)}: $e',
        ),
      );
      return null;
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
/// What stays the same across the passes of one [PublishPlanner.plan] call.
class _PlanRun {
  _PlanRun({
    required this.ticketDir,
    required this.subs,
    required this.continueRun,
    required this.publishUnchanged,
    required this.mergeOnly,
    required this.ask,
    required this.talks,
    required this.reconfigure,
    required this.requireAnswers,
    required this.seedFor,
    required this.wording,
  });

  final Directory ticketDir;
  final List<Node> subs;
  final bool continueRun;
  final bool publishUnchanged;
  final bool mergeOnly;
  final bool ask;

  /// Whether the run asks its questions: it wants to, and somebody is there
  /// to answer them.
  final bool talks;
  final bool reconfigure;
  final bool requireAnswers;

  /// The merge message a repository with [config] starts with.
  final String Function(gg.RepoPublishConfig config) seedFor;
  final PublishPlanWording wording;

  /// The publish files of each repository, read once — what they record is
  /// what a repository keeps when it turns out not to publish.
  final files = <String, gg.RepoPublishFiles>{};

  /// The answers of each repository: the loaded ones, then the asked ones.
  final configs = <String, gg.RepoPublishConfig>{};

  /// The registry versions looked up so far — null where the lookup failed.
  final baselines = <String, Version?>{};

  /// The repositories whose questions were shown already.
  final asked = <String>{};

  /// The repositories whose merge message took its default, unasked.
  final defaulted = <String>{};

  /// Whether the questions still go on one sheet in the editor. Off once no
  /// editor could be opened, or it failed.
  bool sheet = true;
}

// .............................................................................
/// The outcome of one pass of [PublishPlanner.plan].
class _PlanPass {
  final entries = <PublishPlanEntry>[];

  /// The publishing repositories not asked yet, in dependency order — those
  /// with an open question, and those shown next to them for the overview.
  final shown = <Node>[];

  /// The repositories of [shown] with a question to ask.
  final toAsk = <Node>{};

  /// The lines of the repositories that are not published.
  final logs = <String>[];
}

// .............................................................................
/// Mock for [PublishPlanner]
class MockPublishPlanner extends Mock implements PublishPlanner {}

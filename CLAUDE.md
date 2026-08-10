# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

`gg_multi_core` is the foundation of the gg_multi tool family — the multi-repository workspace engine driven by the `gg` CLI. It holds the workspace *model*; the commands that act on it live in the sibling packages `gg_multi_workspace` (add/import/rm/create/sync), `gg_multi_commit` (commit/push/review flows) and `gg_multi_do_publish` (the publish orchestrator).

## Workspace Hierarchy

The family manages three folders at the workspace root:

- **ocean** (`<root>/.ocean/`) — contains all registered repositories and organizations. Formerly named `.master`: `migrateMasterFolderToOcean` (in `lib/src/backend/ocean_migration.dart`) renames a legacy `.master` (and `.trash/.master`) the moment `WorkspaceUtils.defaultOceanWorkspacePath` first sees it. When both folders exist nothing is touched (`.ocean` wins, one warning); a failed rename falls back to `.master` for the run. `isInsideExistingWorkspace` stays a pure predicate that recognizes both names and never renames.
- **Ticket workspace** (`<root>/tickets/<ticket-name>/`) — contains clones of repos scoped to a ticket.
- **Trash** (`<root>/.trash/<ticket-name>/`) — the sibling of `.ocean` that holds what gg removed from a ticket. `Trash` (in `lib/src/backend/trash.dart`) owns it. Closing a ticket moves the **whole ticket folder** there in one piece via `moveTicketToTrash`: repositories as they are, `ticket.json`, `.ticket`, `.gg/` and the `<ticket>.code-workspace` file. Nothing is deleted. A *non-empty* target — a ticket of the same name closed earlier — gets a ` (2)`, ` (3)`, … suffix, so trash content is never overwritten. `moveFromTicket` (single entries) and `moveFromOcean` follow the same rule; all of them rename and fall back to copy + delete when trash and ticket live on different volumes. Emptying the trash is the user's job; gg never does.

`WorkspaceUtils.detectTicketPath()` (in `lib/src/backend/workspace_utils.dart`) navigates up the directory tree to locate which context the CLI is running in.

## Organization folders

Both workspaces group their repositories by the organization of the repo's git URL:

```
<root>/.ocean/<org>/<repo>          e.g. .ocean/ggsuite/gg_multi
<root>/tickets/<ticket>/<org>/<repo> e.g. tickets/33_org_folders/ggsuite/gg_multi
```

Without the org level, two organizations owning a repo of the same name would collide in one flat folder. The ticket mirrors the ocean layout, so a repo has the same relative path in both.

`RepoFolderResolver` (in `lib/src/backend/repo_folder_resolver.dart`) owns the layout:

| Member                                          | Role                                                                                                                                                                                                    |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `destination(workspacePath, repoUrl, repoName)` | Where a repo is cloned to. `organizationOf(url)` needs a repo in the URL — a single-segment URL stays flat. On **Azure DevOps it returns the project**, not the account: repo names are unique per project. |
| `repoDirs(workspacePath)`                       | All repos of a workspace. A direct child is an _organization folder_ when it is no repo itself (`isRepoDir`: `.git`, `pubspec.yaml` or `package.json`) but holds at least one. Hidden folders are skipped. |
| `resolve(workspacePath, repoName)`              | Finds a repo anywhere in the workspace: exact path, then folder name, then manifest package name. Never returns an organization folder.                                                                   |
| `resolveByRemoteUrl` / `urlIdentity`            | Match by git remote url instead of folder name — used by the ocean sync.                                                                                                                                 |
| `relativePath(workspacePath, repoDir)`          | `<org>/<repo>` — used for the ticket copy destination and the `.code-workspace` entries (forward slashes).                                                                                               |
| `removeEmptyOrgFolder(...)`                     | Drops an organization folder that lost its last repo.                                                                                                                                                    |

`migrateToOrgFolders` (in `lib/src/backend/workspace_migration.dart`) recognizes a workspace created before the org folders existed — its repositories lie flat — and renames each into `<workspace>/<org>/<repo>`, with the org read from the repo's git remote. It returns the moved repo names, is a no-op once everything is nested, and skips (with a message) a repo whose organization is unknown or whose target folder is taken.

`UrlParser` (in `lib/src/backend/url_parser.dart`) covers every url shape the platforms hand out — for Azure that is `dev.azure.com/<org>/<project>`, `.../<org>/<project>/_git/<repo>` (what `az repos list` reports), the `<org>/_git/<repo>` shortcut, `v3/<org>/<project>/<repo>` on the ssh host (including the unparsable-as-Uri `https://ssh.dev.azure.com:v3/…` form gg builds itself), and the legacy `<org>.visualstudio.com/<project>/_git/<repo>`. `_git` is Azure's separator between project and repository, so what follows it is never the project. `lib/src/backend/az_output.txt` documents the raw `az repos list` output the parser handles.

`GitHubPlatform.fetchOrgRepos` (in `lib/src/backend/git_platform.dart`) lists an org's repos via the **GitHub CLI** (`gh repo list --json name,sshUrl,url`), `AzureDevOpsPlatform` via `az repos list`. Using the CLIs reuses the caller's existing auth so **private** orgs work; cloning then uses each repo's ssh url. Both require the respective CLI and emit an install hint otherwise.

`organizationsOwningRepo` / `selectOrganization` (in `lib/src/backend/organization_utils.dart`): `do add <repoName>` names no organization, and the same name can exist in several. Every organization from `.organizations` is asked whether it owns the repo (`git ls-remote`, in parallel, result kept in registration order). With more than one owner, the injectable `selectOrganization` prompt offers `<org>/<repo>` via interact's `Select`. Headless runs fail fast through gg_one's `throwWhenNotATerminal`.

## Ticket metadata & state

- `lib/src/backend/ticket_json.dart` — reads/writes/parses `<ticket>/ticket.json` (`writeTicketJson`, `readTicketJson`, `buildTicketJson`, `readTicketDescription` — the single reader of the root `.ticket` description). The file sits **next to** the repositories, never inside one, so git never sees it and a private ticket stays private. The mutable global `ggCliVersion` (seeded with this package's version, overridden by the CLI at startup) gates markers written by a newer gg.
- `lib/src/backend/ticket_state.dart` — ticket-level success cache in `<ticket>/.gg.json`; mirrors gg_one's `GgState` for a whole ticket (aggregate hash over the per-repo hashes). `readSuccess`/`writeSuccess` are hash-based. Keys: `canReview` and `didReview`.
- `lib/src/backend/ticket_cleanup.dart` — `cleanUpTicket`: deletes the remote feature branches per repo, then moves the whole ticket folder to `<root>/.trash/<ticket>` in one go and prints the `cd <workspace root>` command in blue. A failed branch deletion keeps the ticket in place. Shared by `do publish`'s cleanup question and `do rm ticket`.

## Publish skip check

- `lib/src/backend/publish_skip_check.dart` — decides whether a repo needs a release: (1) does any dependency published earlier in the run now carry a version **outside the constraint this repo publishes** (original constraints from the gg_localize_refs backups, manifest as fallback; caret semantics kept correct for 0.x)? (2) If not: does the repo carry **manual changes** — a dirty tree, or any commit this ticket *contributes* whose subject was not generated by gg itself? Contributed means `git log HEAD --not <origin/main> [<last merge-back commit>]`: work already reachable from the main branch is not a change of this ticket (so a `--merge-only` run's output on main does not force the next ticket to release it), and the merge-back commit `do publish` writes after a release hides the commits of that release — gg squash-merges, so the original feature commits never become ancestors of main and would otherwise stay in the range forever. Tags are not used as a base any more. Every gg message starts with **`#gg: `**; the exact pre-prefix bookkeeping subjects are still recognized. A gg-labeled commit is only trusted when it touches nothing but gg-owned files — decided by `isGgOwnedPath` from `gg_one_core`, the same predicate the system-commit helper uses when it decides what a `#gg:` commit may contain, so read side and write side cannot drift apart. Everything undecidable errs toward publishing.

## Publish planner

- `lib/src/backend/publish_planner.dart` — `PublishPlanner` answers the one question `gg do review` and `gg do publish` both have to answer before they do anything: **which repos of this ticket does it actually release?** One pass, in dependency order, per repo: (1) decide — `--publish-unchanged` forces a release, a repo that already carries gg_one step progress (`repoHasPublishStepProgress`) is never skipped because its version is bumped and possibly uploaded, a repo the resume marks `published` is done, otherwise `PublishSkipCheck` decides; (2) ask the version increment (gg_one's `VersionSelector`) and the merge message (`EditMessage`) — **only for a repo that publishes**, and only for what the configuration does not already answer (`forRepo`, so a top-level default counts as much as a per-repo override); (3) predict the version the repos after it are judged against — a skipped one contributes its manifest version (exact), a publishing one `nextPatch/nextMinor/nextMajor` of the version last seen on its registry, the same arithmetic gg_one performs. One pass suffices because a repo's decision depends only on its own state and on dependencies that come *before* it. Everything undecidable (an `rc` channel, an unreadable version, an unreachable registry) predicts `null`, which makes dependents publish rather than resolve against a guess.

  The increment-preview baseline is the version the repo last **published to its registry** (`PublishedVersion`), never the manifest — only `main` carries the released version, so a feature branch's manifest normally lags behind. *Every* failure of that lookup falls back to 0.0.0 with a warning, `Error`s included: a folder that is no git repository makes the tag fallback throw an `ArgumentError`, and no version preview may ever fail the run around it.

  `ask: false` turns the questions off entirely (the pass then only decides). `requireAnswers` says what happens when a repo needs an answer and stdin is no terminal: `do publish` fails with a message naming the repo, `gg do configure-publish` and `--config`; `do review` passes false and leaves the question to the publish, because filtering the pull requests needs no answer. `PublishPlanWording` carries the three vocabularies (`publish` / `merge` / `review`) the shared pass speaks in.

  `publishConfigFileFor(ticketDir)` is the canonical `<ticket>/.gg/gg-publish.json` path — the hand-over between `do review` (writes the answers) and `do publish` (reads them).

- `ProcessRunner`, `defaultProcessRunner`, `runGit` and `captureUncommitted` used to live here. They are **git and process plumbing, not workspace knowledge**, and moved to `gg_git` — import them from there directly. `message_editor_theme.dart` still owns the shared `EditMessage` typedef.

## Code Standards

- **Line length**: 80 characters maximum.
- **Quotes**: Single quotes (`prefer_single_quotes`).
- **Trailing commas**: Required in all parameter/argument lists.
- **Return types**: Always declared explicitly.
- **Public API docs**: All public members require dartdoc comments.
- **Strict analyzer**: `strict-casts`, `strict-inference`, `strict-raw-types` enabled.
- **Test coverage**: 100% required. Every file under `lib/src/` must have a matching test at the same relative path under `test/`. Use `// coverage:ignore-line` and `// coverage:ignore-start/end` only when unavoidable.
- **Mocks**: Mock classes live in the same file as the class they mock.
- **Commits/pushes**: Always go through `gg do commit` / `gg do push`, never raw `git commit` / `git push`.

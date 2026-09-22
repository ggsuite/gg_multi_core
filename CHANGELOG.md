# Changelog

## 4.6.2 - 2026-09-22

### Changed

- "Quiet

## 4.6.1 - 2026-09-15

### Fixed

- Wire the new helix --workspace mode into gg do init workspace, and fix a pre-existing RepoFreshness bug that misjudged a never-fetched checkout's non-main default branch as a feature branch

## 4.6.0 - 2026-09-14

### Added

- `WorkspaceUtils.isHiddenName` and `WorkspaceUtils.existingTicketDir`, which resolves a ticket name to a real ticket only — never to a hidden folder such as `.github` or a plain folder such as `doc`
- `WorkspaceUtils.ticketNameError`, `isValidTicketName` and `normalizeTicketName`: the one check for ticket names — a single folder name that is not empty, no path (no `/` or `\`, not absolute), not hidden and not `tickets` in any case — and the removal of one trailing separator (`T1/` from tab completion) and of one leading `tickets/` that leaves a valid name (`tickets/L1/` → `L1`); `existingTicketDir` returns `null` for every other name
- `WorkspaceUtils.newTicketDir`, the one place a ticket folder is created: it throws when the name is invalid, when the ticket exists, or when `<root>/<name>` or the legacy `<root>/tickets/<name>` is taken by something that is no ticket, takes an empty folder as it is and creates the folder non-recursively

### Fixed

- Hidden folders are never tickets: `WorkspaceUtils.isTicketDir` rejects `.github`, `.claude`, `.dart_tool` and every closed ticket in `.trash` (`<ticket>`, `<ticket> (2)`, …), even with a `ticket.json`; a ticket in a workspace root with a hidden name (`~/.ws/<ticket>`) stays a ticket
- `defaultOceanWorkspacePath`, `defaultGgMultiWorkspacePath` and `isInsideExistingWorkspace` walk past the `.trash` folder, so a command run in `<root>/.trash/…` resolves `<root>/.ocean` instead of `<root>/.trash/.ocean`, and a `.master` in the trash is no longer migrated as a workspace of its own
- `defaultOceanWorkspacePath` resolves `<root>/.ocean` from inside a legacy `<root>/tickets/<ticket>` that holds a `ticket.json` instead of `<root>/tickets/.ocean`, and climbs a relative `workingDir` such as `.` from its absolute path instead of stopping at `./.ocean`
- `.trash` and `tickets` are recognized in any case: a closed ticket in `.Trash/<ticket>` is no active ticket, `Tickets/<ticket>` is a legacy ticket — unless `Tickets` holds a `.ocean` or `.master` and is the workspace root itself
- `existingTicketDir` no longer resolves an empty or absolute name to the legacy `tickets` folder or to an arbitrary folder, because `path.join` drops the root in front of an absolute name

## 4.5.1 - 2026-09-11

### Fixed

- `gg do upgrade ocean` refreshes `origin/HEAD` after the fetch, so a default branch renamed on the server is picked up
- `gg do rm ticket` prints the `cd` hint for the workspace root of a flat `<root>/<ticket>` ticket instead of the folder above it
- Remove a stray `coverage:ignore-end` marker from `ticket_cleanup.dart` that broke `format_coverage --check-ignore` in dependent packages

## 4.5.0 - 2026-09-11

### Changed

- Build clone urls of Azure DevOps organizations in the SSH form git can open

## 4.4.0 - 2026-09-11

### Changed

- `PublishSkipCheck` resolves the declared default branch before falling back to `main`/`master`

### Fixed

- The ticket hash behind `did review`, `can review` and `did push` ignores the same files as `can commit` (`pubspec.lock`, `.gg/` state files), so an unchanged ticket is not reviewed twice

## 4.3.0 - 2026-09-10

### Changed

- Register the organization of Azure DevOps web URLs with their _git base path

### Fixed

- Rename the dna_base test fixtures to dna_dart

### Removed

- Remove the stray ticket.json from the repository root

## 4.2.0 - 2026-09-02

### Changed

- Install the dna_ggsuite DNA

## 4.1.2 - 2026-09-02

### Changed

- Use ggwsm in pipelines

### Fixed

- Fix Windows-specific test failures that blocked the review

## 4.1.1 - 2026-08-15

### Fixed

- Fix invalid refspec when deleting the ticket branch

## 4.1.0 - 2026-08-14

### Changed

- Rework copyright headers

### Fixed

- Cleanup copy right headers. Update to dart 3.13. Auto fixes.
- Cleanup copy right headers. Update to dart 3.13. Auto fixes. Setup quick-check pipeline.

## 4.0.0 - 2026-08-13

### Changed

- Report freshness blockers on a dry run and survive a repo without commits

## 3.1.1 - 2026-08-11

### Changed

- "First javascript implementation"
- Fix shell changes

## 3.1.0 - 2026-08-10

### Added

- `publish_config_io.dart`: `loadTicketRepoPublishFiles` layers the per-repo files over the legacy ticket-wide `gg-publish.json`

### Changed

- `PublishPlanner` keeps the answers per repository (`PublishPlan.configs` / `save()`) and asks every question again, with the recorded answer pre-selected
- `PublishPlanEntry` carries the pull-request body built from the recorded commits
- Refactor commit messages, version increment

## 3.0.1 - 2026-08-10

### Changed

- Make sure »dart pub upgrade --tighten --major-versions« is called before publishing

## 3.0.0 - 2026-08-10

## 2.3.1 - 2026-08-10

### Fixed

- Fix org-url repo add, code-workspace upkeep on rm and the auto-merge PR hint

## 2.3.0 - 2026-08-10

### Changed

- Don't review skipped packages
- Merge origin/main

## 2.2.1 - 2026-08-10

### Removed

- Merge .ticket with ticket.json. Remove usage of .ticket

## 2.2.0 - 2026-08-09

### Changed

- Improve commit behavior
- Move gg commit conventions from gg_git to gg_one_core
- Move the git and process plumbing to gg_git

## 2.1.0 - 2026-08-09

## 2.0.0 - 2026-08-08

### Fixed

- Fix azure URL bug

## 1.0.3 - 2026-08-07

### Fixed

- Fix issue with azure URLs

## 1.0.1 - 2026-08-05

### Changed

- Make pana work: 1.0.0 changelog headings, examples, shorter description

## 1.0.0 - 2026-08-05

### Added

- Initial boilerplate.

### Changed

- Split gg_multi into multiple packages

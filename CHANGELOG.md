# Changelog

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

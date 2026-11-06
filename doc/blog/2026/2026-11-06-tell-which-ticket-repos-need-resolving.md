<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Tell which ticket repos need resolving

## Motivation

- Resolving a repo is the expensive part of localizing a ticket. With
  `pub upgrade` every git dependency costs one connection to its remote,
  per repo and run.
- A caller that changes only some repos of a ticket had no way to ask
  which repos really need to be resolved again, so it resolved all of
  them.
- Resolving only some repos must not lose the healing effect of resolving
  all: a repo an earlier run left unresolved has to be found.

## Strategy

- Offer the existing out-of-sync check as its own read-only call.
- Add a file-only check for a resolution that is missing or does not use
  the path overrides.
- Make `pub get` the only way localizing resolves.

## TicketLocalizer.outOfSync

- Returns the repos with unlocalized refs, in the given order and as the
  given `Node` instances.
- Uses the same `UnlocalizedRefs` check as `check` and
  `localizeUnlocalized`, offline and without the missing-repo search.
- `localizeUnlocalized` and `outOfSync` now share one filter.

## repoDependenciesOutdated

- True for a `pubspec.yaml` whose `.dart_tool/package_config.json` is
  missing, unreadable or does not resolve every `path` override of
  `pubspec_overrides.yaml` to that path – a `pub get` that failed or never
  ran after localizing.
- True for a `package.json` without `node_modules`.
- It compares content, not timestamps: `pub get` leaves
  `package_config.json` untouched when nothing changed, so a checkout that
  only touched `pubspec.yaml` would look outdated forever.

## pub get only

- `localize` and `localizeAndCommit` resolve with `pub get`, which keeps
  the locked versions.
- Their `upgrade` parameter is deprecated and goes with the next major
  release; upgrading belongs to `gg do push`.

## Open Points

- `UnlocalizedRefs` builds the dependency graph once per repo; for large
  tickets one shared graph would be faster.

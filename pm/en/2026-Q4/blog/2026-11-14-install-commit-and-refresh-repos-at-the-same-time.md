<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Install, commit and refresh repos at the same time

## Motivation

- `TicketLocalizer` keeps the references between the repos of a ticket
  pointing at their checkouts. It handled the repos one after the other:
  check, baseline, install, commit
- The check asked gg_localize_refs repo by repo. Each question read the
  ticket and the ocean again, which added up to seconds per run
- The installs are what takes time in a localization, and each one only
  needs the references to be in place
- `RepoFreshness` opened a second connection after every fetch to ask the
  remote for its default branch. Whoever needed the tags as well had to
  fetch once more

## Strategy

- Read the workspace once for all repos instead of once per repo
- Run at the same time what stays inside its own repo, through gg_one_core's
  `runInParallel`. The output still follows the order of the repos
- Keep one after the other what writes into other repos or shares a git
  mirror of the pub cache
- Let one fetch bring everything a checkout needs to know about its remote
- Take the limits from gg_one_core's `GgParallelism`: local work follows
  the machine, remote work gets a small number

## One workspace read for the check

- `check` and `outOfSync` ask gg_localize_refs once for all repos, with
  `UnlocalizedRefs.getAll`
- The answer is unchanged: the unlocalized references per repo, keyed by
  `Directory.path`, only for repos with something to fix

## Baseline and commit for all repos at once

- `baseline` asks the repos at the same time, and inside a repo both
  questions at once: the dirty paths and whether the tree was committed
- `commit` writes the `#gg:` commits at the same time. A commit touches its
  own repo only
- Both use the `light` limit. Failures are still logged per repo and end in
  one exception that names all of them

## Rewrite first, install afterwards

- `localize` now works in two steps. First the references of every repo are
  rewritten, repo by repo in the given order: a repo also writes into the
  repos it depends on
- Then the dependencies of all rewritten repos are installed together
- When a repo cannot be rewritten, the repos before it are installed all
  the same. The failure is logged after the installs, so it is the last
  thing to read
- `localizeAndCommit` still commits every repo but the failed one before it
  throws

## Installs side by side, where that is safe

- New: `installReposDependencies(dirs)` installs many repos, and
  `runInstalls(dirs, install)` does the same for any install function
- Up to eight installs run at a time. Measured: beyond eight they only slow
  each other down, because each one resolves versions and keeps a processor
  busy
- Only Dart repos that resolve from the registry only run side by side.
  They share nothing but the pub cache
- A repo with a git dependency waits its turn, one install at a time: two
  fetches into one git mirror of the pub cache fail. The git dependency may
  stand in `pubspec.yaml`, `pubspec_overrides.yaml` or `pubspec.lock`
- A repo without a lock file, with a `package.json` or with an unreadable
  manifest waits as well. `upgradeDart` makes all of them wait
- When installs throw, the running ones finish, no further one starts and
  the error of the first failed repo in the given order is thrown

## One fetch per repo in RepoFreshness

- `get` fetches with gg_git's `Fetch.get(refreshDefaultBranch: true)`. The
  same connection refreshes `origin/HEAD`; an older git still asks with
  `git remote set-head origin --auto` afterwards
- `mirrorTags` makes the tags of the checkout a copy of the remote's, in
  that same fetch
- `updateAll(onUpToDate:)` names every repo that is on the state of its
  remote afterwards, so a caller that needs that state next does not fetch
  it again. It is never called in a dry run
- `updateAll` handles `GgParallelism.network` repos at a time, not four
- Only a checkout that never recorded an `origin/HEAD` still asks with
  `set-head` before it is classified

## Open Points

- Installs of JavaScript package managers stay one at a time. They are not
  known to be safe side by side
- A git dependency is found by a text match in the manifests and the lock
  file. Whatever cannot be read counts as one, so a repo may wait although
  it would not have to

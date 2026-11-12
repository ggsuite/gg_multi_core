<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# GgRc moves to gg_one_core

## Motivation

- `GgRc` reads the user's `~/.gg_rc`. It lived here, so only the
  commands built on this package could read settings
- gg_one_core now offers one `GgRc` that reads the user file and, on top,
  a repository's `.gg/gg_rc` with the same structure
- Two classes of the same name in one tool family make every library that
  imports both packages ambiguous; one class is enough

## Strategy

- Remove the own implementation and its tests
- Re-export `GgRc` and `ReadSettings` from gg_one_core, so every
  `package:gg_multi_core` import keeps working unchanged
- Keep the user-file behavior exactly as it was

## What stays the same

- `GgRc.load(ggLog:)` reads `~/.gg_rc` (`$GG_RC` names another file)
  and writes it with `builtInDefaults` when missing
- `flag(keys)`, `isSet`, `keyPath`, `defaultFile`, `GgRc.defaults()`
  and `ReadSettings` keep their signatures
- A broken file makes every `flag()` throw, loading itself does not

## What the moved class adds

- `GgRc.load(repo:)` and `GgRc.loadRepo` read a repository's
  `.gg/gg_rc`, which takes precedence over `~/.gg_rc`
- Settings that belong to one repository (`repoDefaults`) may not be set
  in `~/.gg_rc`; a user file holding one loads as broken
- Both files may contain comments

## Dependency updates

- gg_one_core: `GgRc` and `ReadSettings`, now with the repository layer

## Open Points

- The commands of this family act on a ticket, not on one repository, so
  they keep reading the user file only

<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Add the ReadSettings typedef next to GgRc

## Motivation

- `GgRc` is the user's `~/.gg_rc`. `GgRc.load` reads the file and writes it
  with every default when it is missing.
- A command that reads a setting should not call `GgRc.load` directly:
  every test would then read, or even create, the real file in the home
  directory. The command takes the reader as a constructor argument
  instead, and a test hands in one that returns `GgRc.defaults()` or a
  `GgRc` of its own.
- Such an argument needs a function type. Until now this package offered
  `GgRc`, but not the type of the function that loads it, so every user
  had to declare that type itself.
- Two separate declarations of the same type under the same name are two
  different declarations to Dart. A library that exports both does not
  compile.
- The type belongs where `GgRc` is: one declaration that every user of
  `GgRc` imports.

## Strategy

- Declare the type in `lib/src/backend/gg_rc.dart`, right above `GgRc`
- Keep the signature `GgRc.load` already has for its required argument,
  so `GgRc.load` itself is a valid value of the type
- Export it through the existing `export 'src/backend/gg_rc.dart'` of the
  library, without a new file or a new export
- Change nothing about `GgRc` itself

## Implementation

- New public typedef:

  ```dart
  /// Reads the user's settings — [GgRc.load] fits.
  typedef ReadSettings = GgRc Function({required GgLog ggLog});
  ```

- `GgRc.load` has further optional parameters (`file`, `environment`).
  A function type that only names `ggLog` still accepts it, so callers
  can write `readSettings: GgRc.load` without a wrapper
- A test passes a closure instead:
  `readSettings: ({required ggLog}) => const GgRc.defaults()`
- `CLAUDE.md` names the type in the section about `GgRc`

## Result

- `package:gg_multi_core/gg_multi_core.dart` now exports `ReadSettings`
- Nothing changes for existing code: the release adds a name, it removes
  or changes none
- Released as a minor version

## Open Points

- None

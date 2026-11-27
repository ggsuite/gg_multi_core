<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Keep tracked files when copying a repository

## Motivation

- `copyDirectory` copies a repository, e.g. into the folder of a ticket.
  It leaves out what belongs to the working copy and not to the
  repository: `node_modules` and the files gg writes for itself, such as
  `ticket.json`, `publish_config.json` or `publish_state.json`.
- It left them out by name, on every level of the tree. A repository that
  tracks a file with one of these names lost it in the copy: a fixture
  `test/data/ticket.json`, or a document `doc/publish_config.json`.
- The copy then differed from its source without a word. git showed the
  file as deleted, and a commit of everything took the deletion along.

## Strategy

- Name gg's own files by the place where gg writes them: the `.gg` folder
  of the copied directory. Everything else with the same name is content
  of the repository and is copied.
- Keep the simple case simple: a plain name still means »on every level«,
  which is right for `node_modules`.
- Change nothing for the callers. The parameter stays one set of strings;
  only the meaning of an entry with a slash is new.

## Places and names in skipNames

- An entry of `skipNames` with a `/` names one place below the source,
  e.g. `.gg/publish_state.json`. Only that file or folder is left out.
- An entry without a `/` is a name. It is left out wherever it appears,
  as before.
- Leading, trailing and doubled slashes are ignored, so `/.gg/ticket.json`
  and `.gg//ticket.json` name the same place. A place is always written
  with `/`, also on Windows.
- The private `_copyDirectory` carries the place of the folder it is in
  down the tree and compares every entry with the names and the places.

## The new default

- `node_modules` on every level.
- gg's working files, each at its place in `.gg`: `publish_config.json`,
  `publish_state.json`, `create_repo_state.json`, `gg-publish.json`,
  `.gg-publish.json`, `.ticket.json`, `ticket.json` and
  `.gg_localize_refs_publish_to_backup.json`.
- A tracked `ticket.json` or `publish_config.json` anywhere else in the
  repository is copied.

## Tests

- A file named like one of gg's files survives the copy when it is not in
  `.gg`, on the top level and in a subfolder.
- The files in `.gg` are still left out; `.gg/gg.json` is still copied.
- Places with leading, trailing and doubled slashes; a place that names a
  folder; a name and a place in the same set.
- `CLAUDE.md` has a section on copying a repository.

## Open Points

- A caller that passes its own `skipNames` with plain names such as
  `ticket.json` keeps the old behaviour: the file is left out on every
  level. Only the default changed.
- Other files gg may write into `.gg` in the future have to be added to
  the default; the `.gg` folder as a whole is not skipped, because
  `.gg/gg.json` is tracked.

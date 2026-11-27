<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Explain a ticket folder that is in use

## Motivation

- `cleanUpTicket` moves a finished ticket into the trash.
- On Windows the move fails while a terminal or an editor such as VS Code
  sits in the ticket folder: "used by another process", error 32.
- The user only saw the raw error. It did not say why, what was already
  done, or how to finish the cleanup.
- Often the ticket already was in the trash and only its empty folder was
  left, which the message did not tell either.

## Strategy

- Recognize the sharing violation of Windows.
- Tell what is left behind and give the commands that finish the cleanup.
- Keep every other failure as it was.

## Recognize a folder in use

- A `FileSystemException` whose OS error code is 32
  (`ERROR_SHARING_VIOLATION`) counts as a folder in use.

## Tell how to finish

- The move falls back to copy and delete when the rename is refused. When
  only the empty ticket folder is left, the ticket is in the trash already.
  The hint then says so and prints `cd <root>` and `rmdir <ticket>`.
- When the ticket is still in place, the hint asks to leave the folder,
  close the program and retry with `gg do rm ticket <ticket>`.
- `rmdir` gets the path relative to the workspace root, so a legacy
  `tickets/<ticket>` folder works too.

## Tests

- `cleanUpTicket` takes an optional `moveToTrash` function, so tests can
  throw the Windows error on every platform.

## Open Points

- Other programs than terminals and editors can hold the folder as well;
  the hint names only the common ones.

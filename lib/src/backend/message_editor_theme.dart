// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one/gg_one.dart' as gg;

/// Typedef for editing a commit or merge message interactively.
typedef EditMessage = Future<String?> Function(String initialMessage);

/// SGR sequence switching the terminal back to its default colors.
///
/// Re-exported from `gg_one_core`, which owns the interactive prompts and
/// the theme they are drawn with.
const String colorOff = gg.colorOff;

// .............................................................................
/// Opens the interactive message editor with [initialMessage] and returns
/// what the user leaves in the buffer.
///
/// [prompt] labels the editor, [subject] and [hint] describe the prompt in the
/// error a headless run gets instead of hanging. `do commit` and
/// `do configure-publish` share this — they differ only in those three words.
///
/// Only `initialText`, no `defaultValue`: the message is already in the
/// editable buffer, so the "(…)" hint would just repeat it.
// coverage:ignore-start
Future<String?> editMessage(
  String initialMessage, {
  required String prompt,
  required String subject,
  required String hint,
}) async {
  gg.throwWhenNotATerminal(subject, hint);
  return await gg.GgPrompts.current.input(
    prompt: prompt,
    initialText: initialMessage,
    asMessageEditor: true,
  );
}

// coverage:ignore-end

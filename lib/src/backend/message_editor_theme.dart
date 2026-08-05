// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:interact/interact.dart';

/// Typedef for editing a commit or merge message interactively.
typedef EditMessage = Future<String?> Function(String initialMessage);

/// SGR sequence switching the terminal back to its default colors.
const String colorOff = '\x1B[0m';

/// SGR sequence switching the terminal to blue until [colorOff] is written.
const String _blueOn = '\x1B[34m';

/// The theme of the interactive message editors — the commit message of
/// `do commit` and the merge messages of `do configure-publish`. The prompt is
/// yellow, the message being edited is blue.
///
/// The message cannot simply be wrapped in [blue]: interact's `readLine`
/// echoes the edit buffer raw and derives the cursor position from its
/// length, so embedded escape sequences would both end up in the message and
/// misplace the cursor. The prompt suffix therefore switches blue *on*, and
/// everything written after it — the edit buffer — comes out blue. Callers
/// write [colorOff] once the prompt is done. [Theme.valueStyle] colors the
/// value the same way in the confirmation line interact prints afterwards.
final Theme messageEditorTheme = Theme.defaultTheme.copyWith(
  messageStyle: yellow,
  valueStyle: blue,
  inputSuffix: '${Theme.defaultTheme.inputSuffix}$_blueOn',
);

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
  try {
    return Input.withTheme(
      theme: messageEditorTheme,
      prompt: prompt,
      initialText: initialMessage,
    ).interact();
  } finally {
    stdout.write(colorOff);
  }
}

// coverage:ignore-end

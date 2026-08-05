// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_multi_core/src/backend/message_editor_theme.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:interact/interact.dart';
import 'package:test/test.dart';

void main() {
  group('messageEditorTheme', () {
    test('prints the prompt in yellow', () {
      final styled = messageEditorTheme.messageStyle('Edit commit message');
      expect(styled, yellow('Edit commit message'));
      expect(rmControls(styled), 'Edit commit message');
    });

    test('prints the entered message in blue', () {
      final styled = messageEditorTheme.valueStyle(' My message ');
      expect(styled, blue(' My message '));
      expect(rmControls(styled), ' My message ');
    });

    test('switches to blue after the prompt so the edit buffer is blue', () {
      // interact echoes the edit buffer raw right after the input suffix, so
      // the color has to be turned on there and stay on.
      expect(
        messageEditorTheme.inputSuffix,
        startsWith(Theme.defaultTheme.inputSuffix),
      );
      expect(messageEditorTheme.inputSuffix, endsWith('\x1B[34m'));
      expect(messageEditorTheme.inputSuffix, isNot(endsWith(colorOff)));
    });

    test('colorOff resets the terminal', () {
      expect(colorOff, '\x1B[0m');
      expect(rmControls(colorOff), isEmpty);
    });
  });
}

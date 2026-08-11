// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_multi_core/gg_multi_core.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:test/test.dart';

void main() {
  group('message editor', () {
    // #########################################################################
    group('colorOff', () {
      test('is the reset sequence a finished edit writes', () {
        expect(colorOff, '\x1B[0m');
        expect(rmControls(colorOff), isEmpty);
      });

      test('is the one gg_one_core owns', () {
        // The theme the editor is drawn with moved to gg_one_core, which
        // owns the prompts now. This re-export exists so the callers here
        // did not have to learn where it went.
        expect(colorOff, gg.colorOff);
      });
    });

    // #########################################################################
    group('EditMessage', () {
      test('is the signature the commit and publish flows inject', () {
        // Asynchronous, like every prompt in the suite: the answer comes
        // from the user, and an embedder may need a turn of the event loop
        // to get it.
        Future<String?> edit(String initial) async => 'edited: $initial';
        final EditMessage typed = edit;

        expect(typed, isA<EditMessage>());
        expect(typed('seed'), isA<Future<String?>>());
      });

      test('carries what the user left in the buffer', () async {
        Future<String?> edit(String initial) async => initial.toUpperCase();
        final EditMessage typed = edit;

        expect(await typed('message'), 'MESSAGE');
      });
    });
  });
}

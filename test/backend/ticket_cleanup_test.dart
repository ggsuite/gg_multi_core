// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_multi_core/src/backend/ticket_cleanup.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory ticketDir;
  final messages = <String>[];
  final taskMessages = <String>[];

  setUp(() {
    messages.clear();
    taskMessages.clear();
    root = Directory.systemTemp.createTempSync('ticket_cleanup_test_');
    ticketDir = Directory(path.join(root.path, 'tickets', 'T1'))
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory repo(String org, String name) {
    final dir = Directory(path.join(ticketDir.path, org, name))
      ..createSync(recursive: true);
    File(path.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: $name');
    return dir;
  }

  /// A process runner whose `git push origin --delete <branch>` succeeds.
  Future<ProcessResult> okRunner(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool? runInShell,
  }) async {
    return ProcessResult(0, 0, '', '');
  }

  String trashPath([String ticket = 'T1']) =>
      path.join(root.path, '.trash', ticket);

  group('cleanUpTicket', () {
    test('deletes the remote branches, moves the whole ticket folder to the '
        'trash and prints the cd command in blue', () async {
      final repoA = repo('ggsuite', 'a');
      final repoB = repo('ggsuite', 'b');
      // The ticket's own files must travel with it, not be deleted.
      File(
        path.join(ticketDir.path, 'T1.code-workspace'),
      ).writeAsStringSync('{}');
      File(
        path.join(ticketDir.path, 'ticket.json'),
      ).writeAsStringSync('{"issue_id":"T1"}');
      File(path.join(ticketDir.path, '.ticket')).writeAsStringSync('{}');
      Directory(path.join(ticketDir.path, '.gg')).createSync();
      File(
        path.join(ticketDir.path, '.gg', '.gg.json'),
      ).writeAsStringSync('{}');
      final deletedBranches = <String>[];

      await cleanUpTicket(
        ticketDir: ticketDir,
        repoDirs: [repoA, repoB],
        deleteRemoteBranch: true,
        ggLog: messages.add,
        taskLog: taskMessages.add,
        processRunner:
            (
              String executable,
              List<String> arguments, {
              String? workingDirectory,
              Map<String, String>? environment,
              bool? runInShell,
            }) async {
              deletedBranches.add(
                '${path.basename(workingDirectory!)}: '
                '${arguments.join(' ')}',
              );
              return ProcessResult(0, 0, '', '');
            },
      );

      // Only the remote branches are handled per repo — named after the
      // ticket, deleted from the repos' original locations.
      expect(deletedBranches, [
        'a: push origin --delete T1',
        'b: push origin --delete T1',
      ]);

      // The whole folder moved in one piece; nothing was left behind and
      // nothing was deleted.
      expect(ticketDir.existsSync(), isFalse);
      final trash = trashPath();
      expect(Directory(path.join(trash, 'ggsuite', 'a')).existsSync(), isTrue);
      expect(Directory(path.join(trash, 'ggsuite', 'b')).existsSync(), isTrue);
      expect(File(path.join(trash, 'T1.code-workspace')).existsSync(), isTrue);
      expect(File(path.join(trash, 'ticket.json')).existsSync(), isTrue);
      expect(File(path.join(trash, '.ticket')).existsSync(), isTrue);
      expect(File(path.join(trash, '.gg', '.gg.json')).existsSync(), isTrue);

      // One quiet line says where the work now lives — the trash folder,
      // because the ticket kept its name inside it.
      final log = messages.join('\n');
      expect(
        messages,
        contains(cDetail('Moved ticket T1 to ${path.dirname(trash)}')),
      );

      // The way out of the deleted folder is printed in blue.
      expect(log, contains('Change to the workspace root with:'));
      expect(messages.last, cCmd('  cd ${root.absolute.path}'));
    });

    test(
      'keeps the remote branches when deleteRemoteBranch is false',
      () async {
        final repoA = repo('ggsuite', 'a');
        final gitCalls = <String>[];

        await cleanUpTicket(
          ticketDir: ticketDir,
          repoDirs: [repoA],
          deleteRemoteBranch: false,
          ggLog: messages.add,
          taskLog: taskMessages.add,
          processRunner:
              (
                String executable,
                List<String> arguments, {
                String? workingDirectory,
                Map<String, String>? environment,
                bool? runInShell,
              }) async {
                gitCalls.add(arguments.join(' '));
                return ProcessResult(0, 0, '', '');
              },
        );

        expect(gitCalls, isEmpty);
        expect(
          taskMessages.join('\n'),
          contains('Kept remote branch T1 for a.'),
        );
        // The ticket moves either way.
        expect(ticketDir.existsSync(), isFalse);
        expect(
          Directory(path.join(trashPath(), 'ggsuite', 'a')).existsSync(),
          isTrue,
        );
      },
    );

    test('tolerates a remote branch that is already deleted', () async {
      final repoA = repo('ggsuite', 'a');

      await cleanUpTicket(
        ticketDir: ticketDir,
        repoDirs: [repoA],
        deleteRemoteBranch: true,
        ggLog: messages.add,
        taskLog: taskMessages.add,
        processRunner:
            (
              String executable,
              List<String> arguments, {
              String? workingDirectory,
              Map<String, String>? environment,
              bool? runInShell,
            }) async {
              return ProcessResult(0, 1, '', 'remote ref does not exist');
            },
      );

      expect(
        taskMessages.join('\n'),
        contains('Remote branch T1 for a is already deleted.'),
      );
      expect(ticketDir.existsSync(), isFalse);
    });

    test(
      'keeps the ticket in place when a remote branch could not be deleted',
      () async {
        final repoA = repo('ggsuite', 'a');
        final repoB = repo('ggsuite', 'b');
        final attempted = <String>[];

        await cleanUpTicket(
          ticketDir: ticketDir,
          repoDirs: [repoA, repoB],
          deleteRemoteBranch: true,
          ggLog: messages.add,
          taskLog: taskMessages.add,
          processRunner:
              (
                String executable,
                List<String> arguments, {
                String? workingDirectory,
                Map<String, String>? environment,
                bool? runInShell,
              }) async {
                final repoName = path.basename(workingDirectory!);
                attempted.add(repoName);
                return repoName == 'a'
                    ? ProcessResult(0, 1, '', 'network down')
                    : ProcessResult(0, 0, '', '');
              },
        );

        // The failure of one repo does not stop the others …
        expect(attempted, ['a', 'b']);

        final log = messages.join('\n');
        expect(log, contains('Failed to delete remote branch T1 for a'));
        expect(log, contains('Ticket T1 was not moved to the trash'));
        expect(log, contains('--no-delete-remote-branch'));

        // … but the ticket stays where it is, so the command can be retried.
        expect(ticketDir.existsSync(), isTrue);
        expect(repoA.existsSync(), isTrue);
        expect(Directory(trashPath()).existsSync(), isFalse);
        expect(log, isNot(contains('Change to the workspace root')));
      },
    );

    test('skips the branch deletion for a repo folder that is gone', () async {
      final repoA = repo('ggsuite', 'a');
      repoA.deleteSync(recursive: true);
      final gitCalls = <String>[];

      await cleanUpTicket(
        ticketDir: ticketDir,
        repoDirs: [repoA],
        deleteRemoteBranch: true,
        ggLog: messages.add,
        taskLog: taskMessages.add,
        processRunner:
            (
              String executable,
              List<String> arguments, {
              String? workingDirectory,
              Map<String, String>? environment,
              bool? runInShell,
            }) async {
              gitCalls.add(arguments.join(' '));
              return ProcessResult(0, 0, '', '');
            },
      );

      expect(gitCalls, isEmpty);
      expect(
        taskMessages.join('\n'),
        contains('Repository a is gone — no remote branch to delete.'),
      );
      expect(ticketDir.existsSync(), isFalse);
    });

    test(
      'names the full path when the trash already holds that ticket',
      () async {
        // An earlier ticket of the same name makes the folder land in a
        // » (2)« variant — then the plain trash path would be misleading.
        final earlier = Directory(trashPath())..createSync(recursive: true);
        File(path.join(earlier.path, 'keep.txt')).writeAsStringSync('keep');
        repo('ggsuite', 'a');

        await cleanUpTicket(
          ticketDir: ticketDir,
          repoDirs: [Directory(path.join(ticketDir.path, 'ggsuite', 'a'))],
          deleteRemoteBranch: false,
          ggLog: messages.add,
          taskLog: taskMessages.add,
          processRunner: okRunner,
        );

        expect(
          messages,
          contains(cDetail('Moved ticket T1 to ${trashPath('T1 (2)')}')),
        );
      },
    );

    test('reports a ticket that could not be moved', () async {
      repo('ggsuite', 'a');
      // A *file* where the trash folder belongs makes the move fail.
      File(path.join(root.path, '.trash')).writeAsStringSync('blocker');

      await cleanUpTicket(
        ticketDir: ticketDir,
        repoDirs: [Directory(path.join(ticketDir.path, 'ggsuite', 'a'))],
        deleteRemoteBranch: false,
        ggLog: messages.add,
        taskLog: taskMessages.add,
        processRunner: okRunner,
      );

      final log = messages.join('\n');
      expect(log, contains('Failed to move ticket T1 to the trash'));
      expect(ticketDir.existsSync(), isTrue);
      expect(log, isNot(contains('Change to the workspace root')));
    });
  });
}

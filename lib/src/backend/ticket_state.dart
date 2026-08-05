// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_git/gg_git.dart';
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_log/gg_log.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;

/// Stores and retrieves cached success state of ticket-level commands.
///
/// Mirrors `GgState` from `gg_one` but operates on a whole ticket. The hash
/// is an aggregate over the per-repo hashes of all repositories that belong
/// to the ticket. Success state is persisted in a flat `.gg.json` file
/// directly inside the ticket folder.
class TicketState {
  /// Creates a new [TicketState].
  TicketState({required this.ggLog, LastChangesHash? lastChangesHash})
    : _lastChangesHash = lastChangesHash ?? LastChangesHash(ggLog: ggLog);

  /// Logger used for diagnostic output.
  final GgLog ggLog;

  /// Files that are excluded from the per-repo hash so that updating
  /// generated/state files does not invalidate the cache.
  static const List<String> ignoreFiles = <String>[
    '.gg/',
    '.gg.json',
    '.gg/.gg.json',
    'CHANGELOG.md',
  ];

  /// Returns the aggregated 64-bit hash that summarizes the state of all
  /// repositories inside the ticket.
  ///
  /// For each repo, the per-repo hash is calculated via
  /// [LastChangesHash.get] with [ignoreFiles]. The `(repoName, hash)` pairs
  /// are sorted by repository name and folded into one ticket-wide hash.
  Future<int> currentHash({
    required List<Node> subs,
    bool ignoreUnstaged = false,
  }) async {
    final entries = <List<String>>[];
    for (final node in subs) {
      final repoHash = await _lastChangesHash.get(
        directory: node.directory,
        ggLog: ggLog,
        ignoreFiles: ignoreFiles,
        ignoreUnstaged: ignoreUnstaged,
      );
      entries.add(<String>[node.name, repoHash.toString()]);
    }

    entries.sort((a, b) => a[0].compareTo(b[0]));
    final folded = entries.map((e) => e.join(' ')).join('\n');
    return LastChangesHash.fastStringHash(folded);
  }

  /// Returns `true` if the cached success [key] in
  /// `<ticketDir>/.gg.json` matches the current ticket hash.
  Future<bool> readSuccess({
    required Directory ticketDir,
    required List<Node> subs,
    required String key,
    bool ignoreUnstaged = false,
  }) async {
    final stored = await _readStoredHash(ticketDir: ticketDir, key: key);
    if (stored == null) {
      return false;
    }
    final current = await currentHash(
      subs: subs,
      ignoreUnstaged: ignoreUnstaged,
    );
    return current == stored;
  }

  /// Writes the current ticket hash as success for [key] into
  /// `<ticketDir>/.gg.json`. Existing keys are preserved.
  Future<void> writeSuccess({
    required Directory ticketDir,
    required List<Node> subs,
    required String key,
    bool ignoreUnstaged = false,
  }) async {
    final hash = await currentHash(subs: subs, ignoreUnstaged: ignoreUnstaged);
    final data = await _readAll(ticketDir: ticketDir);
    data[key] = <String, dynamic>{
      'success': <String, dynamic>{'hash': hash},
    };
    final file = _configFile(ticketDir: ticketDir);
    await file.writeAsString(jsonEncode(data));
  }

  /// Removes the cached success state for the ticket.
  Future<void> reset({required Directory ticketDir}) async {
    final file = _configFile(ticketDir: ticketDir);
    if (await file.exists()) {
      await file.writeAsString('{}');
    }
  }

  // ######################
  // Private
  // ######################

  final LastChangesHash _lastChangesHash;

  File _configFile({required Directory ticketDir}) {
    return File(path.join(ticketDir.path, '.gg.json'));
  }

  Future<Map<String, dynamic>> _readAll({required Directory ticketDir}) async {
    final file = _configFile(ticketDir: ticketDir);
    if (!await file.exists()) {
      return <String, dynamic>{};
    }
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  Future<int?> _readStoredHash({
    required Directory ticketDir,
    required String key,
  }) async {
    final data = await _readAll(ticketDir: ticketDir);
    final entry = data[key];
    if (entry is! Map<String, dynamic>) return null;
    final success = entry['success'];
    if (success is! Map<String, dynamic>) return null;
    final value = success['hash'];
    return value is int ? value : null;
  }
}

/// Mocktail mock for [TicketState].
class MockTicketState extends Mock implements TicketState {}

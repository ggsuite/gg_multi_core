// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_log/gg_log.dart';
import 'package:path/path.dart' as path;

/// The user's own gg settings: `~/.gg_rc`, one JSON object.
///
/// The keys follow the command path and end with the name of the flag they
/// preset — `{"do": {"add": {"transitive": false}}}` makes `gg do add` behave
/// as if `--no-transitive` was given. A flag given on the command line always
/// wins; the file only replaces the built-in default.
///
/// [load] writes the file with every default spelled out when it is missing,
/// so the settings can be found and changed. An existing file is never
/// rewritten — not even to add a setting a newer gg knows: what it leaves out
/// takes its built-in default.
class GgRc {
  /// Settings read from [file]; what [values] leaves out takes its default.
  const GgRc({required this.values, this.file}) : error = null;

  /// The built-in defaults only — touches no file.
  const GgRc.defaults()
    : values = const <String, dynamic>{},
      file = null,
      error = null;

  /// A [file] that could not be read: every [flag] throws [error].
  const GgRc._broken({required File this.file, required String this.error})
    : values = const <String, dynamic>{};

  /// The name of the file in the home directory.
  static const String fileName = '.gg_rc';

  /// The environment variable that names another file instead.
  static const String pathVariable = 'GG_RC';

  /// Every setting gg knows, with its built-in default.
  static const Map<String, dynamic> builtInDefaults = <String, dynamic>{
    'do': <String, dynamic>{
      'add': <String, dynamic>{'transitive': true},
    },
  };

  /// The settings read from the file — an empty map when it was just created.
  final Map<String, dynamic> values;

  /// The file the settings come from; null for [GgRc.defaults].
  final File? file;

  /// Why [file] could not be read — invalid JSON, or no object; null when it
  /// could. Thrown by [flag], so a run that reads no setting is not stopped
  /// by it.
  final String? error;

  // ...........................................................................
  /// The settings file: `$GG_RC`, otherwise `.gg_rc` in the home directory.
  /// Null when neither the variable nor a home directory is known.
  static File? defaultFile({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final explicit = env[pathVariable];
    if (explicit != null && explicit.isNotEmpty) {
      return File(explicit);
    }
    final home = env['HOME'] ?? env['USERPROFILE'];
    if (home == null || home.isEmpty) {
      return null;
    }
    return File(path.join(home, fileName));
  }

  // ...........................................................................
  /// Reads [file] — by default [defaultFile] of [environment] — and writes it
  /// with [builtInDefaults] first when it does not exist yet. Without a file
  /// the settings are the defaults.
  ///
  /// A file that cannot be written does not fail the command that asked: its
  /// settings are the defaults then. A file that cannot be read, or holds no
  /// JSON object, makes every [flag] throw, naming the file and how to repair
  /// it — gg must not silently ignore settings the user wrote down, but a run
  /// that reads none of them, e.g. because the flag was given, goes on.
  factory GgRc.load({
    required GgLog ggLog,
    File? file,
    Map<String, String>? environment,
  }) {
    file ??= defaultFile(environment: environment);
    if (file == null) {
      return const GgRc.defaults();
    }

    if (!file.existsSync()) {
      try {
        file.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(builtInDefaults)}\n',
        );
        ggLog(
          cDetail(
            '✓ Created ${file.path} — gg reads its defaults from there, '
            'e.g. {"do": {"add": {"transitive": false}}}.',
          ),
        );
      } on FileSystemException catch (e) {
        ggLog(
          cWarn(
            '⚠️ Could not create ${file.path} (${e.osError?.message ?? e}). '
            'gg uses its built-in defaults. Check that the folder is '
            'writable, or name another file in \$$pathVariable.',
          ),
        );
      }
      return GgRc(values: const <String, dynamic>{}, file: file);
    }

    const repair =
        'Fix it, or delete it and gg writes a fresh one with the defaults.';
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      return GgRc._broken(
        file: file,
        error: '${file.path} is no valid JSON: ${e.message}. $repair',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      return GgRc._broken(
        file: file,
        error:
            '${file.path} must hold one JSON object, '
            'e.g. {"do": {"add": {"transitive": false}}}. $repair',
      );
    }
    return GgRc(values: decoded, file: file);
  }

  // ...........................................................................
  /// The boolean setting at [keys] — from the file when it holds one,
  /// otherwise from [builtInDefaults].
  ///
  /// Throws when the file could not be read ([error]), when it holds
  /// something else than `true` or `false` there, and when gg knows no such
  /// setting.
  bool flag(List<String> keys) {
    if (error != null) {
      throw Exception(cError(error!));
    }
    final own = _lookup(values, keys);
    final value = own ?? _lookup(builtInDefaults, keys);
    if (value is bool) {
      return value;
    }
    if (own != null) {
      throw Exception(
        cError(
          '"${keyPath(keys)}" in ${file?.path ?? fileName} must be true or '
          'false, not ${jsonEncode(value)}.',
        ),
      );
    }
    throw ArgumentError.value(keys, 'keys', 'gg knows no such setting');
  }

  // ...........................................................................
  /// Whether the file sets [keys] itself instead of leaving the default.
  bool isSet(List<String> keys) => _lookup(values, keys) != null;

  // ...........................................................................
  /// [keys] as they are written in a message: `do.add.transitive`.
  static String keyPath(List<String> keys) => keys.join('.');

  // ...........................................................................
  static Object? _lookup(Map<String, dynamic> map, List<String> keys) {
    Object? current = map;
    for (final key in keys) {
      if (current is! Map<String, dynamic>) {
        return null;
      }
      current = current[key];
    }
    return current;
  }
}

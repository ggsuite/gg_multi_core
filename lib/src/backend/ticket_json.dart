// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';

import 'package:gg_multi_core/src/gg_multi_core_version.dart';
import 'package:gg_multi_core/src/backend/repo_folder_resolver.dart';

/// Name of the ticket description file inside the ticket folder.
const String ticketJsonFileName = 'ticket.json';

/// Legacy locations of the ticket marker inside a repository.
///
/// gg used to write, commit and push this marker with every feature branch.
/// It is no longer created — the ticket description never leaves the machine
/// it was created on — but `do checkout` still reads it from branches that
/// were pushed by an older gg.
const List<String> legacyTicketJsonRelativePaths = <String>[
  '.gg/.ticket.json',
  '.gg/ticket.json',
];

/// The version of the gg CLI that stamps and checks `.ticket.json` markers.
///
/// The `gg` package overwrites this with its own version at startup. When
/// gg_multi runs standalone the gg_multi version is used as a fallback.
String ggCliVersion = ggMultiCoreVersion;

/// One repository entry of a [TicketJson] marker.
class TicketRepo {
  /// Constructor.
  const TicketRepo({required this.name, required this.url});

  /// Parses a single repository entry from decoded JSON.
  factory TicketRepo.fromJson(Map<String, dynamic> json) => TicketRepo(
    name: json['name']?.toString() ?? '',
    url: json['url']?.toString() ?? '',
  );

  /// The repository folder name (as used in the ocean/ticket workspace).
  final String name;

  /// The git remote URL the repository is cloned from.
  final String url;

  /// Serializes this entry to a JSON map.
  Map<String, String> toJson() => <String, String>{'name': name, 'url': url};
}

/// The content of a `ticket.json`: the ticket id, its description and the full
/// list of repositories (with git URLs) that make up the ticket.
///
/// `gg do add` writes it to `<ticket folder>/ticket.json` — inside the ticket
/// workspace only, never into a repository, so it is never committed and never
/// pushed. `gg do checkout <path|url>` reproduces the ticket 1:1 from it, which
/// makes sharing a ticket an explicit act.
class TicketJson {
  /// Constructor.
  const TicketJson({
    required this.issueId,
    required this.description,
    required this.repositories,
    this.ggVersion = '',
  });

  /// Parses a [TicketJson] from a JSON string. Throws [FormatException] when
  /// the source is not a JSON object and [Exception] when the marker was
  /// written by a newer gg than [ggCliVersion].
  factory TicketJson.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid ticket.json: expected an object.');
    }
    final ggVersion = decoded['gg_version']?.toString() ?? '';
    _checkGgVersion(ggVersion);
    final repos = decoded['repositories'];
    return TicketJson(
      issueId: decoded['issue_id']?.toString() ?? '',
      description: decoded['description']?.toString() ?? '',
      ggVersion: ggVersion,
      repositories: repos is List
          ? repos
                .whereType<Map<String, dynamic>>()
                .map(TicketRepo.fromJson)
                .toList()
          : const <TicketRepo>[],
    );
  }

  /// The ticket id (equals the ticket folder name and the branch name).
  final String issueId;

  /// The human-readable ticket description.
  final String description;

  /// All repositories that belong to the ticket.
  final List<TicketRepo> repositories;

  /// The version of the gg CLI that wrote the marker.
  /// Empty for markers written before gg started stamping its version.
  final String ggVersion;

  /// Renders a pretty (multi-line) JSON string for good readability, ending
  /// with a trailing newline.
  String toPrettyJson() {
    const encoder = JsonEncoder.withIndent('  ');
    final map = <String, Object?>{
      'issue_id': issueId,
      'description': description,
      'gg_version': ggVersion,
      'repositories': repositories.map((r) => r.toJson()).toList(),
    };
    return '${encoder.convert(map)}\n';
  }

  /// Throws when [ggCliVersion] is older than the [required] version a marker
  /// was written with. Legacy markers (empty version) and unparseable
  /// versions never block loading.
  static void _checkGgVersion(String required) {
    if (required.isEmpty) {
      return;
    }
    final Version own;
    final Version req;
    try {
      own = Version.parse(ggCliVersion);
      req = Version.parse(required);
    } on FormatException {
      return;
    }
    if (own < req) {
      throw Exception(
        cError(
          'This ticket was written with gg $required, '
          'but only gg $ggCliVersion is installed.\n'
          'Please update gg: ${cCmd('dart pub global activate gg')}',
        ),
      );
    }
  }
}

/// Builds a [TicketJson] for the ticket at [ticketDir] from [repoDirs].
///
/// `issue_id` is the ticket folder name, `description` is carried over from the
/// `ticket.json` written when the ticket was created, and each repository
/// contributes its folder name and origin remote URL.
TicketJson buildTicketJson({
  required Directory ticketDir,
  required Iterable<Directory> repoDirs,
}) {
  final repositories = <TicketRepo>[
    for (final dir in repoDirs)
      TicketRepo(
        name: path.basename(dir.path),
        url: RepoFolderResolver.remoteUrl(dir) ?? '',
      ),
  ];

  return TicketJson(
    issueId: path.basename(ticketDir.path),
    description: readTicketDescription(ticketDir) ?? '',
    repositories: repositories,
    ggVersion: ggCliVersion,
  );
}

/// Writes (overwriting) [ticket] to `<ticketDir>/ticket.json`.
///
/// The file lives in the ticket workspace, next to the repositories and not
/// inside any of them, so git never sees it and the ticket description cannot
/// reach a remote.
void writeTicketJson(Directory ticketDir, TicketJson ticket) {
  if (!ticketDir.existsSync()) {
    ticketDir.createSync(recursive: true);
  }
  File(
    path.join(ticketDir.path, ticketJsonFileName),
  ).writeAsStringSync(ticket.toPrettyJson());
}

/// Reads `<ticketDir>/ticket.json`, or returns `null` when the file is missing
/// or malformed.
///
/// A gg version mismatch is not swallowed: [TicketJson.fromJsonString] throws
/// so the user learns that their gg is too old, instead of silently getting an
/// incomplete ticket.
TicketJson? readTicketJson(Directory ticketDir) {
  final file = File(path.join(ticketDir.path, ticketJsonFileName));
  if (!file.existsSync()) {
    return null;
  }
  try {
    return TicketJson.fromJsonString(file.readAsStringSync());
  } on FormatException {
    // A hand-edited / truncated ticket.json must not crash the caller.
    return null;
  }
}

/// Reads the trimmed `description` from `<ticketDir>/ticket.json`, or returns
/// `null` when the file is missing, is not a JSON object, is malformed, or
/// carries an empty description.
///
/// The description is the human-written summary of the ticket and therefore
/// the natural default for the messages gg writes on the user's behalf: the
/// commit message of `do commit` and the merge messages of
/// `do configure-publish`.
///
/// The raw JSON is read instead of [readTicketJson] on purpose: a description
/// is a convenience default, so neither a malformed file nor a version stamp
/// from a newer gg may make the caller fail.
String? readTicketDescription(Directory ticketDir) {
  final file = File(path.join(ticketDir.path, ticketJsonFileName));
  if (!file.existsSync()) {
    return null;
  }

  final dynamic decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } catch (_) {
    // A hand-edited / truncated ticket.json must not crash the caller.
    return null;
  }
  if (decoded is! Map<String, dynamic>) {
    return null;
  }

  final description = decoded['description']?.toString().trim();
  if (description == null || description.isEmpty) {
    return null;
  }

  return description;
}

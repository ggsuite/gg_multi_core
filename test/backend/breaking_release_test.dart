// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_core/src/backend/breaking_release.dart';
import 'package:gg_one_core/gg_one_core.dart' as gg;
import 'package:gg_publish/gg_publish.dart' show VersionIncrement;
import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('breaking_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A repo [name] declaring [version], an npm package when [npm], with
  /// [increment] recorded as `gg do review` records it.
  Future<Directory> repo(
    String name,
    String version, {
    VersionIncrement? increment,
    bool npm = false,
  }) async {
    final dir = Directory(path.join(tmp.path, name))..createSync();
    File(path.join(dir.path, 'pubspec.yaml')).writeAsStringSync(
      'name: $name\nversion: $version\n'
      'environment:\n  sdk: ">=3.0.0 <4.0.0"\n',
    );
    if (npm) {
      File(path.join(dir.path, 'package.json'))
          .writeAsStringSync('{"name": "$name", "version": "$version"}');
    }
    if (increment != null) {
      await gg.RepoPublishConfig(versionIncrement: increment)
          .save(file: gg.repoPublishConfigFile(dir));
    }
    return dir;
  }

  group('releaseBreaks', () {
    late Directory pub;
    late Directory npm;

    setUp(() async {
      pub = await repo('pub', '1.0.0');
      npm = await repo('npm', '1.0.0', npm: true);
    });

    bool breaks(VersionIncrement? increment, String? base, Directory dir) =>
        releaseBreaks(
          increment,
          base: base == null ? null : Version.parse(base),
          repoDir: dir,
        );

    test('a major release always breaks', () {
      for (final dir in [pub, npm]) {
        expect(breaks(VersionIncrement.major, '1.2.3', dir), isTrue);
        expect(breaks(VersionIncrement.major, '0.2.3', dir), isTrue);
        expect(breaks(VersionIncrement.major, null, dir), isTrue);
      }
    });

    test('a minor release breaks below 1.0.0 only', () {
      for (final dir in [pub, npm]) {
        expect(breaks(VersionIncrement.minor, '1.2.3', dir), isFalse);
        expect(breaks(VersionIncrement.minor, '0.2.3', dir), isTrue);
        expect(breaks(VersionIncrement.minor, null, dir), isFalse);
      }
    });

    test('a patch release breaks below 0.1.0 for npm only', () {
      expect(breaks(VersionIncrement.patch, '0.0.3', pub), isFalse);
      expect(breaks(VersionIncrement.patch, '0.0.3', npm), isTrue);
      expect(breaks(VersionIncrement.patch, '0.1.3', npm), isFalse);
      expect(breaks(VersionIncrement.patch, '1.0.3', npm), isFalse);
      expect(breaks(VersionIncrement.patch, null, npm), isFalse);
    });

    test('no increment breaks nothing', () {
      expect(breaks(null, '0.0.1', npm), isFalse);
    });

    test('a stray package.json is no npm manifest', () {
      File(path.join(pub.path, 'package.json')).writeAsStringSync('{}');
      expect(breaks(VersionIncrement.patch, '0.0.3', pub), isFalse);
    });
  });

  group('recordedBreakingRepos', () {
    test('names the repos whose recorded release breaks', () async {
      final repos = [
        await repo('a', '1.0.0', increment: VersionIncrement.major),
        await repo('b', '0.4.0', increment: VersionIncrement.minor),
        await repo('c', '1.4.0', increment: VersionIncrement.minor),
        await repo('d', '0.0.4', increment: VersionIncrement.patch),
        await repo('e', '0.0.4'),
        await repo('f', '0.0.4', increment: VersionIncrement.patch, npm: true),
      ];

      final result = await recordedBreakingRepos(
        repoDirs: repos,
        ticketDir: tmp,
      );

      expect(result, {'a', 'b', 'f'});
    });

    test('reads no manifest for a repo without an increment, and takes an '
        'unreadable version as unknown', () async {
      final read = <String>[];

      final result = await recordedBreakingRepos(
        repoDirs: [
          await repo('a', '0.0.1'),
          await repo('b', '1.0.0', increment: VersionIncrement.major),
          await repo('c', '0.1.0', increment: VersionIncrement.minor),
        ],
        ticketDir: tmp,
        readManifestVersion: (dir) async {
          read.add(path.basename(dir.path));
          return 'no version';
        },
      );

      // Unknown: only the major release breaks.
      expect(result, {'b'});
      expect(read, ['b', 'c']);
    });

    test('takes a missing version as unknown', () async {
      final result = await recordedBreakingRepos(
        repoDirs: [await repo('c', '0.1.0', increment: VersionIncrement.minor)],
        ticketDir: tmp,
        readManifestVersion: (_) async => null,
      );

      expect(result, isEmpty);
    });
  });
}

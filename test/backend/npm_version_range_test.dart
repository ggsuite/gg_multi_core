// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_multi_core/src/backend/npm_version_range.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  // ...........................................................................
  /// Whether the npm range [range] admits [version].
  bool allows(String range, String version) => NpmVersionRange.allows(
    NpmVersionRange.tryParse(range)!,
    Version.parse(version),
  );

  // ...........................................................................
  /// Expects [range] to admit every version of [yes] and none of [no].
  void expectRange(
    String range, {
    List<String> yes = const [],
    List<String> no = const [],
  }) {
    for (final version in yes) {
      expect(allows(range, version), isTrue, reason: '$range ∋ $version');
    }
    for (final version in no) {
      expect(allows(range, version), isFalse, reason: '$range ∌ $version');
    }
  }

  group('NpmVersionRange', () {
    group('tryParse()', () {
      test('reads an exact version as a pin', () {
        expectRange('1.2.3', yes: ['1.2.3'], no: ['1.2.4', '1.2.2']);
        expectRange('=1.2.3', yes: ['1.2.3'], no: ['1.2.4']);
        expectRange('v1.2.3', yes: ['1.2.3'], no: ['1.2.4']);
        expectRange('1.2.3+build.5', yes: ['1.2.3'], no: ['1.2.4']);
      });

      test('reads caret ranges the npm way', () {
        expectRange('^1.2.3', yes: ['1.2.3', '1.9.0'], no: ['2.0.0', '1.2.2']);
        expectRange('^0.2.3', yes: ['0.2.3', '0.2.9'], no: ['0.3.0', '0.2.2']);
        // pub would admit everything below 0.1.0 here.
        expectRange('^0.0.3', yes: ['0.0.3'], no: ['0.0.4', '0.0.2']);
        expectRange('^1.2', yes: ['1.2.0', '1.9.9'], no: ['2.0.0', '1.1.9']);
        expectRange('^1.x', yes: ['1.0.0', '1.9.9'], no: ['2.0.0']);
        expectRange('^0.0.x', yes: ['0.0.0', '0.0.9'], no: ['0.1.0']);
        expectRange('^0.0', yes: ['0.0.9'], no: ['0.1.0']);
        expectRange('^0.x', yes: ['0.0.0', '0.9.0'], no: ['1.0.0']);
        expectRange('^*', yes: ['0.0.1', '9.0.0']);
      });

      test('reads tilde ranges', () {
        expectRange('~1.2.3', yes: ['1.2.3', '1.2.9'], no: ['1.3.0', '1.2.2']);
        expectRange('~1.2', yes: ['1.2.0', '1.2.9'], no: ['1.3.0']);
        expectRange('~1', yes: ['1.0.0', '1.9.0'], no: ['2.0.0']);
        expectRange('~>1.2.3', yes: ['1.2.9'], no: ['1.3.0']);
        expectRange('~*', yes: ['0.0.1', '9.0.0']);
      });

      test('reads x-ranges', () {
        expectRange('*', yes: ['0.0.1', '9.0.0']);
        expectRange('', yes: ['0.0.1', '9.0.0']);
        expectRange('x', yes: ['0.0.1', '9.0.0']);
        expectRange('1', yes: ['1.0.0', '1.9.9'], no: ['2.0.0', '0.9.9']);
        expectRange('1.x', yes: ['1.0.0', '1.9.9'], no: ['2.0.0']);
        expectRange('1.2.*', yes: ['1.2.0', '1.2.9'], no: ['1.3.0']);
        expectRange('1.X.X', yes: ['1.5.0'], no: ['2.0.0']);
      });

      test('reads comparators', () {
        expectRange('>=1.2.3', yes: ['1.2.3', '9.0.0'], no: ['1.2.2']);
        expectRange('>=1.2', yes: ['1.2.0'], no: ['1.1.9']);
        expectRange('>1.2.3', yes: ['1.2.4'], no: ['1.2.3']);
        expectRange('>1.2', yes: ['1.3.0'], no: ['1.2.9']);
        expectRange('>1', yes: ['2.0.0'], no: ['1.9.9']);
        expectRange('>*', no: ['0.0.1', '9.0.0']);
        expectRange('<1.2.3', yes: ['1.2.2'], no: ['1.2.3']);
        expectRange('<1.2', yes: ['1.1.9'], no: ['1.2.0']);
        expectRange('<*', no: ['0.0.1', '9.0.0']);
        expectRange('<=1.2.3', yes: ['1.2.3'], no: ['1.2.4']);
        expectRange('<=1.2', yes: ['1.2.9'], no: ['1.3.0']);
        expectRange('<=1', yes: ['1.9.9'], no: ['2.0.0']);
        expectRange('<=*', yes: ['0.0.1', '9.0.0']);
      });

      test('requires every comparator of a set', () {
        expectRange(
          '>=1.2.3 <2.0.0',
          yes: ['1.2.3', '1.9.9'],
          no: ['2.0.0', '1.2.2'],
        );
        expectRange('>= 1.2.3 < 2.0.0', yes: ['1.9.9'], no: ['2.0.0']);
      });

      test('reads hyphen ranges', () {
        expectRange(
          '1.2.3 - 2.3.4',
          yes: ['1.2.3', '2.3.4'],
          no: ['2.3.5', '1.2.2'],
        );
        expectRange('1.2 - 2.3', yes: ['1.2.0', '2.3.9'], no: ['2.4.0']);
      });

      test('admits what any alternative admits', () {
        expectRange(
          '^1.2.3 || ^3.0.0',
          yes: ['1.5.0', '3.1.0'],
          no: ['2.0.0', '4.0.0'],
        );
        expectRange('1.2.3 ||', yes: ['7.0.0']);
      });

      test('drops a workspace prefix in front of a range', () {
        expectRange('workspace:^1.2.3', yes: ['1.5.0'], no: ['2.0.0']);
        expectRange('workspace:1.2.3', yes: ['1.2.3'], no: ['1.2.4']);
      });

      test('reads the semver fragment of a git spec', () {
        expectRange(
          'git+https://github.com/org/a.git#semver:^1.2.3',
          yes: ['1.5.0'],
          no: ['2.0.0'],
        );
        expectRange(
          'git+ssh://git@github.com/org/a.git#semver:%5E1.2.3',
          yes: ['1.5.0'],
          no: ['2.0.0'],
        );
      });

      test('returns null for everything that names no range', () {
        const noRanges = <String?>[
          null,
          'latest',
          'link:../a',
          'file:../a',
          'git+https://github.com/org/a.git',
          'git+https://github.com/org/a.git#main',
          'github:org/a',
          'org/a',
          'npm:other@^1.0.0',
          'catalog:',
          'workspace:*',
          'workspace:^',
          'workspace:~',
          'workspace:',
          '^1.2.3 || latest',
          '>=1.2.3 latest',
          'latest - 2.0.0',
          '1.0.0 - latest',
          '1.2.3.4',
        ];
        for (final spec in noRanges) {
          expect(NpmVersionRange.tryParse(spec), isNull, reason: '$spec');
        }
      });
    });

    group('allows()', () {
      test('admits a prerelease only for the exact pin on it', () {
        expectRange(
          '1.2.3-beta.1',
          yes: ['1.2.3-beta.1'],
          no: ['1.2.3-beta.2', '1.2.3'],
        );
        expectRange('^1.0.0', no: ['1.5.0-beta.1']);
        expectRange('>=1.0.0', no: ['2.0.0-rc.1']);
        expectRange('*', no: ['1.0.0-rc.1']);
      });
    });
  });
}

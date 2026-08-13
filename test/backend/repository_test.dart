// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_multi_core/src/backend/repository.dart';
import 'package:test/test.dart';

void main() {
  group('Repository', () {
    group('cloneUrl', () {
      test('returns httpsUrl when no sshUrl is provided', () {
        const repo = Repository(
          name: 'repo',
          httpsUrl: 'https://example.com/org/repo.git',
        );
        expect(repo.cloneUrl, equals('https://example.com/org/repo.git'));
      });

      test('prefers sshUrl over httpsUrl when provided', () {
        const repo = Repository(
          name: 'repo',
          httpsUrl: 'https://example.com/org/repo.git',
          sshUrl: 'git@example.com:org/repo.git',
        );
        expect(repo.cloneUrl, equals('git@example.com:org/repo.git'));
      });
    });
  });
}

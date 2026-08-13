// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_multi_core/src/backend/organization.dart';
import 'package:test/test.dart';

void main() {
  group('Organization model', () {
    test('toMap/fromMap roundtrip', () {
      final org1 = Organization(
        name: 'foo',
        url: 'https://foo.com/',
        projectName: 'bar',
      );
      final map = org1.toMap();
      final org2 = Organization.fromMap(map);
      expect(org2.id, org1.id);
      expect(org2.name, 'foo');
      expect(org2.url, 'https://foo.com/');
      expect(org2.projectName, 'bar');
    });

    test('fromMap omits projectName if null', () {
      final org1 = Organization(name: 'abc', url: 'url-abc');
      final map = org1.toMap();
      expect(map.containsKey('project_name'), isFalse);
      final org2 = Organization.fromMap(map);
      expect(org2.projectName, isNull);
    });

    test('autogenerates unique id if not given', () {
      final org1 = Organization(name: 'foo', url: 'bar');
      final org2 = Organization(name: 'foo', url: 'baz');
      expect(org1.id, isNot(equals(org2.id)));
      expect(org1 == org2, isTrue, reason: 'Equality based on name');
    });

    test('== operator uses name only', () {
      final o1 = Organization(name: 'a', url: 'x');
      final o2 = Organization(name: 'a', url: 'y', id: 'different');
      expect(o1 == o2, isTrue);
    });

    test('hashCode uses name only', () {
      final o1 = Organization(name: 'a', url: 'x');
      final o2 = Organization(name: 'a', url: 'z');
      expect(o1.hashCode, o2.hashCode);
    });
  });
}

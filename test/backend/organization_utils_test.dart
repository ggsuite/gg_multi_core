// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:gg_multi_core/src/backend/organization.dart';
import 'package:gg_multi_core/src/backend/organization_utils.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('OrganizationUtils', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('org_utils_test_');
      OrganizationUtils.clearCache();
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('readOrganizations returns empty list if file does not exist', () {
      final orgs = OrganizationUtils.readOrganizations(tempDir.path);
      expect(orgs, isEmpty);
    });

    test('appendOrganization creates file and adds entry', () {
      const url = 'https://github.com/myorg/myrepo.git';
      OrganizationUtils.appendOrganization(tempDir.path, url);
      final orgs = OrganizationUtils.readOrganizations(tempDir.path);
      expect(orgs.any((o) => o.name == 'myorg'), isTrue);
      expect(orgs[0].url, 'https://github.com/myorg/');
      final file = File(path.join(tempDir.path, '.organizations'));
      expect(file.existsSync(), isTrue);
      final parsed = jsonDecode(file.readAsStringSync());
      expect(parsed is List, isTrue);
      expect(parsed[0]['name'], 'myorg');
      expect(parsed[0]['url'], 'https://github.com/myorg/');
    });

    test('second append with same org does not duplicate', () {
      OrganizationUtils.appendOrganization(
        tempDir.path,
        'https://github.com/myorg/myrepo.git',
      );
      OrganizationUtils.appendOrganization(
        tempDir.path,
        'https://github.com/myorg/another.git',
      );
      final orgs = OrganizationUtils.readOrganizations(tempDir.path);
      expect(orgs.length, 1);
      expect(orgs[0].name, 'myorg');
      expect(orgs[0].url, 'https://github.com/myorg/');
    });

    group('extractOrganizationFromUrl', () {
      group('extracts github org', () {
        test('from HTTP-URL for repo', () {
          final org = OrganizationUtils.extractOrganizationFromUrl(
            'https://github.com/foobar/repo.git',
          );
          expect(org?.name, equals('foobar'));
          expect(org?.url, equals('https://github.com/foobar/'));
        });

        test('from HTTP-URL for org', () {
          final org = OrganizationUtils.extractOrganizationFromUrl(
            'https://github.com/foobar',
          );
          expect(org?.name, equals('foobar'));
          expect(org?.url, equals('https://github.com/foobar/'));
        });

        test('from HTTP-URL with final / for org', () {
          final org = OrganizationUtils.extractOrganizationFromUrl(
            'https://github.com/foobar/',
          );
          expect(org?.name, equals('foobar'));
          expect(org?.url, equals('https://github.com/foobar/'));
        });

        test('from SSH-URL', () {
          final org = OrganizationUtils.extractOrganizationFromUrl(
            'git@github.com:foobar/barfoo.git',
          );
          expect(org?.name, equals('foobar'));
          expect(org?.url, equals('https://github.com/foobar/'));
        });
      });

      test('returns org structure from generic string', () {
        final org = OrganizationUtils.extractOrganizationFromUrl('foobar-git');
        expect(org?.name, 'foobar-git');
        expect(org?.url, 'https://github.com/foobar-git/');
      });

      group('extracts Azure org', () {
        test('from SSH URL full', () {
          const url = 'git@ssh.dev.azure.com:v3/xyz-abc/ds_cdm/ds_assembly.git';
          final org = OrganizationUtils.extractOrganizationFromUrl(url);
          expect(org?.name, equals('xyz-abc'));
          expect(org?.projectName, equals('ds_cdm'));
          expect(
            org?.url,
            equals('https://ssh.dev.azure.com:v3/xyz-abc/ds_cdm/'),
          );
        });

        test('from HTTPS URL (full, .git)', () {
          const url =
              'https://ssh.dev.azure.com:v3/xyz-abc/ds_cdm/ds_assembly.git';
          final org = OrganizationUtils.extractOrganizationFromUrl(url);
          expect(org?.name, equals('xyz-abc'));
          expect(org?.projectName, equals('ds_cdm'));
          expect(
            org?.url,
            equals('https://ssh.dev.azure.com:v3/xyz-abc/ds_cdm/'),
          );
        });

        test('from HTTPS URL (full, no .git, trailing "/")', () {
          const url =
              'https://ssh.dev.azure.com:v3/xyz-abc/ds_cdm/ds_assembly/';
          final org = OrganizationUtils.extractOrganizationFromUrl(url);
          expect(org?.name, equals('xyz-abc'));
          expect(org?.projectName, equals('ds_cdm'));
          expect(
            org?.url,
            equals('https://ssh.dev.azure.com:v3/xyz-abc/ds_cdm/'),
          );
        });

        test('from HTTPS URL for just project (no repo, ends with "/")', () {
          const url = 'https://ssh.dev.azure.com:v3/xyz-abc/ds_cdm/';
          final org = OrganizationUtils.extractOrganizationFromUrl(url);
          expect(org?.name, equals('xyz-abc'));
          expect(org?.projectName, equals('ds_cdm'));
          expect(
            org?.url,
            equals('https://ssh.dev.azure.com:v3/xyz-abc/ds_cdm/'),
          );
        });

        test('from HTTPS project URL, no trailing /', () {
          const url = 'https://ssh.dev.azure.com:v3/xyz-abc/ds_cdm';
          final org = OrganizationUtils.extractOrganizationFromUrl(url);
          expect(org?.name, equals('xyz-abc'));
          expect(org?.projectName, equals('ds_cdm'));
          expect(
            org?.url,
            equals('https://ssh.dev.azure.com:v3/xyz-abc/ds_cdm/'),
          );
        });

        test('from HTTPS project URL, trailing #', () {
          const url = 'https://ssh.dev.azure.com:v3/xyz-abc/ds_cdm#';
          final org = OrganizationUtils.extractOrganizationFromUrl(url);
          expect(org?.name, equals('xyz-abc'));
          expect(org?.projectName, equals('ds_cdm'));
          expect(
            org?.url,
            equals('https://ssh.dev.azure.com:v3/xyz-abc/ds_cdm/'),
          );
        });
      });
    });

    test('readOrganizations returns empty list if JSON parsing fails', () {
      final orgsFile = File(path.join(tempDir.path, '.organizations'));
      orgsFile.writeAsStringSync('invalid json!'); // not valid JSON
      final orgs = OrganizationUtils.readOrganizations(tempDir.path);
      expect(
        orgs,
        isEmpty,
        reason:
            'Should return empty list if '
            '.organizations file contains invalid JSON',
      );
    });

    test('readOrganizations imports legacy Map format', () {
      final orgsFile = File(path.join(tempDir.path, '.organizations'));
      final legacy = {'a': 'u1', 'b': 'u2'};
      orgsFile.writeAsStringSync(jsonEncode(legacy));
      final orgs = OrganizationUtils.readOrganizations(tempDir.path);
      expect(orgs.length, 2);
      expect(orgs[0].name, 'a');
      expect(orgs[0].url, 'u1');
      expect(orgs[1].name, 'b');
      expect(orgs[1].url, 'u2');
    });

    test('readOrganizations returns empty list if JSON is not List or Map', () {
      final orgsFile = File(path.join(tempDir.path, '.organizations'));
      orgsFile.writeAsStringSync(jsonEncode('this is neither list nor map'));
      final orgs = OrganizationUtils.readOrganizations(tempDir.path);
      expect(orgs, isEmpty);
    });

    test('readOrganizations reads list format', () {
      // This test covers the code path where the file
      // contains a proper JSON list of Organization objects.
      OrganizationUtils.clearCache();
      final file = File(path.join(tempDir.path, '.organizations'));
      final listJson = [
        {'id': '1', 'name': 'o1', 'url': 'u1'},
        {'id': '2', 'name': 'o2', 'url': 'u2', 'project_name': 'p2'},
      ];
      file.writeAsStringSync(jsonEncode(listJson));
      final orgs = OrganizationUtils.readOrganizations(tempDir.path);
      expect(orgs.length, 2);
      expect(orgs[0].name, 'o1');
      expect(orgs[1].projectName, 'p2');
      // Test cache by identical call
      final orgs2 = OrganizationUtils.readOrganizations(tempDir.path);
      expect(identical(orgs, orgs2), isTrue);
    });

    group('buildBaseUrl', () {
      test('returns GitHub HTTPS URL for SSH repoUrl', () {
        final result = OrganizationUtils.buildBaseUrl(
          'git@github.com:myorg/myrepo.git',
          'myorg',
        );
        expect(result, equals('https://github.com/myorg/'));
      });

      test('returns correct HTTPS URL for HTTP(S) repoUrl', () {
        final result = OrganizationUtils.buildBaseUrl(
          'https://gitlab.com/fooorg/myrepo.git',
          'fooorg',
        );
        expect(result, equals('https://gitlab.com/fooorg/'));
      });

      test('falls back to GitHub HTTPS URL on parse error', () {
        final result = OrganizationUtils.buildBaseUrl(
          'https://in valid',
          'someOrg',
        );
        expect(result, equals('https://github.com/someOrg/'));
      });

      test('returns fallback URL when host is empty', () {
        final result = OrganizationUtils.buildBaseUrl(
          'https:///anything',
          'fallback',
        );
        expect(result, equals('https://github.com/fallback/'));
      });

      test('returns fallback URL when host contains invalid characters', () {
        final result = OrganizationUtils.buildBaseUrl(
          'https://examp!e.com/repo.git',
          'fallback',
        );
        expect(result, equals('https://github.com/fallback/'));
      });

      test('returns correct Azure SSH URL for org base with project', () {
        const url = 'git@ssh.dev.azure.com:v3/myorg/myproj/myrepo';
        const org = 'myorg';
        const project = 'myproj';
        final base = OrganizationUtils.buildBaseUrl(url, org, project);
        expect(base, equals('https://ssh.dev.azure.com:v3/myorg/myproj/'));
      });

      test('returns correct Azure HTTP URL for org base with project', () {
        const url = 'https://ssh.dev.azure.com:v3/myorg/myproj/myrepo';
        const org = 'myorg';
        const project = 'myproj';
        final base = OrganizationUtils.buildBaseUrl(url, org, project);
        expect(base, equals('https://ssh.dev.azure.com:v3/myorg/myproj/'));
      });
      test('returns correct Azure HTTP for org base without project', () {
        const url = 'https://ssh.dev.azure.com:v3/myorg/';
        const org = 'myorg';
        final base = OrganizationUtils.buildBaseUrl(url, org);
        expect(base, equals('https://ssh.dev.azure.com:v3/myorg/'));
      });
    });

    group('getOrganizationByName', () {
      test('returns organization when name exists', () {
        OrganizationUtils.writeOrganizations(tempDir.path, [
          Organization(name: 'acme', url: 'https://github.com/acme/'),
        ]);
        final org = OrganizationUtils.getOrganizationByName(
          tempDir.path,
          'acme',
        );
        expect(org, isNotNull);
        expect(org?.name, 'acme');
        expect(org?.url, 'https://github.com/acme/');
      });

      test('returns null if organization name does not exist', () {
        OrganizationUtils.writeOrganizations(tempDir.path, [
          Organization(name: 'foobar', url: 'url://foobar'),
        ]);
        final org = OrganizationUtils.getOrganizationByName(
          tempDir.path,
          'other',
        );
        expect(org, isNull);
      });

      test('is case-sensitive: returns null if case does not match', () {
        OrganizationUtils.writeOrganizations(tempDir.path, [
          Organization(name: 'Bar', url: 'x://bar'),
          Organization(name: 'foo', url: 'x://foo'),
        ]);
        // Pass lowercase
        expect(
          OrganizationUtils.getOrganizationByName(tempDir.path, 'bar'),
          isNull,
        );
        // Pass exact
        expect(
          OrganizationUtils.getOrganizationByName(tempDir.path, 'Bar'),
          isNotNull,
        );
        expect(
          OrganizationUtils.getOrganizationByName(tempDir.path, 'foo')?.url,
          'x://foo',
        );
      });

      test('caches and returns the same object if called repeatedly, '
          'even after file deletion', () {
        final org = Organization(name: 'cached', url: 'https://cached');
        OrganizationUtils.writeOrganizations(tempDir.path, [org]);
        final result1 = OrganizationUtils.getOrganizationByName(
          tempDir.path,
          'cached',
        );
        expect(result1, isNotNull);
        // Remove file, so cache is the only source
        final orgFile = File('${tempDir.path}/.organizations');
        if (orgFile.existsSync()) {
          orgFile.deleteSync();
        }
        final result2 = OrganizationUtils.getOrganizationByName(
          tempDir.path,
          'cached',
        );
        expect(
          identical(result1, result2),
          isTrue,
          reason: 'should be same object from cache',
        );
        expect(result2?.name, 'cached');
      });
    });

    group('OrganizationUtils buffer/cache', () {
      late Directory tempDir;
      setUp(() {
        tempDir = Directory.systemTemp.createTempSync('org_buffer_');
        OrganizationUtils.clearCache();
      });
      tearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      test('caches organizations from file', () {
        final orgFile = File(path.join(tempDir.path, '.organizations'));
        final orgsList = [
          {'id': 'id1', 'name': 'foo', 'url': 'u', 'project_name': 'pn'},
          {'id': 'id2', 'name': 'bar', 'url': 'v'},
        ];
        orgFile.writeAsStringSync(jsonEncode(orgsList));
        final firstRead = OrganizationUtils.readOrganizations(tempDir.path);
        final secondRead = OrganizationUtils.readOrganizations(tempDir.path);
        expect(identical(firstRead, secondRead), isTrue);
        expect(firstRead.length, 2);
        expect(firstRead[0].name, 'foo');
      });

      test('ignores file after caching even if file is changed', () {
        final orgFile = File(path.join(tempDir.path, '.organizations'));
        orgFile.writeAsStringSync(
          jsonEncode([
            {'id': 'id1', 'name': 'foo', 'url': 'bar'},
          ]),
        );
        OrganizationUtils.readOrganizations(tempDir.path);
        orgFile.writeAsStringSync(
          jsonEncode([
            {'id': 'id2', 'name': 'baz', 'url': 'qux'},
          ]),
        );
        final again = OrganizationUtils.readOrganizations(tempDir.path);
        expect(again[0].name, 'foo');
        expect(again[0].id, 'id1');
      });

      test('addOrganization adds and updates cache + disk', () {
        expect(OrganizationUtils.readOrganizations(tempDir.path), isEmpty);
        final org = Organization(name: 'org1', url: 'u1');
        OrganizationUtils.addOrganization(tempDir.path, org);
        final cached = OrganizationUtils.readOrganizations(tempDir.path);
        expect(cached.length, 1);
        expect(cached[0].name, 'org1');
        // File was written as well
        final diskOrg = File(path.join(tempDir.path, '.organizations'));
        final json = jsonDecode(diskOrg.readAsStringSync());
        expect(json[0]['name'], 'org1');
      });

      test('does not add duplicate organizations by name', () {
        final org = Organization(name: 'dupe', url: 'u');
        OrganizationUtils.addOrganization(tempDir.path, org);
        final again = Organization(name: 'dupe', url: 'otheru');
        OrganizationUtils.addOrganization(tempDir.path, again);
        final all = OrganizationUtils.readOrganizations(tempDir.path);
        expect(all.length, 1, reason: 'No duplicates allowed');
      });

      test('getOrganizationByName finds by name', () {
        OrganizationUtils.clearCache();
        final o1 = Organization(name: 'xx', url: 'yy');
        OrganizationUtils.addOrganization(tempDir.path, o1);
        final res = OrganizationUtils.getOrganizationByName(tempDir.path, 'xx');
        expect(res, isNotNull);
        expect(res!.name, 'xx');
      });

      test('getOrganizationByName returns null if not present', () {
        OrganizationUtils.clearCache();
        expect(
          OrganizationUtils.getOrganizationByName(tempDir.path, 'qw'),
          isNull,
        );
      });

      test('getOrganizationByRepoUrl works via org extraction', () {
        OrganizationUtils.clearCache();
        final org = Organization(name: 'someorg', url: 'url');
        OrganizationUtils.addOrganization(tempDir.path, org);
        const url = 'git@github.com:someorg/some-repo.git';
        final found = OrganizationUtils.getOrganizationByRepoUrl(
          tempDir.path,
          url,
        );
        expect(found, isNotNull);
        expect(found!.name, 'someorg');
      });
    });
  });
}

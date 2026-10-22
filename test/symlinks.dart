// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:path/path.dart' as path;

/// Whether this machine lets the tests create symbolic links: Windows
/// allows them in Developer Mode or with administrator rights only.
final bool canCreateSymlinks = () {
  final dir = Directory.systemTemp.createTempSync('gg_symlink_probe');
  try {
    Link(path.join(dir.path, 'probe')).createSync(dir.path);
    return true;
  } on FileSystemException {
    return false; // coverage:ignore-line
  } finally {
    dir.deleteSync(recursive: true);
  }
}();

/// The skip reason of a test whose fixture is a symbolic link, or false.
Object get skipWithoutSymlinks => canCreateSymlinks
    ? false
    : 'Symbolic links need Developer Mode or administrator rights on Windows';

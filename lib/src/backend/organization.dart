// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:math';

/// Represents an organization with id, name, url, and an optional project name.
class Organization {
  /// Generates a random id
  static String _generateId() => '${Random().nextInt(1 << 32)}';

  /// Organization constructor
  Organization({
    String? id,
    required this.name,
    required this.url,
    this.projectName,
  }) : id = id ?? _generateId();

  /// Factory constructor for deserializing from Map
  factory Organization.fromMap(Map<String, dynamic> map) {
    return Organization(
      id: map['id'] as String?,
      name: map['name'] as String,
      url: map['url'] as String,
      projectName: map['project_name'] as String?,
    );
  }

  /// Converts an Organization to a map
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{'id': id, 'name': name, 'url': url};
    if (projectName != null) {
      map['project_name'] = projectName;
    }
    return map;
  }

  /// Unique id of the organization
  final String id;

  /// Organization name (unique key)
  final String name;

  /// Organization's base URL
  final String url;

  /// Optional project name
  final String? projectName;

  @override
  bool operator ==(Object other) {
    if (other is! Organization) return false;
    return name == other.name;
  }

  @override
  int get hashCode => name.hashCode;
}

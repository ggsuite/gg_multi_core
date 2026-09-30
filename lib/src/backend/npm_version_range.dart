// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:pub_semver/pub_semver.dart';

/// Reads the version ranges npm, pnpm and yarn write into a package.json.
///
/// pub_semver speaks pub's dialect, and the two disagree exactly where it
/// hurts: `~1.2.3`, `1.x` and `>=1.0.0 <2.0.0 || ^3.0.0` do not parse at
/// all, and `^0.0.3` parses but means something else — pub admits everything
/// below 0.1.0, npm nothing but 0.0.3 itself. A skip check that read npm
/// ranges as pub constraints would therefore either release every TypeScript
/// package every time, or skip one whose published range does not cover the
/// new version of its dependency.
///
/// The result is a pub_semver constraint, so callers keep one type for both
/// languages — but it has to be asked through [allows], which adds npm's
/// handling of prereleases.
class NpmVersionRange {
  NpmVersionRange._(); // coverage:ignore-line

  // ...........................................................................
  /// Parses the npm range [raw], or returns null when it is none.
  ///
  /// Understood are exact versions, `^` and `~`, x-ranges (`1`, `1.x`,
  /// `1.2.*`, `*`, the empty string), comparators, hyphen ranges and `||`.
  /// A `workspace:` prefix is dropped when a range follows it, and a git
  /// spec contributes the range of its `#semver:` fragment.
  ///
  /// Everything that names no range — `file:`/`link:` refs, git urls without
  /// a semver fragment, `npm:` aliases, `catalog:` entries, dist tags like
  /// `latest`, and the bare `workspace:^` that only resolves at publish time
  /// — yields null.
  static VersionConstraint? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }

    final range = _rangeOf(raw.trim());
    if (range == null) {
      return null;
    }

    final alternatives = <VersionConstraint>[];
    for (final alternative in range.split('||')) {
      final constraint = _parseAlternative(alternative.trim());
      if (constraint == null) {
        return null;
      }
      alternatives.add(constraint);
    }
    return VersionConstraint.unionOf(alternatives);
  }

  // ...........................................................................
  /// Whether the npm range [constraint] admits [version].
  ///
  /// npm admits a prerelease only when a comparator names a prerelease of
  /// the very same `major.minor.patch`. That rule is not expressible as a
  /// pub_semver constraint, so it is answered conservatively here: a
  /// prerelease is admitted by nothing but the exact pin on itself.
  static bool allows(VersionConstraint constraint, Version version) {
    if (version.isPreRelease) {
      return constraint is Version && constraint == version;
    }
    return constraint.allows(version);
  }

  // ######################
  // Private
  // ######################

  static const String _workspacePrefix = 'workspace:';

  static const String _semverFragment = '#semver:';

  /// `major[.minor[.patch]][-prerelease][+build]`, each number optionally a
  /// wildcard, with the leading `v`/`=` npm tolerates.
  static final RegExp _partial = RegExp(
    r'^[v=\s]*'
    r'(\d+|[xX*])'
    r'(?:\.(\d+|[xX*]))?'
    r'(?:\.(\d+|[xX*]))?'
    r'(?:-([0-9A-Za-z.-]+))?'
    r'(?:\+[0-9A-Za-z.-]+)?$',
  );

  static final RegExp _comparator = RegExp(r'^(>=|<=|>|<|=|\^|~>|~)?(.*)$');

  static final RegExp _operatorGap = RegExp(r'(>=|<=|>|<|=|\^|~>|~)\s+');

  static final RegExp _hyphenRange = RegExp(r'^(\S+)\s+-\s+(\S+)$');

  // ...........................................................................
  /// The range part of the dependency spec [spec], or null when the spec
  /// refers to something other than a registry range.
  static String? _rangeOf(String spec) {
    final fragment = spec.indexOf(_semverFragment);
    if (fragment >= 0) {
      return Uri.decodeComponent(
        spec.substring(fragment + _semverFragment.length),
      ).trim();
    }

    if (spec.startsWith(_workspacePrefix)) {
      final range = spec.substring(_workspacePrefix.length).trim();
      // `workspace:*`, `workspace:^` and `workspace:~` are replaced by the
      // version the workspace holds at publish time — unknown here.
      const resolvedAtPublish = <String>{'', '*', '^', '~'};
      return resolvedAtPublish.contains(range) ? null : range;
    }

    // Protocols (`file:`, `link:`, `npm:`, `catalog:`, urls) and paths.
    if (spec.contains(':') || spec.contains('/')) {
      return null;
    }

    return spec;
  }

  // ...........................................................................
  /// Parses one `||` alternative: a hyphen range or a set of comparators
  /// that all have to hold.
  static VersionConstraint? _parseAlternative(String alternative) {
    if (alternative.isEmpty) {
      return VersionConstraint.any;
    }

    final hyphen = _hyphenRange.firstMatch(alternative);
    if (hyphen != null) {
      final from = _parseComparator('>=${hyphen.group(1)}');
      final to = _parseComparator('<=${hyphen.group(2)}');
      return from == null || to == null ? null : from.intersect(to);
    }

    // `>= 1.2.3` is one comparator, not an operator and a version.
    final comparators = alternative
        .replaceAllMapped(_operatorGap, (match) => match.group(1)!)
        .split(RegExp(r'\s+'));

    VersionConstraint result = VersionConstraint.any;
    for (final comparator in comparators) {
      final constraint = _parseComparator(comparator);
      if (constraint == null) {
        return null;
      }
      result = result.intersect(constraint);
    }
    return result;
  }

  // ...........................................................................
  /// Parses a single comparator such as `^1.2.3`, `>=1.2`, `1.x` or `1.2.3`.
  static VersionConstraint? _parseComparator(String comparator) {
    final parts = _comparator.firstMatch(comparator)!;
    final operator = parts.group(1) ?? '';
    final version = _partial.firstMatch(parts.group(2)!.trim());
    if (version == null) {
      return null;
    }

    final major = _number(version.group(1));
    final minor = major == null ? null : _number(version.group(2));
    final patch = minor == null ? null : _number(version.group(3));
    final pre = patch == null ? null : version.group(4);

    // The lowest version the partial stands for, and the first version
    // above everything it stands for (null: there is none, e.g. `*`).
    final floor = Version(major ?? 0, minor ?? 0, patch ?? 0, pre: pre);
    final isFull = patch != null;
    final Version? ceiling = major == null
        ? null
        : minor == null
        ? Version(major + 1, 0, 0)
        : patch == null
        ? Version(major, minor + 1, 0)
        : null;

    switch (operator) {
      case '>=':
        return _range(min: floor);
      case '>':
        if (isFull) {
          return VersionRange(min: floor);
        }
        return ceiling == null ? VersionConstraint.empty : _range(min: ceiling);
      case '<':
        return major == null
            ? VersionConstraint.empty
            : VersionRange(max: floor);
      case '<=':
        if (isFull) {
          return VersionRange(max: floor, includeMax: true);
        }
        return ceiling == null
            ? VersionConstraint.any
            : VersionRange(max: ceiling);
      case '~':
      case '~>':
        if (major == null) {
          return VersionConstraint.any;
        }
        return _range(
          min: floor,
          max: minor == null
              ? Version(major + 1, 0, 0)
              : Version(major, minor + 1, 0),
        );
      case '^':
        if (major == null) {
          return VersionConstraint.any;
        }
        return _range(min: floor, max: _caretCeiling(major, minor, patch));
      default:
        if (isFull) {
          return floor;
        }
        return ceiling == null
            ? VersionConstraint.any
            : _range(min: floor, max: ceiling);
    }
  }

  // ...........................................................................
  /// The first version a caret range on `major.minor.patch` excludes: the
  /// next value of the leftmost non-zero position — of the leftmost *given*
  /// position when everything given is zero (`^0.0.x` ends at 0.1.0, `^0.x`
  /// at 1.0.0).
  static Version _caretCeiling(int major, int? minor, int? patch) {
    if (major > 0 || minor == null) {
      return Version(major + 1, 0, 0);
    }
    if (minor > 0 || patch == null) {
      return Version(0, minor + 1, 0);
    }
    return Version(0, 0, patch + 1);
  }

  // ...........................................................................
  /// `>=min <max`, with [max] exclusive.
  static VersionRange _range({required Version min, Version? max}) =>
      VersionRange(min: min, max: max, includeMin: true);

  // ...........................................................................
  /// The number [part] holds, or null for a wildcard or a missing part.
  static int? _number(String? part) => part == null ? null : int.tryParse(part);
}

// Release version gate (ticket 29).
//
// The pure half of the release pipeline's version discipline. Given a pushed
// release tag (`v<versionName>+<versionCode>`), the pubspec.yaml body, and the
// previous release's tag, it returns a human-readable failure reason, or null
// when the release is allowed to build and publish:
//
//   * the tag must be exactly `v<versionName>+<versionCode>`;
//   * pubspec's `version:` must equal that string exactly;
//   * the versionCode must be strictly greater than the previous release's.
//
// `main()` is the thin CLI the workflow runs: it reads `TAG` / `PUBSPEC` /
// `PREVIOUS_TAG` from the environment, calls the gate, and exits non-zero on
// failure so nothing is ever published from a bad tag.
//
// This file has no package imports so the workflow can run it with plain
// `dart run` before any `flutter pub get`.

import 'dart:io';

/// Parses a release tag `v<versionName>+<versionCode>` into its parts, or null
/// when the tag is not a well-formed release tag.
({String name, int code})? parseReleaseTag(String tag) {
  final t = tag.trim();
  if (!t.startsWith('v')) return null;
  return parseVersion(t.substring(1));
}

/// The raw `version:` value (e.g. `1.0.0+1`) from a pubspec.yaml body, or null
/// when there is no such line.
String? pubspecVersionString(String raw) {
  final m = _versionLine.firstMatch(raw);
  return m?.group(1);
}

/// Splits a `<name>+<code>` version string into its parts, or null when it is
/// not of that form (no `+`, empty name, or non-integer code).
({String name, int code})? parseVersion(String version) {
  final plus = version.lastIndexOf('+');
  if (plus <= 0 || plus == version.length - 1) return null;
  final name = version.substring(0, plus);
  final code = int.tryParse(version.substring(plus + 1));
  if (code == null) return null;
  return (name: name, code: code);
}

/// The reason the release gate fails, or null when it passes.
///
/// [tag] is the pushed tag; [pubspecRaw] is the pubspec.yaml text;
/// [previousTag] is the previous release's tag (null/empty for the first
/// release, in which case the strictly-greater check is skipped).
String? versionGateReason({
  required String tag,
  required String pubspecRaw,
  String? previousTag,
}) {
  final pubspecVersion = pubspecVersionString(pubspecRaw);
  if (pubspecVersion == null) {
    return 'pubspec.yaml has no `version:` line';
  }
  if (tag != 'v$pubspecVersion') {
    return 'tag `$tag` does not equal pubspec version `$pubspecVersion` '
        '(expected `v$pubspecVersion`)';
  }
  final current = parseVersion(pubspecVersion);
  if (current == null) {
    return 'pubspec version `$pubspecVersion` is not `<name>+<code>`';
  }
  if (previousTag != null && previousTag.isNotEmpty) {
    final prev = parseReleaseTag(previousTag);
    if (prev == null) {
      return 'cannot parse previous release tag `$previousTag`';
    }
    if (current.code <= prev.code) {
      return 'versionCode ${current.code} is not strictly greater than the '
          'previous release versionCode ${prev.code}';
    }
  }
  return null;
}

final _versionLine = RegExp(r'^\s*version:\s*(\S+)', multiLine: true);

Future<void> main() async {
  final tag = Platform.environment['TAG'];
  final pubspecPath = Platform.environment['PUBSPEC'] ?? 'pubspec.yaml';
  final previousTag = Platform.environment['PREVIOUS_TAG'];

  if (tag == null || tag.isEmpty) {
    stderr.writeln('version gate: no tag (set TAG)');
    exit(1);
  }
  final pubspecRaw = File(pubspecPath).readAsStringSync();
  final reason = versionGateReason(
    tag: tag,
    pubspecRaw: pubspecRaw,
    previousTag: previousTag,
  );
  if (reason != null) {
    stderr.writeln('version gate: $reason');
    exit(1);
  }
  stdout.writeln('version gate: $tag ok');
}

// Tests for the release version gate (tool/release/version_gate.dart).
//
// Pins the ticket 29 version discipline: a release tag must be exactly
// `v<versionName>+<versionCode>`, pubspec's `version:` must equal it exactly,
// and the versionCode must be strictly greater than the previous release's.
// A failing gate publishes nothing — this suite is the pure half of that
// guarantee; the workflow wiring is what runs it on a pushed tag.

import 'package:flutter_test/flutter_test.dart';

import '../../tool/release/version_gate.dart';

void main() {
  group('parseReleaseTag', () {
    test('parses v<name>+<code>', () {
      final p = parseReleaseTag('v1.0.0+1');
      expect(p, isNotNull);
      expect(p!.name, '1.0.0');
      expect(p.code, 1);
    });

    test('parses a multi-digit code', () {
      final p = parseReleaseTag('v1.2.3+42');
      expect(p!.name, '1.2.3');
      expect(p.code, 42);
    });

    test('keeps a prerelease name intact', () {
      final p = parseReleaseTag('v1.0.0-beta.1+7');
      expect(p!.name, '1.0.0-beta.1');
      expect(p.code, 7);
    });

    test('rejects a tag without the v prefix', () {
      expect(parseReleaseTag('1.0.0+1'), isNull);
    });

    test('rejects a tag without a code', () {
      expect(parseReleaseTag('v1.0.0'), isNull);
    });

    test('rejects a tag with a non-numeric code', () {
      expect(parseReleaseTag('v1.0.0+x'), isNull);
    });

    test('rejects a tag with an empty name', () {
      expect(parseReleaseTag('v+1'), isNull);
    });
  });

  group('parseVersion', () {
    test('splits name+code', () {
      final p = parseVersion('1.0.0+1');
      expect(p!.name, '1.0.0');
      expect(p.code, 1);
    });

    test('keeps a prerelease name intact', () {
      final p = parseVersion('1.0.0-beta.1+7');
      expect(p!.name, '1.0.0-beta.1');
      expect(p.code, 7);
    });

    test('rejects a version without a code', () {
      expect(parseVersion('1.0.0'), isNull);
    });

    test('rejects a version with an empty code', () {
      expect(parseVersion('1.0.0+'), isNull);
    });

    test('rejects a version with a non-numeric code', () {
      expect(parseVersion('1.0.0+x'), isNull);
    });

    test('rejects a version with an empty name', () {
      expect(parseVersion('+1'), isNull);
    });
  });

  group('pubspecVersionString', () {
    test('extracts the version value', () {
      expect(pubspecVersionString('version: 1.0.0+1\n'), '1.0.0+1');
    });

    test('extracts with leading indentation', () {
      expect(pubspecVersionString('   version:   1.2.3+42\n'), '1.2.3+42');
    });

    test('ignores a trailing comment', () {
      expect(pubspecVersionString('version: 1.0.0+1 # build number\n'),
          '1.0.0+1');
    });

    test('returns null for a body with no version line', () {
      expect(pubspecVersionString('name: foo\ndescription: bar\n'), isNull);
    });
  });

  group('versionGateReason', () {
    const pubspec = 'version: 1.0.0+3\n';

    test('passes a matching tag with no previous release', () {
      expect(versionGateReason(tag: 'v1.0.0+3', pubspecRaw: pubspec), isNull);
    });

    test('passes a matching tag with a lower previous code', () {
      expect(
        versionGateReason(
          tag: 'v1.0.0+3',
          pubspecRaw: pubspec,
          previousTag: 'v1.0.0+2',
        ),
        isNull,
      );
    });

    test('fails when the tag versionName differs from pubspec', () {
      expect(
        versionGateReason(tag: 'v1.0.1+3', pubspecRaw: pubspec),
        contains('does not equal pubspec version'),
      );
    });

    test('fails when the tag versionCode differs from pubspec', () {
      expect(
        versionGateReason(tag: 'v1.0.0+4', pubspecRaw: pubspec),
        contains('does not equal pubspec version'),
      );
    });

    test('fails when the tag lacks the v prefix', () {
      expect(
        versionGateReason(tag: '1.0.0+3', pubspecRaw: pubspec),
        contains('does not equal pubspec version'),
      );
    });

    test('fails when pubspec has no version line', () {
      expect(
        versionGateReason(tag: 'v1.0.0+3', pubspecRaw: 'name: foo\n'),
        contains('no `version:` line'),
      );
    });

    test('fails when pubspec version is not name+code', () {
      expect(
        versionGateReason(tag: 'v1.0.0', pubspecRaw: 'version: 1.0.0\n'),
        contains('not `<name>+<code>`'),
      );
    });

    test('fails when versionCode equals the previous release', () {
      expect(
        versionGateReason(
          tag: 'v1.0.0+3',
          pubspecRaw: pubspec,
          previousTag: 'v1.0.0+3',
        ),
        contains('not strictly greater'),
      );
    });

    test('fails when versionCode is lower than the previous release', () {
      expect(
        versionGateReason(
          tag: 'v1.0.0+3',
          pubspecRaw: pubspec,
          previousTag: 'v1.0.0+4',
        ),
        contains('not strictly greater'),
      );
    });

    test('fails when the previous tag is unparseable', () {
      expect(
        versionGateReason(
          tag: 'v1.0.0+3',
          pubspecRaw: pubspec,
          previousTag: 'nonsense',
        ),
        contains('cannot parse previous release tag'),
      );
    });

    test('ignores an empty previous tag', () {
      expect(
        versionGateReason(tag: 'v1.0.0+3', pubspecRaw: pubspec, previousTag: ''),
        isNull,
      );
    });
  });
}

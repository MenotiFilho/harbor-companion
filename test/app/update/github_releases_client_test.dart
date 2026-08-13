// Tests for the GitHub releases client's pure JSON mapper
// (lib/app/update/github_releases_client.dart). Pins the `/releases/latest`
// wire shape: versionCode parsed from `tag_name`, prerelease/draft skipped,
// and a 404-style "no releases" body mapped to null.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/update/github_releases_client.dart';

void main() {
  test('parses a real release tag into versionCode + versionName + notes', () {
    final info = parseLatestRelease(jsonEncode({
      'tag_name': 'v1.4.0+7',
      'name': '1.4.0',
      'prerelease': false,
      'draft': false,
      'body': 'Fixes the thing',
    }));
    expect(info, isNotNull);
    expect(info!.versionCode, 7);
    expect(info.versionName, '1.4.0');
    expect(info.tagName, 'v1.4.0+7');
    expect(info.notes, 'Fixes the thing');
  });

  test('skips a prerelease', () {
    expect(
      parseLatestRelease(jsonEncode({
        'tag_name': 'v1.4.0+7',
        'prerelease': true,
        'draft': false,
      })),
      isNull,
    );
  });

  test('skips a draft', () {
    expect(
      parseLatestRelease(jsonEncode({
        'tag_name': 'v1.4.0+7',
        'prerelease': false,
        'draft': true,
      })),
      isNull,
    );
  });

  test('returns null when the tag has no parseable versionCode', () {
    expect(
      parseLatestRelease(jsonEncode({'tag_name': 'v1.4.0', 'prerelease': false, 'draft': false})),
      isNull,
    );
  });

  test('returns null on a "no releases" / non-release body', () {
    expect(parseLatestRelease(jsonEncode({'message': 'Not Found'})), isNull);
  });
}

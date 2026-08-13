// Tests for the GitHub releases client's pure JSON mapper
// (lib/app/update/github_releases_client.dart). Pins the `/releases/latest`
// wire shape: versionCode parsed from `tag_name`, prerelease/draft skipped,
// a 404-style "no releases" body mapped to null, and the APK asset's
// `browser_download_url` + `sha256:` digest extracted for the install half.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/update/github_releases_client.dart';

Map<String, dynamic> releaseJson({
  String tagName = 'v1.4.0+7',
  bool prerelease = false,
  bool draft = false,
  List<dynamic>? assets,
  String? body = 'Fixes the thing',
}) =>
    {
      'tag_name': tagName,
      'name': '1.4.0',
      'prerelease': prerelease,
      'draft': draft,
      'body': body,
      'assets': ?assets,
    };

List<dynamic> apkAsset({
  String name = 'harbor-companion.apk',
  String url = 'https://github.com/owner/repo/releases/download/v1.4.0+7/harbor-companion.apk',
  String digest = 'sha256:d6da28451a1e15cf7a75f2c3f151befad3b80ad0bb232ab15c20897e54f21478',
}) =>
    [
      {'name': name, 'browser_download_url': url, 'digest': digest},
    ];

void main() {
  test('parses a real release tag into versionCode + versionName + notes', () {
    final info = parseLatestRelease(jsonEncode(releaseJson(assets: apkAsset())));
    expect(info, isNotNull);
    expect(info!.versionCode, 7);
    expect(info.versionName, '1.4.0');
    expect(info.tagName, 'v1.4.0+7');
    expect(info.notes, 'Fixes the thing');
  });

  test('extracts the APK asset download url and hex digest', () {
    final info = parseLatestRelease(jsonEncode(releaseJson(assets: apkAsset())));
    expect(info!.downloadUrl,
        'https://github.com/owner/repo/releases/download/v1.4.0+7/harbor-companion.apk');
    expect(info.sha256,
        'd6da28451a1e15cf7a75f2c3f151befad3b80ad0bb232ab15c20897e54f21478');
  });

  test('picks the APK asset among non-APK assets', () {
    final info = parseLatestRelease(jsonEncode(releaseJson(assets: [
      {'name': 'SHA256SUMS', 'browser_download_url': 'https://x/sums', 'digest': 'sha256:aaaa'},
      ...apkAsset(),
    ])));
    expect(info!.downloadUrl, contains('harbor-companion.apk'));
  });

  test('returns null when there is no APK asset', () {
    expect(parseLatestRelease(jsonEncode(releaseJson())), isNull);
  });

  test('returns null when the APK asset has no sha256 digest', () {
    final info = parseLatestRelease(jsonEncode(releaseJson(assets: [
      {'name': 'harbor-companion.apk', 'browser_download_url': 'https://x/a.apk'},
    ])));
    expect(info, isNull);
  });

  test('skips a prerelease', () {
    expect(
      parseLatestRelease(jsonEncode(releaseJson(prerelease: true, assets: apkAsset()))),
      isNull,
    );
  });

  test('skips a draft', () {
    expect(
      parseLatestRelease(jsonEncode(releaseJson(draft: true, assets: apkAsset()))),
      isNull,
    );
  });

  test('returns null when the tag has no parseable versionCode', () {
    expect(
      parseLatestRelease(jsonEncode(releaseJson(tagName: 'v1.4.0', assets: apkAsset()))),
      isNull,
    );
  });

  test('returns null on a "no releases" / non-release body', () {
    expect(parseLatestRelease(jsonEncode({'message': 'Not Found'})), isNull);
  });
}

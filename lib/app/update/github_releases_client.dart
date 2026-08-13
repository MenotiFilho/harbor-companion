// GitHub Releases HTTP seam (ticket 28).
//
// `ReleasesClient` fetches the latest published release and folds it into a
// `ReleaseInfo` (versionCode parsed from the `v<name>+<code>` tag). The real
// implementation (dart:io) hits GitHub directly — no `/api-proxy`. The
// `/releases/latest` endpoint already skips prerelease/draft and returns 404
// when the repo has no releases, so `null` is "no update", distinct from a
// thrown network/HTTP failure (which the controller catches and quiets).
//
// The pure JSON mapper is top-level so tests pin the wire shape without
// network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'update_reducer.dart';

const String githubOwner = 'MenotiFilho';
const String githubRepo = 'harbor-companion';

/// Parses a `/releases/latest` JSON body into a [ReleaseInfo], or null when
/// there is no usable release (a 404 body / no tag / prerelease / draft / no
/// downloadable APK asset with a `sha256:` digest).
ReleaseInfo? parseLatestRelease(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return null;
  if (decoded['prerelease'] == true || decoded['draft'] == true) return null;
  final tag = decoded['tag_name'] as String?;
  if (tag == null) return null;
  final code = parseVersionCodeFromTag(tag);
  if (code == null) return null;

  // The install half needs a downloadable APK asset: its browser_download_url
  // (not the api.github.com URL) and its `sha256:` digest (hex for ota_update).
  String? downloadUrl;
  String? sha256;
  final assets = decoded['assets'];
  if (assets is List) {
    for (final asset in assets) {
      if (asset is! Map<String, dynamic>) continue;
      final name = asset['name'];
      final url = asset['browser_download_url'];
      final digest = asset['digest'];
      if (name is String &&
          name.endsWith('.apk') &&
          url is String &&
          digest is String &&
          digest.startsWith('sha256:')) {
        downloadUrl = url;
        sha256 = digest.substring('sha256:'.length);
        break;
      }
    }
  }
  if (downloadUrl == null || sha256 == null) return null;

  return ReleaseInfo(
    versionCode: code,
    versionName: parseVersionNameFromTag(tag),
    tagName: tag,
    notes: decoded['body'] as String?,
    downloadUrl: downloadUrl,
    sha256: sha256,
  );
}

abstract interface class ReleasesClient {
  /// The latest non-prerelease, non-draft release, or null when the repo has
  /// none. Throws on network/HTTP failure (the controller catches + quiets).
  Future<ReleaseInfo?> fetchLatestRelease();
}

/// Real releases client over dart:io HTTP, unauthenticated (the 60/hr
/// anonymous rate limit is far above a launch-only check).
class HttpReleasesClient implements ReleasesClient {
  final Duration timeout;
  final String owner;
  final String repo;

  HttpReleasesClient({
    this.timeout = const Duration(seconds: 8),
    this.owner = githubOwner,
    this.repo = githubRepo,
  });

  @override
  Future<ReleaseInfo?> fetchLatestRelease() async {
    final url =
        Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest');
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(url);
      // The GitHub API requires a User-Agent header and an accept type.
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'harbor-companion')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(timeout);
      if (response.statusCode == HttpStatus.notFound) return null;
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode} for $url');
      }
      final raw = await response.transform(utf8.decoder).join();
      return parseLatestRelease(raw);
    } finally {
      client.close(force: true);
    }
  }
}

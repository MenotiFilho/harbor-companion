// Jikan (anime) seam + shared throttle (ticket 05).
//
// Jikan is rate-limited hard (HTTP 429); the reference client serializes
// requests ≥400ms apart with exponential backoff and a 4-attempt cap
// (jikan.ts:285-348). [JikanQueue] is the **single shared** 400ms-serialized
// queue: Search routes its `fetch:jikan` through it, and the Home catalog must
// route its Jikan rows through the same [jikanQueueProvider] so the two
// surfaces can never hammer the API concurrently.
//
// The pure JSON→model mappers are top-level so tests pin the wire shapes
// without network. Anime ids prefer `kitsu:` (resolved via
// `https://relations.yuna.moe/api/ids`) then `mal:` then `anilist:`
// (jikan.ts:210-216).
//
// Wire contract: docs/wire-contract.md §5.3.

library;

import 'dart:async';
import 'dart:convert';

import 'search_reducer.dart' show AnimeHit;

const String jikanBase = 'https://api.jikan.moe/v4';
const String relationsBase = 'https://relations.yuna.moe';

/// Thrown by the raw Jikan fetch when the upstream answers 429.
class JikanRateLimited implements Exception {
  const JikanRateLimited();
}

/// Parses a Jikan `/anime?q=…` response `{ "data": [...] }` into anime hits.
/// `kitsu`/`anilist` ids are resolved separately (best-effort) via
/// [parseAnimeIdRelations].
List<AnimeHit> parseJikanSearch(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return const [];
  final data = decoded['data'];
  if (data is! List) return const [];
  return [
    for (final item in data)
      if (item is Map<String, dynamic>) _parseJikanAnime(item),
  ];
}

AnimeHit _parseJikanAnime(Map<String, dynamic> j) {
  final images = j['images'];
  final jpg = images is Map<String, dynamic> ? images['jpg'] : null;
  final jpgMap = jpg is Map<String, dynamic> ? jpg : const <String, dynamic>{};
  return AnimeHit(
    malId: (j['mal_id'] as num?)?.toInt(),
    format: j['type'] as String?,
    name: j['title'] as String? ?? '',
    year: j['year'] is num ? '${j['year']}' : j['year'] as String?,
    poster: jpgMap['large_image_url'] as String? ?? jpgMap['image_url'] as String?,
    background: jpgMap['image_url'] as String?,
    overview: j['synopsis'] as String? ?? '',
  );
}

/// Parses a `relations.yuna.moe/api/ids` response into `(kitsuId, anilistId)`.
/// Tolerant of a missing/odd payload — a failed resolution just leaves the id
/// null (and [AnimeHit.metaId] falls back to `mal:`).
(int?, int?) parseAnimeIdRelations(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return (null, null);
    final kitsu = decoded['kitsu'];
    final anilist = decoded['anilist'];
    return (
      kitsu is num ? kitsu.toInt() : null,
      anilist is num ? anilist.toInt() : null,
    );
  } catch (_) {
    return (null, null);
  }
}

/// The shared Jikan throttle: serializes fetches ≥[spacing] apart with 429
/// backoff ([maxAttempts] attempts, 2s/4s/6s…). A non-429 error or exhausted
/// retries resolves to empty (a timeout is a fallback to empty, never an error).
///
/// A single instance is shared app-wide via [jikanQueueProvider]; Search and the
/// Home catalog both ride it.
class JikanQueue {
  final Future<List<AnimeHit>> Function(String query) fetch;
  final Duration spacing;
  final int maxAttempts;
  final Future<void> Function(Duration) _sleep;

  JikanQueue({
    required this.fetch,
    this.spacing = const Duration(milliseconds: 400),
    this.maxAttempts = 4,
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  Future<void> _chain = Future<void>.value();

  /// Enqueues a Jikan search. Calls are serialized ≥[spacing] apart; the caller
  /// always receives a value (never throws).
  Future<List<AnimeHit>> search(String query) {
    final completer = Completer<List<AnimeHit>>();
    _chain = _chain.then((_) async {
      List<AnimeHit> result;
      try {
        result = await _run(query);
      } catch (_) {
        result = const [];
      }
      completer.complete(result);
    });
    return completer.future;
  }

  Future<List<AnimeHit>> _run(String query) async {
    await _sleep(spacing);
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        return await fetch(query);
      } on JikanRateLimited {
        await _sleep(Duration(seconds: 2 * (attempt + 1)));
      }
    }
    return const [];
  }
}

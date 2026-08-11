import 'search_controller.dart';

// Throwaway host/source simulator for the Search prototype.
//
// Simulates the three data sources the real app fetches directly from the
// internet (no Harbor proxy — wire-contract §5):
//   - TMDB     search/multi  — only meaningful when snapshot.tmdbKey is present.
//   - Cinemeta catalog/{type}/top/search=<q>.json — always available, keyless.
//   - Jikan    /anime?q=…    — rate-limited (429); requests MUST ride a shared
//                              ≥400ms serialized queue + 429 backoff.
//
// The knobs (toggled from the TUI) exist to push the reducer's hard cases:
//   - tmdbKey   on/off       — keyless phone falls back to cinemeta rows.
//   - slowSource — a source sleeps past the 8s guard → SourceTimedOut.
//   - jikan429  on/off       — Jikan returns 429, exercising backoff, then
//                              succeeds after the queue drains.
//   - duplicateTitles on/off — cinemeta returns a same-title, same-year entry
//                              as TMDB → dedupeByTitle must drop it; anime
//                              returns a same-title hit → notAnimeDupe drops
//                              the film-row version.

class SourceSim {
  bool tmdbKeyed = true;
  Source? slowSource;
  bool jikan429 = false;
  bool duplicateTitles = false;

  // Shared Jikan throttle: every fetch is chained ≥400ms after the last one,
  // exactly like beta's throttledJikanFetch (jikan.ts:290-312). Two requests
  // in the same instant are serialized.
  final _jikanChain = Future<void>.value();
  int _jikanTotal = 0;
  int jikan429Hits = 0;

      Future<List<Meta>> tmdb(String q) => _run(Source.tmdb, () async {
            if (!tmdbKeyed) return const [];
            // search/multi → movies + series; first entry doubles as the top match.
            return [
              Meta(id: 'tmdb:movie:603', type: 'movie', name: 'The Matrix',
                  poster: 'https://image.tmdb.org/t/p/w500/matrix.jpg',
                  background: 'https://image.tmdb.org/t/p/w1280/matrix_bg.jpg',
                  releaseInfo: '1999'),
              Meta(id: 'tmdb:tv:1396', type: 'series', name: 'Breaking Bad',
                  poster: 'https://image.tmdb.org/t/p/w500/bb.jpg', releaseInfo: '2008'),
              Meta(id: 'tmdb:movie:120', type: 'movie', name: 'The Lord of the Rings',
                  poster: 'https://image.tmdb.org/t/p/w500/lotr.jpg', releaseInfo: '2001'),
            ];
          });

  Future<List<Meta>> cinemeta(String q) => _run(Source.cinemeta, () async {
        final base = <Meta>[
          Meta(id: 'tt0133093', type: 'movie', name: 'The Matrix',
              poster: 'https://images.stremio/matrix.jpg', releaseInfo: '1999'),
          Meta(id: 'tt0903747', type: 'series', name: 'Breaking Bad',
              poster: 'https://images.stremio/bb.jpg', releaseInfo: '2008'),
          Meta(id: 'tt0111161', type: 'movie', name: 'The Shawshank Redemption',
              poster: 'https://images.stremio/shawshank.jpg', releaseInfo: '1994'),
        ];
        if (duplicateTitles) {
          // Same title, SAME year as the TMDB Matrix entry → must be dropped by
          // dedupeByTitle (a remake would survive with a different year).
          base.add(Meta(id: 'tt9999999', type: 'movie', name: 'The Matrix',
              poster: 'https://images.stremio/matrix_dup.jpg', releaseInfo: '1999'));
        }
        return base;
      });

  Future<List<AnimeHit>> jikan(String q) => _jikan(() async {
        if (jikan429) {
          jikan429Hits++;
          throw const _Jikan429();
        }
        if (duplicateTitles) {
          // A hit whose name collides with the TMDB/cinemeta Matrix row: the
          // film row must vanish from movies, and the anime top-match replaces
          // the TMDB pinned card (mergeTopMatch).
          return [
            AnimeHit(malId: 1111, kitsuId: 2222, format: 'TV', name: 'The Matrix',
                year: '1998', poster: 'https://cdn.myanimelist.net/matrix_anime.jpg',
                overview: 'An animated take on the same name.'),
          ];
        }
        return [
          AnimeHit(malId: 16498, kitsuId: 6922, format: 'TV', name: 'Attack on Titan',
              year: '2013', poster: 'https://cdn.myanimelist.net/aot.jpg',
              overview: 'Humanity fights man-eating titans.'),
        ];
      });

  // -- plumbing --------------------------------------------------------------

  Future<List<Meta>> _run(Source src, Future<List<Meta>> Function() body) async {
    await _delay(slowSource == src ? const Duration(seconds: 9) : _latency(src));
    return body();
  }

  Future<List<AnimeHit>> _jikan(Future<List<AnimeHit>> Function() body) {
    _jikanTotal++;
    final slot = _jikanChain.then((_) async {
      await _delay(const Duration(milliseconds: 400)); // ≥400ms spacing
      if (slowSource == Source.jikan) await _delay(const Duration(seconds: 9));
      // 429 backoff: 2s, then 4s (beta caps at 4 attempts: jikan.ts:322-335).
      for (var attempt = 0; attempt < 4; attempt++) {
        try {
          return await body();
        } on _Jikan429 {
          await _delay(Duration(seconds: 2 * (attempt + 1)));
          if (slowSource == Source.jikan) await _delay(const Duration(seconds: 9));
        }
      }
      return const <AnimeHit>[];
    });
    // Chain keeps draining regardless of this call's outcome.
    return slot;
  }

  Duration _latency(Source src) => switch (src) {
        Source.tmdb => const Duration(milliseconds: 120),
        Source.cinemeta => const Duration(milliseconds: 300),
        Source.jikan => const Duration(milliseconds: 600),
      };

  Future<void> _delay(Duration d) => Future.delayed(d);

  int get jikanRequests => _jikanTotal;
}

class _Jikan429 implements Exception {
  const _Jikan429();
}

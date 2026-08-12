// Riverpod controller for Search (ticket 05).
//
// Thin glue between the pure reducer (search_reducer.dart) and the outside
// world. Drains the reducer's `effects` buffer into the search HTTP fetcher
// (`fetch:<source>`), arms the 180ms debounce timer and the 8s per-source
// guard, and routes `playMeta` through the WS client. Folds the host's
// `tmdbKey` (from snapshots) into the reducer so a keyless search downgrades to
// cinemeta and re-applies the moment a key lands (KeyChanged).
//
// Jikan goes through the single shared [jikanQueueProvider] so Search and the
// Home catalog can never hammer the API concurrently (ticket 05).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/meta.dart';
import '../remote/remote_controller.dart';
import '../ws/client_controller.dart';
import 'jikan.dart';
import 'search_fetcher.dart';
import 'search_reducer.dart';

/// Search fetch seam. Defaults to the real dart:io HTTP fetcher; tests override
/// with a fake.
final searchFetcherProvider =
    Provider<SearchFetcher>((ref) => HttpSearchFetcher());

/// The single shared Jikan throttle (Search + Home catalog). One instance
/// app-wide, so concurrent Jikan fetches are serialized regardless of surface.
final jikanQueueProvider = Provider<JikanQueue>((ref) {
  final fetcher = ref.watch(searchFetcherProvider);
  return JikanQueue(fetch: fetcher.searchJikan);
});

/// Debounce + source-guard windows. Defaults to the reducer's constants; tests
/// override to drive time.
final searchDebounceProvider = Provider<Duration>((ref) => debounceDelay);
final searchSourceTimeoutProvider = Provider<Duration>((ref) => sourceTimeout);

class SearchController extends Notifier<SearchState> {
  Timer? _debounceTimer;
  final Set<Timer> _sourceTimers = {};

  @override
  SearchState build() {
    ref.onDispose(() {
      _debounceTimer?.cancel();
      for (final t in _sourceTimers) {
        t.cancel();
      }
    });

    // Seed the current key, then re-run an active query whenever the host's
    // key changes in a snapshot (keyless → cinemeta only; key → TMDB joins).
    final currentKey = ref.read(wsClientControllerProvider).tmdbKey;
    ref.listen(wsClientControllerProvider, (previous, next) {
      if (next.tmdbKey != previous?.tmdbKey) {
        _dispatch(KeyChanged(next.tmdbKey));
      }
    });
    return SearchState(tmdbKey: currentKey);
  }

  // -- UI entry points -------------------------------------------------------

  void queryChanged(String query) => _dispatch(QueryChanged(query));

  void submit() => _dispatch(const Submit());

  void clear() => _dispatch(const Clear());

  void toggleHideAnime() => _dispatch(const ToggleHideAnime());

  void playMeta(Meta meta, {int? season, int? episode}) =>
      _dispatch(PlayMeta(meta, season: season, episode: episode));

  // -- The one place state mutates -------------------------------------------

  void _dispatch(SearchEvent event) {
    state = searchReduce(state, event);
    _drain(state);
  }

  void _drain(SearchState next) {
    if (next.effects.isEmpty) return;
    final effects = List<String>.from(next.effects);
    next.effects.clear();
    for (final effect in effects) {
      final parts = effect.split(':');
      switch (parts[0]) {
        case 'debounce':
          final id = int.parse(parts[1]);
          _armDebounce(id);
        case 'fetch':
          final src = Source.values.byName(parts[1]);
          final id = int.parse(parts[2]);
          final query = parts.sublist(3).join(':');
          _fireSource(src, id, query);
        case 'playMeta':
          _sendPlayMeta();
      }
    }
  }

  void _armDebounce(int id) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(ref.read(searchDebounceProvider), () {
      _debounceTimer = null;
      if (!ref.mounted) return;
      _dispatch(DebounceFired(id));
    });
  }

  Future<void> _fireSource(Source src, int id, String query) async {
    final future = _fetchSource(src, query);
    late final Timer timer;
    timer = Timer(ref.read(searchSourceTimeoutProvider), () {
      _sourceTimers.remove(timer);
      if (!ref.mounted) return;
      _dispatch(SourceTimedOut(id, src));
    });
    _sourceTimers.add(timer);
    try {
      final payload = await future;
      timer.cancel();
      _sourceTimers.remove(timer);
      if (!ref.mounted) return;
      _dispatch(SourceResult(id, src, payload));
    } catch (_) {
      timer.cancel();
      _sourceTimers.remove(timer);
      if (!ref.mounted) return;
      // A source error is a fallback to empty, never an error (8s guard).
      _dispatch(SourceTimedOut(id, src));
    }
  }

  Future<Object> _fetchSource(Source src, String query) {
    final fetcher = ref.read(searchFetcherProvider);
    return switch (src) {
      Source.tmdb => _fetchTmdb(fetcher, query),
      Source.cinemeta => fetcher.searchCinemeta(query),
      Source.jikan => ref.read(jikanQueueProvider).search(query),
    };
  }

  Future<TmdbSearchPayload> _fetchTmdb(SearchFetcher fetcher, String query) async {
    final key = state.tmdbKey;
    if (key == null) return const TmdbSearchPayload([], []);
    return fetcher.searchTmdb(query, key);
  }

  void _sendPlayMeta() {
    final command = state.pendingPlay;
    if (command == null) return;
    // The Remote layer owns the awaiting-start window (ticket 07).
    ref.read(remoteControllerProvider.notifier).playMeta(command);
  }
}

final searchControllerProvider =
    NotifierProvider<SearchController, SearchState>(SearchController.new);

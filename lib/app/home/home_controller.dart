// Riverpod controller for Home/catalog (ticket 04).
//
// Thin glue between the pure reducer (home_reducer.dart) and the outside
// world. Drains the reducer's `effects` buffer into the catalog HTTP fetcher
// (`fetch:rows`/`fetch:detail`) and the WS client (`playMeta`), and folds the
// host's `tmdbKey` into the reducer so rows auto-upgrade the moment a key
// arrives in a snapshot.
//
// The playMeta command goes through the WS client's own `sendCommand`, so it is
// rejected with a notice while disconnected (ticket 02) — the phone never
// resolves streams and never holds credentials (wire-contract §4).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ws/client_controller.dart';
import 'catalog_fetcher.dart';
import 'home_reducer.dart';
import 'meta.dart';

/// Catalog fetch seam. Defaults to the real dart:io HTTP fetcher; tests
/// override with a fake.
final catalogFetcherProvider =
    Provider<CatalogFetcher>((ref) => HttpCatalogFetcher());

class HomeController extends Notifier<HomeState> {
  @override
  HomeState build() {
    // Seed the current key, then upgrade/downgrade rows whenever the host's
    // key changes in a snapshot (the WS client persists + re-applies it).
    final currentKey = ref.read(wsClientControllerProvider).tmdbKey;
    ref.listen(wsClientControllerProvider, (previous, next) {
      if (next.tmdbKey != previous?.tmdbKey) {
        _dispatch(KeyChanged(next.tmdbKey));
      }
    });
    return HomeState(tmdbKey: currentKey);
  }

  void load() => _dispatch(const LoadHome());

  void openDetail(Meta meta) => _dispatch(OpenDetail(meta));

  void closeDetail() => _dispatch(const CloseDetail());

  void playMeta(Meta meta, {int? season, int? episode}) =>
      _dispatch(PlayMeta(meta, season: season, episode: episode));

  // -- The one place state mutates -------------------------------------------

  void _dispatch(HomeEvent event) {
    state = homeReduce(state, event);
    _drain(state);
  }

  void _drain(HomeState next) {
    if (next.effects.isEmpty) return;
    final effects = List<String>.from(next.effects);
    next.effects.clear();
    for (final effect in effects) {
      switch (effect) {
        case 'fetch:rows':
          _fetchRows();
        case 'fetch:detail':
          _fetchDetail();
        case 'playMeta':
          _sendPlayMeta();
      }
    }
  }

  Future<void> _fetchRows() async {
    final key = state.tmdbKey;
    try {
      final rows = await ref.read(catalogFetcherProvider).fetchRows(key);
      if (!ref.mounted) return;
      _dispatch(RowsLoaded(rows, key));
    } catch (error) {
      if (!ref.mounted) return;
      _dispatch(RowsFailed(error, key));
    }
  }

  Future<void> _fetchDetail() async {
    final pending = state.detail;
    if (pending == null || pending.status != DetailStatus.loading) return;
    final meta = pending.meta;
    try {
      // Use the key pinned at request time, not the current one — the id's
      // source (imdb vs tmdb:) must match the source that listed it.
      final detail = await ref
          .read(catalogFetcherProvider)
          .fetchDetail(meta.type, meta.id, pending.tmdbKey);
      if (!ref.mounted) return;
      _dispatch(DetailLoaded(meta, detail));
    } catch (error) {
      if (!ref.mounted) return;
      _dispatch(DetailFailed(meta, error));
    }
  }

  void _sendPlayMeta() {
    final command = state.pendingPlay;
    if (command == null) return;
    ref
        .read(wsClientControllerProvider.notifier)
        .sendCommand('playMeta', command.toPayload());
  }
}

final homeControllerProvider =
    NotifierProvider<HomeController, HomeState>(HomeController.new);

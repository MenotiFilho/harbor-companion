// Thin wiring tests for the Search controller (ticket 05). The reducer is the
// decision seam; these pin the glue: debounce timer → fan-out into the fetcher
// (TMDB only when keyed), per-source settlement → published results, tmdbKey
// folding from the WS client's snapshots, and playMeta routed through the
// Remote layer.

import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/meta.dart';
import 'package:harbor_companion/app/remote/remote_controller.dart';
import 'package:harbor_companion/app/remote/remote_reducer.dart';
import 'package:harbor_companion/app/search/jikan.dart';
import 'package:harbor_companion/app/search/search_controller.dart';
import 'package:harbor_companion/app/search/search_fetcher.dart';
import 'package:harbor_companion/app/search/search_reducer.dart';
import 'package:harbor_companion/app/ws/client_controller.dart';
import 'package:harbor_companion/app/ws/host_keys.dart';
import 'package:harbor_companion/app/ws/ws_transport.dart';

class FakeConnection implements WsConnection {
  final List<String> sent = [];
  final _frames = StreamController<String>.broadcast();
  @override
  Stream<String> get frames => _frames.stream;
  @override
  void send(String message) => sent.add(message);
  @override
  Future<void> close() async => _frames.close();

  void emit(String frame) => _frames.add(frame);
}

class FakeTransport implements WsTransport {
  final List<FakeConnection> connections = [];
  @override
  Future<WsConnection> open(String url) async {
    final c = FakeConnection();
    connections.add(c);
    return c;
  }
}

class FakeKeyStore implements HostKeyStore {
  HostKeys keys = const HostKeys();
  @override
  Future<HostKeys> load() async => keys;
  @override
  Future<void> save(HostKeys k) async {
    keys = k;
  }
}

class FakeSearchFetcher implements SearchFetcher {
  final List<String> tmdbQueries = [];
  final List<String> cineQueries = [];
  final List<String> jikanQueries = [];

  @override
  Future<TmdbSearchPayload> searchTmdb(String query, String tmdbKey) async {
    tmdbQueries.add(query);
    const matrix = Meta(id: 'tmdb:movie:1', type: 'movie', name: 'The Matrix', poster: 'p');
    return TmdbSearchPayload(
      const [matrix],
      const [Meta(id: 'tmdb:tv:2', type: 'series', name: 'The Matrix Animated')],
      const TopMatch(kind: 'movie', meta: matrix),
    );
  }

  @override
  Future<List<Meta>> searchCinemeta(String query) async {
    cineQueries.add(query);
    return const [Meta(id: 'tt0133093', type: 'movie', name: 'The Matrix', releaseInfo: '1999')];
  }

  @override
  Future<List<AnimeHit>> searchJikan(String query) async {
    jikanQueries.add(query);
    return const [AnimeHit(malId: 1, kitsuId: 2, format: 'TV', name: 'Attack on Titan')];
  }
}

Map<String, dynamic> snapshotFrame({int updatedAt = 1000, String? tmdbKey}) {
  return {
    't': 'snapshot',
    'snapshot': {
      'proto': 1,
      'idle': true,
      'updatedAt': updatedAt,
      'tmdbKey': ?tmdbKey,
    },
  };
}

void main() {
  late FakeTransport transport;
  late FakeKeyStore keyStore;
  late FakeSearchFetcher fetcher;
  late ProviderContainer container;

  Duration wsNow() => Duration(milliseconds: clock.now().millisecondsSinceEpoch);

  ProviderContainer makeContainer() {
    transport = FakeTransport();
    keyStore = FakeKeyStore();
    fetcher = FakeSearchFetcher();
    return ProviderContainer(
      overrides: [
        wsTransportProvider.overrideWithValue(transport),
        wsKeyStoreProvider.overrideWithValue(keyStore),
        wsClockProvider.overrideWithValue(wsNow),
        searchFetcherProvider.overrideWithValue(fetcher),
        jikanQueueProvider.overrideWithValue(
          JikanQueue(fetch: fetcher.searchJikan, spacing: Duration.zero),
        ),
      ],
    );
  }

  test('a keyless query debounces then fans out to cinemeta + jikan only', () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(wsClientControllerProvider.notifier).connect('192.168.1.50');
      async.flushMicrotasks();

      container.read(searchControllerProvider.notifier).queryChanged('matrix');
      expect(container.read(searchControllerProvider).status, SearchStatus.typing);
      async.elapse(debounceDelay);
      async.flushMicrotasks();

      expect(fetcher.tmdbQueries, isEmpty, reason: 'keyless → no TMDB');
      expect(fetcher.cineQueries, ['matrix']);
      expect(fetcher.jikanQueries, ['matrix']);

      async.flushMicrotasks();
      final state = container.read(searchControllerProvider);
      expect(state.status, SearchStatus.done);
      expect(state.results!.topMatch, isNull, reason: 'keyless → no top match');
      expect(state.results!.movies.single.id, 'tt0133093');
      addTearDown(container.dispose);
    });
  });

  test('a keyed host also fans out to TMDB and pins a top match', () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(wsClientControllerProvider.notifier).connect('192.168.1.50');
      async.flushMicrotasks();
      container.read(searchControllerProvider); // instantiate + listen to key
      transport.connections.single
          .emit(jsonEncode(snapshotFrame(tmdbKey: 'k', updatedAt: 1000)));
      async.flushMicrotasks();

      container.read(searchControllerProvider.notifier).queryChanged('matrix');
      async.elapse(debounceDelay);
      async.flushMicrotasks();

      expect(fetcher.tmdbQueries, ['matrix']);
      expect(fetcher.cineQueries, ['matrix']);

      async.flushMicrotasks();
      final state = container.read(searchControllerProvider);
      expect(state.status, SearchStatus.done);
      expect(state.results!.topMatch, isNotNull);
      expect(state.results!.topMatch!.meta.id, 'tmdb:movie:1');
      addTearDown(container.dispose);
    });
  });

  test('playMeta routes through the Remote layer (awaitingStart)', () async {
    container = makeContainer();
    container.read(wsClientControllerProvider.notifier).connect('192.168.1.50');
    await Future<void>.delayed(Duration.zero);

    container.read(searchControllerProvider);
    container.read(searchControllerProvider.notifier).playMeta(
          const Meta(id: 'tt1', type: 'movie', name: 'Shawshank'),
        );

    expect(container.read(remoteControllerProvider).phase, RemotePhase.awaitingStart);
    addTearDown(container.dispose);
  });
}

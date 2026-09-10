// Thin wiring tests for the Home controller (ticket 41). The reducer is the
// decision seam; these pin the glue that makes the Letterboxd rails track
// Settings: the config the controller passes to the fetcher, a manifest-URL /
// catalog-toggle change triggering a refetch, and an unrelated setting not
// refetching the catalog.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/catalog_fetcher.dart';
import 'package:harbor_companion/app/home/catalog_request.dart';
import 'package:harbor_companion/app/home/home_controller.dart';
import 'package:harbor_companion/app/letterboxd/letterboxd.dart';
import 'package:harbor_companion/app/home/meta.dart';
import 'package:harbor_companion/app/settings/settings_controller.dart';
import 'package:harbor_companion/app/settings/settings_store.dart';
import 'package:harbor_companion/app/ws/client_controller.dart';
import 'package:harbor_companion/app/ws/ws_transport.dart';

class FakeConnection implements WsConnection {
  final _frames = StreamController<String>.broadcast();
  @override
  Stream<String> get frames => _frames.stream;
  @override
  void send(String message) {}
  @override
  Future<void> close() async => _frames.close();
}

class FakeTransport implements WsTransport {
  @override
  Future<WsConnection> open(String url) async => FakeConnection();
}

/// Records the [CatalogRequest] handed to each `fetchRows` call.
class RecordingCatalogFetcher implements CatalogFetcher {
  final List<CatalogRequest> rowRequests = [];

  @override
  Future<List<HomeRow>> fetchRows(CatalogRequest request) async {
    rowRequests.add(request);
    return [
      HomeRow('Top Movies', [Meta(id: 'tt1', type: 'movie', name: 'The Matrix')]),
    ];
  }

  @override
  Future<DetailMeta> fetchDetail(String type, String id, String? tmdbKey) async =>
      DetailMeta(meta: Meta(id: id, type: type, name: 'Detail'));
}

/// Lets the settings restore + the resulting fetch microtasks settle.
Future<void> settle() => Future<void>.delayed(Duration.zero);

ProviderContainer make(RecordingCatalogFetcher fetcher, SettingsStore store) =>
    ProviderContainer(
      overrides: [
        wsTransportProvider.overrideWithValue(FakeTransport()),
        wsKeyStoreProvider.overrideWithValue(InMemoryHostKeyStore()),
        catalogFetcherProvider.overrideWithValue(fetcher),
        settingsStoreProvider.overrideWithValue(store),
      ],
    );

void main() {
  test('load passes the seeded Letterboxd config (URL empty, defaults on)', () async {
    final fetcher = RecordingCatalogFetcher();
    final container = make(fetcher, InMemorySettingsStore());
    addTearDown(container.dispose);

    container.read(homeControllerProvider.notifier).load();
    await settle();

    expect(fetcher.rowRequests, hasLength(1));
    expect(fetcher.rowRequests.single.letterboxd.manifestUrl, '');
    expect(
      fetcher.rowRequests.single.letterboxd.enabledCatalogIds,
      kDefaultLetterboxdCatalogIds,
    );
    expect(fetcher.rowRequests.single.showBuiltInCatalogs, isTrue);
  });

  test('setting the manifest URL refetches with the active config', () async {
    final fetcher = RecordingCatalogFetcher();
    final container = make(fetcher, InMemorySettingsStore());
    addTearDown(container.dispose);
    container.read(homeControllerProvider); // build + register the listener
    await settle();

    container
        .read(settingsControllerProvider.notifier)
        .setLetterboxdManifestUrl('https://api.stremboxd.com/stremio/abc/manifest.json');
    await settle();

    expect(fetcher.rowRequests, isNotEmpty);
    expect(
      fetcher.rowRequests.last.letterboxd.manifestUrl,
      'https://api.stremboxd.com/stremio/abc/manifest.json',
    );
  });

  test('toggling a catalog refetches with the updated enabled set', () async {
    final fetcher = RecordingCatalogFetcher();
    final container = make(fetcher, InMemorySettingsStore());
    addTearDown(container.dispose);
    container.read(homeControllerProvider);
    await settle();

    container
        .read(settingsControllerProvider.notifier)
        .setLetterboxdCatalogEnabled('letterboxd-friends', true);
    await settle();

    expect(
      fetcher.rowRequests.last.letterboxd.enabledCatalogIds,
      contains('letterboxd-friends'),
    );
  });

  test('toggling a built-in row off refetches with it disabled', () async {
    final fetcher = RecordingCatalogFetcher();
    final container = make(fetcher, InMemorySettingsStore());
    addTearDown(container.dispose);
    container.read(homeControllerProvider);
    await settle();

    container
        .read(settingsControllerProvider.notifier)
        .setBuiltInRowEnabled('cinemeta:top-movies', false);
    await settle();

    expect(
      fetcher.rowRequests.last.disabledBuiltInRowKeys,
      contains('cinemeta:top-movies'),
    );
  });

  test('reordering rows refetches with the new order', () async {
    final fetcher = RecordingCatalogFetcher();
    final container = make(fetcher, InMemorySettingsStore());
    addTearDown(container.dispose);
    container.read(homeControllerProvider);
    await settle();

    container.read(settingsControllerProvider.notifier).moveHomeRow(0, 2);
    await settle();

    expect(fetcher.rowRequests.last.rowOrder[2], 'cinemeta:top-movies');
  });

  test('an unrelated setting change does not refetch the catalog', () async {
    final fetcher = RecordingCatalogFetcher();
    final container = make(fetcher, InMemorySettingsStore());
    addTearDown(container.dispose);
    container.read(homeControllerProvider.notifier).load();
    await settle();
    final calls = fetcher.rowRequests.length;

    container
        .read(settingsControllerProvider.notifier)
        .setShowPlaybackLocation(true);
    await settle();

    expect(fetcher.rowRequests.length, calls);
  });

  test('a persisted URL restored at startup refetches with it', () async {
    final fetcher = RecordingCatalogFetcher();
    final store = InMemorySettingsStore();
    await store.saveLetterboxdManifestUrl('https://api.stremboxd.com/stremio/abc/manifest.json');
    final container = make(fetcher, store);
    addTearDown(container.dispose);

    container.read(homeControllerProvider); // seeds '' before the async restore
    await settle();

    expect(
      fetcher.rowRequests.last.letterboxd.manifestUrl,
      'https://api.stremboxd.com/stremio/abc/manifest.json',
    );
  });
}

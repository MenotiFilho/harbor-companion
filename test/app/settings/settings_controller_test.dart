// Wiring tests for the Settings controller (ticket 40). The controller is the
// single mutation point for the leaf boolean preferences; these pin the default
// (off), the toggle→persist glue, and the startup restore from the store. The
// store seam is the real in-memory implementation; persistence is asserted
// through its public load/save API rather than a duplicate fake.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/home/home_rows.dart';
import 'package:harbor_companion/app/letterboxd/letterboxd.dart';
import 'package:harbor_companion/app/settings/settings_controller.dart';
import 'package:harbor_companion/app/settings/settings_store.dart';

Future<ProviderContainer> make({bool show = false}) async {
  final store = InMemorySettingsStore();
  if (show) await store.saveShowPlaybackLocation(true);
  return ProviderContainer(
    overrides: [settingsStoreProvider.overrideWithValue(store)],
  );
}

void main() {
  test('defaults the playback location to hidden (off)', () async {
    final container = await make();
    addTearDown(container.dispose);
    expect(container.read(settingsControllerProvider).showPlaybackLocation, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(settingsControllerProvider).showPlaybackLocation, isFalse);
  });

  test('setShowPlaybackLocation updates state and persists it', () async {
    final store = InMemorySettingsStore();
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    container.read(settingsControllerProvider.notifier).setShowPlaybackLocation(true);
    expect(container.read(settingsControllerProvider).showPlaybackLocation, isTrue);
    expect(await store.loadShowPlaybackLocation(), isTrue);

    container.read(settingsControllerProvider.notifier).setShowPlaybackLocation(false);
    expect(container.read(settingsControllerProvider).showPlaybackLocation, isFalse);
    expect(await store.loadShowPlaybackLocation(), isFalse);
  });

  test('restores a persisted true on startup', () async {
    final container = await make(show: true);
    addTearDown(container.dispose);
    // Before the async restore resolves, the default (off) is in effect.
    expect(container.read(settingsControllerProvider).showPlaybackLocation, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(settingsControllerProvider).showPlaybackLocation, isTrue);
  });

  test('defaults the Letterboxd config: no URL, watchlist/recommended/popular on',
      () async {
    final container = await make();
    addTearDown(container.dispose);
    final state = container.read(settingsControllerProvider);
    expect(state.letterboxdManifestUrl, '');
    expect(state.enabledLetterboxdCatalogs, kDefaultLetterboxdCatalogIds);
    expect(state.disabledBuiltInRowKeys, isEmpty);
    expect(state.homeRowOrder, kDefaultHomeRowOrder);
  });

  test('setBuiltInRowEnabled updates state and persists', () async {
    final store = InMemorySettingsStore();
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final ctrl = container.read(settingsControllerProvider.notifier);

    ctrl.setBuiltInRowEnabled('cinemeta:top-movies', false);
    expect(
      container.read(settingsControllerProvider).disabledBuiltInRowKeys,
      contains('cinemeta:top-movies'),
    );
    expect(await store.loadDisabledBuiltInRowKeys(), contains('cinemeta:top-movies'));

    ctrl.setBuiltInRowEnabled('cinemeta:top-movies', true);
    expect(
      container.read(settingsControllerProvider).disabledBuiltInRowKeys,
      isEmpty,
    );
  });

  test('setAllBuiltInRowsEnabled(false) disables every built-in rail', () async {
    final store = InMemorySettingsStore();
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final ctrl = container.read(settingsControllerProvider.notifier);

    ctrl.setAllBuiltInRowsEnabled(false);
    final disabled = container.read(settingsControllerProvider).disabledBuiltInRowKeys;
    expect(disabled, hasLength(kCinemetaRows.length + kTmdbRows.length));
    expect(disabled, contains('tmdb:upcoming'));

    ctrl.setAllBuiltInRowsEnabled(true);
    expect(container.read(settingsControllerProvider).disabledBuiltInRowKeys, isEmpty);
  });

  test('moveHomeRow reorders and persists', () async {
    final store = InMemorySettingsStore();
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final ctrl = container.read(settingsControllerProvider.notifier);

    // Move the first row to index 2 (onReorderItem convention: final index).
    ctrl.moveHomeRow(0, 2);
    final order = container.read(settingsControllerProvider).homeRowOrder;
    expect(order[2], 'cinemeta:top-movies');
    expect(await store.loadHomeRowOrder(), order);
  });

  test('restores a persisted disabled row and order on startup', () async {
    final store = InMemorySettingsStore();
    await store.saveDisabledBuiltInRowKeys({'tmdb:upcoming'});
    await store.saveHomeRowOrder([
      'letterboxd:letterboxd-watchlist',
      ...kDefaultHomeRowOrder.where((k) => k != 'letterboxd:letterboxd-watchlist'),
    ]);
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    // Read once to build the controller (and kick off the async restore).
    expect(container.read(settingsControllerProvider).disabledBuiltInRowKeys, isEmpty);
    await Future<void>.delayed(Duration.zero);
    final state = container.read(settingsControllerProvider);
    expect(state.disabledBuiltInRowKeys, {'tmdb:upcoming'});
    expect(state.homeRowOrder.first, 'letterboxd:letterboxd-watchlist');
  });

  test('setLetterboxdManifestUrl trims, updates state and persists', () async {
    final store = InMemorySettingsStore();
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    container
        .read(settingsControllerProvider.notifier)
        .setLetterboxdManifestUrl('  https://api.stremboxd.com/stremio/abc/manifest.json  ');
    expect(
      container.read(settingsControllerProvider).letterboxdManifestUrl,
      'https://api.stremboxd.com/stremio/abc/manifest.json',
    );
    expect(
      await store.loadLetterboxdManifestUrl(),
      'https://api.stremboxd.com/stremio/abc/manifest.json',
    );
  });

  test('setLetterboxdCatalogEnabled adds/removes and persists', () async {
    final store = InMemorySettingsStore();
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final ctrl = container.read(settingsControllerProvider.notifier);

    ctrl.setLetterboxdCatalogEnabled('letterboxd-friends', true);
    expect(
      container.read(settingsControllerProvider).enabledLetterboxdCatalogs,
      contains('letterboxd-friends'),
    );
    expect(await store.loadEnabledLetterboxdCatalogs(), contains('letterboxd-friends'));

    ctrl.setLetterboxdCatalogEnabled('letterboxd-popular', false);
    expect(
      container.read(settingsControllerProvider).enabledLetterboxdCatalogs,
      isNot(contains('letterboxd-popular')),
    );
    expect(
      await store.loadEnabledLetterboxdCatalogs(),
      isNot(contains('letterboxd-popular')),
    );
  });

  test('restores a persisted Letterboxd URL and catalog set on startup', () async {
    final store = InMemorySettingsStore();
    await store.saveLetterboxdManifestUrl('https://x/manifest.json');
    await store.saveEnabledLetterboxdCatalogs({'letterboxd-top250'});
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    // Defaults hold until the async restore resolves.
    expect(container.read(settingsControllerProvider).letterboxdManifestUrl, '');
    await Future<void>.delayed(Duration.zero);
    final state = container.read(settingsControllerProvider);
    expect(state.letterboxdManifestUrl, 'https://x/manifest.json');
    expect(state.enabledLetterboxdCatalogs, {'letterboxd-top250'});
  });
}

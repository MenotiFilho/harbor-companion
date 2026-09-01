// Wiring tests for the Settings controller (ticket 40). The controller is the
// single mutation point for the leaf boolean preferences; these pin the default
// (off), the toggle→persist glue, and the startup restore from the store. The
// store seam is the real in-memory implementation; persistence is asserted
// through its public load/save API rather than a duplicate fake.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
}

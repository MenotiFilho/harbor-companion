// Riverpod controller for app settings (ticket 40).
//
// Persists a small set of user preferences through the `SettingsStore` seam.
// Unlike the playback/connect features there is no reducer here: each setting
// is a leaf boolean, so the controller is the single mutation point and the
// store is the persistence seam. Tests override `settingsStoreProvider` with an
// in-memory fake (or the whole controller provider with a stub); the real
// shared_preferences-backed store is wired in main().
//
// `showPlaybackLocation` gates the Remote's playback-location ("This PC" /
// cast) section. It defaults to off (hidden) and is restored on startup so the
// choice survives a restart.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_store.dart';

/// Settings persistence seam. Defaults to an in-memory store; the
/// shared_preferences-backed store is wired in main(). Tests override.
final settingsStoreProvider =
    Provider<SettingsStore>((ref) => InMemorySettingsStore());

class SettingsState {
  final bool showPlaybackLocation;

  const SettingsState({this.showPlaybackLocation = false});

  SettingsState copyWith({bool? showPlaybackLocation}) => SettingsState(
        showPlaybackLocation:
            showPlaybackLocation ?? this.showPlaybackLocation,
      );
}

class SettingsController extends Notifier<SettingsState> {
  @override
  SettingsState build() {
    _restore();
    return const SettingsState();
  }

  /// Loads the persisted preferences so an opted-in user keeps the playback
  /// location section across restarts.
  Future<void> _restore() async {
    final store = ref.read(settingsStoreProvider);
    final show = await store.loadShowPlaybackLocation();
    if (!ref.mounted) return;
    state = state.copyWith(showPlaybackLocation: show);
  }

  void setShowPlaybackLocation(bool value) {
    state = state.copyWith(showPlaybackLocation: value);
    ref.read(settingsStoreProvider).saveShowPlaybackLocation(value);
  }
}

final settingsControllerProvider =
    NotifierProvider<SettingsController, SettingsState>(SettingsController.new);

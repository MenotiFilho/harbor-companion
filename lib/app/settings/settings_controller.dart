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
// choice survives a restart. `letterboxdManifestUrl` + `enabledLetterboxdCatalogs`
// gate the Home's Stremboxd rails (ticket 41); both are restored on startup and
// the Home controller listens for changes.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../letterboxd/letterboxd.dart';
import 'settings_store.dart';

/// Settings persistence seam. Defaults to an in-memory store; the
/// shared_preferences-backed store is wired in main(). Tests override.
final settingsStoreProvider =
    Provider<SettingsStore>((ref) => InMemorySettingsStore());

class SettingsState {
  final bool showPlaybackLocation;

  /// The Stremboxd manifest URL (`''` when unset).
  final String letterboxdManifestUrl;

  /// The enabled Letterboxd catalog ids.
  final Set<String> enabledLetterboxdCatalogs;

  const SettingsState({
    this.showPlaybackLocation = false,
    this.letterboxdManifestUrl = '',
    this.enabledLetterboxdCatalogs = kDefaultLetterboxdCatalogIds,
  });

  SettingsState copyWith({
    bool? showPlaybackLocation,
    String? letterboxdManifestUrl,
    Set<String>? enabledLetterboxdCatalogs,
  }) =>
      SettingsState(
        showPlaybackLocation:
            showPlaybackLocation ?? this.showPlaybackLocation,
        letterboxdManifestUrl:
            letterboxdManifestUrl ?? this.letterboxdManifestUrl,
        enabledLetterboxdCatalogs:
            enabledLetterboxdCatalogs ?? this.enabledLetterboxdCatalogs,
      );
}

class SettingsController extends Notifier<SettingsState> {
  @override
  SettingsState build() {
    _restore();
    return const SettingsState();
  }

  /// Loads the persisted preferences so an opted-in user keeps the playback
  /// location section and Letterboxd config across restarts.
  Future<void> _restore() async {
    final store = ref.read(settingsStoreProvider);
    final show = await store.loadShowPlaybackLocation();
    final manifestUrl = await store.loadLetterboxdManifestUrl();
    final catalogIds = await store.loadEnabledLetterboxdCatalogs();
    if (!ref.mounted) return;
    state = state.copyWith(
      showPlaybackLocation: show,
      letterboxdManifestUrl: manifestUrl,
      enabledLetterboxdCatalogs: catalogIds,
    );
  }

  void setShowPlaybackLocation(bool value) {
    state = state.copyWith(showPlaybackLocation: value);
    ref.read(settingsStoreProvider).saveShowPlaybackLocation(value);
  }

  /// Sets the Stremboxd manifest URL (trimmed; `''` clears it).
  void setLetterboxdManifestUrl(String url) {
    final trimmed = url.trim();
    state = state.copyWith(letterboxdManifestUrl: trimmed);
    ref.read(settingsStoreProvider).saveLetterboxdManifestUrl(trimmed);
  }

  /// Enables/disables a single Letterboxd catalog rail.
  void setLetterboxdCatalogEnabled(String id, bool enabled) {
    final next = {...state.enabledLetterboxdCatalogs};
    if (enabled) {
      next.add(id);
    } else {
      next.remove(id);
    }
    state = state.copyWith(enabledLetterboxdCatalogs: next);
    ref.read(settingsStoreProvider).saveEnabledLetterboxdCatalogs(next);
  }
}

final settingsControllerProvider =
    NotifierProvider<SettingsController, SettingsState>(SettingsController.new);

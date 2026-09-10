// Riverpod controller for app settings (tickets 40, 41).
//
// Persists a small set of user preferences through the `SettingsStore` seam.
// Unlike the playback/connect features there is no reducer here: each setting
// is a leaf value, so the controller is the single mutation point and the store
// is the persistence seam. Tests override `settingsStoreProvider` with an
// in-memory fake (or the whole controller provider with a stub); the real
// shared_preferences-backed store is wired in main().
//
// Settings:
//   - `showPlaybackLocation` gates the Remote's playback-location section.
//   - `letterboxdManifestUrl` + `enabledLetterboxdCatalogs` gate the Home's
//     Stremboxd rails (ticket 41).
//   - `disabledBuiltInRowKeys` + `homeRowOrder` control which built-in rails
//     show and where every rail (built-in + Letterboxd) sits on Home. The Home
//     controller listens for any of these and refetches.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/home_rows.dart';
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

  /// Built-in row keys the user switched off.
  final Set<String> disabledBuiltInRowKeys;

  /// Every known row key (built-in + Letterboxd) in Home display order.
  final List<String> homeRowOrder;

  const SettingsState({
    this.showPlaybackLocation = false,
    this.letterboxdManifestUrl = '',
    this.enabledLetterboxdCatalogs = kDefaultLetterboxdCatalogIds,
    this.disabledBuiltInRowKeys = const {},
    this.homeRowOrder = kDefaultHomeRowOrder,
  });

  SettingsState copyWith({
    bool? showPlaybackLocation,
    String? letterboxdManifestUrl,
    Set<String>? enabledLetterboxdCatalogs,
    Set<String>? disabledBuiltInRowKeys,
    List<String>? homeRowOrder,
  }) =>
      SettingsState(
        showPlaybackLocation:
            showPlaybackLocation ?? this.showPlaybackLocation,
        letterboxdManifestUrl:
            letterboxdManifestUrl ?? this.letterboxdManifestUrl,
        enabledLetterboxdCatalogs:
            enabledLetterboxdCatalogs ?? this.enabledLetterboxdCatalogs,
        disabledBuiltInRowKeys:
            disabledBuiltInRowKeys ?? this.disabledBuiltInRowKeys,
        homeRowOrder: homeRowOrder ?? this.homeRowOrder,
      );
}

class SettingsController extends Notifier<SettingsState> {
  @override
  SettingsState build() {
    _restore();
    return const SettingsState();
  }

  /// Loads the persisted preferences so the user's choices survive restarts.
  Future<void> _restore() async {
    final store = ref.read(settingsStoreProvider);
    final show = await store.loadShowPlaybackLocation();
    final manifestUrl = await store.loadLetterboxdManifestUrl();
    final catalogIds = await store.loadEnabledLetterboxdCatalogs();
    final disabled = await store.loadDisabledBuiltInRowKeys();
    final order = await store.loadHomeRowOrder();
    if (!ref.mounted) return;
    state = state.copyWith(
      showPlaybackLocation: show,
      letterboxdManifestUrl: manifestUrl,
      enabledLetterboxdCatalogs: catalogIds,
      disabledBuiltInRowKeys: disabled,
      // Reconcile with the current app version's known rows (a new release may
      // add rails); unknown saved keys are dropped.
      homeRowOrder: normalizeRowOrder(order),
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

  /// Shows/hides a single built-in rail.
  void setBuiltInRowEnabled(String key, bool enabled) {
    final next = {...state.disabledBuiltInRowKeys};
    if (enabled) {
      next.remove(key);
    } else {
      next.add(key);
    }
    state = state.copyWith(disabledBuiltInRowKeys: next);
    ref.read(settingsStoreProvider).saveDisabledBuiltInRowKeys(next);
  }

  /// Shows/hides every built-in rail at once (the "only Letterboxd" shortcut).
  void setAllBuiltInRowsEnabled(bool enabled) {
    final next = enabled ? <String>{} : {for (final row in kAllBuiltInRows) row.id};
    state = state.copyWith(disabledBuiltInRowKeys: next);
    ref.read(settingsStoreProvider).saveDisabledBuiltInRowKeys(next);
  }

  /// Moves the row at [oldIndex] to [newIndex] and persists the new order.
  /// [newIndex] is the final index (the `onReorderItem` convention).
  void moveHomeRow(int oldIndex, int newIndex) {
    final order = [...state.homeRowOrder];
    if (oldIndex < 0 || oldIndex >= order.length) return;
    final target = newIndex.clamp(0, order.length - 1);
    final key = order.removeAt(oldIndex);
    order.insert(target, key);
    state = state.copyWith(homeRowOrder: order);
    ref.read(settingsStoreProvider).saveHomeRowOrder(order);
  }
}

final settingsControllerProvider =
    NotifierProvider<SettingsController, SettingsState>(SettingsController.new);

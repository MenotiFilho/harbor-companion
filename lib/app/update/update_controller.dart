// Riverpod controller for the self-update check half (ticket 28).
//
// Thin glue between the pure reducer (update_reducer.dart) and the outside
// world: the GitHub releases client (HTTP) and the version provider
// (`package_info_plus` build number). It drains the reducer's `check:<seq>`
// effect into the client, folds the result/failure back in as
// [RemoteResult]/[NoRelease]/[CheckFailed], loads the local versionCode before
// firing the launch check, and logs `fail:<reason>` quietly — never a modal,
// never an auto-retry. Returning to the foreground is [SetForegrounded] and
// never re-checks, so cold start + foreground return can't double-fire.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'github_releases_client.dart';
import 'update_reducer.dart';
import 'version_provider.dart';

/// Version provider seam. Defaults to package_info_plus; tests override.
final selfUpdateVersionProvider =
    Provider<VersionProvider>((ref) => PackageInfoVersionProvider());

/// GitHub releases client seam. Defaults to the real dart:io HTTP client;
/// tests override with a fake.
final releasesClientProvider =
    Provider<ReleasesClient>((ref) => HttpReleasesClient());

class SelfUpdateController extends Notifier<SelfUpdateState> {
  bool _launched = false;

  @override
  SelfUpdateState build() {
    _init();
    return SelfUpdateState();
  }

  /// Loads the local version, then fires the one launch check. Mirrors the
  /// connect controller's `_restore()` → `Launch` ordering so the local
  /// versionCode is always present before a [RemoteResult] can be compared.
  Future<void> _init() async {
    final version = await ref.read(selfUpdateVersionProvider).load();
    if (!ref.mounted) return;
    _dispatch(LocalVersionLoaded(version.code, version.name));
    if (!_launched) {
      _launched = true;
      _dispatch(const Launch());
    }
  }

  // -- UI entry points -------------------------------------------------------

  /// Manual "Check for updates" from Settings; reuses the same check path.
  void checkNow() => _dispatch(const CheckRequested());

  void setForegrounded(bool value) => _dispatch(SetForegrounded(value));

  void dismissPrompt() => _dispatch(const DismissPrompt());

  // -- The one place state mutates -------------------------------------------

  void _dispatch(SelfUpdateEvent event) {
    state = updateReduce(state, event);
    _drain(state);
  }

  /// Maps the effects buffer onto the side-channels.
  void _drain(SelfUpdateState next) {
    if (next.effects.isEmpty) return;
    final effects = List<String>.from(next.effects);
    next.effects.clear();
    for (final effect in effects) {
      if (effect.startsWith('check:')) {
        final seq = int.parse(effect.substring('check:'.length));
        _runCheck(seq);
      } else if (effect == 'prompt') {
        // No side-channel: the UI reads `promptVisible` and shows the dialog.
      } else if (effect.startsWith('fail:')) {
        // Quiet: a network failure is logged, never surfaced as a modal.
        debugPrint('self-update check failed: ${effect.substring('fail:'.length)}');
      }
    }
  }

  Future<void> _runCheck(int seq) async {
    try {
      final info = await ref.read(releasesClientProvider).fetchLatestRelease();
      if (!ref.mounted) return;
      if (info == null) {
        _dispatch(NoRelease(seq));
      } else {
        _dispatch(RemoteResult(seq, info));
      }
    } catch (e) {
      if (!ref.mounted) return;
      _dispatch(CheckFailed(seq, '$e'));
    }
  }
}

final selfUpdateControllerProvider =
    NotifierProvider<SelfUpdateController, SelfUpdateState>(
  SelfUpdateController.new,
);

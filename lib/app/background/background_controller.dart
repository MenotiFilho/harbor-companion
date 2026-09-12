// Thin controller for the persistent-connection foreground service (#64).
//
// Folds the connect layer's active-host signal, the Settings toggle, the app
// lifecycle, and the platform's notification-action stream into
// [BackgroundEvent]s, drains the reducer's effects onto the [BackgroundPlatform]
// seam, and folds the platform's start/stop results back in as events. It makes
// no decision of its own.
//
// The reconnect schedule is untouched: this module never pauses or resumes it
// (ADR-0006). The service is scoped to the connection, not to playback.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connect/connect_controller.dart';
import '../connect/connect_reducer.dart';
import '../remote/remote_controller.dart';
import '../settings/settings_controller.dart';
import '../shell/shell_controller.dart';
import 'background_notification_view.dart';
import 'background_platform.dart';
import 'background_reducer.dart';

/// Platform seam. Defaults to a safe no-op so tests never touch Android; main()
/// overrides it with the flutter_foreground_task-backed adapter.
final backgroundPlatformProvider =
    Provider<BackgroundPlatform>((ref) => const NoopBackgroundPlatform());

/// An active host is one that connected, or an established connection being
/// retried. A host that has never connected (`connecting` / `failed`) gets no
/// service, and an explicit disconnect (`idle`) tears it down.
bool backgroundServiceActive(ConnectState s) =>
    s.phase == ConnPhase.connected || s.phase == ConnPhase.reconnecting;

class BackgroundController extends Notifier<BackgroundState> {
  StreamSubscription<BackgroundAction>? _actionsSub;

  @override
  BackgroundState build() {
    ref.onDispose(() => _actionsSub?.cancel());

    // Connect lifecycle → active host + display name.
    ref.listen(connectControllerProvider, (previous, next) {
      _dispatch(ConnectionChanged(
        backgroundServiceActive(next),
        next.selected?.name,
      ));
    });
    // Settings toggle → keep-connection opt-out.
    ref.listen(settingsControllerProvider, (previous, next) {
      _dispatch(KeepConnectionChanged(next.keepConnectionInBackground));
    });
    // Derived now-playing view → idle ↔ media morph (#65). Riverpod v3 computes
    // a derived Provider lazily, and a `ref.listen` on the view itself does not
    // fire until something reads it; re-read it whenever either of its inputs
    // changes instead. The read is deferred a microtask: reading it inside the
    // dependency's own listener would still see the previous cached value. A
    // socket drop clears the Remote's `nowPlaying` at once, so this nulls the
    // surface immediately (never a stale paused surface).
    void foldNotificationView() {
      scheduleMicrotask(() {
        if (!ref.mounted) return;
        _dispatch(NowPlayingChanged(ref.read(backgroundNotificationViewProvider)));
      });
    }

    ref.listen(connectionStatusProvider, (previous, next) => foldNotificationView());
    ref.listen(remoteControllerProvider, (previous, next) => foldNotificationView());
    // Notification actions → the reducer (which ignores them for now).
    _actionsSub = ref.read(backgroundPlatformProvider).actions.listen(
          (action) => _dispatch(NotificationActionReceived(action)),
          onError: (Object _) {},
        );

    // Seed from the current values: the connect/settings/remote controllers may
    // already be built (e.g. the shell instantiates connect at startup). The
    // seed may emit a start effect, drained on the next microtask so build()
    // stays pure. Media is folded first so a start mid-playback posts the media
    // surface, not the idle status.
    final connect = ref.read(connectControllerProvider);
    final settings = ref.read(settingsControllerProvider);
    final media = ref.read(backgroundNotificationViewProvider);
    var initial = backgroundReduce(BackgroundState(), NowPlayingChanged(media));
    initial = backgroundReduce(
      initial,
      ConnectionChanged(
        backgroundServiceActive(connect),
        connect.selected?.name,
      ),
    );
    initial = backgroundReduce(
      initial,
      KeepConnectionChanged(settings.keepConnectionInBackground),
    );
    scheduleMicrotask(() {
      if (ref.mounted) _drain(initial);
    });
    return initial;
  }

  /// Lifecycle from main.dart's WidgetsBindingObserver.
  void setForegrounded(bool foregrounded) =>
      _dispatch(ForegroundChanged(foregrounded));

  // -- The one place state mutates -------------------------------------------

  void _dispatch(BackgroundEvent event) {
    state = backgroundReduce(state, event);
    _drain(state);
  }

  /// Maps the effects buffer onto the platform seam.
  void _drain(BackgroundState next) {
    if (next.effects.isEmpty) return;
    final effects = List<String>.from(next.effects);
    next.effects.clear();
    for (final effect in effects) {
      switch (effect) {
        case 'startService':
          _startService();
        case 'updateService':
          _updateService();
        case 'stopService':
          _stopService();
      }
    }
  }

  Future<void> _startService() async {
    try {
      await ref.read(backgroundPlatformProvider).startService(state.notification);
      if (!ref.mounted) return;
      _dispatch(const ServiceStarted());
    } catch (e) {
      // Android 12+ background-start restriction / Android 14+ missing type
      // permission / engine failure: degrade honestly instead of crashing.
      if (!ref.mounted) return;
      _dispatch(ServiceStartFailed('$e'));
    }
  }

  Future<void> _updateService() async {
    try {
      await ref.read(backgroundPlatformProvider).updateService(state.notification);
    } catch (_) {
      // The service is still running; a failed notification refresh must not
      // tear it down or wedge the state. The next host change tries again.
    }
  }

  Future<void> _stopService() async {
    try {
      await ref.read(backgroundPlatformProvider).stopService();
    } catch (_) {
      // The service was not running (or the platform refused the stop): either
      // way it is down, so fold it as stopped.
    } finally {
      if (ref.mounted) _dispatch(const ServiceStopped());
    }
  }
}

final backgroundControllerProvider =
    NotifierProvider<BackgroundController, BackgroundState>(
  BackgroundController.new,
);

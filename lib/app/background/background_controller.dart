// Thin controller for the persistent-connection foreground service (#64).
//
// Folds the connect layer's active-host signal, the Settings toggle, the app
// lifecycle, the platform's notification-action stream, the OS
// notification-permission status, and the live socket status into
// [BackgroundEvent]s, drains the reducer's effects onto the [BackgroundPlatform]
// seam, and folds the platform's results back in as events. It makes no
// decision of its own.
//
// The reconnect schedule is untouched: this module never pauses or resumes it
// (ADR-0006). The service is scoped to the connection, not to playback. A
// denied notification permission (#67) is a degradation: it never stops the
// service; the reducer only avoids offering the rationale again.
//
// Battery / OEM onboarding (#68): the exemption check runs at startup and on
// every foreground return; Settings drives the direct request / list /
// generic-settings effects. The reactive nudge is decided purely in the
// reducer from the injected clock's timestamps (background stretch + throttle);
// this controller only stamps the lifecycle event and feeds the socket status.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connect/connect_controller.dart';
import '../connect/connect_reducer.dart';
import '../remote/remote_controller.dart';
import '../settings/settings_controller.dart';
import '../shell/shell_controller.dart';
import '../shell/shell_reducer.dart' show ConnectionStatus;
import 'background_notification_view.dart';
import 'background_platform.dart';
import 'background_reducer.dart';
import 'open_remote_request.dart';

/// Platform seam. Defaults to a safe no-op so tests never touch Android; main()
/// overrides it with the flutter_foreground_task-backed adapter.
final backgroundPlatformProvider =
    Provider<BackgroundPlatform>((ref) => const NoopBackgroundPlatform());

/// Default clock: epoch milliseconds. Tests override with a manual clock so the
/// reactive battery nudge's background-stretch and throttle windows are
/// deterministic.
final backgroundClockProvider = Provider<int Function()>(
  (ref) => () => DateTime.now().millisecondsSinceEpoch,
);

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

    // Connect lifecycle → active host + display name. `reconnecting` rides
    // along so the idle notification can show `Reconnecting…` (ADR-0005)
    // instead of a stale `Connected to <host>`.
    ref.listen(connectControllerProvider, (previous, next) {
      _dispatch(ConnectionChanged(
        backgroundServiceActive(next),
        next.selected?.name,
        reconnecting: next.phase == ConnPhase.reconnecting,
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

    ref.listen(connectionStatusProvider, (previous, next) {
      // The live socket status feeds the reactive battery nudge ("was the
      // socket down on resume"), distinct from the active-host signal above.
      _dispatch(SocketConnectionChanged(next == ConnectionStatus.connected));
      foldNotificationView();
    });
    ref.listen(remoteControllerProvider, (previous, next) => foldNotificationView());
    // Notification actions → the reducer (which only records them, so a
    // dismissal can never stop the service) and then onto the host: every
    // transport action calls the existing RemoteController method on the main
    // isolate, so it sends exactly the wire command the app would (#66).
    _actionsSub = ref.read(backgroundPlatformProvider).actions.listen(
          (action) {
            _dispatch(NotificationActionReceived(action));
            _applyAction(action);
          },
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
    final socketConnected =
        ref.read(connectionStatusProvider) == ConnectionStatus.connected;
    var initial = backgroundReduce(BackgroundState(), NowPlayingChanged(media));
    initial = backgroundReduce(
      initial,
      ConnectionChanged(
        backgroundServiceActive(connect),
        connect.selected?.name,
        reconnecting: connect.phase == ConnPhase.reconnecting,
      ),
    );
    initial = backgroundReduce(
      initial,
      KeepConnectionChanged(settings.keepConnectionInBackground),
    );
    initial = backgroundReduce(initial, SocketConnectionChanged(socketConnected));
    scheduleMicrotask(() {
      if (ref.mounted) _drain(initial);
    });
    // The OS permission is unknown at build; check it asynchronously. Until it
    // lands the reducer treats it as granted, so a first connect can never fire
    // the OS prompt cold.
    scheduleMicrotask(_refreshNotificationPermission);
    // The battery-exemption state is likewise unknown at build; check it so
    // Settings is honest from the first open.
    scheduleMicrotask(_refreshBatteryExemption);
    // A process the OS killed and relaunched has no in-memory background entry;
    // restore the persisted one so the reactive nudge (#68) can still decide.
    scheduleMicrotask(_restoreBackgroundedAtMs);
    return initial;
  }

  /// Lifecycle from main.dart's WidgetsBindingObserver.
  void setForegrounded(bool foregrounded) {
    _dispatch(ForegroundChanged(foregrounded, atMs: _nowMs()));
    if (foregrounded) {
      // The user may have changed the OS state in Android settings; re-check so
      // the Settings rows stay honest. The battery nudge decision already ran in
      // the reducer from the event's timestamp.
      _refreshNotificationPermission();
      _refreshBatteryExemption();
      // The stretch has been consumed; a later cold start must not replay it.
      _persistBackgroundedAtMs(null);
    } else {
      // Persist the entry time so an OEM kill + relaunch can still evaluate the
      // nudge (the same-process path uses the in-memory value).
      _persistBackgroundedAtMs(state.backgroundedAtMs);
    }
  }

  /// Restores the persisted background-entry timestamp on cold start, falling
  /// back to any in-memory value, and replays it through the reducer's resume
  /// fold. Runs once per process; a no-op when there is nothing to restore.
  Future<void> _restoreBackgroundedAtMs() async {
    final int? persisted;
    try {
      persisted = await ref.read(settingsStoreProvider).loadBackgroundedAtMs();
    } catch (_) {
      return;
    }
    // The app may already have backgrounded by the time the async load lands;
    // that is the live path, not a cold-start replay.
    if (!ref.mounted || !state.foregrounded) return;
    final restored = persisted ?? state.backgroundedAtMs;
    if (restored == null) return;
    _dispatch(BackgroundedAtRestored(restored, _nowMs()));
    // The stretch has been consumed; don't let a later cold start replay it.
    _persistBackgroundedAtMs(null);
  }

  void _persistBackgroundedAtMs(int? ms) {
    ref.read(settingsStoreProvider).saveBackgroundedAtMs(ms);
  }

  int _nowMs() => ref.read(backgroundClockProvider)();

  // -- Notification permission (#67) -----------------------------------------

  /// Re-reads the OS permission state. Called at startup and on each foreground
  /// return.
  void refreshNotificationPermission() => _refreshNotificationPermission();

  /// Manual re-ask from Settings (the caller has shown the rationale already).
  void requestNotificationPermission() =>
      _dispatch(const NotificationPermissionRequested());

  /// Manual deep-link from Settings when Android will no longer ask.
  void openNotificationSettings() =>
      _dispatch(const NotificationSettingsRequested());

  /// The shell accepted the automatic rationale.
  void acceptNotificationRationale() =>
      _dispatch(const NotificationRationaleAccepted());

  /// The shell declined the automatic rationale.
  void declineNotificationRationale() =>
      _dispatch(const NotificationRationaleDeclined());

  Future<void> _refreshNotificationPermission() async {
    try {
      final status = await ref
          .read(backgroundPlatformProvider)
          .checkNotificationPermission();
      if (!ref.mounted) return;
      _dispatch(NotificationPermissionChanged(status));
    } catch (_) {
      // Keep the last known status; the next foreground retries.
    }
  }

  // -- Battery / OEM onboarding (#68) ----------------------------------------

  /// Re-reads the battery-exemption state. Called at startup, on each foreground
  /// return, and after the user visits an OS battery screen.
  void checkBatteryExemption() => _refreshBatteryExemption();

  /// Fires the direct exemption request from Settings. If Android has no direct
  /// handler, the reducer falls back to the optimization list.
  void requestBatteryExemption() =>
      _dispatch(const BatteryExemptionRequested());

  /// Opens the optimization list explicitly (the fallback route).
  void openBatteryOptimizationSettings() =>
      _dispatch(const BatteryOptimizationListRequested());

  /// Opens the generic system battery-settings screen (the OEM tips action).
  void openBatterySettings() => _dispatch(const BatterySettingsRequested());

  /// Dismisses the reactive battery nudge and feeds the throttle.
  void dismissBatteryNudge() =>
      _dispatch(BatteryNudgeDismissed(atMs: _nowMs()));

  Future<void> _refreshBatteryExemption() async {
    try {
      final exempt = await ref
          .read(backgroundPlatformProvider)
          .isIgnoringBatteryOptimizations();
      if (!ref.mounted) return;
      _dispatch(BatteryExemptionChanged(exempt));
    } catch (_) {
      // Keep the last known state; the next foreground/settings open retries.
    }
  }

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
        case 'updateMediaSession':
          _updateMediaSession();
        case 'stopService':
          _stopService();
        case 'requestPermission':
          _requestNotificationPermission();
        case 'openNotificationSettings':
          _openNotificationSettings();
        case 'requestBatteryExemption':
          _requestBatteryExemption();
        case 'openBatteryOptimizationSettings':
          _openBatteryOptimizationSettings();
        case 'openBatterySettings':
          _openBatterySettings();
      }
    }
  }

  /// Maps a tapped notification action onto the existing [RemoteController]
  /// methods (ADR-0005). No optimistic state: the surface corrects on the next
  /// snapshot. Gating matches the surface: prev/next only when the snapshot
  /// reported them, so a stale button can never send a command.
  void _applyAction(BackgroundAction action) {
    switch (action) {
      case BackgroundOpened():
        ref.read(openRemoteRequestProvider.notifier).request();
      case BackgroundTogglePlay():
        if (state.media != null) {
          ref.read(remoteControllerProvider.notifier).togglePlay();
        }
      case BackgroundPrevious():
        if (state.media?.hasPrevEpisode ?? false) {
          ref.read(remoteControllerProvider.notifier).prevEpisode();
        }
      case BackgroundNext():
        if (state.media?.hasNextEpisode ?? false) {
          ref.read(remoteControllerProvider.notifier).nextEpisode();
        }
      case BackgroundSeek(:final positionSec):
        if (state.media != null) {
          ref.read(remoteControllerProvider.notifier).seek(positionSec);
        }
      case BackgroundDismissed():
        // Dismissal is a service-lifecycle no-op; nothing to send.
        break;
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

  Future<void> _updateMediaSession() async {
    try {
      await ref
          .read(backgroundPlatformProvider)
          .updateMediaSession(state.media);
    } catch (_) {
      // Best-effort anchor; the next snapshot tries again.
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

  Future<void> _requestNotificationPermission() async {
    try {
      final status =
          await ref.read(backgroundPlatformProvider).requestNotificationPermission();
      if (!ref.mounted) return;
      _dispatch(NotificationPermissionChanged(status));
    } catch (_) {
      // No activity / plugin failure: fold a re-askable denial. The service is
      // untouched; the Settings row stays available.
      if (!ref.mounted) return;
      _dispatch(const NotificationPermissionChanged(
        NotificationPermissionStatus.denied,
      ));
    }
  }

  Future<void> _openNotificationSettings() async {
    try {
      await ref.read(backgroundPlatformProvider).openNotificationSettings();
    } catch (_) {
      // Best-effort deep-link; a platform refusal is not actionable here.
    }
  }

  Future<void> _requestBatteryExemption() async {
    var launched = false;
    try {
      launched = await ref
          .read(backgroundPlatformProvider)
          .requestIgnoreBatteryOptimizations();
    } catch (_) {
      launched = false;
    }
    if (!ref.mounted) return;
    if (!launched) {
      // Android offered no direct handler: fall back to the optimization list.
      _dispatch(const BatteryExemptionUnavailable());
      return;
    }
    // The user returned from the OS prompt; re-read the exemption state so
    // Settings reflects the answer.
    await _refreshBatteryExemption();
  }

  Future<void> _openBatteryOptimizationSettings() async {
    try {
      await ref
          .read(backgroundPlatformProvider)
          .openBatteryOptimizationSettings();
    } catch (_) {
      // Best-effort deep-link; a platform refusal is not actionable here.
      return;
    }
    if (ref.mounted) await _refreshBatteryExemption();
  }

  Future<void> _openBatterySettings() async {
    try {
      await ref.read(backgroundPlatformProvider).openBatterySettings();
    } catch (_) {
      // Best-effort deep-link; a platform refusal is not actionable here.
    }
  }
}

final backgroundControllerProvider =
    NotifierProvider<BackgroundController, BackgroundState>(
  BackgroundController.new,
);

// Wiring tests for the background controller (#64 / #65). The reducer is the
// decision seam; these pin the glue: connect/disconnect/toggle effects reach
// the fake platform, the "start only while foregrounded" rule holds through
// the lifecycle event, a refused start degrades without throwing, and the
// notification morphs idle ↔ media (and clears on a socket drop) off the
// derived now-playing view.

import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/background/background_controller.dart';
import 'package:harbor_companion/app/background/background_platform.dart';
import 'package:harbor_companion/app/background/background_reducer.dart';
import 'package:harbor_companion/app/background/open_remote_request.dart';
import 'package:harbor_companion/app/connect/connect_controller.dart';
import 'package:harbor_companion/app/connect/host_registry.dart';
import 'package:harbor_companion/app/connect/lan_scan.dart';
import 'package:harbor_companion/app/settings/settings_controller.dart';
import 'package:harbor_companion/app/settings/settings_store.dart';
import 'package:harbor_companion/app/ws/client_controller.dart';
import 'package:harbor_companion/app/ws/host_keys.dart';
import 'package:harbor_companion/app/ws/ws_transport.dart';

class FakeConnection implements WsConnection {
  final _frames = StreamController<String>.broadcast();
  final List<String> sent = [];
  bool closed = false;
  @override
  Stream<String> get frames => _frames.stream;
  @override
  void send(String message) => sent.add(message);
  @override
  Future<void> close() async {
    closed = true;
    await _frames.close();
  }

  void emit(String frame) => _frames.add(frame);
}

class FakeTransport implements WsTransport {
  final List<FakeConnection> connections = [];
  @override
  Future<WsConnection> open(String url) async {
    final connection = FakeConnection();
    connections.add(connection);
    return connection;
  }
}

/// A snapshot frame the WS client will fold into the Remote state. `updatedAt`
/// must strictly increase between frames (the client coalesces on it).
Map<String, dynamic> snapshotFrame({
  required int updatedAt,
  bool idle = false,
  String mediaTitle = 'Breaking Bad',
  String? posterUrl,
  Map<String, dynamic>? episode,
  bool playing = true,
  double positionSec = 0,
  double durationSec = 2700,
  bool hasPrev = false,
  bool hasNext = false,
}) {
  return {
    't': 'snapshot',
    'snapshot': {
      'proto': 1,
      'idle': idle,
      'mediaId': idle ? null : 'tt0903747',
      'mediaTitle': idle ? null : mediaTitle,
      'posterUrl': idle ? null : posterUrl,
      'episode': idle ? null : episode,
      'source': idle ? null : {'quality': '1080p'},
      'positionSec': idle ? 0 : positionSec,
      'durationSec': idle ? 0 : durationSec,
      'playing': idle ? false : playing,
      'volume': 1,
      'muted': false,
      'target': {'kind': 'local', 'label': 'This PC'},
      'castDevices': <String>[],
      'castDiscovering': false,
      'hasPrevEpisode': idle ? false : hasPrev,
      'hasNextEpisode': idle ? false : hasNext,
      'subtitlesOn': false,
      'canToggleSubtitles': false,
      'textEntry': null,
      'updatedAt': updatedAt,
    },
  };
}

class FakeKeyStore implements HostKeyStore {
  @override
  Future<HostKeys> load() async => const HostKeys();
  @override
  Future<void> save(HostKeys keys) async {}
}

class FakeBackgroundPlatform implements BackgroundPlatform {
  final List<BackgroundNotification> startCalls = [];
  final List<BackgroundNotification> updateCalls = [];
  final List<BackgroundMediaSurface?> mediaSessionCalls = [];
  int stopCalls = 0;
  bool failStart = false;

  /// The status the fake reports for checks and for the OS prompt result.
  NotificationPermissionStatus permission = NotificationPermissionStatus.granted;

  /// What the fake's request helper returns (defaults to [permission]).
  NotificationPermissionStatus? requestResult;

  int checkCalls = 0;
  int requestCalls = 0;
  int openSettingsCalls = 0;

  /// Battery / OEM (#68) state the fake reports and records.
  bool batteryExempt = false;
  bool batteryRequestLaunchable = true;
  int batteryCheckCalls = 0;
  int batteryRequestCalls = 0;
  int batteryListCalls = 0;
  int batterySettingsCalls = 0;

  /// Local network / Android 17 readiness (#69) the fake records.
  LocalNetworkPermissionStatus localNetworkStatus =
      LocalNetworkPermissionStatus.granted;
  int localNetworkCheckCalls = 0;
  int localNetworkRequestCalls = 0;

  final StreamController<BackgroundAction> _actions =
      StreamController<BackgroundAction>.broadcast();

  @override
  Future<void> startService(BackgroundNotification notification) async {
    startCalls.add(notification);
    if (failStart) {
      throw const BackgroundServiceException('SecurityException: missing type');
    }
  }

  @override
  Future<void> updateService(BackgroundNotification notification) async {
    updateCalls.add(notification);
  }

  @override
  Future<void> updateMediaSession(BackgroundMediaSurface? media) async {
    mediaSessionCalls.add(media);
  }

  @override
  Future<void> stopService() async => stopCalls++;

  @override
  Future<NotificationPermissionStatus> checkNotificationPermission() async {
    checkCalls++;
    return permission;
  }

  @override
  Future<NotificationPermissionStatus> requestNotificationPermission() async {
    requestCalls++;
    permission = requestResult ?? permission;
    return permission;
  }

  @override
  Future<void> openNotificationSettings() async => openSettingsCalls++;

  @override
  Future<bool> isIgnoringBatteryOptimizations() async {
    batteryCheckCalls++;
    return batteryExempt;
  }

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async {
    batteryRequestCalls++;
    return batteryRequestLaunchable;
  }

  @override
  Future<void> openBatteryOptimizationSettings() async => batteryListCalls++;

  @override
  Future<void> openBatterySettings() async => batterySettingsCalls++;

  @override
  Future<LocalNetworkPermissionStatus> checkLocalNetworkPermission() async {
    localNetworkCheckCalls++;
    return localNetworkStatus;
  }

  @override
  Future<LocalNetworkPermissionStatus> requestLocalNetworkPermission() async {
    localNetworkRequestCalls++;
    return localNetworkStatus;
  }

  @override
  Stream<BackgroundAction> get actions => _actions.stream;

  void emit(BackgroundAction action) => _actions.add(action);
}

void main() {
  late FakeBackgroundPlatform platform;
  late FakeTransport transport;
  late ProviderContainer container;
  late InMemorySettingsStore settingsStore;

  /// Manual epoch-ms clock for the battery-nudge windows (#68). Tests advance
  /// it explicitly; the service-lifecycle tests leave it at 0.
  late int backgroundMs;

  Duration now() => Duration(milliseconds: clock.now().millisecondsSinceEpoch);

  ProviderContainer makeContainer({InMemorySettingsStore? store}) {
    platform = FakeBackgroundPlatform();
    transport = FakeTransport();
    backgroundMs = 0;
    settingsStore = store ?? InMemorySettingsStore();
    final c = ProviderContainer(
      overrides: [
        wsTransportProvider.overrideWithValue(transport),
        wsKeyStoreProvider.overrideWithValue(FakeKeyStore()),
        wsClockProvider.overrideWithValue(now),
        connectClockProvider.overrideWithValue(now),
        hostRegistryStoreProvider.overrideWithValue(InMemoryHostRegistryStore()),
        subnetScannerProvider.overrideWithValue(const FixedSubnetScanner([])),
        settingsStoreProvider.overrideWithValue(settingsStore),
        backgroundPlatformProvider.overrideWithValue(platform),
        backgroundClockProvider.overrideWithValue(() => backgroundMs),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  ConnectController connect() => container.read(connectControllerProvider.notifier);

  void connectTo(String name) {
    connect().addHost('h1', name, '192.168.1.50');
    connect().acknowledgeWarning();
  }

  test('a successful connect starts the service with the idle notification',
      () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();

      connectTo('desk');
      async.flushMicrotasks();

      expect(platform.startCalls, hasLength(1));
      expect(platform.startCalls.single.title, 'Harbor Companion');
      expect(platform.startCalls.single.text, 'Connected to desk');
      expect(
        container.read(backgroundControllerProvider).serviceStatus,
        BackgroundServiceStatus.running,
      );
    });
  });

  test('the connect path never checks or requests the Android 17 local '
      'network permission (#69)', () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();

      connectTo('desk');
      async.flushMicrotasks();

      // On current versions the permission is a no-op behind the seam; the
      // connection must never be gated or delayed by it.
      expect(platform.localNetworkCheckCalls, 0);
      expect(platform.localNetworkRequestCalls, 0);
      expect(
        container.read(backgroundControllerProvider).serviceStatus,
        BackgroundServiceStatus.running,
      );
    });
  });

  test('an explicit disconnect stops the service', () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();
      connectTo('desk');
      async.flushMicrotasks();

      connect().disconnect();
      async.flushMicrotasks();

      expect(platform.stopCalls, 1);
      expect(
        container.read(backgroundControllerProvider).serviceStatus,
        BackgroundServiceStatus.stopped,
      );
    });
  });

  test('removing the active host stops the service', () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();
      connectTo('desk');
      async.flushMicrotasks();

      connect().removeHost('h1');
      async.flushMicrotasks();

      expect(platform.stopCalls, 1);
    });
  });

  test('turning the toggle off while running stops the service', () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();
      connectTo('desk');
      async.flushMicrotasks();

      container
          .read(settingsControllerProvider.notifier)
          .setKeepConnectionInBackground(false);
      async.flushMicrotasks();

      expect(platform.stopCalls, 1);
    });
  });

  test('with the toggle off no service ever starts', () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();

      container
          .read(settingsControllerProvider.notifier)
          .setKeepConnectionInBackground(false);
      async.flushMicrotasks();

      connectTo('desk');
      async.flushMicrotasks();

      expect(platform.startCalls, isEmpty);
    });
  });

  test('a refused start degrades without throwing', () {
    fakeAsync((async) {
      container = makeContainer();
      platform.failStart = true;
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();

      connectTo('desk');
      async.flushMicrotasks();

      final state = container.read(backgroundControllerProvider);
      expect(state.serviceStatus, BackgroundServiceStatus.degraded);
      expect(state.lastError, contains('missing type'));
    });
  });

  test('a connect while backgrounded waits for the next foreground', () {
    fakeAsync((async) {
      container = makeContainer();
      final background = container.read(backgroundControllerProvider.notifier);
      background.setForegrounded(false);
      connect();
      async.flushMicrotasks();

      connectTo('desk');
      async.flushMicrotasks();
      expect(platform.startCalls, isEmpty);

      background.setForegrounded(true);
      async.flushMicrotasks();
      expect(platform.startCalls, hasLength(1));
    });
  });

  test('a notification action is folded without changing the service', () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();
      connectTo('desk');
      async.flushMicrotasks();

      platform.emit(BackgroundAction.dismissed);
      async.flushMicrotasks();

      expect(
        container.read(backgroundControllerProvider).serviceStatus,
        BackgroundServiceStatus.running,
      );
      expect(platform.stopCalls, 0);
    });
  });

  // Frame-driven tests: the WS fake is a real broadcast stream, so drive the
  // event loop with a few zero-delay turns (the pattern in
  // remote_controller_test) rather than fake_async's microtask flush.
  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('playing media morphs the idle notification into the media surface',
      () async {
    container = makeContainer();
    container.read(backgroundControllerProvider.notifier);
    connect();
    await settle();
    connectTo('desk');
    await settle();
    expect(platform.startCalls.single.text, 'Connected to desk');

    transport.connections.single.emit(jsonEncode(snapshotFrame(
      updatedAt: 1000,
      mediaTitle: 'Breaking Bad',
      posterUrl: 'http://desk:11471/poster.jpg',
      episode: const {'season': 2, 'episode': 5, 'name': 'Breakage'},
      playing: true,
      positionSec: 120,
      durationSec: 2700,
      hasPrev: true,
      hasNext: true,
    )));
    await settle();

    final posted = platform.updateCalls.single;
    expect(posted.title, 'Breaking Bad');
    expect(posted.text, 'S2 · E5  Breakage');
    expect(posted.media?.posterUrl, 'http://desk:11471/poster.jpg');
    expect(posted.media?.playing, isTrue);
    expect(posted.media?.hasPrevEpisode, isTrue);
    expect(posted.media?.hasNextEpisode, isTrue);
    expect(posted.media?.positionSec, 120);
    expect(posted.media?.durationSec, 2700);
    expect(platform.stopCalls, 0);
  });

  test('a socket drop clears the media surface and keeps the service running',
      () async {
    container = makeContainer();
    container.read(backgroundControllerProvider.notifier);
    connect();
    await settle();
    connectTo('desk');
    await settle();

    transport.connections.single.emit(jsonEncode(snapshotFrame(
      updatedAt: 1000,
      mediaTitle: 'Breaking Bad',
      episode: const {'season': 2, 'episode': 5, 'name': 'Breakage'},
    )));
    await settle();
    expect(platform.updateCalls.last.title, 'Breaking Bad');

    // The socket drops: the Remote reducer clears `nowPlaying` at once, so the
    // notification morphs back to the idle/reconnecting status. The service
    // stays up because the connect layer is reconnecting, not disconnected.
    await transport.connections.single.close();
    await settle();

    final posted = platform.updateCalls.last;
    expect(posted.media, isNull);
    // The connect layer is reconnecting, so the idle surface morphs to the
    // reconnecting status rather than a stale "Connected to desk" (ADR-0005).
    expect(posted.text, 'Reconnecting…');
    expect(platform.stopCalls, 0);
    expect(
      container.read(backgroundControllerProvider).serviceStatus,
      BackgroundServiceStatus.running,
    );
  });

  // -------------------------------------------------------------------------
  // #66: host-authoritative transport controls on the notification.
  // -------------------------------------------------------------------------

  /// Drives a connected, running service that holds [frame]'s media and
  /// returns the wire connection, with the connect handshake frames cleared.
  Future<FakeConnection> runningWithMedia(Map<String, dynamic> frame) async {
    container = makeContainer();
    container.read(backgroundControllerProvider.notifier);
    connect();
    await settle();
    connectTo('desk');
    await settle();
    final connection = transport.connections.single;
    connection.emit(jsonEncode(frame));
    await settle();
    connection.sent.clear();
    return connection;
  }

  test('play/pause sends the same command the app does, with no optimism',
      () async {
    final connection = await runningWithMedia(snapshotFrame(
      updatedAt: 1000,
      mediaTitle: 'Breaking Bad',
      playing: true,
    ));

    platform.emit(BackgroundAction.togglePlay);
    await settle();

    expect(connection.sent.single, contains('"action":"pause"'));
    // Host-authoritative: the surface still says playing until a snapshot
    // corrects it — no optimistic flip.
    expect(container.read(backgroundControllerProvider).media?.playing, isTrue);

    connection.emit(jsonEncode(snapshotFrame(
      updatedAt: 1400,
      mediaTitle: 'Breaking Bad',
      playing: false,
    )));
    await settle();
    expect(container.read(backgroundControllerProvider).media?.playing, isFalse);

    platform.emit(BackgroundAction.togglePlay);
    await settle();
    expect(connection.sent.last, contains('"action":"play"'));
  });

  test('prev/next are emitted only when the snapshot reports them', () async {
    final connection = await runningWithMedia(snapshotFrame(
      updatedAt: 1000,
      playing: true,
      hasPrev: false,
      hasNext: false,
    ));

    platform.emit(BackgroundAction.previous);
    platform.emit(BackgroundAction.next);
    await settle();
    expect(connection.sent, isEmpty,
        reason: 'no prev/next episode → the buttons do nothing');

    connection.emit(jsonEncode(snapshotFrame(
      updatedAt: 1400,
      playing: true,
      hasPrev: true,
      hasNext: true,
    )));
    await settle();
    final surface = container.read(backgroundControllerProvider).media!;
    expect(surface.hasPrevEpisode, isTrue);
    expect(surface.hasNextEpisode, isTrue);

    platform.emit(BackgroundAction.previous);
    platform.emit(BackgroundAction.next);
    await settle();
    expect(connection.sent, hasLength(2));
    expect(connection.sent[0], contains('prevEpisode'));
    expect(connection.sent[1], contains('nextEpisode'));
  });

  test('the seek scrubber emits seek and the snapshot re-anchors the surface',
      () async {
    final connection = await runningWithMedia(snapshotFrame(
      updatedAt: 1000,
      playing: true,
      positionSec: 0,
      durationSec: 2700,
    ));

    platform.emit(const BackgroundSeek(120));
    await settle();
    expect(connection.sent.single, contains('"action":"seek"'));
    expect(connection.sent.single, contains('"positionSec":120'));

    // The host moved to 120; the position-only snapshot re-anchors the native
    // PlaybackState even though the plugin notification is not reposted.
    platform.mediaSessionCalls.clear();
    connection.emit(jsonEncode(snapshotFrame(
      updatedAt: 1400,
      playing: true,
      positionSec: 120,
      durationSec: 2700,
    )));
    await settle();
    expect(platform.mediaSessionCalls.last?.positionSec, 120);
  });

  test('tapping the notification body requests opening the Remote tab', () {
    fakeAsync((async) {
      container = makeContainer();
      container.read(backgroundControllerProvider.notifier);
      connect();
      async.flushMicrotasks();
      connectTo('desk');
      async.flushMicrotasks();

      expect(container.read(openRemoteRequestProvider), 0);
      platform.emit(BackgroundAction.opened);
      async.flushMicrotasks();
      expect(container.read(openRemoteRequestProvider), 1);

      // A second tap still produces an observable change.
      platform.emit(BackgroundAction.opened);
      async.flushMicrotasks();
      expect(container.read(openRemoteRequestProvider), 2);
    });
  });

  // -------------------------------------------------------------------------
  // #67: contextual notification permission.
  // -------------------------------------------------------------------------

  BackgroundController background() =>
      container.read(backgroundControllerProvider.notifier);

  test('at launch the permission is checked but nothing is offered', () {
    fakeAsync((async) {
      container = makeContainer();
      platform.permission = NotificationPermissionStatus.denied;
      background();
      connect();
      async.flushMicrotasks();

      expect(platform.checkCalls, greaterThan(0));
      expect(platform.requestCalls, 0);
      expect(container.read(backgroundControllerProvider).rationaleVisible,
          isFalse);
    });
  });

  test('the first connect with the toggle on offers the rationale, not the OS '
      'prompt', () {
    fakeAsync((async) {
      container = makeContainer();
      platform.permission = NotificationPermissionStatus.denied;
      background();
      connect();
      async.flushMicrotasks();
      connectTo('desk');
      async.flushMicrotasks();

      expect(container.read(backgroundControllerProvider).rationaleVisible,
          isTrue);
      // Only the in-app rationale is up; Android has not been asked yet.
      expect(platform.requestCalls, 0);
      // The service still starts (denial never blocks it).
      expect(platform.startCalls, hasLength(1));
    });
  });

  test('with the toggle off the permission is never requested', () {
    fakeAsync((async) {
      container = makeContainer();
      platform.permission = NotificationPermissionStatus.denied;
      background();
      connect();
      async.flushMicrotasks();
      container
          .read(settingsControllerProvider.notifier)
          .setKeepConnectionInBackground(false);
      async.flushMicrotasks();

      connectTo('desk');
      async.flushMicrotasks();

      expect(container.read(backgroundControllerProvider).rationaleVisible,
          isFalse);
      expect(platform.requestCalls, 0);
      expect(platform.startCalls, isEmpty);
    });
  });

  test('a granted permission never offers the rationale', () {
    fakeAsync((async) {
      container = makeContainer();
      background();
      connect();
      async.flushMicrotasks();
      connectTo('desk');
      async.flushMicrotasks();

      expect(container.read(backgroundControllerProvider).rationaleVisible,
          isFalse);
      expect(platform.requestCalls, 0);
    });
  });

  test('a permanently denied permission never offers the rationale', () {
    fakeAsync((async) {
      container = makeContainer();
      platform.permission = NotificationPermissionStatus.permanentlyDenied;
      background();
      connect();
      async.flushMicrotasks();
      connectTo('desk');
      async.flushMicrotasks();

      expect(container.read(backgroundControllerProvider).rationaleVisible,
          isFalse);
      expect(platform.requestCalls, 0);
      expect(container.read(backgroundControllerProvider).serviceStatus,
          BackgroundServiceStatus.running);
    });
  });

  test('accepting the rationale fires the OS prompt; a denial leaves the '
      'service running', () {
    fakeAsync((async) {
      container = makeContainer();
      platform.permission = NotificationPermissionStatus.denied;
      background();
      connect();
      async.flushMicrotasks();
      connectTo('desk');
      async.flushMicrotasks();

      background().acceptNotificationRationale();
      async.flushMicrotasks();

      expect(platform.requestCalls, 1);
      final state = container.read(backgroundControllerProvider);
      expect(state.rationaleVisible, isFalse);
      expect(state.notificationPermission, NotificationPermissionStatus.denied);
      // The denial is a degradation: the service is untouched.
      expect(state.serviceStatus, BackgroundServiceStatus.running);
      expect(platform.stopCalls, 0);
    });
  });

  test('declining the rationale never fires the OS prompt, and no later event '
      're-prompts', () {
    fakeAsync((async) {
      container = makeContainer();
      platform.permission = NotificationPermissionStatus.denied;
      background();
      connect();
      async.flushMicrotasks();
      connectTo('desk');
      async.flushMicrotasks();

      background().declineNotificationRationale();
      async.flushMicrotasks();
      expect(platform.requestCalls, 0);
      expect(container.read(backgroundControllerProvider).rationaleVisible,
          isFalse);

      // A later foreground return re-checks the still-denied permission but
      // must not offer the rationale again.
      background().setForegrounded(false);
      async.flushMicrotasks();
      background().setForegrounded(true);
      async.flushMicrotasks();
      expect(container.read(backgroundControllerProvider).rationaleVisible,
          isFalse);
      expect(platform.requestCalls, 0);
    });
  });

  test('a manual re-ask from Settings fires the OS prompt', () {
    fakeAsync((async) {
      container = makeContainer();
      platform.permission = NotificationPermissionStatus.denied;
      background();
      connect();
      async.flushMicrotasks();
      connectTo('desk');
      async.flushMicrotasks();
      background().declineNotificationRationale();
      async.flushMicrotasks();

      background().requestNotificationPermission();
      async.flushMicrotasks();

      expect(platform.requestCalls, 1);
      expect(container.read(backgroundControllerProvider).rationaleVisible,
          isFalse);
    });
  });

  test('the Settings deep-link opens the OS notification settings', () {
    fakeAsync((async) {
      container = makeContainer();
      background();
      async.flushMicrotasks();

      background().openNotificationSettings();
      async.flushMicrotasks();

      expect(platform.openSettingsCalls, 1);
    });
  });

  // -------------------------------------------------------------------------
  // #68: battery / OEM onboarding.
  // -------------------------------------------------------------------------

  test('the exemption check folds the platform state', () {
    fakeAsync((async) {
      container = makeContainer();
      platform.batteryExempt = true;
      background();
      async.flushMicrotasks();

      expect(platform.batteryCheckCalls, greaterThan(0));
      expect(container.read(backgroundControllerProvider).batteryExempt, isTrue);
    });
  });

  test('the direct exemption request refreshes the state when it launches', () {
    fakeAsync((async) {
      container = makeContainer();
      background();
      async.flushMicrotasks();
      platform.batteryCheckCalls = 0;

      background().requestBatteryExemption();
      async.flushMicrotasks();

      expect(platform.batteryRequestCalls, 1);
      // Launched → no fallback; the state is re-read afterwards.
      expect(platform.batteryListCalls, 0);
      expect(platform.batteryCheckCalls, greaterThan(0));
    });
  });

  test('an unavailable direct request falls back to the optimization list', () {
    fakeAsync((async) {
      container = makeContainer();
      platform.batteryRequestLaunchable = false;
      background();
      async.flushMicrotasks();

      background().requestBatteryExemption();
      async.flushMicrotasks();

      expect(platform.batteryRequestCalls, 1);
      expect(platform.batteryListCalls, 1);
    });
  });

  test('the optimization list and generic battery settings are wired', () {
    fakeAsync((async) {
      container = makeContainer();
      background();
      async.flushMicrotasks();

      background().openBatteryOptimizationSettings();
      async.flushMicrotasks();
      expect(platform.batteryListCalls, 1);

      background().openBatterySettings();
      async.flushMicrotasks();
      expect(platform.batterySettingsCalls, 1);
    });
  });

  test('resuming with the socket down after a background stretch nudges', () {
    fakeAsync((async) {
      container = makeContainer();
      // Socket stays down (default connection status is disconnected).
      final bg = background();
      async.flushMicrotasks();

      backgroundMs = 1000;
      bg.setForegrounded(false);
      async.flushMicrotasks();

      backgroundMs = 1000 + kBatteryNudgeBackgroundThresholdMs;
      bg.setForegrounded(true);
      async.flushMicrotasks();

      expect(container.read(backgroundControllerProvider).batteryNudgeVisible,
          isTrue);

      bg.dismissBatteryNudge();
      async.flushMicrotasks();
      expect(container.read(backgroundControllerProvider).batteryNudgeVisible,
          isFalse);
    });
  });

  test('the nudge is throttled: a resume inside the window stays quiet', () {
    fakeAsync((async) {
      container = makeContainer();
      final bg = background();
      async.flushMicrotasks();

      backgroundMs = 1000;
      bg.setForegrounded(false);
      async.flushMicrotasks();
      backgroundMs = 1000 + kBatteryNudgeBackgroundThresholdMs;
      bg.setForegrounded(true);
      async.flushMicrotasks();
      expect(container.read(backgroundControllerProvider).batteryNudgeVisible,
          isTrue);
      bg.dismissBatteryNudge();
      async.flushMicrotasks();

      // A second background/resume inside the throttle window must not nudge.
      backgroundMs += kBatteryNudgeBackgroundThresholdMs;
      bg.setForegrounded(false);
      async.flushMicrotasks();
      backgroundMs += kBatteryNudgeBackgroundThresholdMs;
      bg.setForegrounded(true);
      async.flushMicrotasks();
      expect(container.read(backgroundControllerProvider).batteryNudgeVisible,
          isFalse);
    });
  });

  test('with the toggle off no nudge fires', () {
    fakeAsync((async) {
      container = makeContainer();
      container
          .read(settingsControllerProvider.notifier)
          .setKeepConnectionInBackground(false);
      final bg = background();
      async.flushMicrotasks();

      backgroundMs = 1000;
      bg.setForegrounded(false);
      async.flushMicrotasks();
      backgroundMs = 1000 + kBatteryNudgeBackgroundThresholdMs;
      bg.setForegrounded(true);
      async.flushMicrotasks();

      expect(container.read(backgroundControllerProvider).batteryNudgeVisible,
          isFalse);
    });
  });

  test('backgrounding persists the entry time and foregrounding clears it', () {
    fakeAsync((async) {
      container = makeContainer();
      final bg = background();
      async.flushMicrotasks();

      backgroundMs = 1000;
      bg.setForegrounded(false);
      async.flushMicrotasks();
      expect(settingsStore.backgroundedAtMs, 1000);

      backgroundMs = 2000;
      bg.setForegrounded(true);
      async.flushMicrotasks();
      expect(settingsStore.backgroundedAtMs, isNull);
    });
  });

  test('a cold start replays the persisted stretch and nudges (#68)', () {
    fakeAsync((async) {
      // The OS killed the process in the background; the only trace is the
      // timestamp on disk. The socket is down (default status) and the toggle
      // is on (default).
      container = makeContainer(
        store: InMemorySettingsStore(backgroundedAtMs: 1000),
      );
      backgroundMs = 1000 + kBatteryNudgeBackgroundThresholdMs;
      background();
      async.flushMicrotasks();

      final state = container.read(backgroundControllerProvider);
      expect(state.batteryNudgeVisible, isTrue);
      expect(state.lastBatteryNudgeMs, backgroundMs);
      // Consumed on restore so a later cold start cannot replay it.
      expect(settingsStore.backgroundedAtMs, isNull);
    });
  });

  test('a cold start restore does not nudge with the toggle off', () {
    fakeAsync((async) {
      container = makeContainer(
        store: InMemorySettingsStore(backgroundedAtMs: 1000),
      );
      backgroundMs = 1000 + kBatteryNudgeBackgroundThresholdMs;
      container
          .read(settingsControllerProvider.notifier)
          .setKeepConnectionInBackground(false);
      background();
      async.flushMicrotasks();

      expect(container.read(backgroundControllerProvider).batteryNudgeVisible,
          isFalse);
      expect(settingsStore.backgroundedAtMs, isNull);
    });
  });

  test('a cold start with no persisted stretch stays quiet', () {
    fakeAsync((async) {
      container = makeContainer();
      backgroundMs = 1000 + kBatteryNudgeBackgroundThresholdMs;
      background();
      async.flushMicrotasks();

      expect(container.read(backgroundControllerProvider).batteryNudgeVisible,
          isFalse);
    });
  });
}

// Tests for the derived background notification view (#65).
//
// The provider composes the playing surface from the shell connection gate plus
// the Remote reducer's `NowPlaying`, in the same spirit as the player bar's
// `playerBarViewProvider`. These pin idle ↔ media composition and, crucially,
// that a socket drop clears the surface at once.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/background/background_notification_view.dart';
import 'package:harbor_companion/app/remote/remote_controller.dart';
import 'package:harbor_companion/app/remote/remote_reducer.dart';
import 'package:harbor_companion/app/shell/shell_controller.dart';
import 'package:harbor_companion/app/shell/shell_reducer.dart';
import 'package:harbor_companion/app/ws/client_reducer.dart' show EpisodeRef;

/// A Remote controller stub whose state can be driven without a socket, so the
/// view can be tested against the exact `NowPlaying` shapes and events the real
/// controller folds in.
class _StubRemoteController extends RemoteController {
  final RemoteState _initial;
  _StubRemoteController(this._initial);

  @override
  RemoteState build() => _initial;

  void apply(RemoteEvent event) => state = remoteReduce(state, event);
}

RemoteState held({
  String title = 'Breaking Bad',
  String? posterUrl,
  EpisodeRef? episode,
  bool playing = true,
  double positionSec = 0,
  double durationSec = 0,
  bool hasPrev = false,
  bool hasNext = false,
}) =>
    RemoteState(
      connected: true,
      phase: RemotePhase.nowPlaying,
      nowPlaying: NowPlaying(
        mediaId: 'tt0903747',
        mediaTitle: title,
        posterUrl: posterUrl,
        episode: episode,
        playing: playing,
        positionSec: positionSec,
        durationSec: durationSec,
        hasPrevEpisode: hasPrev,
        hasNextEpisode: hasNext,
      ),
    );

ProviderContainer container({
  RemoteState? remote,
  ConnectionStatus connection = ConnectionStatus.connected,
}) {
  final c = ProviderContainer(
    overrides: [
      connectionStatusProvider.overrideWith(ConnectionStatusController.new),
      remoteControllerProvider
          .overrideWith(() => _StubRemoteController(remote ?? RemoteState())),
    ],
  );
  addTearDown(c.dispose);
  c.read(connectionStatusProvider.notifier).set(connection);
  return c;
}

void main() {
  test('null while disconnected, even with held media', () {
    final c = container(
      remote: held(),
      connection: ConnectionStatus.disconnected,
    );
    expect(c.read(backgroundNotificationViewProvider), isNull);
  });

  test('null when connected but nothing is held', () {
    final c = container(remote: RemoteState(connected: true));
    expect(c.read(backgroundNotificationViewProvider), isNull);
  });

  test('the playing surface when connected and media is held', () {
    final c = container(
      remote: held(
        posterUrl: 'http://desk:11471/poster.jpg',
        episode: const EpisodeRef(2, 5, 'Breakage'),
        playing: true,
        positionSec: 120,
        durationSec: 2700,
        hasPrev: true,
        hasNext: true,
      ),
    );

    final view = c.read(backgroundNotificationViewProvider);
    expect(view, isNotNull);
    expect(view!.title, 'Breaking Bad');
    expect(view.episodeLine, 'S2 · E5  Breakage');
    expect(view.posterUrl, 'http://desk:11471/poster.jpg');
    expect(view.playing, isTrue);
    expect(view.positionSec, 120);
    expect(view.durationSec, 2700);
    expect(view.hasPrevEpisode, isTrue);
    expect(view.hasNextEpisode, isTrue);
  });

  test('a socket drop clears the surface the moment the Remote drops', () {
    final c = container(remote: held());
    final stub = c.read(remoteControllerProvider.notifier) as _StubRemoteController;
    expect(c.read(backgroundNotificationViewProvider), isNotNull);

    // The Remote layer's Disconnected event clears `nowPlaying`; the shell
    // connection status is still connected here, so the null comes from the
    // media clearing, not the connection gate.
    stub.apply(const Disconnected());

    expect(c.read(connectionStatusProvider), ConnectionStatus.connected);
    expect(c.read(backgroundNotificationViewProvider), isNull);
  });

  test('a held media is hidden once the connection gate drops', () {
    final c = container(remote: held());
    expect(c.read(backgroundNotificationViewProvider), isNotNull);

    c.read(connectionStatusProvider.notifier).set(ConnectionStatus.disconnected);

    expect(c.read(backgroundNotificationViewProvider), isNull);
  });
}

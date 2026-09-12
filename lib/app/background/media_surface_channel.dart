// App-owned native media surface for the persistent-connection notification
// (ticket #66, ADR-0005).
//
// `flutter_foreground_task` 11.0.3 has no MediaStyle/bitmap API, so the app
// owns a thin MethodChannel (`dev.harbor.harbor_companion/media_surface`) whose
// Android side holds a platform `android.media.session.MediaSession` and
// republishes the notification under the SAME id as the plugin's foreground
// service (`kBackgroundServiceId`), so the service stays foreground while the
// single notification becomes a media surface.
//
// No new AndroidX dependency: the platform `MediaSession` + `Notification.MediaStyle`
// (API 21+) cover the artwork, scrubber and headset/Bluetooth transport buttons.
//
// This is deliberately best-effort: any channel failure must never break the
// service or the app. The fallback is the plugin's own notification buttons
// (`surfaceActions`), which stay wired behind the same `BackgroundPlatform`.

import 'dart:async';

import 'package:flutter/services.dart';

import 'background_platform.dart';

/// The native surface seam. `show` publishes/updates the notification (artwork
/// included); `anchor` re-pushes only the transport state from a freshest
/// snapshot; `clear` restores the plugin's idle notification.
abstract interface class MediaSurfaceChannel {
  Stream<BackgroundAction> get actions;

  Future<void> show(BackgroundNotification notification);

  Future<void> anchor(BackgroundMediaSurface media);

  Future<void> clear();
}

class MethodChannelMediaSurface implements MediaSurfaceChannel {
  static const MethodChannel _channel =
      MethodChannel('dev.harbor.harbor_companion/media_surface');

  final StreamController<BackgroundAction> _actions =
      StreamController<BackgroundAction>.broadcast();

  MethodChannelMediaSurface() {
    _channel.setMethodCallHandler(_onCall);
    // Handshake: tells the native side our handler is registered so it can
    // flush a cold-start "opened" tap from the notification body.
    _invoke('ready', const <String, Object?>{});
  }

  @override
  Stream<BackgroundAction> get actions => _actions.stream;

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'action') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final id = args['action'];
    if (id is! String) return null;
    final position = args['positionSec'];
    final action = backgroundActionFromId(
      id,
      positionSec: position is num ? position.toDouble() : null,
    );
    if (action != null) _actions.add(action);
    return null;
  }

  @override
  Future<void> show(BackgroundNotification notification) => _invoke('show', {
        'title': notification.title,
        'text': notification.text,
        ..._mediaArgs(notification.media),
      });

  @override
  Future<void> anchor(BackgroundMediaSurface media) =>
      _invoke('anchor', _mediaArgs(media));

  @override
  Future<void> clear() => _invoke('clear', const <String, Object?>{});

  Map<String, Object?> _mediaArgs(BackgroundMediaSurface? media) {
    if (media == null) return const {'idle': true};
    return {
      'idle': false,
      'title': media.title,
      'episodeLine': media.episodeLine,
      'posterUrl': media.posterUrl,
      'playing': media.playing,
      'positionSec': media.positionSec,
      'durationSec': media.durationSec,
      'hasPrev': media.hasPrevEpisode,
      'hasNext': media.hasNextEpisode,
    };
  }

  Future<void> _invoke(String method, Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // No native surface wired (tests, other platforms): the plugin
      // notification remains the only surface.
    } on PlatformException {
      // The native side failed; never let the notification break the service.
    }
  }
}

// Throwaway scaffold — simulates the Harbor host side of the wire so the TUI
// can push real frame sequences at the client module. Not portable; the shell
// owns this.

library;

import 'dart:convert';
import 'client.dart';

class HostSim {
  bool online = true;
  int updatedAt = 1000; // synthetic host clock (ms)

  // host model
  bool playing = false;
  bool idle = true;
  String? title;
  String? episodeName;
  int? season;
  int? episode;
  double positionSec = 0;
  double durationSec = 0;
  double volume = 1;
  bool muted = false;
  bool subtitlesOn = false;
  String tmdbKey = 'tmdb-key-1234';
  String hostVersion = '0.9.117-beta (proto 1)';
  final List<String> castDevices = ['Living Room TV', 'Bedroom Chromecast'];
  final int watchlistCount = 42;
  final int historyCount = 18;
  final int favoritesCount = 7;
  bool textEntryActive = false;
  String textEntryValue = '';
  String textEntryPlaceholder = 'Search…';

  final List<String> commandLog = [];
  final List<String> outgoing = [];

  int get skipSnapshot => -1; // not used; see _skipActions

  static const Set<String> _skipActions = {'nav', 'setText', 'ping'};

  void connect() {
    outgoing.add(jsonEncode({'t': 'hello', 'proto': 1, 'server': 'harbor-remote'}));
    push();
  }

  void push() {
    updatedAt += 400;
    outgoing.add(jsonEncode(_snapshot().toJson()));
  }

  void burst() {
    for (var i = 0; i < 3; i++) {
      push();
    }
  }

  void stale() {
    // a frame carrying an older updatedAt than the last one the client saw
    outgoing.add(jsonEncode(_snapshotWith(updatedAt - 500).toJson()));
  }

  void garbage() {
    outgoing.add('this is definitely not json{{{{');
  }

  void error(String message) {
    outgoing.add(jsonEncode({'t': 'error', 'message': message}));
  }

  void pong() {
    outgoing.add(jsonEncode({'t': 'pong', 'at': 1234567890}));
  }

  void revokeKey() {
    tmdbKey = 'revoked-${updatedAt}';
    push();
  }

  void receive(String frame) {
    Object? decoded;
    try {
      decoded = jsonDecode(frame);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic> || decoded['t'] != 'cmd') return;
    final command = decoded['command'];
    if (command is! Map<String, dynamic>) return;
    _applyCommand(command);
    commandLog.add(jsonEncode(command));
    if (commandLog.length > 6) commandLog.removeAt(0);
    if (!_skipActions.contains(command['action'])) {
      push();
    }
  }

  void _applyCommand(Map<String, dynamic> c) {
    switch (c['action']) {
      case 'play':
        _startPlayback();
      case 'pause':
        playing = false;
      case 'seek':
        final pos = (c['positionSec'] as num?)?.toDouble() ?? 0;
        positionSec = pos < 0 ? 0 : pos;
      case 'setVolume':
        volume = ((c['volume'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
        if (muted && volume > 0) muted = false;
      case 'setMuted':
        muted = c['muted'] as bool? ?? false;
      case 'toggleSubtitles':
        subtitlesOn = !subtitlesOn;
      case 'prevEpisode':
        episode = (episode ?? 2) - 1;
        episodeName = 'Episode ${episode!}';
        _startPlayback();
      case 'nextEpisode':
        episode = (episode ?? 1) + 1;
        episodeName = 'Episode ${episode!}';
        _startPlayback();
      case 'playMeta':
        final name = c['name'] as String?;
        final metaId = c['metaId'] as String? ?? 'tt0000000';
        title = name ?? 'Meta $metaId';
        season = (c['season'] as num?)?.toInt();
        episode = (c['episode'] as num?)?.toInt();
        episodeName = season == null ? null : 'S${season!}E${episode!}';
        _startPlayback();
      case 'setText':
        textEntryActive = true;
        textEntryValue = c['value'] as String? ?? '';
      case 'submitText':
        textEntryActive = false;
        textEntryValue = '';
      case 'blurText':
        textEntryActive = false;
        textEntryValue = '';
      case 'openSearch':
        textEntryActive = true;
        textEntryValue = '';
    }
  }

  void _startPlayback() {
    idle = false;
    playing = true;
    durationSec = 5400;
  }

  // advance the host clock 400ms: position creeps while playing (so the progress
  // bar visibly moves) and any command echo is pushed
  void tick400() {
    if (playing && !idle) {
      positionSec = (positionSec + 0.4).clamp(0.0, durationSec);
    }
    push();
  }

  Snapshot _snapshot() => _snapshotWith(updatedAt);

  Snapshot _snapshotWith(int ts) {
    if (textEntryActive) {
      idle = true;
    }
    return Snapshot(
      idle: idle,
      mediaId: idle ? null : 'tt0000001',
      mediaTitle: idle ? null : title,
      episode: episode == null && episodeName == null
          ? null
          : EpisodeRef(season, episode, episodeName),
      positionSec: positionSec,
      durationSec: durationSec,
      playing: playing && !idle,
      volume: volume,
      muted: muted,
      target: const TargetInfo('local', 'This PC'),
      castDevices: castDevices,
      hasPrevEpisode: !idle && (episode ?? 1) > 1,
      hasNextEpisode: !idle,
      subtitlesOn: subtitlesOn,
      canToggleSubtitles: !idle && !muted,
      textEntry: textEntryActive ? TextEntry(textEntryValue, textEntryPlaceholder) : null,
      hostVersion: hostVersion,
      tmdbKey: tmdbKey,
      library: LibrarySummary(watchlistCount, historyCount, favoritesCount),
      updatedAt: ts,
    );
  }
}

// Tests for the Library / My Stuff state model (lib/app/library/library_reducer.dart).
//
// Pins the ticket 06 acceptance criteria: derive-on-change refresh (never the
// 400ms tick, never `updatedAt`), host-authoritative toggles (resolve on
// reflection, reject after 3 un-reflected snapshots or an error frame, no
// optimistic state), the cloud-sync honest revert, the derived empty states
// (needConnect / emptyLibrary / stale), display-only trackers, and the
// persistence on/off round-trip.

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/library/library_reducer.dart';
import 'package:harbor_companion/app/ws/client_reducer.dart'
    show LibraryItem, SnapshotLibrary;

LibraryItem item(String id, {String type = 'movie', String? name, String? poster}) =>
    LibraryItem(id, type, name, poster, null);

SnapshotLibrary lib({
  List<LibraryItem> watchlist = const [],
  List<LibraryItem> history = const [],
  List<LibraryItem> favorites = const [],
}) =>
    SnapshotLibrary(watchlist: watchlist, history: history, favorites: favorites);

List<String> drain(LibraryState s) {
  final e = List<String>.from(s.effects);
  s.effects.clear();
  return e;
}

LibraryState connected() => libraryReduce(LibraryState(), const Connected());

LibraryState withLibrary(LibraryState s, SnapshotLibrary library, {int updatedAt = 1000}) =>
    libraryReduce(s, SnapshotArrived(library, const [], updatedAt));

void main() {
  final matrix = item('tt0133093', name: 'The Matrix', poster: 'https://img/m.jpg');
  final shawshank = item('tt0111161', name: 'Shawshank');
  final got = item('tt0944947', type: 'series', name: 'Game of Thrones');

  group('derive-on-change refresh model', () {
    test('pure 400ms ticks with an unchanged library never rebuild the view', () {
      final seed = lib(watchlist: [matrix], history: [shawshank]);
      var s = withLibrary(connected(), seed);
      final before = s.view;
      final rebuilds = s.viewRebuilds;
      for (var i = 0; i < 10; i++) {
        s = libraryReduce(s, SnapshotArrived(seed, const [], 1400 + i * 400));
      }
      expect(s.snapshotsSeen, 11); // 1 initial + 10 ticks
      expect(s.viewRebuilds, rebuilds, reason: 'ticks never re-derive the view');
      expect(identical(s.view, before), isTrue);
    });

    test('a changed library rebuilds exactly once', () {
      final seed = lib(watchlist: [matrix]);
      var s = withLibrary(connected(), seed);
      final rebuilds = s.viewRebuilds;
      s = libraryReduce(s, SnapshotArrived(lib(watchlist: [matrix, shawshank]), const [], 1400));
      expect(s.viewRebuilds, rebuilds + 1);
      expect(s.view.watchlist, hasLength(2));
    });

    test('updatedAt advancing alone (playback churn) never rebuilds', () {
      final seed = lib(watchlist: [matrix]);
      var s = withLibrary(connected(), seed, updatedAt: 1000);
      final rebuilds = s.viewRebuilds;
      s = libraryReduce(s, SnapshotArrived(seed, const [], 99999));
      expect(s.liveUpdatedAt, 99999);
      expect(s.viewRebuilds, rebuilds);
    });

    test('an absent library field is an empty library, not an error', () {
      var s = connected();
      s = libraryReduce(s, SnapshotArrived(null, const [], 1000));
      expect(s.view.emptyKind, EmptyKind.emptyLibrary);
      expect(s.notice, isNull);
    });
  });

  group('host-authoritative toggles', () {
    test('Toggle sends libraryAction, marks pending, and is NOT optimistic', () {
      final seed = lib(watchlist: [matrix]);
      var s = withLibrary(connected(), seed);
      s = libraryReduce(s, Toggle('watchlist', matrix, false));
      expect(s.pendingCommand!.action, 'libraryAction');
      expect(s.pendingCommand!.payload['metaId'], 'tt0133093');
      expect(s.pendingCommand!.payload['op'], {'kind': 'watchlist', 'on': false});
      expect(drain(s), ['command']);
      expect(s.pending, hasLength(1));
      // The view still derives from the snapshot: membership is unchanged.
      expect(s.view.inSection('watchlist', matrix.id), isTrue);
    });

    test('the next snapshot reflecting the op resolves it', () {
      var s = withLibrary(connected(), lib(watchlist: [matrix]));
      s = libraryReduce(s, Toggle('watchlist', matrix, false));
      s = libraryReduce(s, SnapshotArrived(lib(watchlist: const []), const [], 1400));
      expect(s.opsResolved, 1);
      expect(s.pending, isEmpty);
      expect(s.view.inSection('watchlist', matrix.id), isFalse);
    });

    test('a toggle while disconnected is dropped with a notice, never sent', () {
      final s = libraryReduce(LibraryState(), Toggle('watchlist', matrix, true));
      expect(s.notice, contains('Not connected'));
      expect(drain(s), isEmpty);
      expect(s.pendingCommand, isNull);
    });

    test('a toggle to the already-current state sends nothing', () {
      var s = withLibrary(connected(), lib(watchlist: [matrix]));
      s = libraryReduce(s, Toggle('watchlist', matrix, true));
      expect(s.notice, contains('already watchlist on'));
      expect(drain(s), isEmpty);
      expect(s.pending, isEmpty);
    });

    test('a duplicate in-flight toggle is refused', () {
      var s = withLibrary(connected(), lib(watchlist: [matrix]));
      s = libraryReduce(s, Toggle('watchlist', matrix, false));
      drain(s);
      final after = libraryReduce(s, Toggle('watchlist', matrix, false));
      expect(after.notice, contains('already in flight'));
      expect(drain(after), isEmpty);
      expect(after.pending, hasLength(1));
    });

    test('watched membership maps onto history', () {
      var s = withLibrary(connected(), lib(history: [shawshank]));
      expect(s.view.inSection('watched', shawshank.id), isTrue);
      expect(s.view.inSection('watchlist', shawshank.id), isFalse);
      s = libraryReduce(s, Toggle('watched', shawshank, false));
      expect(s.pendingCommand!.payload['op'], {'kind': 'watched', 'on': false});
    });
  });

  group('rejection (host ignores the op)', () {
    test('an op is rejected after 3 un-reflected snapshots', () {
      final seed = lib(watchlist: [matrix]);
      var s = withLibrary(connected(), seed);
      s = libraryReduce(s, Toggle('watchlist', matrix, false));
      s = libraryReduce(s, SnapshotArrived(seed, const [], 1400));
      expect(s.pending, hasLength(1), reason: 'not rejected after 1 unreflected');
      s = libraryReduce(s, SnapshotArrived(seed, const [], 1800));
      expect(s.pending, hasLength(1), reason: 'not rejected after 2 unreflected');
      s = libraryReduce(s, SnapshotArrived(seed, const [], 2200));
      expect(s.opsRejected, 1);
      expect(s.pending, isEmpty);
      expect(s.view.inSection('watchlist', matrix.id), isTrue,
          reason: 'honest revert — the view never shows a membership the host lacks');
    });

    test('an error frame rejects all pending ops immediately', () {
      var s = withLibrary(connected(), lib(watchlist: [matrix, shawshank]));
      s = libraryReduce(s, Toggle('watchlist', matrix, false));
      s = libraryReduce(s, Toggle('watchlist', shawshank, false));
      drain(s);
      s = libraryReduce(s, ErrorFrame('invalid message'));
      expect(s.opsRejected, 2);
      expect(s.pending, isEmpty);
    });

    test('an error frame with nothing pending is just a notice', () {
      final s = libraryReduce(connected(), ErrorFrame('stray'));
      expect(s.opsRejected, 0);
      expect(s.notice, contains('stray'));
    });
  });

  group('cloud-sync honest revert', () {
    test('watchlist OFF on a cloud item never reflects, so it reverts', () {
      // The host silently no-ops watchlist OFF on Stremio-cloud items: the
      // snapshot keeps the item. The chip must honestly revert.
      final seed = lib(watchlist: [matrix]);
      var s = withLibrary(connected(), seed);
      s = libraryReduce(s, Toggle('watchlist', matrix, false));
      for (var i = 0; i < 3; i++) {
        s = libraryReduce(s, SnapshotArrived(seed, const [], 1400 + i * 400));
      }
      expect(s.opsRejected, 1);
      expect(s.view.inSection('watchlist', matrix.id), isTrue,
          reason: 'the app can never show a membership the host does not have');
    });
  });

  group('derived empty states', () {
    test('disconnected with nothing persisted → needConnect', () {
      final s = libraryReduce(LibraryState(), const Disconnected());
      expect(s.view.emptyKind, EmptyKind.needConnect);
      expect(s.view.stale, isFalse);
    });

    test('connected with all sections empty → emptyLibrary', () {
      var s = connected();
      s = libraryReduce(s, SnapshotArrived(const SnapshotLibrary(), const [], 1000));
      expect(s.view.emptyKind, EmptyKind.emptyLibrary);
    });

    test('disconnected with persisted data and persistence on → stale', () {
      final seed = lib(watchlist: [matrix]);
      var s = libraryReduce(LibraryState(), PersistLoaded(true, seed));
      s = libraryReduce(s, const Disconnected());
      expect(s.view.stale, isTrue);
      expect(s.view.watchlist, hasLength(1));
      expect(s.view.emptyKind, EmptyKind.none);
    });

    test('persistence off → needConnect even with persisted data', () {
      var s = libraryReduce(LibraryState(), PersistLoaded(false, lib(watchlist: [matrix])));
      s = libraryReduce(s, const Disconnected());
      expect(s.view.emptyKind, EmptyKind.needConnect);
      expect(s.view.stale, isFalse);
    });

    test('connected with content → live view, not stale', () {
      final s = withLibrary(connected(), lib(watchlist: [matrix]));
      expect(s.view.stale, isFalse);
      expect(s.view.emptyKind, EmptyKind.none);
      expect(s.view.watchlist, hasLength(1));
    });
  });

  group('trackers display-only', () {
    test('linked trackers land in the view, no write op is emitted', () {
      final s = withLibrary(connected(), lib(watchlist: [matrix]));
      final after = libraryReduce(s, SnapshotArrived(lib(watchlist: [matrix]), const ['simkl', 'trakt'], 1400));
      expect(after.view.trackers, ['simkl', 'trakt']);
      expect(drain(after), isEmpty, reason: 'trackers never emit a command');
    });
  });

  group('persistence', () {
    test('enabling persistence with live data emits a persist write', () {
      var s = withLibrary(connected(), lib(watchlist: [matrix]));
      s = libraryReduce(s, const TogglePersistence());
      expect(s.persistEnabled, isTrue);
      expect(s.pendingPersist, isNotNull);
      expect(drain(s), ['persist']);
    });

    test('a changed library with persistence on emits a persist write', () {
      var s = withLibrary(connected(), lib(watchlist: [matrix]));
      s = libraryReduce(s, const TogglePersistence());
      drain(s);
      s = libraryReduce(s, SnapshotArrived(lib(watchlist: [matrix, shawshank]), const [], 1400));
      expect(drain(s), ['persist']);
      expect(s.persisted!.watchlist, hasLength(2));
    });

    test('PersistWritten clears dirty and counts the completed write', () {
      var s = withLibrary(connected(), lib(watchlist: [matrix]));
      s = libraryReduce(s, const TogglePersistence());
      s = libraryReduce(s, PersistWritten(s.liveSig));
      expect(s.persistWrites, 1);
      expect(s.persistDirty, isFalse);
    });

    test('disabling persistence does not emit a write', () {
      var s = withLibrary(connected(), lib(watchlist: [matrix]));
      s = libraryReduce(s, const TogglePersistence());
      drain(s);
      final off = libraryReduce(s, const TogglePersistence());
      expect(off.persistEnabled, isFalse);
      expect(drain(off), isEmpty);
    });
  });

  group('encoding helpers', () {
    test('the signature catches a poster swap', () {
      final a = lib(watchlist: [item('tt1', name: 'Matrix', poster: 'https://img/old.jpg')]);
      final b = lib(watchlist: [item('tt1', name: 'Matrix', poster: 'https://img/new.jpg')]);
      expect(librarySignature(a) == librarySignature(b), isFalse);
    });

    test('the signature ignores nothing else (id/type/name/poster/background all counted)', () {
      final a = lib(watchlist: [item('tt1', name: 'Matrix')]);
      final b = lib(watchlist: [item('tt1', name: 'Matrix', poster: null)]);
      expect(librarySignature(a), librarySignature(b));
    });

    test('encodeLibraryAction emits the exact libraryAction payload (no action key)', () {
      final p = encodeLibraryAction('favorite', matrix, true);
      expect(p, {
        'metaId': 'tt0133093',
        'metaType': 'movie',
        'name': 'The Matrix',
        'poster': 'https://img/m.jpg',
        'op': {'kind': 'favorite', 'on': true},
      });
      expect(p.containsKey('action'), isFalse);
    });

    test('encodePersisted / decodePersisted round-trip', () {
      final seed = lib(
        watchlist: [matrix],
        history: [shawshank],
        favorites: [got],
      );
      final decoded = decodePersisted(encodePersisted(seed))!;
      expect(librarySignature(decoded), librarySignature(seed));
    });

    test('decodePersisted returns null on garbage', () {
      expect(decodePersisted(''), isNull);
      expect(decodePersisted('not json'), isNull);
    });
  });
}

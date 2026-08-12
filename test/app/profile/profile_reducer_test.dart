// Tests for the Profile / who's-watching state model
// (lib/app/profile/profile_reducer.dart).
//
// Pins the ticket 08 acceptance criteria: profiles render from the snapshot
// (`id`/`name`/`avatar`/`color`), selecting a profile emits a `setProfile {id}`
// command and the next snapshot reflects the active profile (host-authoritative
// — no optimistic flip), derive-on-change (never the 400 ms tick), and the
// derived needConnect / noProfiles empty states.

import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/profile/profile_reducer.dart';
import 'package:harbor_companion/app/ws/client_reducer.dart' show Profile;

List<String> drain(ProfileState s) {
  final e = List<String>.from(s.effects);
  s.effects.clear();
  return e;
}

Profile p(String id, [String name = '', String? avatar, String? color]) =>
    Profile(id, name, avatar, color);

ProfileState connected() => profileReduce(ProfileState(), const Connected());

void main() {
  group('profiles render from the snapshot', () {
    test('a snapshot with profiles renders the list and the active id', () {
      final s = profileReduce(
        connected(),
        SnapshotArrived(p('dad', 'Dad', null, '#ff0000'), [
          p('dad', 'Dad', null, '#ff0000'),
          p('kid', 'Kid', 'https://img/k.png', '#00ff00'),
        ]),
      );
      expect(s.view.profiles, hasLength(2));
      expect(s.view.profiles[0].id, 'dad');
      expect(s.view.profiles[0].name, 'Dad');
      expect(s.view.profiles[0].color, '#ff0000');
      expect(s.view.profiles[1].avatar, 'https://img/k.png');
      expect(s.view.activeId, 'dad');
      expect(s.view.emptyKind, ProfileEmptyKind.none);
    });

    test('the active profile comes from snapshot.profile, not the list order',
        () {
      final s = profileReduce(
        connected(),
        SnapshotArrived(p('kid'), [p('dad'), p('kid')]),
      );
      expect(s.view.activeId, 'kid');
    });

    test('a snapshot with a null active profile still renders the list', () {
      final s = profileReduce(
        connected(),
        SnapshotArrived(null, [p('dad'), p('kid')]),
      );
      expect(s.view.profiles, hasLength(2));
      expect(s.view.activeId, isNull);
    });
  });

  group('selecting a profile', () {
    test('select emits a setProfile {id} command effect', () {
      final s = profileReduce(
        connected(),
        SnapshotArrived(p('dad', 'Dad'), [p('dad', 'Dad'), p('kid', 'Kid')]),
      );
      final after = profileReduce(s, const Select('kid'));
      expect(after.pendingCommand!.action, 'setProfile');
      expect(after.pendingCommand!.payload, {'id': 'kid'});
      expect(after.notice, contains('Kid'));
      expect(drain(after), ['command']);
    });

    test('selecting the active profile is a no-op (nothing sent)', () {
      final s = profileReduce(
        connected(),
        SnapshotArrived(p('dad', 'Dad'), [p('dad', 'Dad')]),
      );
      final after = profileReduce(s, const Select('dad'));
      expect(after.notice, contains('Already watching as Dad'));
      expect(drain(after), isEmpty);
    });

    test('select while disconnected is rejected and never queued', () {
      final s = profileReduce(ProfileState(), const Select('kid'));
      expect(s.notice, contains('Not connected'));
      expect(drain(s), isEmpty);
    });

    test('selecting an unknown profile id is rejected', () {
      final s = profileReduce(
        connected(),
        SnapshotArrived(p('dad'), [p('dad')]),
      );
      final after = profileReduce(s, const Select('ghost'));
      expect(after.notice, contains('Unknown profile'));
      expect(drain(after), isEmpty);
    });

    test('selecting an empty id is rejected', () {
      final s = profileReduce(
        connected(),
        SnapshotArrived(p(''), [p('')]),
      );
      final after = profileReduce(s, const Select(''));
      expect(after.notice, contains('no id'));
      expect(drain(after), isEmpty);
    });
  });

  group('host-authoritative reflection', () {
    test('the next snapshot that reports a new active profile updates the view',
        () {
      var s = profileReduce(
        connected(),
        SnapshotArrived(p('dad'), [p('dad'), p('kid')]),
      );
      s = profileReduce(s, const Select('kid'));
      drain(s);
      expect(s.view.activeId, 'dad', reason: 'nothing flips until the host says so');

      s = profileReduce(s, SnapshotArrived(p('kid'), [p('dad'), p('kid')]));
      expect(s.view.activeId, 'kid');
    });

    test('selecting never changes the active profile optimistically', () {
      final s = profileReduce(
        connected(),
        SnapshotArrived(p('dad'), [p('dad'), p('kid')]),
      );
      final after = profileReduce(s, const Select('kid'));
      expect(after.view.activeId, 'dad');
      expect(after.active?.id, 'dad');
    });
  });

  group('derive-on-change (never the 400 ms tick)', () {
    test('an unchanged snapshot does not re-derive the view', () {
      var s = profileReduce(
        connected(),
        SnapshotArrived(p('dad'), [p('dad'), p('kid')]),
      );
      final before = s.view;
      final rebuilds = s.viewRebuilds;
      s = profileReduce(s, SnapshotArrived(p('dad'), [p('dad'), p('kid')]));
      expect(identical(s.view, before), isTrue,
          reason: 'the view is the same object when nothing changed');
      expect(s.viewRebuilds, rebuilds);
    });

    test('a changed profile list re-derives the view', () {
      var s = profileReduce(
        connected(),
        SnapshotArrived(p('dad'), [p('dad')]),
      );
      final rebuilds = s.viewRebuilds;
      s = profileReduce(s, SnapshotArrived(p('dad'), [p('dad'), p('kid')]));
      expect(s.viewRebuilds, rebuilds + 1);
    });

    test('a changed active profile re-derives the view', () {
      var s = profileReduce(
        connected(),
        SnapshotArrived(p('dad'), [p('dad'), p('kid')]),
      );
      final rebuilds = s.viewRebuilds;
      s = profileReduce(s, SnapshotArrived(p('kid'), [p('dad'), p('kid')]));
      expect(s.viewRebuilds, rebuilds + 1);
    });
  });

  group('derived empty states', () {
    test('disconnected shows the needConnect empty state', () {
      final s = profileReduce(connected(), const Disconnected());
      expect(s.view.emptyKind, ProfileEmptyKind.needConnect);
    });

    test('connected with no profiles shows the noProfiles empty state', () {
      final s = profileReduce(connected(), SnapshotArrived(null, const []));
      expect(s.view.emptyKind, ProfileEmptyKind.noProfiles);
    });

    test('disconnect drops to needConnect and clears the list', () {
      var s = profileReduce(
        connected(),
        SnapshotArrived(p('dad'), [p('dad')]),
      );
      s = profileReduce(s, const Disconnected());
      expect(s.view.emptyKind, ProfileEmptyKind.needConnect);
      expect(s.profiles, isEmpty);
      expect(s.active, isNull);
    });
  });
}

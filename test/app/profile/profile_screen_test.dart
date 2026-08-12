// Thin widget test for the Profile screen (the reducer is the real seam).
// Verifies the derived empty states (needConnect / noProfiles), the profile list
// rendering with the active profile highlighted, tap-to-switch routing to the
// controller, and the absence of any account/Stremio linking surface.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:harbor_companion/app/profile/profile_controller.dart';
import 'package:harbor_companion/app/profile/profile_reducer.dart';
import 'package:harbor_companion/app/profile/profile_screen.dart';
import 'package:harbor_companion/app/ws/client_reducer.dart' show Profile;

class _StubProfileController extends ProfileController {
  final List<String> selected = [];
  @override
  ProfileState build() => _state;
  final ProfileState _state;
  _StubProfileController(this._state);
  @override
  void select(String id) => selected.add(id);
}

Widget _wrap(ProfileState state, {_StubProfileController? controller}) =>
    ProviderScope(
      overrides: [
        profileControllerProvider.overrideWith(
          () => controller ?? _StubProfileController(state),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: ProfileScreen())),
    );

void main() {
  final dad = Profile('dad', 'Dad', null, '#ff0000');
  final kid = Profile('kid', 'Kid', 'https://img/k.png', '#00ff00');

  testWidgets('needConnect shows the connect empty state', (tester) async {
    await tester.pumpWidget(_wrap(ProfileState(
      connected: false,
      view: const ProfileView(emptyKind: ProfileEmptyKind.needConnect),
    )));
    expect(find.text('Connect to switch profiles'), findsOneWidget);
  });

  testWidgets('noProfiles shows the no-profiles empty state', (tester) async {
    await tester.pumpWidget(_wrap(ProfileState(
      connected: true,
      view: const ProfileView(emptyKind: ProfileEmptyKind.noProfiles),
    )));
    expect(find.text('No profiles'), findsOneWidget);
  });

  testWidgets('the list renders profile names with the active one highlighted',
      (tester) async {
    await tester.pumpWidget(_wrap(ProfileState(
      connected: true,
      view: ProfileView(profiles: [dad, kid], activeId: 'dad'),
    )));

    expect(find.text('Dad'), findsOneWidget);
    expect(find.text('Kid'), findsOneWidget);
    expect(find.text('Watching'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('tapping a profile routes to select(id)', (tester) async {
    final controller = _StubProfileController(ProfileState(
      connected: true,
      view: ProfileView(profiles: [dad, kid], activeId: 'dad'),
    ));
    await tester.pumpWidget(_wrap(
      ProfileState(connected: true),
      controller: controller,
    ));

    await tester.tap(find.text('Kid'));
    expect(controller.selected, ['kid']);
  });

  testWidgets('there is no account or Stremio linking surface', (tester) async {
    await tester.pumpWidget(_wrap(ProfileState(
      connected: true,
      view: ProfileView(profiles: [dad, kid], activeId: 'dad'),
    )));

    expect(find.text('Sign in'), findsNothing);
    expect(find.text('Account'), findsNothing);
    expect(find.text('Stremio'), findsNothing);
    expect(find.text('Link account'), findsNothing);
    expect(find.byType(TextButton), findsNothing);
  });
}

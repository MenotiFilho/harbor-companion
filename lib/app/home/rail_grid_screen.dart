// Dedicated rail grid (ticket 76, ADR-0009).
//
// A rail's title or its "See more" card pushes this route with the rail already
// snapshotted in the controller (`HomeState.activeRailGrid`): the full
// downloaded page (Cinemeta ~50, Stremboxd 100, TMDB 20), its source, request
// and cursor. The grid renders every captured item in a responsive,
// width-driven grid that reuses the rail's `PosterCard` — instant, with no
// fetch, no cache write and no age badge. A Home round while the grid is open
// never changes this snapshot.
//
// On-scroll pagination (advancing the per-source cursor, dedupe, end/error
// footers) is #77; this screen shows exactly what was downloaded at open.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'home_controller.dart';
import 'home_screen.dart' show PosterCard;
import 'meta.dart';

class RailGridScreen extends ConsumerWidget {
  const RailGridScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grid = ref.watch(homeControllerProvider).activeRailGrid;

    return Scaffold(
      appBar: AppBar(title: Text(grid?.title ?? 'Grid')),
      body: grid == null
          ? const Center(child: Text('No rail selected'))
          : _RailGrid(items: grid.items),
    );
  }
}

/// The responsive grid itself: columns are chosen by the available width via
/// [SliverGridDelegateWithMaxCrossAxisExtent], and each cell is the rail's own
/// [PosterCard] (its width left null so the delegate defines it).
class _RailGrid extends StatelessWidget {
  final List<Meta> items;
  const _RailGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(child: Text('Nothing to show'));
    }
    return GridView.builder(
      key: const ValueKey('railGrid'),
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 150,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.58,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => PosterCard(meta: items[i], width: null),
    );
  }
}

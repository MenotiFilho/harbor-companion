// Native Home + catalog screens — the perf core of the effort. A vertical
// ListView.builder of poster rails (only visible rows are ever built), each a
// horizontal ListView.builder of poster cards. Images ride Flutter's ImageCache.

import 'package:flutter/material.dart';

import 'catalog_repo.dart';
import 'meta.dart';
import 'poster_image.dart';

/// Perf counters the benchmark reads.
class HomeMetrics {
  static int cardsBuilt = 0;
  static void reset() => cardsBuilt = 0;
}

/// Fixed rail height; also the outer ListView's itemExtent, so scroll math and
/// the benchmark's distance calculations are exact.
const double kRowExtent = 176;

class HomeScreen extends StatefulWidget {
  final CatalogRepo repo;
  const HomeScreen({super.key, required this.repo});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final List<HomeRow> _rows = widget.repo.fetchHome();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: const ValueKey('homeList'),
      itemCount: _rows.length,
      itemExtent: kRowExtent,
      itemBuilder: (context, i) => HomeRowRail(row: _rows[i]),
    );
  }
}

class HomeRowRail extends StatelessWidget {
  final HomeRow row;
  const HomeRowRail({super.key, required this.row});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kRowExtent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              row.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: row.items.length,
              itemBuilder: (context, j) => PosterCard(meta: row.items[j]),
            ),
          ),
        ],
      ),
    );
  }
}

class PosterCard extends StatelessWidget {
  final Meta meta;
  const PosterCard({super.key, required this.meta});

  @override
  Widget build(BuildContext context) {
    HomeMetrics.cardsBuilt++;
    return SizedBox(
      width: 110,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image(
                image: PosterImage(meta.poster ?? ''),
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            meta.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

// Per-rail Home model (ticket 71).
//
// The Home no longer fetches every rail behind one `Future.wait` and treats the
// result as a single list. Instead the `CatalogFetcher` emits one outcome per
// *planned* rail, addressed by its stable `rowKey`:
//
//   loaded  — the rail loaded with `items` (possibly empty: an emptied catalog
//             commits and the rail disappears)
//   failed  — the fetch errored; the previous copy (if any) is kept
//   absent  — the rail is not applicable this round (e.g. an enabled Letterboxd
//             catalog the manifest does not list); it is dropped
//
// The reducer commits each outcome atomically per rail. A rail is never
// assembled from two rounds; the `loaded`/`failed`/`absent` distinction is what
// lets an emptied watchlist clear while a network failure keeps the copy.
// Cache identity + age live in the cache ticket (#72); this file only models the
// outcome wire shape and the rendered per-rail state.

import 'meta.dart';

/// The result of attempting one planned Home rail. Sealed so the reducer's
/// commit switch is exhaustive.
sealed class HomeRailOutcome {
  final String rowKey;
  const HomeRailOutcome(this.rowKey);
}

/// The rail [rowKey] loaded under [title] with [items]. Empty [items] is a valid
/// `loaded` outcome — the rail commits empty and is removed from the Home.
/// [hasMore] is the source's own "there is more than this page" signal (ticket
/// 72 carries it into the cache entry; the render cap/see-more is #75).
class HomeRailLoaded extends HomeRailOutcome {
  final String title;
  final List<Meta> items;
  final bool hasMore;
  const HomeRailLoaded(super.rowKey, this.title, this.items, {this.hasMore = false});
}

/// The rail [rowKey] failed with [error]. A previous copy in state is kept.
class HomeRailFailed extends HomeRailOutcome {
  final Object error;
  const HomeRailFailed(super.rowKey, this.error);
}

/// The rail [rowKey] is not applicable this round and is dropped.
class HomeRailAbsent extends HomeRailOutcome {
  const HomeRailAbsent(super.rowKey);
}

/// Where a planned rail is in the current round.
enum RailStatus { pending, loaded, failed, absent }

/// The Home's per-`rowKey` state. [pending] means the current round has not
/// settled this rail yet. [items] survives a [RailStatus.failed] commit, so a
/// failed rail with a previous copy still renders its content.
///
/// [fromCache] marks a rail served from disk before/without fresh content; the
/// age badge renders while it is true and it clears the moment a fresh `loaded`
/// outcome commits. [updatedAt] is the cache write time (ms since epoch) and is
/// null for fresh content.
class RailState {
  final String rowKey;
  final String title;
  final List<Meta> items;
  final RailStatus status;
  final String? error;
  final bool fromCache;
  final int? updatedAt;
  final bool hasMore;

  const RailState({
    required this.rowKey,
    this.title = '',
    this.items = const [],
    this.status = RailStatus.pending,
    this.error,
    this.fromCache = false,
    this.updatedAt,
    this.hasMore = false,
  });

  bool get hasItems => items.isNotEmpty;

  RailState copyWith({
    String? title,
    List<Meta>? items,
    RailStatus? status,
    String? error,
    bool clearError = false,
    bool? fromCache,
    int? updatedAt,
    bool clearUpdatedAt = false,
    bool? hasMore,
  }) =>
      RailState(
        rowKey: rowKey,
        title: title ?? this.title,
        items: items ?? this.items,
        status: status ?? this.status,
        error: clearError ? null : (error ?? this.error),
        fromCache: fromCache ?? this.fromCache,
        updatedAt: clearUpdatedAt ? null : (updatedAt ?? this.updatedAt),
        hasMore: hasMore ?? this.hasMore,
      );
}

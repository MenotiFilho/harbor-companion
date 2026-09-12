// The Home rails request value (tickets 41, 71).
//
// Bundles the inputs that identify one fetch round: the host's TMDB key in
// effect, the user's Letterboxd/Stremboxd config, which built-in rails are
// switched off, and the row order. `planHomeRowKeys` derives the ordered rail
// keys the round attempts; every per-rail outcome carries the request that
// produced it so a late outcome from a superseded round (key changed, a row
// toggled or moved) is dropped.

import '../letterboxd/letterboxd.dart';
import 'home_rows.dart';

class CatalogRequest {
  final String? tmdbKey;

  final LetterboxdConfig letterboxd;

  /// Built-in row keys ([BuiltInRow.id]) the user switched off.
  final Set<String> disabledBuiltInRowKeys;

  /// Every known row key in display order (built-in + Letterboxd).
  final List<String> rowOrder;

  const CatalogRequest({
    this.tmdbKey,
    this.letterboxd = const LetterboxdConfig(),
    this.disabledBuiltInRowKeys = const {},
    this.rowOrder = kDefaultHomeRowOrder,
  });

  static const _unset = Object();

  /// Copies the request, optionally replacing fields. [tmdbKey] uses a sentinel
  /// so it can be cleared back to null (a `null` means "leave unchanged").
  CatalogRequest copyWith({
    Object? tmdbKey = _unset,
    LetterboxdConfig? letterboxd,
    Set<String>? disabledBuiltInRowKeys,
    List<String>? rowOrder,
  }) =>
      CatalogRequest(
        tmdbKey: identical(tmdbKey, _unset) ? this.tmdbKey : tmdbKey as String?,
        letterboxd: letterboxd ?? this.letterboxd,
        disabledBuiltInRowKeys:
            disabledBuiltInRowKeys ?? this.disabledBuiltInRowKeys,
        rowOrder: rowOrder ?? this.rowOrder,
      );

  /// Whether any built-in rail for the source currently in effect is enabled.
  bool get showBuiltInCatalogs {
    final activeSource = tmdbKey == null ? 'cinemeta' : 'tmdb';
    return rowOrder.any((key) {
      final row = builtInRowById(key);
      return row != null &&
          row.source == activeSource &&
          !disabledBuiltInRowKeys.contains(key);
    });
  }

  @override
  bool operator ==(Object other) =>
      other is CatalogRequest &&
      other.tmdbKey == tmdbKey &&
      other.letterboxd == letterboxd &&
      _sameSet(other.disabledBuiltInRowKeys, disabledBuiltInRowKeys) &&
      _sameList(other.rowOrder, rowOrder);

  @override
  int get hashCode => Object.hash(
        tmdbKey,
        letterboxd,
        Object.hashAllUnordered(disabledBuiltInRowKeys),
        Object.hashAll(rowOrder),
      );
}

/// The ordered row keys [request] should attempt: the enabled built-in rows for
/// the source in effect (TMDB when keyed, else Cinemeta), plus the enabled
/// Letterboxd catalogs when a manifest URL is set. Pure so tests pin the
/// filtering + order without network. A Letterboxd key survives planning even
/// when the manifest may not list it — the manifest is consulted at fetch time.
///
/// This is the one definition of "the planned rails" the Home renders and the
/// fetcher resolves; the reducer imports it to derive the pending rails.
List<String> planHomeRowKeys(CatalogRequest request) {
  final activeSource = request.tmdbKey == null ? 'cinemeta' : 'tmdb';
  final letterboxdActive = request.letterboxd.isActive;
  final keys = <String>[];
  for (final key in request.rowOrder) {
    final builtIn = builtInRowById(key);
    if (builtIn != null) {
      if (builtIn.source != activeSource) continue;
      if (request.disabledBuiltInRowKeys.contains(key)) continue;
      keys.add(key);
      continue;
    }
    final catalogId = letterboxdCatalogId(key);
    if (catalogId == null || !letterboxdActive) continue;
    if (!request.letterboxd.enabledCatalogIds.contains(catalogId)) continue;
    keys.add(key);
  }
  return keys;
}

bool _sameSet(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

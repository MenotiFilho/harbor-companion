// The Home rows request value (ticket 41).
//
// Bundles the inputs that identify one `fetchRows` request: the host's TMDB key
// in effect, the user's Letterboxd/Stremboxd config, which built-in rails are
// switched off, and the row order. A rows result carries the request that
// produced it so a late fetch from a superseded request (key changed, a row
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

bool _sameSet(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// Host metadata keys piped inside every snapshot (tmdbKey/rpdbKey/tvdbKey).
//
// The host only includes a key when it's configured (wire-verified), so each
// snapshot's keys are the source of truth; the WS client persists them and
// re-applies them from every snapshot so TMDB browsing keeps working even when
// a snapshot arrives with the key absent.

class HostKeys {
  final String? tmdbKey;
  final String? rpdbKey;
  final String? tvdbKey;
  const HostKeys({this.tmdbKey, this.rpdbKey, this.tvdbKey});

  bool get isEmpty => tmdbKey == null && rpdbKey == null && tvdbKey == null;

  bool sameAs(HostKeys other) =>
      tmdbKey == other.tmdbKey && rpdbKey == other.rpdbKey && tvdbKey == other.tvdbKey;
}

/// Key store seam: persistence for the host metadata keys. Injected into the
/// WS client controller; tests provide an in-memory fake.
abstract interface class HostKeyStore {
  Future<HostKeys> load();
  Future<void> save(HostKeys keys);
}

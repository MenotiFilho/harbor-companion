// Throwaway interactive TUI for the Search logic prototype.
//
// Drives the pure reducer in lib/search_controller.dart against the simulated
// sources in lib/source_sim.dart. The reducer is the validated module; this
// file (like bin/ws_client_proto.dart) is scaffolding. The shell owns all
// impurities: the debounce timer, the fetch dispatch, the wire "send".

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:search_proto/source_sim.dart';
import 'package:search_proto/search_controller.dart';

const _keys = '''
  type        type a query (Enter ends)        d         toggle duplicate-title mode
  s           submit (record recent)           j         toggle jikan 429 mode
  x           clear                            l         toggle slow-source mode (cycles)
  k           toggle tmdbKey                   h         toggle hide-anime
  p           playMeta the top result          q         quit
  <enter>     (blank) = reprint state
''';

Future<void> main() async {
  var state = SearchState();
  final sim = SourceSim();
  final pending = <int, Map<Source, Timer>>{};
  final debounce = <int, Timer>{};

  late void Function(SearchEvent) _dispatch;
  late void Function() drain;

  _dispatch = (e) {
    state = reduce(state, e);
    drain();
    _print(state, sim);
  };

  Future<Object> _fire(Source src, int id, String q) {
    switch (src) {
      case Source.tmdb:
        return sim.tmdb(q);
      case Source.cinemeta:
        return sim.cinemeta(q);
      case Source.jikan:
        return sim.jikan(q);
    }
  }

  drain = () {
    final effects = List<String>.from(state.effects);
    state.effects.clear();
    for (final fx in effects) {
      final parts = fx.split(':');
      switch (parts[0]) {
        case 'debounce':
          final id = int.parse(parts[1]);
          debounce[id]?.cancel();
          debounce[id] = Timer(debounceDelay, () => _dispatch(DebounceFired(id)));
        case 'fetch':
          final src = Source.values.byName(parts[1]);
          final id = int.parse(parts[2]);
          final q = parts.sublist(3).join(':');
          final timer = Timer(sourceTimeout, () {
            _dispatch(SourceTimedOut(id, src));
          });
          (pending[id] ??= {})[src] = timer;
          _fire(src, id, q).then((payload) {
            timer.cancel();
            pending[id]?.remove(src);
            _dispatch(SourceResult(id, src, payload));
          });
        case 'send':
          stdout.writeln('  → WS SEND  ${parts.sublist(1).join(':')}');
        default:
          stdout.writeln('  (unknown effect: $fx)');
      }
    }
  };

  stdout.writeln('''
  Search state-model prototype — answers wayfinder ticket #9.
  Ports beta src/lib/search-context.tsx + search.ts + mobile-search.tsx.

  $_keys
  ''');
  _print(state, sim);

  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final l = line.trim();
    switch (l) {
      case '':
        _print(state, sim);
      case 'q':
        exit(0);
      case 's':
        _dispatch(const Submit());
      case 'x':
        _dispatch(const Clear());
      case 'k':
        sim.tmdbKeyed = !sim.tmdbKeyed;
        stdout.writeln('  tmdbKey ${sim.tmdbKeyed ? 'ON' : 'OFF'}');
        _dispatch(QueryChanged(state.query)); // re-run with the new key
      case 'd':
        sim.duplicateTitles = !sim.duplicateTitles;
        stdout.writeln('  duplicate-title mode ${sim.duplicateTitles ? 'ON' : 'OFF'}');
      case 'j':
        sim.jikan429 = !sim.jikan429;
        stdout.writeln('  jikan-429 mode ${sim.jikan429 ? 'ON' : 'OFF'}');
      case 'l':
        final cycle = [null, Source.cinemeta, Source.jikan, Source.tmdb];
        final cur = cycle.indexOf(sim.slowSource);
        sim.slowSource = cycle[(cur + 1) % cycle.length];
        stdout.writeln('  slow-source: ${sim.slowSource?.name ?? 'none'} (8s guard exercise)');
      case 'h':
        _dispatch(const ToggleHideAnime());
      case 'p':
        final r = state.results;
        if (r == null || r.grid.isEmpty) {
          stdout.writeln('  (no results to play yet)');
        } else {
          _dispatch(PlayMeta(r.grid.first));
        }
      default:
        if (l.startsWith('play ')) {
          final r = state.results;
          final idx = int.tryParse(l.split(' ')[1]) ?? -1;
          if (r == null || idx < 0 || idx >= r.grid.length) {
            stdout.writeln('  (index out of range)');
          } else {
            _dispatch(PlayMeta(r.grid[idx]));
          }
          break;
        }
        _dispatch(QueryChanged(l));
    }
  });
}

void _print(SearchState s, SourceSim sim) {
  stdout.writeln('''
  ┌─ search state ──────────────────────────────────────────────────────────
  │ query    ${s.query.isEmpty ? '(empty)' : s.query}
  │ status   ${s.status.name.padRight(7)}  req#${s.requestId}  pending={${s.pending.map((x) => x.name).join(',')}}
  │ recent   [${s.recent.join(' · ')}]
  │ knobs    tmdbKey=${sim.tmdbKeyed}  hideAnime=${s.hideAnime}  jikan429=${sim.jikan429}
  │          slow=${sim.slowSource?.name ?? '-'}  dupTitles=${sim.duplicateTitles}
  │          jikan reqs=${sim.jikanRequests}  429=${sim.jikan429Hits}
  │ dropped  stale=${s.requestsBumped}  timeouts=${s.sourceTimeouts}
  │ notice   ${s.notice ?? '-'}''');
  final r = s.results;
  if (r != null) {
    stdout.writeln('  │');
    stdout.writeln('  │ RESULTS (${r.grid.length} in grid):');
    if (r.topMatch != null) {
      stdout.writeln('  │   ★ ${r.topMatch!.kind} top: ${r.topMatch!.meta.name} (${r.topMatch!.meta.id})');
    }
    for (final m in r.movies) {
      stdout.writeln('  │     🎬 movie  ${m.name}  [${m.id}]  ${m.releaseInfo ?? ''}');
    }
    for (final m in r.series) {
      stdout.writeln('  │     📺 series ${m.name}  [${m.id}]  ${m.releaseInfo ?? ''}');
    }
    for (final a in r.anime) {
      stdout.writeln('  │     ⛩ anime  ${a.name}  [${a.metaId}]  ${a.year ?? ''}');
    }
    if (s.lastPlayMeta != null) {
      stdout.writeln('  │');
      stdout.writeln('  │ last playMeta frame: ${s.lastPlayMeta}');
    }
  }
  stdout.writeln('  └──────────────────────────────────────────────────────────');
  stdout.writeln('  > ');
}

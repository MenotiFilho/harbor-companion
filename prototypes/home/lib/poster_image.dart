// Poster images flow through Flutter's real ImageCache (putIfAbsent keyed by
// provider equality), so the benchmark measures genuine cache-hit behaviour —
// the same mechanics Image.network / cached_network_image rely on in the real
// app. The bytes are a tiny embedded PNG; decoding is deterministic and offline.
//
// loadCount counts actual decodes, which is the cache-miss signal the benchmark
// reads: scrolling back up should cause ~zero new loads if the cache holds.

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// A 1x1 transparent PNG, decoded for every poster in the spike.
const String _kPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

class PosterImage extends ImageProvider<PosterImage> {
  final String url;

  /// Total decode (cache-miss) count across all PosterImage instances.
  static int loadCount = 0;

  PosterImage(this.url);

  @override
  Future<PosterImage> obtainKey(ImageConfiguration configuration) async => this;

  @override
  ImageStreamCompleter loadImage(PosterImage key, ImageDecoderCallback decode) {
    loadCount++;
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: 1.0,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _load(PosterImage key, ImageDecoderCallback decode) async {
    final bytes = base64Decode(_kPng);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) => other is PosterImage && other.url == url;

  @override
  int get hashCode => Object.hash(PosterImage, url);
}

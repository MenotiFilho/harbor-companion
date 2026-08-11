#!/usr/bin/env bash
# Run the Search logic prototype. Uses `dart` from PATH, or DART_SDK env, or
# the Flutter SDK's dart, or a locally-downloaded SDK at /tmp/opencode/dart/dart-sdk.
set -euo pipefail
cd "$(dirname "$0")"

DART_BIN=""
if command -v dart >/dev/null 2>&1; then
  DART_BIN="$(command -v dart)"
elif [[ -n "${DART_SDK:-}" && -x "${DART_SDK}/bin/dart" ]]; then
  DART_BIN="${DART_SDK}/bin/dart"
elif [[ -x ~/flutter/bin/dart ]]; then
  DART_BIN=~/flutter/bin/dart
elif [[ -x /tmp/opencode/dart/dart-sdk/bin/dart ]]; then
  DART_BIN=/tmp/opencode/dart/dart-sdk/bin/dart
else
  echo "Dart SDK not found. Install it or set DART_SDK." >&2
  exit 1
fi

exec "$DART_BIN" run bin/search_proto.dart

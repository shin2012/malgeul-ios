#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if command -v swiftc >/dev/null; then S=$(command -v swiftc); else
  S="${SWIFTC:-$HOME/.local/swift/swift-6.0.3-RELEASE-ubuntu22.04-aarch64/usr/bin/swiftc}"
fi
OUT="${TMPDIR:?}/malgeul-recording-tests"
"$S" Malgeul/Core/RecordingSafety.swift RecordingTests/main.swift -o "$OUT"
"$OUT"
"$S" Malgeul/Core/RecordingLaunch.swift LaunchTests/main.swift -o "${OUT}-launch"
"${OUT}-launch"

#!/usr/bin/env bash
# 순수 로직(Aligner·VoiceMath·SpeakerLabel) 리눅스 시험 — Swift 툴체인 필요
set -euo pipefail
cd "$(dirname "$0")/.."
S="${SWIFTC:-$(ls -d ~/.local/swift/*/usr/bin 2>/dev/null | head -1)/swiftc}"
OUT="${TMPDIR:-/tmp}/malgeul-logic-tests"
"$S" -O Malgeul/OnDevice/Aligner.swift LogicTests/main.swift -o "$OUT"
"$OUT"

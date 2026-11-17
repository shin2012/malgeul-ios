#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${SWIFTC:-}" ]]; then S="$SWIFTC"
elif command -v swiftc >/dev/null; then S="$(command -v swiftc)"
else S="$(python3 -c 'import glob; print(glob.glob("/home/yoseop/.local/swift/*/usr/bin/swiftc")[0])')"
fi
OUT="${TMPDIR:?}/malgeul-note-list-tests"
"$S" Malgeul/Core/Models.swift Malgeul/Core/NoteListProjection.swift NoteListTests/main.swift -o "$OUT"
"$OUT"
python3 NoteListTests/store_test.py "$S"

#!/usr/bin/env bash
# 실제 앱에서 쓰는 두 번 누르기 삭제 정책 시험
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${SWIFTC:-}" ]]; then S="$SWIFTC"
elif command -v swiftc >/dev/null; then S="$(command -v swiftc)"
else
  S="$(python3 -c 'import glob; print(glob.glob("/home/yoseop/.local/swift/*/usr/bin/swiftc")[0])')"
fi
OUT="${TMPDIR:?}/malgeul-deletion-tests"
"$S" Malgeul/Core/TwoTapDeletion.swift DeletionTests/main.swift -o "$OUT"
"$OUT"

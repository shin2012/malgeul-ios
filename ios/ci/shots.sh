#!/bin/bash
# Usage: shots.sh <app path> <out dir>
set -u
APP="$1"; OUT="$2"; mkdir -p "$OUT"
BUNDLE=kr.b-612.malgeul
ARGS=(-demoServer http://127.0.0.1:8080 -demoToken demo)
DEFAULT="list detail chat doc record settings"
read -r -a SCREENS <<< "${SCREENS:-$DEFAULT}"

pick() { xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
c=[x for k,v in d.items() if 'iOS' in k for x in v if x['name'].startswith('$1')]
c.sort(key=lambda x: x['name'])
print(c[-1]['udid'] if c else '')"; }

# 실제 라이브 액티비티: 앱이 띄움 → 설정 앱으로 넘어가 다이내믹 아일랜드 → 잠금(⌘L) 후 깨워(⌘⇧H) 잠금 화면
real_live() {
  local UDID=$1 NAME=$2 s=$3
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE" "${ARGS[@]}" -screen "$s" >/dev/null
  sleep 12
  xcrun simctl io "$UDID" screenshot "$OUT/${NAME}-${s}-app.png" >/dev/null 2>&1
  xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null 2>&1 || true
  sleep 4
  xcrun simctl io "$UDID" screenshot "$OUT/${NAME}-${s}-island.png" >/dev/null 2>&1 && echo "shot $NAME $s island"
  open -a Simulator --args -CurrentDeviceUDID "$UDID" || true
  sleep 6
  osascript -e 'tell application "Simulator" to activate' -e 'delay 1' \
    -e 'tell application "System Events" to keystroke "l" using command down' || echo "lock keystroke failed"
  sleep 3
  osascript -e 'tell application "Simulator" to activate' \
    -e 'tell application "System Events" to keystroke "h" using {command down, shift down}' || echo "home keystroke failed"
  sleep 4
  xcrun simctl io "$UDID" screenshot "$OUT/${NAME}-${s}-lock.png" >/dev/null 2>&1 && echo "shot $NAME $s lock"
  osascript -e 'tell application "Simulator" to quit' || true
  sleep 2
}

for kind in "iPhone" "iPad Pro"; do
  UDID=$(pick "$kind")
  [ -z "$UDID" ] && { echo "no $kind"; continue; }
  NAME=$(echo "$kind" | tr ' ' '_')
  xcrun simctl boot "$UDID" || true
  xcrun simctl bootstatus "$UDID" -b
  xcrun simctl status_bar "$UDID" override --time 9:41 --batteryLevel 100 --cellularBars 4 || true
  if [ "$kind" = "iPad Pro" ]; then xcrun simctl ui "$UDID" appearance dark || true; fi
  xcrun simctl install "$UDID" "$APP"
  first=1
  for s in "${SCREENS[@]}"; do
    # 잠금 화면 점검(live·real): 이름 끝이 dark면 다크 모드, 아니면 주간 모드
    case "$s" in
      live|real) xcrun simctl ui "$UDID" appearance light || true ;;
      livedark|realdark) xcrun simctl ui "$UDID" appearance dark || true ;;
    esac
    if [ "$s" = real ] || [ "$s" = realdark ]; then
      real_live "$UDID" "$NAME" "$s"; first=0; continue
    fi
    xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" "${ARGS[@]}" -screen "$s" >/dev/null
    if [ $first = 1 ]; then sleep 15; first=0; else sleep 7; fi
    xcrun simctl io "$UDID" screenshot "$OUT/${NAME}-${s}.png" >/dev/null 2>&1 && echo "shot $NAME $s"
    if xcrun simctl spawn "$UDID" launchctl list | grep -q "$BUNDLE"; then echo "alive $NAME $s"; else echo "CRASHED $NAME $s"; fi
  done
  xcrun simctl shutdown "$UDID" || true
done

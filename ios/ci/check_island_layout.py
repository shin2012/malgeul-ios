#!/usr/bin/env python3
"""아일랜드의 세로 버튼 재사용·무제한 높이 회귀를 막는 소스 계약 시험."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
views = (root / 'LiveActivity/RecordingLiveViews.swift').read_text()
widget = (root / 'MalgeulWidget/RecordingLiveActivity.swift').read_text()
assert 'struct LiveIslandControls: View' in views, '아일랜드 전용 가로 제어부가 없음'
controls = views.split('struct LiveIslandControls: View', 1)[1].split('struct LiveIslandExpandedBottom:', 1)[0]
assert 'HStack(spacing: 8)' in controls and 'VStack(' not in controls, '아일랜드 버튼은 가로 한 줄이어야 함'
assert controls.count('.frame(width: 44, height: 44)') == 2, '일시정지·종료 터치 영역은 각각 44pt'
assert 'ToggleRecordingPauseIntent()' in controls and 'StopRecordingIntent()' in controls
assert controls.count('.accessibilityLabel(') == 2, '아이콘 버튼에 한글 접근성 이름 필요'
bottom = views.split('struct LiveIslandExpandedBottom:', 1)[1]
assert 'LiveIslandControls(shown: shown)' in bottom
assert 'LiveToggleButton(' not in bottom, '잠금 화면의 세로 버튼을 아일랜드에서 재사용하면 안 됨'
assert 'maxHeight: .infinity' not in widget, '확장 영역이 무제한 높이를 요구하면 안 됨'
compact = widget.split('compactTrailing: {', 1)[1].split('} minimal:', 1)[0]
assert '.lineLimit(1)' in compact and '.minimumScaleFactor(' in compact, '작은 아일랜드 시간은 큰 글씨에서도 한 줄 유지'
assert 'if shown.canStop { LiveToggleButton(shown: shown, scheme: scheme) }' in views, '잠금 화면 제어부는 유지'
print('PASS 아일랜드 가로 제어부·44pt 터치·접근성·높이 계약, 잠금 화면 제어부 유지')

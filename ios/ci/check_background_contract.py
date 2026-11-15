#!/usr/bin/env python3
"""간편 녹음이 앱 열기 우회로 되돌아가지 않게 소스 계약을 점검한다."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
intent = (root / 'Malgeul/Core/MalgeulAppShortcutsProvider.swift').read_text()
for forbidden in ['continueInForeground', 'requestToContinueInForeground', 'ForegroundContinuableIntent', '.foreground(', 'UIApplication.shared.applicationState']:
    assert forbidden not in intent, f'단축어에 전경 우회가 남음: {forbidden}'
assert 'static let openAppWhenRun = false' in intent
assert 'IntentModes = [.background]' in intent
assert 'start(requiresLiveActivity: true)' in intent
recorder = (root / 'Malgeul/Core/Recorder.swift').read_text()
assert '.mixWithOthers' in recorder
start = recorder.split('func start(requiresLiveActivity:', 1)[1].split('    func pause()', 1)[0]
assert '.setActive(true)' not in start, '녹음기의 자동 활성화보다 수동 활성화를 선행하지 않음'
print('PASS 앱 열기·전경 대기 우회 없음, 백그라운드 인텐트·혼합 세션 계약')

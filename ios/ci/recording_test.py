#!/usr/bin/env python3
"""실제 시뮬레이터 앱의 녹음 시험 결과를 회수하고 실패를 CI에 전달한다."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

app, out = sys.argv[1:]
out = Path(out)
out.mkdir(parents=True, exist_ok=True)
bundle = 'kr.b-612.malgeul'

def sim(*args):
    p = subprocess.run(['xcrun', 'simctl', *args], check=True, text=True, capture_output=True,
                       timeout=600 if args[0] == 'bootstatus' else 120)
    return p.stdout.strip()

devices = json.loads(sim('list', 'devices', 'available', '-j'))['devices']
runtimes = json.loads(sim('list', 'runtimes', '-j'))['runtimes']
runtime = max((r for r in runtimes if r.get('isAvailable') and 'iOS' in r['identifier']),
              key=lambda r: tuple(int(v) for v in r['version'].split('.')))
print('RUNTIME', runtime['identifier'], flush=True)
current_devices = devices[runtime['identifier']]
phones = [d for d in current_devices if d['name'].startswith('iPhone')]
udid = phones[0]['udid']
print('DEVICE', phones[0]['name'], udid, flush=True)
try:
    if phones[0]['state'] != 'Booted': sim('boot', udid)
    subprocess.run(['open','-a','Simulator','--args','-CurrentDeviceUDID',udid],check=True,timeout=60)
    sim('bootstatus', udid, '-b')
    sim('install', udid, app)
    sim('privacy', udid, 'grant', 'microphone', bundle)
    container = Path(sim('get_app_container', udid, bundle, 'data'))
    report = container / 'Documents/recording-selftest.json'
    for denied in [False, True]:
        if report.exists(): report.unlink()
        if denied: sim('privacy', udid, 'revoke', 'microphone', bundle)
        sim('launch', '--terminate-running-process', udid, bundle,
            '-demoServer', 'http://127.0.0.1:8080', '-demoToken', 'demo',
            '-recordingSelfTest', 'YES', '-recordingDeniedTest', 'YES' if denied else 'NO')
        deadline = time.monotonic() + 100
        while not report.exists() and time.monotonic() < deadline: time.sleep(1)
        if not report.exists(): raise RuntimeError('녹음 시험 결과 대기 시간 초과')
        data = json.loads(report.read_text())
        name = 'permission-denied' if denied else 'recording-runtime'
        (out / (name + '.json')).write_text(json.dumps(data, ensure_ascii=False, indent=2))
        print(name, json.dumps(data, ensure_ascii=False), flush=True)
        if data['failed'] or not data['checks']: raise RuntimeError(name + ' 실패')
    for screen in ['live', 'livedark']:
        sim('launch', '--terminate-running-process', udid, bundle,
            '-demoServer', 'http://127.0.0.1:8080', '-demoToken', 'demo',
            '-recordingSelfTest', 'NO', '-recordingDeniedTest', 'NO', '-screen', screen)
        time.sleep(5)
        sim('io', udid, 'screenshot', str(out / (screen + '.png')))
    sim('ui', udid, 'content_size', 'extra-extra-extra-large')
    sim('launch', '--terminate-running-process', udid, bundle,
        '-demoServer', 'http://127.0.0.1:8080', '-demoToken', 'demo',
        '-recordingSelfTest', 'NO', '-recordingDeniedTest', 'NO', '-screen', 'live')
    time.sleep(5)
    sim('io', udid, 'screenshot', str(out / 'live-large.png'))
    sim('ui', udid, 'content_size', 'large')
finally:
    sim('shutdown', udid)

# 아일랜드 없는 아이패드에서는 같은 미리보기와 기존 잠금 화면 카드의 회귀를 확인한다.
ipads = [d for d in current_devices if d['name'].startswith('iPad Pro')]
assert ipads, '아이패드 시뮬레이터가 없음'
ipad = ipads[0]['udid']
try:
    if ipads[0]['state'] != 'Booted': sim('boot', ipad)
    subprocess.run(['open','-a','Simulator','--args','-CurrentDeviceUDID',ipad],check=True,timeout=60)
    sim('bootstatus', ipad, '-b')
    sim('install', ipad, app)
    for screen in ['live', 'livedark']:
        sim('launch', '--terminate-running-process', ipad, bundle,
            '-demoServer', 'http://127.0.0.1:8080', '-demoToken', 'demo', '-screen', screen)
        time.sleep(7)
        sim('io', ipad, 'screenshot', str(out / ('ipad-' + screen + '.png')))
    sim('ui', ipad, 'content_size', 'extra-extra-extra-large')
    sim('launch', '--terminate-running-process', ipad, bundle,
        '-demoServer', 'http://127.0.0.1:8080', '-demoToken', 'demo', '-screen', 'live')
    time.sleep(5)
    sim('io', ipad, 'screenshot', str(out / 'ipad-live-large.png'))
finally:
    sim('shutdown', ipad)

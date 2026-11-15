#!/usr/bin/env python3
"""업로드 뒤 App Store Connect를 읽어 처리 상태와 내부 그룹 배포를 확인한다."""
import json
import os
from pathlib import Path
import time
import urllib.parse
import urllib.request
import jwt

kid, issuer = os.environ['ASC_KEY_ID'], os.environ['ASC_ISSUER_ID']
key = Path.home().joinpath('private_keys', f'AuthKey_{kid}.p8').read_text()
base = 'https://api.appstoreconnect.apple.com/v1/'

def api(path, body=None):
    now = int(time.time())
    token = jwt.encode({'iss': issuer, 'iat': now, 'exp': now + 600, 'aud': 'appstoreconnect-v1'}, key, algorithm='ES256', headers={'kid': kid})
    r = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'})
    with urllib.request.urlopen(r, timeout=60) as f: return json.load(f) if f.status != 204 else {}

def query(resource, params): return resource + '?' + urllib.parse.urlencode(params)

apps = api(query('apps', {'filter[bundleId]': 'kr.b-612.malgeul'}))['data']
assert len(apps) == 1
app_id = apps[0]['id']
build_number = os.environ['GITHUB_RUN_NUMBER']
deadline = time.monotonic() + 1200
while True:
    builds = api(query('builds', {'filter[app]': app_id, 'filter[version]': build_number, 'include': 'preReleaseVersion'}))
    build = next((b for b in builds['data'] if b['attributes']['version'] == build_number), None)
    state = build['attributes']['processingState'] if build else 'NOT_VISIBLE'
    print('ASC', build_number, state, flush=True)
    if state == 'VALID': break
    if state in ['FAILED', 'INVALID'] or time.monotonic() > deadline: raise RuntimeError('ASC processing: ' + state)
    time.sleep(30)

assert build is not None
internal = [g for g in api(f'apps/{app_id}/betaGroups')['data'] if g['attributes'].get('isInternalGroup')]
verified = []
for group in internal:
    members = api(f"betaGroups/{group['id']}/relationships/builds")['data']
    if not any(b['id'] == build['id'] for b in members):
        api(f"betaGroups/{group['id']}/relationships/builds", {'data': [{'type': 'builds', 'id': build['id']}]})
    members = api(f"betaGroups/{group['id']}/relationships/builds")['data']
    assert any(b['id'] == build['id'] for b in members), '그룹 빌드 연결 확인 실패'
    verified.append(group['id'])

result = {'build': build, 'included': builds.get('included', []), 'sourceRevision': os.environ['GITHUB_SHA'],
          'internalGroupIDs': verified, 'betaDetail': api(f"builds/{build['id']}/buildBetaDetail")['data']}
out = Path(os.environ['RUNNER_TEMP']) / 'verification'
out.mkdir(exist_ok=True)
(out / 'asc-build.json').write_text(json.dumps(result, indent=2))
print('ASC_VERIFIED', json.dumps(result), flush=True)

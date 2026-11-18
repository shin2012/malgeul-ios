#!/usr/bin/env python3
"""App Store Connect 앱 레코드에 macOS 플랫폼이 있는지 확인하고 없으면 추가한다.

CI에서 실행: ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8 환경변수.
사용: asc_prepare_mac.py <앱 번들 ID> <버전 x.y.z> [추가 번들 ID ...]
- 번들 ID의 platform 값을 출력(IOS로만 등록된 ID가 Mac 서명에 쓰이는지 진단용).
- MAC_OS appStoreVersion 이 없으면 POST /v1/appStoreVersions 로 플랫폼을 추가한다.
"""
import json, sys, time, urllib.error, urllib.parse, urllib.request, os
import jwt

bundle, version, extra = sys.argv[1], sys.argv[2], sys.argv[3:]
now = int(time.time())
token = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                   os.environ["ASC_KEY_P8"], algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]})
base = "https://api.appstoreconnect.apple.com/v1"

def call(path, body=None, method=None):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
                                 method=method or ("POST" if body else "GET"))
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.load(r) if r.length != 0 else {}
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

for ident in [bundle, *extra]:
    st, res = call("/bundleIds?" + urllib.parse.urlencode({"filter[identifier]": ident}))
    for item in res.get("data", []):
        if item["attributes"]["identifier"] == ident:
            print("번들", ident, "platform=", item["attributes"].get("platform"))

st, res = call("/apps?" + urllib.parse.urlencode({"filter[bundleId]": bundle}))
apps = [a for a in res.get("data", []) if a["attributes"]["bundleId"] == bundle]
if not apps:
    sys.exit(f"ASC 앱 레코드 없음: {bundle}")
app_id = apps[0]["id"]
st, res = call(f"/apps/{app_id}/appStoreVersions?" + urllib.parse.urlencode({"filter[platform]": "MAC_OS", "limit": 5}))
if res.get("data"):
    print("macOS 플랫폼 있음:", [v["attributes"]["versionString"] for v in res["data"]])
    sys.exit(0)
body = {"data": {"type": "appStoreVersions", "attributes": {"platform": "MAC_OS", "versionString": version},
                 "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}}
st, res = call("/appStoreVersions", body)
print("macOS 플랫폼 추가 응답", st, json.dumps(res, ensure_ascii=False)[:800])
if st not in (200, 201):
    sys.exit("macOS 플랫폼 추가 실패 — App Store Connect 앱 페이지에서 '플랫폼 추가 → macOS'가 필요할 수 있음")

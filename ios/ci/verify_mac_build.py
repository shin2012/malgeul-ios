#!/usr/bin/env python3
"""업로드한 macOS 빌드가 App Store Connect에서 VALID가 될 때까지 읽는다.
사용: verify_mac_build.py <번들 ID> <빌드 번호>"""
import json, os, sys, time, urllib.parse, urllib.request
import jwt

bundle, build_number = sys.argv[1], sys.argv[2]
def token():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                      os.environ["ASC_KEY_P8"], algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]})
def read(path):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com/v1" + path, headers={"Authorization": "Bearer " + token()})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)
app = read("/apps?" + urllib.parse.urlencode({"filter[bundleId]": bundle}))["data"][0]
for _ in range(45):
    res = read("/builds?" + urllib.parse.urlencode({"filter[app]": app["id"], "filter[version]": build_number,
                                                    "filter[preReleaseVersion.platform]": "MAC_OS", "include": "preReleaseVersion"}))
    if res["data"]:
        st = res["data"][0]["attributes"]["processingState"]
        ver = [i["attributes"]["version"] for i in res.get("included", []) if i["type"] == "preReleaseVersions"]
        print("MAC_OS 빌드", build_number, ver, st)
        if st == "VALID":
            sys.exit(0)
        if st in ("FAILED", "INVALID"):
            sys.exit("처리 실패: " + st)
    else:
        print("아직 목록에 없음")
    time.sleep(20)
sys.exit("처리 상태 확인 시간 초과")

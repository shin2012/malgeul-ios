#!/usr/bin/env python3
"""스크린샷용 가짜 서버 — 중립적인 예시 데이터만 사용. /app/api/* 를 Bearer demo 로 응답."""
import json, math, struct, wave, io
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "Bearer demo"

def meeting(i, title, status, tags, dur, size, cost, audio=1, ai=1, err=None, day=7):
    return {"id": i, "title": title, "original_filename": f"녹음 {i}.m4a", "duration_seconds": dur, "file_size_bytes": size,
            "status": status, "cost_usd": None if cost is None else f"{cost:.6f}", "error_message": err, "ai_analyzed": ai,
            "audio_ready": audio, "created_at": f"2026-11-0{day}T05:10:00.000Z", "recorded_at": f"2026-11-0{day}T01:00:00.000Z",
            "transcribed_at": None, "segment_count": 12, "tags": tags}

MEETINGS = [
    meeting(7, "새 녹음", "pending", [], None, 2_400_000, None, audio=0, ai=0, day=8),
    meeting(6, "주간 일정 점검", "processing", [], 1820, 7_300_000, None, day=8),
    meeting(5, "디자인 시안 검토 회의", "done", ["디자인", "일정", "시안"], 2794, 11_175_435, 0.131939),
    meeting(4, "고객 문의 대응 개선 논의", "done", ["고객지원", "자동화"], 4211, 16_800_000, 0.198812, day=5),
    meeting(3, "분기 예산 검토", "error", [], 980, 3_900_000, None, err="AssemblyAI 대기 시간 초과", day=4),
    meeting(2, "신규 서비스 기획 킥오프", "done", ["기획", "킥오프", "역할 분담"], 7793, 31_171_851, 0.368003, day=2),
]

SEGS = [
    ("김지현", "오늘은 디자인 시안 두 가지를 보고 다음 주 일정까지 정하려고 합니다. 먼저 첫 번째 시안부터 보시죠."),
    ("박민수", "첫 번째 시안은 메인 화면에 검색창을 크게 두고, 아래에 최근 본 항목을 카드로 보여 주는 구성입니다."),
    ("이서연(추정)", "카드가 너무 많으면 작은 화면에서 답답해 보일 것 같아요. 휴대폰 기준으로 세 장 정도면 어떨까요?"),
    ("김지현", "좋습니다. 그럼 휴대폰은 세 장, 태블릿은 여섯 장으로 하죠. 두 번째 시안은요?"),
    ("박민수", "두 번째는 목록형입니다. 정보가 많이 보이는 대신 첫인상이 조금 밋밋할 수 있습니다."),
    ("Speaker D", "저는 두 번째가 실제로 쓰기엔 더 편할 것 같아요. 검색 결과를 비교하기가 쉽거든요."),
    ("김지현", "그럼 기본은 첫 번째 시안으로 가고, 설정에서 목록형으로 바꿀 수 있게 하죠."),
    ("이서연(추정)", "일정은 다음 주 수요일까지 시안 확정, 금요일까지 개발 착수로 잡으면 될 것 같습니다."),
    ("박민수", "네, 수요일 오전에 최종 시안 공유드리겠습니다."),
    ("김지현", "좋아요. 오늘 회의는 여기까지 하겠습니다. 수고하셨습니다."),
]

def detail(mid):
    m = next((x for x in MEETINGS if x["id"] == mid), MEETINGS[2])
    d = dict(m)
    t = 6000
    segs = []
    for i, (sp, tx) in enumerate(SEGS):
        segs.append({"seq": i, "speaker": sp, "text": tx, "start_ms": t, "end_ms": t + 9000})
        t += 11000
    d["transcript_json"] = segs if m["status"] == "done" else []
    return d

REPORT = {"meeting_id": 5, "type": "meeting", "subject": "디자인 시안 검토 및 개발 착수 일정 확정", "status": "done",
          "error_message": None, "model": "demo", "updated_at": "2026-11-07T05:20:00.000Z", "edited_at": "2026-11-07T06:00:00.000Z"}

SPEAKER = {"status": "done", "result": {
    "assigned": [
        {"from": "Speaker C", "to": "이서연(추정)", "basis": "목소리+내용 일치", "similarity": 0.91,
         "evidence": ["일정은 다음 주 수요일까지 시안 확정, 금요일까지 개발 착수로 잡으면 될 것 같습니다."]},
    ],
    "unresolved": {"Speaker D": "확신 부족 (최고 0.55)"},
    "voice": {"by_label": {}},
}}

CHAT = {"history": [
    {"role": "user", "text": "주요 결정사항을 정리해줘"},
    {"role": "assistant", "text": "## 주요 결정사항\n\n1. **기본 화면**은 첫 번째 시안(검색창 + 카드)으로 결정\n2. 설정에서 **목록형**으로 바꿀 수 있게 함\n3. 카드 수: 휴대폰 3장, 태블릿 6장\n\n| 할 일 | 담당 | 기한 |\n|---|---|---|\n| 최종 시안 공유 | 박민수 | 수요일 오전 |\n| 개발 착수 | 개발팀 | 금요일 |\n\n> 다음 회의에서 시안 반응을 다시 확인하기로 했습니다."},
]}

REPORT_HTML = """<!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>(회의록) 261107_예시</title><style>body{font-family:-apple-system;margin:0;background:#eee}.bar{position:sticky;top:0;background:#222;color:#fff;padding:10px;display:flex;gap:8px}
.bar button{border:0;border-radius:6px;padding:6px 10px}.doc{background:#fff;margin:16px auto;max-width:720px;padding:32px;min-height:900px}
h1{text-align:center;letter-spacing:.3em}</style></head><body data-type="meeting" data-conf="on" data-wm="on">
<div class=bar><button onclick="window.print()">인쇄 / PDF 저장</button><button id=btn-save>저장</button><span id=save-st>수정본</span></div>
<article class="doc" id="doc"><h1>회 의 록</h1><p class=subject>디자인 시안 검토 및 개발 착수 일정 확정</p>
<ul><li>기본 화면은 첫 번째 시안으로 결정</li><li>설정에서 목록형 선택 가능</li><li>다음 주 수요일 최종 시안 공유</li></ul></article></body></html>"""

def tone_wav():
    buf = io.BytesIO()
    w = wave.open(buf, "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(b"".join(struct.pack("<h", int(3000 * math.sin(i / 16000 * 2 * math.pi * 440))) for i in range(16000 * 3)))
    w.close()
    return buf.getvalue()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, body, ctype="application/json; charset=utf-8"):
        b = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(b))); self.end_headers()
        self.wfile.write(b)

    def route(self):
        p = self.path.split("?")[0]
        if p == "/health": return self.send(200, {"ok": True})
        if not p.startswith("/app/api/"): return self.send(404, {"error": "Not Found"})
        if self.headers.get("Authorization") != TOKEN: return self.send(401, {"error": "앱 토큰이 올바르지 않습니다"})
        parts = p[len("/app/api/"):].strip("/").split("/")
        if parts == ["meetings"]: return self.send(200, MEETINGS)
        if parts == ["util", "exchange-rate"]: return self.send(200, {"rate": 1380.5})
        if parts[0] == "meetings" and len(parts) >= 2 and parts[1].isdigit():
            mid = int(parts[1]); rest = parts[2:]
            if not rest: return self.send(200, detail(mid))
            if rest == ["report"]: return self.send(200, REPORT)
            if rest == ["speaker-id"]: return self.send(200, SPEAKER)
            if rest == ["report.html"]: return self.send(200, REPORT_HTML.encode(), "text/html; charset=utf-8")
            if rest == ["audio"]: return self.send(200, tone_wav(), "audio/wav")
            return self.send(200, {"ok": True})
        if parts[0] == "chat" and parts[-1] == "history": return self.send(200, CHAT)
        if parts[0] == "transcribe" and parts[1] == "progress":
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            self.wfile.write(b'data: {"type":"progress","message":"AssemblyAI \xeb\x8c\x80\xea\xb8\xb0 \xec\xa4\x91..."}\n\n'); self.wfile.flush()
            import time; time.sleep(60); return
        return self.send(200, {"ok": True})

    do_GET = route
    do_POST = route
    do_PATCH = route
    do_PUT = route
    do_DELETE = route

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(__import__("os").environ.get("PORT", "8080"))), H).serve_forever()

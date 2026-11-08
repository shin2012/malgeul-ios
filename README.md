# 📝 줄글로 iOS

![Swift](https://img.shields.io/badge/Swift-5-F05138?style=flat-square&logo=swift&logoColor=white)
![iOS](https://img.shields.io/badge/iOS-18%2B-000000?style=flat-square&logo=apple&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-앱-0A84FF?style=flat-square&logo=swift&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-TestFlight-2088FF?style=flat-square&logo=githubactions&logoColor=white)

회의 녹음 받아쓰기 서비스 **줄글로**의 iPhone·iPad 앱입니다. 웹에서 하던 일을 모두 앱에서 할 수 있고, 앱 안에서 바로 녹음해 올릴 수 있습니다.

> [!NOTE]
> 이 저장소에는 앱 코드만 있습니다. 서버 주소와 앱 토큰은 코드에 없으며, 설정 화면이나 `julglo://setup?server=…&token=…` 링크로 기기에 입력합니다(토큰은 키체인 저장).

---

## ✨ 기능

| 구분 | 내용 |
|------|------|
| 🎙️ 녹음 | 앱에서 바로 녹음(AAC 모노 24kHz), 일시정지·이어서, 화면이 꺼져도 계속 녹음, 전화 등 끼어들기 후 자동 이어 녹음, 실시간 파형 |
| ⬆️ 업로드 | 녹음 끝 → 제목 입력 → 업로드(녹음 시작 시각을 녹음 시각으로 저장), 선택 시 압축이 끝나면 바로 받아쓰기 |
| 📂 파일 추가 | 파일 앱에서 가져오기, 음성 메모 등 다른 앱의 공유·열기로 바로 업로드 |
| 🔁 백그라운드 업로드 | 앱을 닫아도 업로드 계속, SHA-256 중복 확인, 100MB 초과는 Tailscale 직통 경로로만 |
| 📋 회의 목록 | 상태·길이·크기(압축 중 표시)·녹음 시각·등록 상대 시각·비용(달러/원)·태그, 정렬 7가지, 검색, 통계(전체·완료·총 길이·누적 비용·환율) |
| ✏️ 편집 | 제목 수정, 녹음 시각 수정, 여러 개 선택 삭제 |
| 🧠 받아쓰기 | AssemblyAI / 로컬 선택, 진행 상황 실시간 표시, 취소 |
| 📜 스크립트 | 화자별 색 구분, 구간 재생(오디오는 한 번 받아 두고 재사용), 화자 이름 변경(전체/이 발언만), 스크립트 검색 |
| 💬 채팅 | 스크립트 기반 질문(스트리밍 답변), 추천 질문, 대화 기록 지우기, 마크다운(표·목록) 표시 |
| 📄 문서 | 회의록·출장복명서 자동 작성(자동 판별/회의록/출장복명서), 보기·편집·저장·자동 작성본으로 되돌리기, 인쇄, PDF 보기·공유, HTML 저장 |
| 🗣️ 화자 식별 | 자동 식별 결과(근거·목소리 유사도·미확정) 보기, 다시 식별 |
| 📴 오프라인 | 마지막으로 받은 목록·스크립트를 먼저 보여 줌 |

---

## 🧭 화면 구성

```mermaid
flowchart LR
    A[회의 탭] --> B[회의 목록]
    B --> C[스크립트]
    C --> D[채팅<br/>아이패드: 오른쪽 패널<br/>아이폰: 시트]
    C --> E[문서 패널]
    E --> F[보기·편집]
    G[녹음 탭] --> H[녹음기]
    H --> I[녹음 완료 → 업로드]
    G --> J[내 녹음]
    K[설정 탭]
```

---

## 🔐 서버 연결

앱은 서버의 앱 전용 경로 `/app/api/*`를 `Authorization: Bearer <앱 토큰>`으로 호출합니다. 서버는 토큰을 확인한 뒤 `/api/*`로 넘깁니다.

<details>
<summary>설정 링크 형식</summary>

```
julglo://setup?server=https://<서버>&tailscale=https://<Tailscale 직통 주소>&token=<앱 토큰>
```

</details>

---

## 🛠️ 빌드

Mac 없이 GitHub Actions에서 빌드합니다.

| 동작 | 결과 |
|------|------|
| `ios/**` 푸시 | 시뮬레이터 빌드(서명 없음)로 컴파일 확인 |
| `gh workflow run ios.yml -f testflight=true` | 아카이브 → IPA → TestFlight 업로드 |

- 프로젝트 파일은 `ios/gen_project.py`로 생성합니다(동기화 폴더 방식이라 `ios/Julglo/` 안의 Swift 파일은 자동 포함).
- 필요한 저장소 비밀값: `ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `APPLE_TEAM_ID`
- 번들 ID: `kr.b-612.julglo`

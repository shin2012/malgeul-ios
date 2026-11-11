import Foundation

/// 기기 받아쓰기 후 화자 추정
enum SpeakerMode: String, CaseIterable, Identifiable {
    case server, device, hybrid, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .server: return "서버 (목소리+내용)"
        case .device: return "이 기기 (목소리)"
        case .hybrid: return "기기 목소리 + 서버 내용"
        case .off: return "하지 않음"
        }
    }
    var usesDeviceVoice: Bool { self == .device || self == .hybrid }
}

/// 로그인한 회원
struct AccountUser: Codable, Equatable {
    var id: Int
    var email: String
    var name: String
    var role: String
    var isAdmin: Bool { role == "admin" }
}

/// 서버 주소(빌드 때 고정)·로그인 토큰·앱 옵션. 토큰은 공유 키체인, 나머지는 UserDefaults.
@MainActor
final class AppConfig: ObservableObject {
    static let shared = AppConfig()

    // 공개 저장소라 서버 주소는 코드에 두지 않음 — CI가 빌드할 때 비밀값 MG_SERVER_URL을 Info.plist(MGServerURL)에 넣음
    var server: String { SharedSettings.server }
    /// 로그인 토큰 (공유 키체인 → 공유 확장도 같은 값을 씀)
    @Published var token: String { didSet { Keychain.set(token, for: "session") } }
    @Published var user: AccountUser? {
        didSet { UserDefaults.standard.set(user.flatMap { try? JSONEncoder().encode($0) }, forKey: "account") }
    }
    /// 올릴 그룹 (없으면 서버의 기본 그룹)
    @Published var uploadGroup: Int? { didSet { Keychain.set(uploadGroup.map(String.init) ?? "", for: "uploadGroup") } }
    /// 녹음을 올린 뒤 압축이 끝나면 바로 AssemblyAI 받아쓰기 시작
    @Published var autoTranscribeRecordings: Bool { didSet { UserDefaults.standard.set(autoTranscribeRecordings, forKey: "autoTranscribe") } }
    /// 업로드가 끝난 녹음 파일을 기기에서 지울지
    @Published var deleteAfterUpload: Bool { didSet { UserDefaults.standard.set(deleteAfterUpload, forKey: "deleteAfterUpload") } }
    /// 받아쓰기 방식 (공유 확장도 읽도록 키체인)
    @Published var engine: TranscribeEngine { didSet { Keychain.set(engine.rawValue, for: "engine") } }
    /// 공유 메뉴로 받은 파일 처리 방식 (공유 확장도 읽도록 키체인)
    @Published var shareAction: ShareAction { didSet { Keychain.set(shareAction.rawValue, for: "shareAction") } }
    /// 기기 받아쓰기 때 화자 추정 방식
    @Published var speakerMode: SpeakerMode { didSet { UserDefaults.standard.set(speakerMode.rawValue, forKey: "speakerMode") } }
    /// 기기 목소리 판정 기준 (기기 임베딩 모델은 서버와 달라 따로 맞춤)
    @Published var voiceStrong: Double { didSet { UserDefaults.standard.set(voiceStrong, forKey: "voiceStrong") } }
    @Published var voiceWeak: Double { didSet { UserDefaults.standard.set(voiceWeak, forKey: "voiceWeak") } }
    @Published var voiceMargin: Double { didSet { UserDefaults.standard.set(voiceMargin, forKey: "voiceMargin") } }

    static let defaultVoice = (strong: 0.75, weak: 0.55, margin: 0.15)
    var voiceThresholds: [String: Double] { ["strong": voiceStrong, "weak": voiceWeak, "margin": voiceMargin] }

    /// 기기 받아쓰기 가능 여부 (iOS 26+)
    static var deviceTranscribeAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private init() {
        let d = UserDefaults.standard
        // 예전 방식(서버 주소·공용 앱 토큰·Tailscale 직통 주소)은 더 쓰지 않음 → 지우고 로그인부터
        for k in ["server", "appToken", "tailscale"] where Keychain.get(k) != nil { Keychain.set("", for: k) }
        token = Keychain.get("session") ?? ""
        user = d.data(forKey: "account").flatMap { try? JSONDecoder().decode(AccountUser.self, from: $0) }
        uploadGroup = Keychain.get("uploadGroup").flatMap(Int.init)
        autoTranscribeRecordings = d.object(forKey: "autoTranscribe") as? Bool ?? false
        deleteAfterUpload = d.object(forKey: "deleteAfterUpload") as? Bool ?? false
        let e = TranscribeEngine.current
        engine = (e == .device && !AppConfig.deviceTranscribeAvailable) ? .assemblyai : e
        speakerMode = SpeakerMode(rawValue: d.string(forKey: "speakerMode") ?? "") ?? .server
        let sa = ShareAction.current
        shareAction = (sa == .deviceThenUpload && !AppConfig.deviceTranscribeAvailable) ? .keep : sa
        voiceStrong = d.object(forKey: "voiceStrong") as? Double ?? AppConfig.defaultVoice.strong
        voiceWeak = d.object(forKey: "voiceWeak") as? Double ?? AppConfig.defaultVoice.weak
        voiceMargin = d.object(forKey: "voiceMargin") as? Double ?? AppConfig.defaultVoice.margin
    }

    var isConfigured: Bool {
        !token.trimmingCharacters(in: .whitespaces).isEmpty && server.hasPrefix("http") && URL(string: server) != nil
    }

    /// 로그아웃: 토큰·회원 정보 지움 (기기에 있는 녹음은 남김)
    func signOut() {
        token = ""
        user = nil
        uploadGroup = nil
    }
}

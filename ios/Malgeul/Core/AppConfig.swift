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

/// 서버 주소·앱 토큰·앱 옵션. 토큰은 키체인, 나머지는 UserDefaults.
@MainActor
final class AppConfig: ObservableObject {
    static let shared = AppConfig()

    // 공개 저장소이므로 서버 주소·토큰은 코드에 두지 않음 — 설정 화면 또는 malgeul://setup 링크로 입력
    static let defaultServer = ""
    static let defaultTailscale = ""

    // 서버 주소·토큰은 공유 키체인에 저장 → 공유 확장(다른 앱에서 보내기)도 같은 값을 씀
    @Published var server: String { didSet { Keychain.set(server, for: "server") } }
    @Published var tailscaleServer: String { didSet { Keychain.set(tailscaleServer, for: "tailscale") } }
    @Published var token: String { didSet { Keychain.set(token, for: "appToken") } }
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
        server = Keychain.get("server") ?? AppConfig.defaultServer
        tailscaleServer = Keychain.get("tailscale") ?? AppConfig.defaultTailscale
        token = Keychain.get("appToken") ?? ""
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

    /// malgeul://setup?server=https://...&token=...
    func handleSetupURL(_ url: URL) -> Bool {
        guard url.scheme == "malgeul", url.host == "setup",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        if let s = items.first(where: { $0.name == "server" })?.value, !s.isEmpty { server = s }
        if let t = items.first(where: { $0.name == "tailscale" })?.value, !t.isEmpty { tailscaleServer = t }
        if let t = items.first(where: { $0.name == "token" })?.value, !t.isEmpty { token = t }
        return true
    }
}

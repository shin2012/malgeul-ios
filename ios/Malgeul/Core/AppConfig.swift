import Foundation

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

    private init() {
        let d = UserDefaults.standard
        server = Keychain.get("server") ?? AppConfig.defaultServer
        tailscaleServer = Keychain.get("tailscale") ?? AppConfig.defaultTailscale
        token = Keychain.get("appToken") ?? ""
        autoTranscribeRecordings = d.object(forKey: "autoTranscribe") as? Bool ?? false
        deleteAfterUpload = d.object(forKey: "deleteAfterUpload") as? Bool ?? false
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

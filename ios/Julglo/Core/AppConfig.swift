import Foundation
import Security

/// 서버 주소·앱 토큰·앱 옵션. 토큰은 키체인, 나머지는 UserDefaults.
@MainActor
final class AppConfig: ObservableObject {
    static let shared = AppConfig()

    // 공개 저장소이므로 서버 주소·토큰은 코드에 두지 않음 — 설정 화면 또는 julglo://setup 링크로 입력
    static let defaultServer = ""
    static let defaultTailscale = ""

    @Published var server: String { didSet { UserDefaults.standard.set(server, forKey: "server") } }
    @Published var tailscaleServer: String { didSet { UserDefaults.standard.set(tailscaleServer, forKey: "tailscaleServer") } }
    @Published var token: String { didSet { Keychain.set(token, for: "appToken") } }
    /// 녹음을 올린 뒤 압축이 끝나면 바로 AssemblyAI 받아쓰기 시작
    @Published var autoTranscribeRecordings: Bool { didSet { UserDefaults.standard.set(autoTranscribeRecordings, forKey: "autoTranscribe") } }
    /// 업로드가 끝난 녹음 파일을 기기에서 지울지
    @Published var deleteAfterUpload: Bool { didSet { UserDefaults.standard.set(deleteAfterUpload, forKey: "deleteAfterUpload") } }

    private init() {
        let d = UserDefaults.standard
        server = d.string(forKey: "server") ?? AppConfig.defaultServer
        tailscaleServer = d.string(forKey: "tailscaleServer") ?? AppConfig.defaultTailscale
        token = Keychain.get("appToken") ?? ""
        autoTranscribeRecordings = d.object(forKey: "autoTranscribe") as? Bool ?? false
        deleteAfterUpload = d.object(forKey: "deleteAfterUpload") as? Bool ?? false
    }

    var isConfigured: Bool {
        !token.trimmingCharacters(in: .whitespaces).isEmpty && server.hasPrefix("http") && URL(string: server) != nil
    }

    /// julglo://setup?server=https://...&token=...
    func handleSetupURL(_ url: URL) -> Bool {
        guard url.scheme == "julglo", url.host == "setup",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        if let s = items.first(where: { $0.name == "server" })?.value, !s.isEmpty { server = s }
        if let t = items.first(where: { $0.name == "tailscale" })?.value, !t.isEmpty { tailscaleServer = t }
        if let t = items.first(where: { $0.name == "token" })?.value, !t.isEmpty { token = t }
        return true
    }
}

enum Keychain {
    private static let service = "kr.b-612.julglo"

    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        #if targetEnvironment(simulator)
        if status != errSecSuccess { UserDefaults.standard.set(value, forKey: "kc_" + key) }
        #else
        _ = status
        #endif
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            return String(data: d, encoding: .utf8)
        }
        #if targetEnvironment(simulator)
        return UserDefaults.standard.string(forKey: "kc_" + key)
        #else
        return nil
        #endif
    }
}

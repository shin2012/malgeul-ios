import Foundation
import Security

/// 앱과 공유 확장이 함께 쓰는 키체인 (공유 키체인 그룹 — App Group 없이 자동 서명 가능)
enum Keychain {
    private static let service = "kr.b-612.malgeul"
    private static var group: String? {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "SharedKeychainGroup") as? String,
              !g.isEmpty, !g.contains("$(") else { return nil }
        return g
    }

    private static func base(_ key: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    static func set(_ value: String, for key: String) {
        SecItemDelete(base(key) as CFDictionary)
        guard !value.isEmpty else {
            #if targetEnvironment(simulator)
            UserDefaults.standard.removeObject(forKey: "kc_" + key)
            #endif
            return
        }
        var add = base(key)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        #if targetEnvironment(simulator)
        // 서명 없는 시뮬레이터 빌드는 키체인 그룹 권한이 없어 실패 → UserDefaults로 대신
        if status != errSecSuccess { UserDefaults.standard.set(value, forKey: "kc_" + key) }
        #else
        _ = status
        #endif
    }

    static func get(_ key: String) -> String? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
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

/// 서버 연결 정보 (앱 설정에서 저장, 공유 확장이 읽음)
enum SharedSettings {
    static var server: String { Keychain.get("server") ?? "" }
    static var tailscale: String { Keychain.get("tailscale") ?? "" }
    static var token: String { (Keychain.get("appToken") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static var isConfigured: Bool { !token.isEmpty && server.hasPrefix("http") && URL(string: server) != nil }

    static func apiURL(_ path: String, server: String) -> URL? {
        URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines) + "/app/api/" + path)
    }
}

/// 업로드 공용 도구: 해시·멀티파트 본문·경로 선택
enum UploadKit {
    static let hundredMB: Int64 = 100 * 1024 * 1024

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func sha256(of url: URL) -> String? {
        SHA256Stream.hex(of: url)
    }

    /// fields 는 파일보다 앞에 넣어야 서버가 읽음 (recorded_at, auto_transcribe)
    static func writeMultipart(source: URL, filename: String, fields: [String: String], boundary: String, to out: URL) throws {
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let w = try FileHandle(forWritingTo: out)
        defer { try? w.close() }
        var head = ""
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n"
        }
        let safeName = filename.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n"
        head += "Content-Type: \(mime(for: filename))\r\n\r\n"
        try w.write(contentsOf: Data(head.utf8))
        let r = try FileHandle(forReadingFrom: source)
        defer { try? r.close() }
        while true {
            let chunk = autoreleasepool { r.readData(ofLength: 4 * 1024 * 1024) }
            if chunk.isEmpty { break }
            try w.write(contentsOf: chunk)
        }
        try w.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    static func mime(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "webm": return "audio/webm"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }

    /// Tailscale 직통 주소가 열려 있는지 (4초)
    static func probe(_ base: String) async -> Bool {
        let b = base.trimmingCharacters(in: .whitespaces)
        guard b.hasPrefix("http"), let u = URL(string: b + "/health") else { return false }
        var r = URLRequest(url: u)
        r.timeoutInterval = 4
        guard let (_, resp) = try? await URLSession.shared.data(for: r), let h = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(h.statusCode)
    }
}

import Foundation
import UIKit

enum APIError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "로그인이 필요합니다."
        case .http(401, let msg): return msg.isEmpty ? "로그인이 필요합니다." : msg
        case .http(let code, let msg): return msg.isEmpty ? "HTTP \(code)" : msg
        case .badResponse: return "응답 파싱 오류"
        }
    }
}

extension Error {
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let u = self as? URLError, u.code == .cancelled { return true }
        return false
    }
}

/// 말글 서버 API. 앱 전용 경로 /app/api/* 를 Bearer 토큰으로 호출.
@MainActor
final class API {
    static let shared = API()
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    var config: AppConfig { AppConfig.shared }

    func baseURL(_ server: String? = nil, requireLogin: Bool = true) throws -> URL {
        let s = (server ?? config.server).trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("http"), var u = URL(string: s) else { throw APIError.http(0, "서버 주소가 빌드에 들어 있지 않습니다") }
        if requireLogin && !config.isConfigured { throw APIError.notConfigured }
        u.append(path: "app/api")
        return u
    }

    // MARK: 회원 (로그인 전에도 부름)

    private func publicJSON(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let u = URL(string: try baseURL(requireLogin: false).absoluteString + "/" + path) else { throw APIError.badResponse }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await session.data(for: r)
        try Self.check(resp, d)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    /// 로그인 → 토큰·회원 정보 저장
    func login(email: String, password: String) async throws {
        let o = try await publicJSON("auth/login", ["email": email, "password": password, "client": "app",
                                                    "device_name": UIDevice.current.name + " · 말글 앱"])
        guard let t = o["token"] as? String, let u = o["user"] as? [String: Any],
              let d = try? JSONSerialization.data(withJSONObject: u),
              let user = try? JSONDecoder().decode(AccountUser.self, from: d) else { throw APIError.badResponse }
        config.token = t
        config.user = user
    }
    /// 가입 신청 (관리자 승인 후 사용) → 안내 문구
    func signup(email: String, password: String, name: String) async throws -> String {
        let o = try await publicJSON("auth/signup", ["email": email, "password": password, "name": name])
        return o["message"] as? String ?? "가입 신청이 접수되었습니다."
    }
    func resetRequest(email: String) async throws -> String {
        let o = try await publicJSON("auth/reset-request", ["email": email])
        return o["message"] as? String ?? "메일을 보냈습니다."
    }
    /// 회원 정보 새로 받기 (이름·권한 바뀜 반영)
    func refreshMe() async {
        guard let d = try? await data("auth/me"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let u = o["user"],
              let ud = try? JSONSerialization.data(withJSONObject: u),
              let user = try? JSONDecoder().decode(AccountUser.self, from: ud) else { return }
        config.user = user
    }
    func logout() async {
        _ = try? await data("auth/logout", method: "POST", json: [:])
        config.signOut()
    }
    func deleteAccount(password: String) async throws {
        try await data("auth/account", method: "DELETE", json: ["password": password])
        config.signOut()
    }
    func rename(user name: String) async throws {
        try await data("auth/me", method: "PATCH", json: ["name": name])
        config.user?.name = name
    }

    // MARK: 그룹

    func groups() async throws -> [MeetingGroup] {
        let d = try await data("groups")
        DiskCache.save(d, key: "groups")
        return try decode([MeetingGroup].self, d)
    }
    func createGroup(_ name: String) async throws { try await data("groups", method: "POST", json: ["name": name]) }
    func renameGroup(_ id: Int, _ name: String) async throws { try await data("groups/\(id)", method: "PATCH", json: ["name": name]) }
    func deleteGroup(_ id: Int) async throws { try await data("groups/\(id)", method: "DELETE") }
    func moveMeeting(_ id: Int, toGroup g: Int) async throws { try await data("meetings/\(id)/group", method: "PATCH", json: ["group_id": g]) }

    func url(_ path: String, server: String? = nil) throws -> URL {
        // path 예: "meetings/12/report.html?download=1"
        let base = try baseURL(server).absoluteString
        guard let u = URL(string: base + "/" + path) else { throw APIError.badResponse }
        return u
    }

    var authHeader: String { "Bearer \(config.token.trimmingCharacters(in: .whitespacesAndNewlines))" }

    func request(_ path: String, method: String = "GET", json: [String: Any]? = nil, server: String? = nil) throws -> URLRequest {
        var r = URLRequest(url: try url(path, server: server))
        r.httpMethod = method
        r.setValue(authHeader, forHTTPHeaderField: "Authorization")
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    @discardableResult
    func data(_ path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> Data {
        let r = try request(path, method: method, json: json)
        let (d, resp) = try await session.data(for: r)
        try Self.check(resp, d)
        return d
    }

    static func check(_ resp: URLResponse, _ d: Data) throws {
        guard let h = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(h.statusCode) else {
            var msg = ""
            if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let e = o["error"] as? String { msg = e }
            // 로그인이 풀림(만료·다른 기기에서 비밀번호 변경·사용 중지) → 로그인 화면으로
            if h.statusCode == 401, (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["login"] as? Bool == true {
                Task { @MainActor in AppConfig.shared.signOut() }
            }
            throw APIError.http(h.statusCode, msg)
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ d: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: d) } catch { throw APIError.badResponse }
    }

    // MARK: 회의

    func meetingsRaw() async throws -> Data { try await data("meetings") }

    func meeting(_ id: Int) async throws -> MeetingDetail {
        let d = try await data("meetings/\(id)")
        DiskCache.save(d, key: "meeting_\(id)")
        return try decode(MeetingDetail.self, d)
    }

    func setTitle(_ id: Int, _ title: String) async throws {
        try await data("meetings/\(id)/title", method: "PATCH", json: ["title": title])
    }

    func setRecordedAt(_ id: Int, _ date: Date) async throws -> Date? {
        let d = try await data("meetings/\(id)/recorded-at", method: "PATCH", json: ["recorded_at": DateParse.isoString(date)])
        let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        return (o?["recorded_at"] as? String).flatMap(DateParse.iso)
    }

    func renameSpeaker(_ id: Int, old: String, new: String, seq: Int, all: Bool) async throws {
        try await data("meetings/\(id)/speaker", method: "PATCH",
                       json: ["old_speaker": old, "new_speaker": new, "segment_index": seq, "all": all])
    }

    func deleteMeeting(_ id: Int) async throws {
        try await data("meetings/\(id)", method: "DELETE")
        DiskCache.remove(key: "meeting_\(id)")
    }

    func checkHash(_ hash: String, server: String) async throws -> DuplicateCheck {
        let r = try request("meetings/check-hash?hash=\(hash)", server: server)
        let (d, resp) = try await session.data(for: r)
        try Self.check(resp, d)
        return try decode(DuplicateCheck.self, d)
    }

    // MARK: 받아쓰기

    func startTranscribe(_ id: Int, local: Bool) async throws {
        try await data(local ? "transcribe/start-local" : "transcribe/start", method: "POST", json: ["id": id])
    }

    func cancelTranscribe(_ id: Int) async throws {
        try await data("transcribe/cancel", method: "POST", json: ["id": id])
    }

    /// SSE 진행률: 메시지 문자열을 내보내고 done/error에서 끝남
    func transcribeProgress(_ id: Int) -> AsyncThrowingStream<[String: Any], Error> {
        sse(path: "transcribe/progress/\(id)", method: "GET", json: nil)
    }

    // MARK: 기기 받아쓰기

    /// 기기 받아쓰기 결과 저장. replace=true면 이미 받아쓴 회의도 덮어씀(서버가 이전 대본 보관)
    func submitDeviceResult(_ id: Int, segments: [DeviceSegment], duration: Double, engine: String,
                            speakerMode: SpeakerMode, voice: [String: Any]?, replace: Bool) async throws {
        var body: [String: Any] = ["id": id, "segments": segments.map(\.json), "duration_seconds": Int(duration.rounded()),
                                   "engine": engine, "speaker_mode": speakerMode.rawValue, "replace": replace]
        if let voice { body["voice"] = voice }
        var r = try request("transcribe/device-result", method: "POST", json: body)
        r.timeoutInterval = 120
        let (d, resp) = try await session.data(for: r)
        try Self.check(resp, d)
    }

    /// 웹·다른 기기에서도 진행률이 보이게 (실패해도 무시)
    func deviceProgress(_ id: Int, pct: Double?, message: String?, done: Bool = false) async {
        var body: [String: Any] = ["id": id, "done": done]
        if let pct { body["pct"] = Int(pct * 100) }
        if let message { body["message"] = message }
        _ = try? await data("transcribe/device-progress", method: "POST", json: body)
    }

    struct VoicePerson: Decodable { let key: String; let name: String; let clips: Int; let seconds: Int }
    struct VoiceProfilesResponse: Decodable { let version: String; let people: [VoicePerson] }

    func voiceProfiles(exclude: Int?) async throws -> VoiceProfilesResponse {
        try decode(VoiceProfilesResponse.self, try await data("voice/profiles" + (exclude.map { "?exclude=\($0)" } ?? "")))
    }

    /// 인물 참고 음성(16kHz wav) 내려받기
    func voicePersonAudio(key: String, exclude: Int?) async throws -> URL {
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "key", value: key)] + (exclude.map { [URLQueryItem(name: "exclude", value: String($0))] } ?? [])
        var r = try request("voice/person-audio" + (c.percentEncodedQuery.map { "?" + $0 } ?? ""))
        r.timeoutInterval = 180
        let (tmp, resp) = try await session.download(for: r)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw APIError.http(h.statusCode, "") }
        let out = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).wav")
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    /// 기기에서 계산한 목소리 점수로 화자 다시 추정
    func rerunSpeakerIDWithVoice(_ id: Int, mode: SpeakerMode, voice: [String: Any]) async throws {
        try await data("meetings/\(id)/speaker-id", method: "POST", json: ["mode": mode.rawValue, "voice": voice])
    }

    /// 시험용 복제(오디오만 복사, 대본 없음)
    func cloneMeeting(_ id: Int, prefix: String) async throws -> Int {
        let d = try await data("meetings/\(id)/clone", method: "POST", json: ["prefix": prefix])
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any], let n = (o["id"] as? NSNumber)?.intValue else {
            throw APIError.badResponse
        }
        return n
    }

    // MARK: 채팅

    func chatHistory(_ id: Int) async throws -> [ChatMessage] {
        let d = try await data("chat/\(id)/history")
        let r = try decode(ChatHistoryResponse.self, d)
        return r.history.map { ChatMessage(role: $0.role, text: $0.text ?? $0.content ?? "") }
    }

    func clearChat(_ id: Int) async throws { try await data("chat/\(id)/history", method: "DELETE") }

    func chat(_ id: Int, question: String) -> AsyncThrowingStream<[String: Any], Error> {
        sse(path: "chat/\(id)", method: "POST", json: ["question": question])
    }

    private func sse(path: String, method: String, json: [String: Any]?) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { cont in
            let task = Task { @MainActor in
                do {
                    var r = try self.request(path, method: method, json: json)
                    r.timeoutInterval = 600
                    r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, resp) = try await self.session.bytes(for: r)
                    if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                        var body = Data()
                        for try await b in bytes { body.append(b); if body.count > 4000 { break } }
                        try Self.check(resp, body)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = Data(line.dropFirst(6).utf8)
                        if let o = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                            cont.yield(o)
                        }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: 문서 · 화자 식별

    func report(_ id: Int) async throws -> ReportInfo {
        try decode(ReportInfo.self, try await data("meetings/\(id)/report"))
    }

    func generateReport(_ id: Int, type: String) async throws {
        try await data("meetings/\(id)/report", method: "POST", json: ["type": type])
    }

    func speakerID(_ id: Int) async throws -> SpeakerIDInfo {
        try decode(SpeakerIDInfo.self, try await data("meetings/\(id)/speaker-id"))
    }

    func rerunSpeakerID(_ id: Int) async throws {
        try await data("meetings/\(id)/speaker-id", method: "POST")
    }

    /// report.pdf / report.html?download=1 을 내려받아 서버가 붙인 파일 이름으로 임시 폴더에 저장
    func downloadReport(_ id: Int, pdf: Bool) async throws -> URL {
        let r = try request(pdf ? "meetings/\(id)/report.pdf?download=1" : "meetings/\(id)/report.html?download=1")
        let (d, resp) = try await session.data(for: r)
        try Self.check(resp, d)
        var name = (resp as? HTTPURLResponse).flatMap { Self.filename(from: $0) } ?? "report.\(pdf ? "pdf" : "html")"
        name = name.replacingOccurrences(of: "/", with: "_")
        let dir = FileManager.default.temporaryDirectory.appending(path: "reports/\(id)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appending(path: name)
        try d.write(to: out)
        return out
    }

    static func filename(from resp: HTTPURLResponse) -> String? {
        guard let cd = resp.value(forHTTPHeaderField: "Content-Disposition") else { return nil }
        if let r = cd.range(of: "filename*=UTF-8''") {
            let enc = cd[r.upperBound...].split(separator: ";").first.map(String.init) ?? ""
            return enc.removingPercentEncoding
        }
        if let r = cd.range(of: "filename=\"") {
            return cd[r.upperBound...].split(separator: "\"").first.map(String.init)
        }
        return nil
    }

    // MARK: 기타

    func exchangeRate() async -> Double? {
        guard let d = try? await data("util/exchange-rate") else { return nil }
        return (try? JSONDecoder().decode(ExchangeRate.self, from: d))?.rate
    }

    // MARK: 오디오 (구간 재생용, 한 번 받아 두고 재사용)

    func audioFile(_ id: Int) async throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "audio", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appending(path: "\(id).mp3")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let r = try request("meetings/\(id)/audio")
        let (tmp, resp) = try await session.download(for: r)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw APIError.http(h.statusCode, h.statusCode == 404 ? "오디오 없음" : "")
        }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }
}

/// 서버 응답 원본을 그대로 저장해 두고 다음 실행 때 먼저 보여 줌(오프라인에서도 목록·스크립트 열람)
enum DiskCache {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "cache", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func save(_ d: Data, key: String) { try? d.write(to: dir.appending(path: key + ".json"), options: .atomic) }
    static func load(key: String) -> Data? { try? Data(contentsOf: dir.appending(path: key + ".json")) }
    static func remove(key: String) { try? FileManager.default.removeItem(at: dir.appending(path: key + ".json")) }
}

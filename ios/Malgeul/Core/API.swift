import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "설정에서 서버 주소와 앱 토큰을 입력해 주세요."
        case .http(401, _): return "앱 토큰이 올바르지 않습니다. 설정에서 확인해 주세요."
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

    func baseURL(_ server: String? = nil) throws -> URL {
        let s = (server ?? config.server).trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.isConfigured, var u = URL(string: s) else { throw APIError.notConfigured }
        u.append(path: "app/api")
        return u
    }

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

    /// Tailscale 직통 주소(ts.meetings…)가 열리는지 — 100MB 넘는 파일은 이 경로로만 올릴 수 있음
    func probeTailscale() async -> Bool {
        let ts = config.tailscaleServer.trimmingCharacters(in: .whitespaces)
        guard ts.hasPrefix("http"), let u = URL(string: ts + "/health") else { return false }
        var r = URLRequest(url: u)
        r.timeoutInterval = 4
        guard let (_, resp) = try? await session.data(for: r), let h = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(h.statusCode)
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

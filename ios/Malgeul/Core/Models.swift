import Foundation

// MARK: - 유연한 JSON 값 (화자 식별 결과처럼 모양이 바뀌는 데이터용)

enum JSONValue: Decodable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
    subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }
    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var array: [JSONValue] { if case .array(let a) = self { return a }; return [] }
    var object: [String: JSONValue] { if case .object(let o) = self { return o }; return [:] }
    var isNull: Bool { if case .null = self { return true }; return false }
}

// MARK: - 디코딩 도우미

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension KeyedDecodingContainer where K == AnyKey {
    func int(_ k: String) -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: AnyKey(k)) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: AnyKey(k)) { return Int(v) }
        if let s = try? decodeIfPresent(String.self, forKey: AnyKey(k)) { return Int(s) }
        if let b = try? decodeIfPresent(Bool.self, forKey: AnyKey(k)) { return b ? 1 : 0 }
        return nil
    }
    func double(_ k: String) -> Double? {
        if let v = try? decodeIfPresent(Double.self, forKey: AnyKey(k)) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: AnyKey(k)) { return Double(s) }
        return nil
    }
    func str(_ k: String) -> String? { try? decodeIfPresent(String.self, forKey: AnyKey(k)) }
    func date(_ k: String) -> Date? { str(k).flatMap(DateParse.iso) }
}

enum DateParse {
    private static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func iso(_ s: String) -> Date? { frac.date(from: s) ?? plain.date(from: s) }
    static func isoString(_ d: Date) -> String { frac.string(from: d) }
}

// MARK: - 회의

struct Meeting: Decodable, Identifiable, Hashable {
    let id: Int
    var title: String
    var originalFilename: String?
    var durationSeconds: Int?
    var fileSizeBytes: Int?
    var status: String
    var costUsd: Double?
    var errorMessage: String?
    var aiAnalyzed: Int?
    var audioReady: Int?
    var createdAt: Date?
    var recordedAt: Date?
    var transcribedAt: Date?
    var segmentCount: Int?
    var tags: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.int("id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "id 없음"))
        }
        self.id = id
        title = c.str("title") ?? "(제목 없음)"
        originalFilename = c.str("original_filename")
        durationSeconds = c.int("duration_seconds")
        fileSizeBytes = c.int("file_size_bytes")
        status = c.str("status") ?? "pending"
        costUsd = c.double("cost_usd")
        errorMessage = c.str("error_message")
        aiAnalyzed = c.int("ai_analyzed")
        audioReady = c.int("audio_ready")
        createdAt = c.date("created_at")
        recordedAt = c.date("recorded_at")
        transcribedAt = c.date("transcribed_at")
        segmentCount = c.int("segment_count")
        if let t = try? c.decodeIfPresent([String].self, forKey: AnyKey("tags")) {
            tags = t
        } else if let s = c.str("tags"), let d = s.data(using: .utf8), let t = try? JSONDecoder().decode([String].self, from: d) {
            tags = t
        } else {
            tags = []
        }
    }

    var isDone: Bool { status == "done" }
    var isProcessing: Bool { status == "processing" }
    var isCompressing: Bool { audioReady == 0 }
    var recordedOrCreated: Date? { recordedAt ?? createdAt }
}

struct Segment: Decodable, Identifiable, Hashable {
    var seq: Int
    var speaker: String
    var text: String
    var startMs: Int?
    var endMs: Int?
    var id: Int { seq }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        seq = c.int("seq") ?? 0
        speaker = c.str("speaker") ?? "화자"
        text = c.str("text") ?? ""
        startMs = c.int("start_ms")
        endMs = c.int("end_ms")
    }
}

struct MeetingDetail: Decodable {
    var meeting: Meeting
    var segments: [Segment]

    init(from decoder: Decoder) throws {
        meeting = try Meeting(from: decoder)
        let c = try decoder.container(keyedBy: AnyKey.self)
        segments = (try? c.decodeIfPresent([Segment].self, forKey: AnyKey("transcript_json"))) ?? []
    }
}

// MARK: - 문서(회의록/출장복명서)

struct ReportInfo: Decodable, Equatable {
    var type: String?
    var subject: String?
    var status: String
    var errorMessage: String?
    var model: String?
    var updatedAt: String?
    var editedAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        type = c.str("type")
        subject = c.str("subject")
        status = c.str("status") ?? "none"
        errorMessage = c.str("error_message")
        model = c.str("model")
        updatedAt = c.str("updated_at")
        editedAt = c.str("edited_at")
    }
    init(status: String) { self.status = status }
}

// MARK: - 화자 자동 식별

struct SpeakerIDInfo: Decodable {
    var status: String?
    var result: JSONValue?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        status = c.str("status")
        result = try? c.decodeIfPresent(JSONValue.self, forKey: AnyKey("result"))
    }
    init(status: String?) { self.status = status; result = nil }
}

// MARK: - 채팅

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: String   // user | assistant
    var text: String
    var streaming = false
}

struct ChatHistoryResponse: Decodable {
    struct Item: Decodable { var role: String; var text: String?; var content: String? }
    var history: [Item]
}

struct ExchangeRate: Decodable { var rate: Double? }

struct DuplicateCheck: Decodable {
    struct Existing: Decodable { var id: Int?; var title: String? }
    var duplicate: Bool
    var existing: Existing?
}

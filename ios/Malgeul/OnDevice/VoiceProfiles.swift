import Foundation

/// 기기 화자 추정용 인물 목소리 프로필.
/// 서버가 이름이 확정된 사람별 참고 음성(최대 60초)을 주면 기기에서 임베딩을 계산해 캐시한다.
/// 캐시 키 = 인물키 + 참고 구간 서명(구간 수·길이) → 이름 표기가 바뀌거나 새 회의가 생기면 그 사람만 다시 계산.
@MainActor
final class VoiceProfiles: ObservableObject {
    static let shared = VoiceProfiles()

    struct Person: Codable, Identifiable, Equatable {
        var key: String
        var name: String
        var sig: String
        var embedding: [Float]
        var id: String { key + "|" + sig }
    }
    private struct Store: Codable {
        var engine: String
        var people: [Person]
        var updatedAt: Date?
    }

    @Published private(set) var cached: [Person] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var busy = false
    @Published var status: String?

    private static var file: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appending(path: "voice_profiles.json")
    }

    private init() {
        if let d = try? Data(contentsOf: Self.file), let s = try? JSONDecoder().decode(Store.self, from: d),
           s.engine == DiarizerEngine.engineName {
            cached = s.people
            updatedAt = s.updatedAt
        }
    }

    /// 프로필 수(최근 계산된 서로 다른 인물)
    var peopleCount: Int { Set(cached.map(\.key)).count }

    private func save() {
        let s = Store(engine: DiarizerEngine.engineName, people: cached, updatedAt: updatedAt)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: Self.file, options: .atomic) }
    }

    func clear() {
        cached = []
        updatedAt = nil
        try? FileManager.default.removeItem(at: Self.file)
    }

    /// 필요한 인물 프로필을 준비해 돌려줌. exclude: 이 회의의 발언은 참고 음성에서 뺌(자기 자신과 비교 방지)
    func ensure(exclude: Int?, onProgress: ((Double, String) -> Void)? = nil) async throws -> [Person] {
        busy = true
        defer { busy = false; status = nil }
        let list = try await API.shared.voiceProfiles(exclude: exclude)
        var out: [Person] = []
        for (i, p) in list.people.enumerated() {
            let sig = "\(p.clips)-\(p.seconds)"
            if var hit = cached.first(where: { $0.key == p.key && $0.sig == sig }) {
                if hit.name != p.name { hit.name = p.name; replace(hit) }
                out.append(hit)
                continue
            }
            let msg = "목소리 프로필 만드는 중 · \(p.name) (\(i + 1)/\(list.people.count))"
            status = msg
            onProgress?(Double(i) / Double(max(1, list.people.count)), msg)
            try Task.checkCancellation()
            let wav = try await API.shared.voicePersonAudio(key: p.key, exclude: exclude)
            defer { try? FileManager.default.removeItem(at: wav) }
            guard let emb = try await DiarizerEngine.shared.embedSingle(url: wav) else { continue }
            let person = Person(key: p.key, name: p.name, sig: sig, embedding: emb)
            replace(person)
            out.append(person)
        }
        // 제외 없이 받은 목록 기준으로 더는 없는 인물·서명은 정리
        if exclude == nil {
            let keep = Set(out.map(\.id))
            cached.removeAll { !keep.contains($0.id) }
        }
        updatedAt = Date()
        save()
        onProgress?(1, "목소리 프로필 준비 완료")
        return out
    }

    private func replace(_ p: Person) {
        cached.removeAll { $0.key == p.key && $0.sig == p.sig }
        cached.append(p)
        if cached.count > 300 { cached.removeFirst(cached.count - 300) }
    }

    /// 라벨별 임베딩 → 서버로 보낼 voice 본문
    static func voicePayload(labelEmbeddings: [String: [Float]], people: [Person]) -> (payload: [String: Any], scores: [String: [(name: String, sim: Double)]]) {
        let s = VoiceMath.scores(labels: labelEmbeddings, people: people.map { ($0.name, $0.embedding) })
        let cfg = AppConfig.shared
        let payload: [String: Any] = [
            "by_label": VoiceMath.scoresJSON(s),
            "thresholds": cfg.voiceThresholds,
            "profiled": people.map(\.name),
            "engine": DiarizerEngine.engineName
        ]
        return (payload, s)
    }
}

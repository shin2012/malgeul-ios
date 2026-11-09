import Foundation

// 기기 받아쓰기 결과 맞추기 — 순수 로직(Foundation만 사용, 서버 리눅스에서도 시험)
// 받아쓰기 단어(시각 포함) + 화자 구간 → 화자별 발언 세그먼트

/// 받아쓰기 조각 하나. text는 원문 그대로(앞뒤 공백 포함될 수 있음). 시각은 초.
struct TimedWord: Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// 화자 구분 결과 구간 (초)
struct SpeakerTurn: Equatable {
    var speaker: String
    var start: Double
    var end: Double
}

/// 서버에 보낼 발언 세그먼트
struct DeviceSegment: Codable, Equatable {
    var speaker: String
    var text: String
    var startMs: Int
    var endMs: Int

    var json: [String: Any] { ["speaker": speaker, "text": text, "start_ms": startMs, "end_ms": endMs] }
}

enum Aligner {
    /// 'Speaker A', 'Speaker B'… (등장 순서). 26명 넘으면 'Speaker AA'…
    static func label(_ i: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        if i < 26 { return "Speaker \(letters[i])" }
        return "Speaker \(letters[(i / 26 - 1) % 26])\(letters[i % 26])"
    }

    /// 화자 구분 모델의 내부 이름(S1, 0 …)을 등장 순서대로 'Speaker A'… 로 바꿈
    static func relabel(_ turns: [SpeakerTurn]) -> (turns: [SpeakerTurn], map: [String: String]) {
        var map: [String: String] = [:]
        let sorted = turns.sorted { $0.start < $1.start }
        for t in sorted where map[t.speaker] == nil { map[t.speaker] = label(map.count) }
        return (sorted.map { SpeakerTurn(speaker: map[$0.speaker]!, start: $0.start, end: $0.end) }, map)
    }

    /// 단어 구간과 가장 많이 겹치는 화자. 겹침이 없으면 가까운 구간(maxDistance 초 안)의 화자
    static func speaker(for w: TimedWord, turns: [SpeakerTurn], maxDistance: Double = 2.0) -> String? {
        var best: String?
        var bestOverlap = 0.0
        for t in turns {
            let o = min(w.end, t.end) - max(w.start, t.start)
            if o > bestOverlap { bestOverlap = o; best = t.speaker }
        }
        if best != nil { return best }
        let mid = (w.start + w.end) / 2
        var bestDist = Double.infinity
        for t in turns {
            let d = mid < t.start ? t.start - mid : (mid > t.end ? mid - t.end : 0)
            if d < bestDist { bestDist = d; best = t.speaker }
        }
        return bestDist <= maxDistance ? best : nil
    }

    static func endsSentence(_ s: String) -> Bool {
        guard let c = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!。？！".contains(c)
    }

    /// 단어 → 세그먼트.
    /// 끊는 기준: 화자가 바뀜 / 쉼이 maxGap초 넘음 / 세그먼트가 maxLen초 넘었고 문장이 끝남
    static func align(words: [TimedWord], turns rawTurns: [SpeakerTurn],
                      maxGap: Double = 1.5, maxLen: Double = 30) -> [DeviceSegment] {
        let words = words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !words.isEmpty else { return [] }
        let turns = relabel(rawTurns).turns
        // 조각에 띄어쓰기가 들어 있지 않은 엔진이면 공백으로 이음
        let hasSpaces = words.contains { ($0.text.first?.isWhitespace ?? false) || ($0.text.last?.isWhitespace ?? false) }

        var out: [DeviceSegment] = []
        var cur: (speaker: String, text: String, start: Double, end: Double)?
        var lastSpeaker = turns.first?.speaker ?? label(0)

        func flush() {
            guard let c = cur else { return }
            let t = c.text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                out.append(DeviceSegment(speaker: c.speaker, text: t,
                                         startMs: Int((c.start * 1000).rounded()), endMs: Int((c.end * 1000).rounded())))
            }
            cur = nil
        }

        for w in words {
            let sp = speaker(for: w, turns: turns) ?? lastSpeaker
            lastSpeaker = sp
            if let c = cur {
                let gap = w.start - c.end
                let tooLong = c.end - c.start > maxLen && endsSentence(c.text)
                if sp != c.speaker || gap > maxGap || tooLong { flush() }
            }
            if cur == nil {
                cur = (sp, w.text, w.start, w.end)
            } else {
                cur!.text += hasSpaces ? w.text : " " + w.text
                cur!.end = max(cur!.end, w.end)
            }
        }
        flush()
        return out
    }
}

/// 목소리 임베딩 비교 — 순수 로직
enum VoiceMath {
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y; na += x * x; nb += y * y
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// 여러 임베딩의 평균(각각 길이 1로 맞춘 뒤)
    static func centroid(_ list: [[Float]]) -> [Float]? {
        let v = list.filter { !$0.isEmpty }
        guard let n = v.first?.count, v.allSatisfy({ $0.count == n }) else { return nil }
        var sum = [Double](repeating: 0, count: n)
        for e in v {
            let norm = e.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            guard norm > 0 else { continue }
            for i in 0..<n { sum[i] += Double(e[i]) / norm }
        }
        return sum.map { Float($0 / Double(v.count)) }
    }

    /// 라벨별 인물 유사도 (내림차순): { "Speaker A": [(name, sim)] }
    static func scores(labels: [String: [Float]], people: [(name: String, embedding: [Float])]) -> [String: [(name: String, sim: Double)]] {
        var out: [String: [(name: String, sim: Double)]] = [:]
        for (label, e) in labels {
            out[label] = people.map { ($0.name, cosine(e, $0.embedding)) }.sorted { $0.1 > $1.1 }
        }
        return out
    }

    /// 서버로 보낼 JSON 모양: { label: [{name, sim}] } (상위 5명)
    static func scoresJSON(_ s: [String: [(name: String, sim: Double)]]) -> [String: Any] {
        var o: [String: Any] = [:]
        for (k, v) in s {
            o[k] = v.prefix(5).map { ["name": $0.name, "sim": ($0.sim * 1000).rounded() / 1000] as [String: Any] }
        }
        return o
    }
}

/// 익명 화자 라벨 판별 (서버 speakerId.js isAnonLabel 과 같은 규칙)
enum SpeakerLabel {
    static func isAnon(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.range(of: "^(speaker|화자|참석자|발화자)\\s*[a-z0-9]{1,3}$", options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func isEstimated(_ s: String) -> Bool {
        s.range(of: "추정\\)\\s*$", options: .regularExpression) != nil
    }
}

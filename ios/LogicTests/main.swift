// 리눅스에서 순수 로직 시험: ios/LogicTests/run.sh
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    if !cond { failures += 1; print("✗ \(msg) (line \(line))") } else { print("✓ \(msg)") }
}

// relabel: 등장 순서대로 Speaker A, B
do {
    let r = Aligner.relabel([SpeakerTurn(speaker: "S2", start: 5, end: 6), SpeakerTurn(speaker: "S7", start: 0, end: 4), SpeakerTurn(speaker: "S2", start: 7, end: 8)])
    check(r.map["S7"] == "Speaker A" && r.map["S2"] == "Speaker B", "relabel 등장 순서")
    check(r.turns.first?.speaker == "Speaker A", "relabel 정렬")
    check(Aligner.label(26) == "Speaker AA" && Aligner.label(27) == "Speaker AB", "27번째 이후 라벨")
}

// speaker(for:): 겹침 최대, 겹침 없으면 근처
do {
    let turns = [SpeakerTurn(speaker: "Speaker A", start: 0, end: 2), SpeakerTurn(speaker: "Speaker B", start: 1.5, end: 5)]
    check(Aligner.speaker(for: TimedWord(text: "x", start: 1.6, end: 3), turns: turns) == "Speaker B", "겹침 큰 쪽")
    check(Aligner.speaker(for: TimedWord(text: "x", start: 6, end: 6.5), turns: turns) == "Speaker B", "겹침 없으면 가까운 구간")
    check(Aligner.speaker(for: TimedWord(text: "x", start: 20, end: 21), turns: turns) == nil, "너무 멀면 nil")
}

// align: 화자 변경·쉼·띄어쓰기
do {
    let words = [
        TimedWord(text: " 안녕하세요", start: 0.0, end: 0.8),
        TimedWord(text: " 반갑습니다.", start: 0.9, end: 1.6),
        TimedWord(text: " 네", start: 2.0, end: 2.3),
        TimedWord(text: " 좋아요", start: 2.4, end: 2.9),
        TimedWord(text: " 다음", start: 6.0, end: 6.4),   // 쉼 3초 → 새 세그먼트(같은 화자)
        TimedWord(text: "   ", start: 6.5, end: 6.6)      // 빈 조각 무시
    ]
    let turns = [SpeakerTurn(speaker: "s1", start: 0, end: 1.8), SpeakerTurn(speaker: "s0", start: 1.9, end: 3.0), SpeakerTurn(speaker: "s0", start: 5.8, end: 7)]
    let segs = Aligner.align(words: words, turns: turns)
    check(segs.count == 3, "세그먼트 3개 (\(segs.count))")
    check(segs.first == DeviceSegment(speaker: "Speaker A", text: "안녕하세요 반갑습니다.", startMs: 0, endMs: 1600), "첫 세그먼트 \(segs.first.map { "\($0)" } ?? "")")
    check(segs.dropFirst().first?.speaker == "Speaker B" && segs.dropFirst().first?.text == "네 좋아요", "두 번째 화자 B")
    check(segs.last?.text == "다음" && segs.last?.startMs == 6000, "쉼 뒤 새 세그먼트")
}

// align: 띄어쓰기 없는 조각은 공백으로 이음, 화자 정보 없으면 Speaker A
do {
    let segs = Aligner.align(words: [TimedWord(text: "하나", start: 0, end: 1), TimedWord(text: "둘", start: 1.1, end: 2)], turns: [])
    check(segs.count == 1 && segs[0].text == "하나 둘" && segs[0].speaker == "Speaker A", "공백 없는 조각·화자 없음")
}

// align: 긴 발언은 문장 끝에서 자름
do {
    var words: [TimedWord] = []
    for i in 0..<40 { words.append(TimedWord(text: i % 10 == 9 ? " 끝." : " 말", start: Double(i), end: Double(i) + 0.9)) }
    let segs = Aligner.align(words: words, turns: [SpeakerTurn(speaker: "a", start: 0, end: 50)], maxLen: 15)
    check(segs.count >= 2 && segs.allSatisfy { Aligner.endsSentence($0.text) || $0 == segs.last! }, "긴 발언 문장 끝에서 자름 (\(segs.count))")
}

// VoiceMath
do {
    check(abs(VoiceMath.cosine([1, 0], [1, 0]) - 1) < 1e-9, "cosine 같음 1")
    check(abs(VoiceMath.cosine([1, 0], [0, 1])) < 1e-9, "cosine 직교 0")
    check(VoiceMath.cosine([1, 0], [1, 0, 0]) == 0, "길이 다르면 0")
    let c = VoiceMath.centroid([[2, 0], [0, 3]])!
    check(abs(c[0] - 0.5) < 1e-6 && abs(c[1] - 0.5) < 1e-6, "centroid 정규화 평균")
    let s = VoiceMath.scores(labels: ["Speaker A": [1, 0]], people: [("갑", [0, 1]), ("을", [1, 0.1])])
    check(s["Speaker A"]?.first?.name == "을", "scores 내림차순")
    let j = VoiceMath.scoresJSON(s)["Speaker A"] as? [[String: Any]]
    check(j?.count == 2 && (j?.first?["name"] as? String) == "을", "scoresJSON")
}

// SpeakerLabel
do {
    check(SpeakerLabel.isAnon("Speaker A") && SpeakerLabel.isAnon("화자 2") && !SpeakerLabel.isAnon("신요섭"), "익명 라벨")
    check(SpeakerLabel.isEstimated("신요섭(추정)") && SpeakerLabel.isEstimated("김용섭이사(프레임아웃, 추정)") && !SpeakerLabel.isEstimated("신요섭"), "추정 라벨")
}

print(failures == 0 ? "모두 통과" : "실패 \(failures)건")
exit(failures == 0 ? 0 : 1)

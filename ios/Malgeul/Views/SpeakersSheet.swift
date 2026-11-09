import SwiftUI

/// 참석자 · 대화 점유율 (웹과 같은 시트)
/// 화자별 말한 시간 비율 막대, 이름 바꾸기·추정 확정, 자동으로 찾기(서버 화자 식별) 결과
struct SpeakersSheet: View {
    let meetingID: Int
    let segments: [Segment]
    @ObservedObject var doc: DocModel
    var onRename: (String, String) -> Void   // (old, new) 전체 변경

    @Environment(\.dismiss) private var dismiss
    @State private var editing: String?
    @State private var value = ""
    @State private var confirmRerun = false
    @FocusState private var focused: Bool

    struct Person: Identifiable { let id: String; var ms: Int; var count: Int }

    private var people: [Person] {
        var map: [String: Person] = [:]
        for s in segments {
            var p = map[s.speaker] ?? Person(id: s.speaker, ms: 0, count: 0)
            p.ms += max(0, (s.endMs ?? s.startMs ?? 0) - (s.startMs ?? 0))
            p.count += 1
            map[s.speaker] = p
        }
        return map.values.sorted { $0.ms > $1.ms }
    }

    var body: some View {
        let list = people
        let total = max(1, list.reduce(0) { $0 + $1.ms })
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(list) { (p: Person) in
                        row(p, pct: Double(p.ms) / Double(total))
                        if p.id != list.last?.id { Divider().overlay(Color.mgLine) }
                    }
                    autoBox.padding(.top, 16)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(Color.mgBg)
            .navigationTitle("참석자 · 대화 점유율")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("닫기")
                }
            }
            .confirmationDialog("화자를 다시 찾을까요?", isPresented: $confirmRerun, titleVisibility: .visible) {
                Button("다시 찾기") { Task { await doc.rerunSpeaker() } }
            } message: { Text("자동으로 붙인 ‘추정’ 이름은 원래 라벨로 되돌린 뒤 다시 판단합니다.") }
            .task { await doc.refresh() }
        }
    }

    private func row(_ p: Person, pct: Double) -> some View {
        let sp = SpeakerName(p.id)
        return HStack(alignment: .top, spacing: 12) {
            SpeakerAvatar(initial: sp.initial, size: 36)
            if editing == p.id {
                HStack(spacing: 8) {
                    TextField("이름 (예: 홍길동(소속))", text: $value)
                        .focused($focused)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12).frame(height: 40)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentMalgeul, lineWidth: 1))
                        .onSubmit { save(p.id) }
                    Button("저장") { save(p.id) }.buttonStyle(WebButtonStyle())
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(sp.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.mgFg)
                        if !sp.org.isEmpty { Text(sp.org).font(.system(size: 13)).foregroundStyle(Color.mgFg3) }
                        if sp.guess { Pill(text: "추정") }
                    }
                    .lineLimit(1)
                    HStack(spacing: 10) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.mgBg3)
                                Capsule().fill(Color.accentMalgeul).frame(width: max(5, g.size.width * pct))
                            }
                        }
                        .frame(height: 8)
                        Text(String(format: "%.1f%%", pct * 100)).font(.system(size: 13)).monospacedDigit()
                            .foregroundStyle(Color.mgFg2).frame(width: 50, alignment: .trailing)
                    }
                    Text("발언 \(p.count)회 · \(Fmt.durationKo(p.ms / 1000))").font(.system(size: 13)).monospacedDigit().foregroundStyle(Color.mgFg3)
                }
                Button(sp.guess ? "확정·수정" : "이름 바꾸기") {
                    value = SpeakerName.editable(p.id)
                    editing = p.id
                    focused = true
                }
                .buttonStyle(WebButtonStyle(kind: .ghost, small: true))
            }
        }
        .padding(.vertical, 14)
    }

    private func save(_ old: String) {
        let n = value.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        if !n.isEmpty && n != old { onRename(old, n) }
    }

    private var autoBox: some View {
        let s = doc.speaker
        let res = s?.result
        let assigned = res?["assigned"]?.array ?? []
        var status = "아직 실행하지 않았습니다"
        switch s?.status {
        case "processing": status = "내용과 목소리를 분석하는 중… 몇 분 걸립니다"
        case "done": status = assigned.isEmpty ? "찾지 못했습니다" : "\(assigned.count)명을 찾았습니다"
        case "skipped": status = res?["basis"]?.string == "이미 지정됨" ? "이름이 이미 모두 지정되어 있습니다" : (res?["basis"]?.string ?? "건너뜀")
        case "error": status = "오류: \(res?["error"]?.string ?? "")"
        default: break
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("자동으로 찾기").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.mgFg)
                    HStack(spacing: 6) {
                        if s?.status == "processing" { ProgressView().controlSize(.mini) }
                        Text(status).font(.system(size: 13.5)).foregroundStyle(Color.mgFg3)
                    }
                }
                Spacer()
                Button(s?.status == nil ? "찾기" : "다시 찾기") { confirmRerun = true }
                    .buttonStyle(WebButtonStyle(kind: .ghost, small: true))
                    .disabled(s?.status == "processing")
            }
            if s?.status == "done" {
                ForEach(Array(assigned.enumerated()), id: \.offset) { (_: Int, a: JSONValue) in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(a["from"]?.string ?? "") → \(a["to"]?.string ?? "")").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.mgFg)
                        Text([a["basis"]?.string, a["similarity"]?.double.map { String(format: "목소리 %.2f", $0) }].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 13)).foregroundStyle(Color.mgFg2)
                        if let ev = a["evidence"]?[0]?.string {
                            Text("“\(ev)”").font(.system(size: 13)).foregroundStyle(Color.mgFg3).lineLimit(3)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.mgBg2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

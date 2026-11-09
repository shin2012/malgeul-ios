import SwiftUI

/// 상세 화면 ⋯ — 아래에서 올라오는 시트 (클로바노트 구성: 다운로드 3칸 + 동작 목록)
struct MeetingActionsSheet: View {
    let hasReport: Bool
    var pick: (MeetingAction) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("내보내기").font(.headline).padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 14)
                HStack(spacing: 0) {
                    big("대화 기록", "doc.plaintext") { pick(.shareText) }
                    big("녹음 파일", "waveform") { pick(.shareAudio) }
                    big("회의록 PDF", "doc.richtext", disabled: !hasReport) { pick(.sharePDF) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 18)
                Divider()
                row("전체 대화 텍스트 복사", "doc.on.doc") { pick(.copyText) }
                row("참석자 대화 점유율", "chart.pie") { pick(.talkShare) }
                row("제목 바꾸기", "pencil") { pick(.rename) }
                row("녹음 시각 바꾸기", "calendar") { pick(.recordedAt) }
                Divider().padding(.vertical, 4)
                if AppConfig.deviceTranscribeAvailable {
                    row("이 기기에서 다시 받아쓰기", "iphone.and.arrow.forward") { pick(.redoDevice) }
                }
                row("기기 목소리로 화자 다시 추정", "person.wave.2") { pick(.speakersDevice) }
                Divider().padding(.vertical, 4)
                row("삭제", "trash", destructive: true) { pick(.delete) }
            }
            .padding(.bottom, 20)
        }
    }

    private func big(_ title: String, _ icon: String, disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.title2).frame(height: 30)
                Text(title).font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    private func row(_ title: String, _ icon: String, destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.body).frame(width: 26)
                Text(title).font(.body)
                Spacer()
            }
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 참석자 대화 점유율 — 화자별 말한 시간 비율 (발언 구간 길이 합)
struct TalkShareView: View {
    let segments: [Segment]
    var onRename: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable { let id: String; let ms: Int; let count: Int }

    private var rows: [Row] {
        var ms: [String: Int] = [:], cnt: [String: Int] = [:]
        for s in segments {
            let d = max(0, (s.endMs ?? s.startMs ?? 0) - (s.startMs ?? 0))
            ms[s.speaker, default: 0] += d
            cnt[s.speaker, default: 0] += 1
        }
        return ms.map { Row(id: $0.key, ms: $0.value, count: cnt[$0.key] ?? 0) }.sorted { $0.ms > $1.ms }
    }

    var body: some View {
        let list = rows
        let total = max(1, list.reduce(0) { $0 + $1.ms })
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(list) { r in
                        let sp = SpeakerName(r.id)
                        let pct = Double(r.ms) / Double(total)
                        Button { onRename(r.id) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(sp.display).font(.body.weight(.semibold)).lineLimit(1)
                                    if sp.guess { Text("추정").font(.caption2).foregroundStyle(.secondary) }
                                    Spacer()
                                    Text(String(format: "%.1f%%", pct * 100)).font(.body).monospacedDigit().foregroundStyle(.secondary)
                                }
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color(.tertiarySystemFill))
                                        Capsule().fill(Color.accentMalgeul).frame(width: max(6, g.size.width * pct))
                                    }
                                }
                                .frame(height: 10)
                                Text("발언 \(r.count)회 · \(Fmt.durationKo(r.ms / 1000))")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Text("이름을 누르면 화자 이름을 바꿀 수 있습니다.").font(.footnote).foregroundStyle(.tertiary)
                }
                .padding(24)
            }
            .navigationTitle("참석자 대화 점유율")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
        }
    }
}

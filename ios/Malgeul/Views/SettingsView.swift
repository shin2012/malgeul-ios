import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var config: AppConfig
    @Environment(\.isPresented) private var presented
    @Environment(\.dismiss) private var dismissSheet

    var body: some View {
        NavigationStack {
            Form {
                AccountSection()
                GroupsSection()

                Section("녹음") {
                    Toggle("녹음 업로드 후 바로 받아쓰기", isOn: $config.autoTranscribeRecordings)
                    Toggle("업로드가 끝난 녹음은 기기에서 지우기", isOn: $config.deleteAfterUpload)
                }

                ProcessingSection()
                UsageSection()

                Section("정보") {
                    LabeledContent("버전", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    if let u = URL(string: config.server) {
                        Link(destination: u) { Label("웹에서 열기", systemImage: "safari") }
                    }
                }
            }
            .navigationTitle("설정")
            .toolbar {
                if presented {
                    ToolbarItem(placement: .confirmationAction) { Button("완료") { dismissSheet() } }
                }
            }
        }
    }
}

/// 사용량: 이번 달·전체 받아쓰기 비용 (웹 설정 > 사용량과 같음)
private struct UsageSection: View {
    @EnvironmentObject private var store: MeetingStore
    var body: some View {
        let cal = Calendar.current
        let month = store.meetings.filter { m in m.createdAt.map { cal.isDate($0, equalTo: .now, toGranularity: .month) } ?? false }
        let mc = month.reduce(0) { $0 + ($1.costUsd ?? 0) }
        Section {
            LabeledContent("이번 달") { Text(costText(mc) + " · \(month.count)건").monospacedDigit() }
            LabeledContent("전체") { Text(costText(store.totalCost) + " · \(store.meetings.count)건").monospacedDigit() }
        } header: {
            Text("사용량")
        } footer: {
            if let r = store.krwRate { Text("환율 1달러 = \(Fmt.number(r))원") }
        }
    }
    private func costText(_ usd: Double) -> String {
        Fmt.krw(usd, rate: store.krwRate) ?? String(format: "$%.2f", usd)
    }
}

/// 연결 상태 점: 초록 = 연결됨, 빨강 = 안 됨, 회색 = 주소 없음, 주황 깜빡임 = 확인 중
struct StatusDot: View {
    enum Kind: Equatable { case ok, fail, none, checking }
    let kind: Kind

    private var color: Color {
        switch kind {
        case .ok: return .green
        case .fail: return .red
        case .none: return Color.secondary.opacity(0.4)
        case .checking: return .secondary
        }
    }

    var body: some View {
        Group {
            if kind == .checking {
                Circle().fill(color)
                    .phaseAnimator([1.0, 0.25]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 0.6) }
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityLabel(kind == .ok ? "연결됨" : kind == .fail ? "연결 안 됨" : kind == .checking ? "확인 중" : "주소 없음")
    }
}

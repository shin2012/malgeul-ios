import SwiftUI

@main
struct MalgeulWatchApp: App {
    @StateObject private var rec = WatchRecorder.shared

    init() { WatchRecorder.shared.activate() }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(rec)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var rec: WatchRecorder
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section { recordButton }
                    .listRowBackground(Color.clear)
                if !rec.items.isEmpty {
                    Section("녹음") {
                        ForEach(rec.items) { r in
                            NavigationLink { DetailView(id: r.id) } label: { Row(r: r) }
                        }
                        .onDelete { idx in idx.map { rec.items[$0].id }.forEach(rec.delete) }
                    }
                }
            }
            .navigationTitle("말글")
        }
        .alert("녹음", isPresented: Binding(get: { rec.lastError != nil }, set: { if !$0 { rec.lastError = nil } })) {
            Button("확인", role: .cancel) { rec.lastError = nil }
        } message: { Text(rec.lastError ?? "") }
        .onChange(of: scenePhase) { _, p in if p == .active { rec.sendPending() } }
    }

    private var recordButton: some View {
        VStack(spacing: 6) {
            Button {
                if rec.state == .recording { rec.stop() } else { Task { await rec.start() } }
            } label: {
                ZStack {
                    Circle().fill(Color.red).frame(width: 64, height: 64)
                    if rec.state == .recording {
                        RoundedRectangle(cornerRadius: 5).fill(.white).frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "mic.fill").font(.title2).foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rec.state == .recording ? "녹음 끝내기" : "녹음 시작")

            if rec.state == .recording {
                Text(WFmt.clock(rec.elapsed)).font(.title3.monospacedDigit().weight(.semibold))
                Text(rec.livePlace ?? "장소 찾는 중…").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .multilineTextAlignment(.center)
            } else {
                Text("눌러서 녹음").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 목록 한 줄: 파일 이름 · 시각 · 장소 · 전송 상태
struct Row: View {
    let r: WatchRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(r.id).font(.caption.weight(.semibold)).lineLimit(2)
            Label(WFmt.when(r.startedAt) + " · " + WFmt.clock(r.duration), systemImage: "clock")
                .font(.caption2).foregroundStyle(.secondary)
            Label(r.place ?? "장소 없음", systemImage: "mappin.and.ellipse")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            TransferLabel(r: r)
        }
        .padding(.vertical, 2)
    }
}

struct TransferLabel: View {
    let r: WatchRecording

    var body: some View {
        switch r.transfer {
        case .sent: Label("폰으로 보냄", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case .sending: Label("폰으로 보내는 중", systemImage: "arrow.up.circle").font(.caption2).foregroundStyle(.blue)
        case .waiting: Label(r.message ?? "보내기 대기", systemImage: "iphone.slash").font(.caption2).foregroundStyle(.orange)
        case .failed: Label(r.message ?? "보내기 실패", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
        }
    }
}

struct DetailView: View {
    let id: String
    @EnvironmentObject private var rec: WatchRecorder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let r = rec.items.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    field("파일", r.id)
                    field("녹음 시각", WFmt.full(r.startedAt))
                    field("길이", WFmt.clock(r.duration))
                    field("장소", r.place ?? "장소 없음")
                    if let la = r.latitude, let lo = r.longitude {
                        field("좌표", String(format: "%.5f, %.5f", la, lo))
                    }
                    TransferLabel(r: r)
                    if r.transfer == .failed || r.transfer == .waiting {
                        Button("다시 보내기") { rec.send(r.id) }
                    }
                    Button("삭제", role: .destructive) { rec.delete(r.id); dismiss() }
                }
            }
            .navigationTitle("녹음")
        }
    }

    private func field(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.footnote)
        }
    }
}

enum WFmt {
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    private static func fmt(_ p: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = p
        return f
    }
    private static let short = fmt("M월 d일 HH:mm")
    private static let long = fmt("yyyy년 M월 d일 (E) HH:mm:ss")
    static func when(_ d: Date) -> String { short.string(from: d) }
    static func full(_ d: Date) -> String { long.string(from: d) }
}

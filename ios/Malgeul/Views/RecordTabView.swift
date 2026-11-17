import SwiftUI

/// 녹음 탭: 앱에서 바로 녹음 → 끝내면 제목 정하고 업로드(선택: 바로 받아쓰기). 기기에 남은 녹음 관리.
struct RecordTabView: View {
    @Environment(\.isPresented) private var presented
    @Environment(\.dismiss) private var dismissSheet
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var recordings: RecordingStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var config: AppConfig
    @EnvironmentObject private var uploads: UploadCenter
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var device: OnDeviceJobCenter

    @State private var deletion = TwoTapDeletion()

    var body: some View {
        NavigationStack {
            List {
                Section { RecorderPanel() }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                Text("녹음을 끝내면 전체 목록에서 이어서 관리할 수 있어요.")
                    .font(.system(size: 13)).foregroundStyle(Color.mgFg3)
                    .frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.mgBg)
            .navigationTitle("녹음")
            .toolbar {
                if presented {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismissSheet() } }
                }
            }
            .refreshable { recordings.reload(); device.resume() }
            .sheet(item: $recorder.finished) { r in FinishRecordingSheet(recording: r) }
            .onDisappear { deletion.reset() }
            .onChange(of: router.startRecordingRequest, initial: true) { _, req in
                guard req else { return }
                router.startRecordingRequest = false
                if !recorder.isActive { Task { await recorder.start() } }
            }
            .onAppear { recordings.reload() }
        }
    }


}

struct RecorderPanel: View {
    @EnvironmentObject private var recorder: Recorder
    @State private var deletion = TwoTapDeletion()

    var body: some View {
        VStack(spacing: 18) {
            Text(Fmt.clock(recorder.elapsed))
                .font(.system(size: 56, weight: .light, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(recorder.state == .recording ? .primary : .secondary)

            Waveform(levels: recorder.levels, active: recorder.state == .recording)
                .frame(height: 56)
                .padding(.horizontal)

            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(recorder.state == .recording ? Color.red : Color.secondary)

            HStack(spacing: 36) {
                if recorder.isActive {
                    TwoTapDeleteButton(target: "active", confirmation: $deletion, title: "녹음 삭제") { recorder.discard() }
                        .frame(width: 90).frame(minHeight: 56)
                }

                Button {
                    switch recorder.state {
                    case .idle: Task { await recorder.start() }
                    case .recording: recorder.pause()
                    case .paused: recorder.resume()
                    }
                } label: {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 4).frame(width: 84, height: 84)
                        if recorder.state == .recording {
                            Image(systemName: "pause.fill").font(.system(size: 30)).foregroundStyle(.red)
                        } else if recorder.state == .paused {
                            Image(systemName: "record.circle").font(.system(size: 40)).foregroundStyle(.red)
                        } else {
                            Circle().fill(Color.red).frame(width: 68, height: 68)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recorder.state == .idle ? "녹음 시작" : recorder.state == .recording ? "일시정지" : "이어서 녹음")
                .sensoryFeedback(.impact, trigger: recorder.state)

                if recorder.isActive {
                    Button { recorder.stop() } label: {
                        Image(systemName: "stop.fill").font(.title2).frame(width: 56, height: 56)
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                    .accessibilityLabel("녹음 끝내기")
                }
            }

            if recorder.permissionDenied {
                VStack(spacing: 6) {
                    Text("마이크 권한이 꺼져 있어 녹음할 수 없습니다.").font(.footnote).foregroundStyle(.red)
                    Button("설정 앱에서 허용하기") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                    .font(.footnote)
                }
            }
            if let e = recorder.lastError {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .animation(.default, value: recorder.state)
        .onChange(of: recorder.state) { _, _ in deletion.reset() }
        .onDisappear { deletion.reset() }
    }

    private var statusText: String {
        switch recorder.state {
        case .idle: return "버튼을 누르면 녹음을 시작합니다 · 화면이 꺼져도 계속 녹음돼요"
        case .recording: return "● 녹음 중"
        case .paused: return recorder.interrupted ? "전화 등으로 잠시 멈췄어요 · 끝나면 자동으로 이어집니다" : "일시정지"
        }
    }
}

struct Waveform: View {
    let levels: [Float]
    let active: Bool
    var body: some View {
        GeometryReader { g in
            let n = max(levels.count, 1)
            let w = g.size.width / CGFloat(n)
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
                    Capsule()
                        .fill(active ? Color.red.opacity(0.85) : Color.secondary.opacity(0.4))
                        .frame(width: max(2, w * 0.55), height: max(3, CGFloat(l) * g.size.height))
                        .frame(width: w)
                }
            }
            .frame(height: g.size.height)
        }
        .accessibilityHidden(true)
    }
}

struct RecordingRow: View {
    let recording: Recording
    @EnvironmentObject private var uploads: UploadCenter
    @EnvironmentObject private var device: OnDeviceJobCenter

    var body: some View {
        NoteRowContent(title: recording.title, compact: true) {
            NoteRowMetadata(date: recording.startedAt, duration: Int(recording.duration), status: statusText)
            if let job = device.job(recording: recording.id) {
                DeviceJobLine(job: job)
            } else if let job = uploads.isUploading(recordingID: recording.id) {
                if job.state == .failed {
                    Text(job.message ?? "업로드 실패").foregroundStyle(Color.mgDanger)
                        .font(.system(size: 13.5)).lineLimit(2)
                } else if job.state == .uploading {
                    HStack {
                        Text("업로드 중")
                        Spacer()
                        Text("\(Int(job.progress * 100))%").monospacedDigit()
                    }.font(.system(size: 13)).foregroundStyle(Color.mgFg3)
                    ProgressView(value: job.progress).tint(Color.accentMalgeul)
                } else {
                    HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(job.state == .finishing ? "서버에 저장 중" : (job.message ?? "파일 준비 중")) }
                        .font(.system(size: 13.5)).foregroundStyle(Color.mgFg3)
                }
            }
            if let place = recording.place {
                Text(place).font(.system(size: 13.5)).foregroundStyle(Color.mgFg3).lineLimit(1)
            }
        }
    }

    private var statusText: String? {
        if device.job(recording: recording.id) != nil || uploads.isUploading(recordingID: recording.id) != nil { return nil }
        return recording.meetingID == nil ? "받아쓰기 전" : "업로드됨"
    }
}

/// 녹음 끝 → 제목 정하고 바로 업로드
struct FinishRecordingSheet: View {
    let recording: Recording
    @EnvironmentObject private var config: AppConfig
    @EnvironmentObject private var recordings: RecordingStore
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var transcribe = false

    var body: some View {
        NavigationStack {
            Form {
                Section("제목") {
                    TextField("회의 제목", text: $title)
                }
                Section {
                    LabeledContent("길이", value: Fmt.clock(recording.duration))
                    LabeledContent("녹음 시각", value: Fmt.date(recording.startedAt))
                    if let p = recording.place { LabeledContent("장소", value: p) }
                    if recording.fromWatch == true { LabeledContent("녹음 기기", value: "애플워치") }
                    LabeledContent("크기", value: Fmt.size(recording.fileSize))
                }
                Section {
                    Toggle("업로드 후 바로 받아쓰기 (AssemblyAI)", isOn: $transcribe)
                } footer: {
                    Text(config.isConfigured
                         ? "업로드는 앱을 닫아도 계속됩니다. 받아쓰기는 서버 압축이 끝나면 시작돼요. 녹음 시각은 녹음을 시작한 시각으로 저장됩니다."
                         : "설정에서 서버를 연결하면 업로드할 수 있어요. 녹음은 ‘내 녹음’에 보관됩니다.")
                }
            }
            .navigationTitle("녹음 완료")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("나중에") { save(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("업로드") {
                        save()
                        var r = recording
                        r.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? recording.title : title
                        recordings.upload(r, autoTranscribe: transcribe)
                        dismiss()
                        router.tab = .meetings
                    }
                    .disabled(!config.isConfigured)
                }
            }
            .onAppear {
                title = recording.title
                transcribe = config.autoTranscribeRecordings
            }
        }
        .interactiveDismissDisabled()
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && t != recording.title { recordings.rename(recording.id, title: t) }
    }
}

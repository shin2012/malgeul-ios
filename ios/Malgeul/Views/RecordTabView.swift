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

    @State private var confirmDiscard = false
    @State private var renaming: Recording?
    @State private var renameText = ""
    @State private var deleting: Recording?

    var body: some View {
        NavigationStack {
            List {
                Section { RecorderPanel(confirmDiscard: $confirmDiscard) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                Section {
                    if recordings.items.isEmpty {
                        Text("아직 녹음이 없습니다.").foregroundStyle(.secondary)
                    }
                    ForEach(recordings.items) { r in
                        VStack(alignment: .leading, spacing: 6) {
                            RecordingRow(recording: r)
                            if let j = device.job(recording: r.id) { DeviceJobLine(job: j) }
                        }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { deleting = r } label: { Label("삭제", systemImage: "trash") }
                                Button { renameText = r.title; renaming = r } label: { Label("이름", systemImage: "pencil") }.tint(.gray)
                            }
                            .swipeActions(edge: .leading) {
                                if r.meetingID == nil && uploads.isUploading(recordingID: r.id) == nil && config.isConfigured {
                                    Button { recordings.upload(r, autoTranscribe: config.autoTranscribeRecordings) } label: {
                                        Label("업로드", systemImage: "arrow.up.circle")
                                    }.tint(.accentMalgeul)
                                }
                            }
                            .contextMenu {
                                if config.isConfigured && uploads.isUploading(recordingID: r.id) == nil {
                                    Button { recordings.upload(r, autoTranscribe: false) } label: {
                                        Label(r.meetingID == nil ? "업로드" : "다시 업로드", systemImage: "arrow.up.circle")
                                    }
                                    Button { recordings.upload(r, autoTranscribe: true) } label: {
                                        Label("업로드 후 바로 받아쓰기", systemImage: "waveform")
                                    }
                                    if AppConfig.deviceTranscribeAvailable && r.meetingID == nil && device.job(recording: r.id) == nil {
                                        Button {
                                            device.requestNotificationPermission()
                                            device.enqueueLocalFirst(r)
                                        } label: { Label("이 기기에서 받아쓰고 함께 올리기", systemImage: "iphone") }
                                    }
                                }
                                if let id = r.meetingID {
                                    Button { router.meetingID = id; router.tab = .meetings } label: { Label("회의 열기", systemImage: "text.bubble") }
                                }
                                ShareLink(item: r.fileURL) { Label("공유", systemImage: "square.and.arrow.up") }
                                Button { renameText = r.title; renaming = r } label: { Label("이름 변경", systemImage: "pencil") }
                                Divider()
                                Button(role: .destructive) { deleting = r } label: { Label("삭제", systemImage: "trash") }
                            }
                    }
                } header: {
                    Text("내 녹음")
                } footer: {
                    Text("녹음 파일은 이 기기의 ‘파일 › 나의 iPhone › 말글 › 녹음’에도 보관됩니다.")
                }
            }
            .navigationTitle("녹음")
            .toolbar {
                if presented {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismissSheet() } }
                }
            }
            .refreshable { recordings.reload(); device.resume() }
            .sheet(item: $recorder.finished) { r in FinishRecordingSheet(recording: r) }
            .alert("이름 변경", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { r in
                TextField("제목", text: $renameText)
                Button("저장") {
                    let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { recordings.rename(r.id, title: t) }
                }
                Button("취소", role: .cancel) {}
            }
            .confirmationDialog("녹음 파일을 이 기기에서 삭제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { r in
                Button("삭제", role: .destructive) {
                    if player.playingKey == "rec-\(r.id)" { player.stop() }
                    recordings.delete(r.id)
                }
            } message: { r in
                Text(r.meetingID == nil ? "아직 업로드하지 않은 녹음입니다. 삭제하면 되돌릴 수 없습니다." : "서버에 올린 회의는 그대로 남습니다.")
            }
            .confirmationDialog("녹음을 버릴까요? 지금까지 녹음한 내용이 삭제됩니다.", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("녹음 버리기", role: .destructive) { recorder.discard() }
            }
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
    @Binding var confirmDiscard: Bool

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
                    Button { confirmDiscard = true } label: {
                        Image(systemName: "trash").font(.title2).frame(width: 56, height: 56)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.circle)
                    .accessibilityLabel("녹음 버리기")
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
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var uploads: UploadCenter
    @EnvironmentObject private var router: Router

    private var key: String { "rec-\(recording.id)" }

    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggleFile(recording.fileURL, key: key) } label: {
                Image(systemName: player.playingKey == key ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.accentMalgeul)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.playingKey == key ? "정지" : "재생")

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(Fmt.date(recording.startedAt)) · \(Fmt.clock(recording.duration)) · \(Fmt.size(recording.fileSize))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                status
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let job = uploads.isUploading(recordingID: recording.id) {
            switch job.state {
            case .failed:
                Text(job.message ?? "업로드 실패").font(.caption).foregroundStyle(.red)
            case .uploading:
                ProgressView(value: job.progress).tint(.accentMalgeul)
            default:
                HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("업로드 준비 중").font(.caption).foregroundStyle(.secondary) }
            }
        } else if let id = recording.meetingID {
            Button { router.meetingID = id; router.tab = .meetings } label: {
                Label("업로드됨", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        } else {
            Label("기기에만 있음", systemImage: "iphone").font(.caption).foregroundStyle(Color.accentMalgeul)
        }
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

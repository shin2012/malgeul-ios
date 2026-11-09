import SwiftUI

/// 설정 > 처리 방식: 받아쓰기·화자 추정을 어디서 할지 + 기기 모델 상태
struct ProcessingSection: View {
    @EnvironmentObject private var config: AppConfig
    @EnvironmentObject private var voices: VoiceProfiles
    @EnvironmentObject private var device: OnDeviceJobCenter

    @State private var speechState = "확인 중…"
    @State private var speechInstalled = false
    @State private var speechBusy = false
    @State private var speechProgress: Double?
    @State private var diarizerReady = DiarizerEngine.modelsOnDisk
    @State private var diarizerBusy = false
    @State private var message: String?

    var body: some View {
        Section {
            Picker("받아쓰기", selection: $config.engine) {
                ForEach(TranscribeEngine.allCases) { e in
                    if e != .device || AppConfig.deviceTranscribeAvailable { Text(e.label).tag(e) }
                }
            }
            if config.engine == .device {
                Picker("화자 추정", selection: $config.speakerMode) {
                    ForEach(SpeakerMode.allCases) { Text($0.label).tag($0) }
                }
            }
            Picker("공유 메뉴로 받은 파일", selection: $config.shareAction) {
                ForEach(ShareAction.allCases) { a in
                    if a != .deviceThenUpload || AppConfig.deviceTranscribeAvailable { Text(a.label).tag(a) }
                }
            }
            if !SharedInbox.available && config.shareAction != .upload {
                Text("앱 그룹이 아직 준비되지 않아 공유 메뉴에서는 바로 올리기만 됩니다.").font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("처리 방식")
        } footer: {
            Text(footer)
        }

        if AppConfig.deviceTranscribeAvailable {
            Section {
                LabeledContent("한국어 음성 모델") {
                    if speechBusy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            if let p = speechProgress { Text("\(Int(p * 100))%").monospacedDigit() }
                        }
                    } else {
                        Text(speechState).foregroundStyle(speechInstalled ? Color.green : Color.secondary)
                    }
                }
                if !speechInstalled && !speechBusy {
                    Button("한국어 음성 모델 받기") { Task { await installSpeech() } }
                }
                LabeledContent("화자 구분 모델") {
                    if diarizerBusy { ProgressView().controlSize(.small) }
                    else { Text(diarizerReady ? "준비됨" : "받지 않음 (약 100MB)").foregroundStyle(diarizerReady ? Color.green : Color.secondary) }
                }
                if !diarizerReady && !diarizerBusy {
                    Button("화자 구분 모델 받기") { Task { await prepareDiarizer() } }
                }
                LabeledContent("목소리 프로필") {
                    if voices.busy { ProgressView().controlSize(.small) }
                    else {
                        Text(voices.peopleCount > 0 ? "\(voices.peopleCount)명" + (voices.updatedAt.map { " · \(Fmt.relative($0, now: .now))" } ?? "") : "없음")
                            .foregroundStyle(.secondary)
                    }
                }
                if let s = voices.status { Text(s).font(.caption).foregroundStyle(.secondary) }
                Button("목소리 프로필 새로 만들기") {
                    Task {
                        do { _ = try await voices.ensure(exclude: nil); message = "목소리 프로필 \(voices.peopleCount)명 준비됨" }
                        catch { message = error.localizedDescription }
                    }
                }
                .disabled(voices.busy || !config.isConfigured)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                NavigationLink("기기 처리 실험 · 판정 기준") { DeviceLabView() }
            } header: {
                Text("기기 처리")
            } footer: {
                Text("받아쓰기와 화자 구분은 이 기기 안에서만 하고, 결과(대본)만 서버에 저장합니다. 목소리 프로필은 서버에서 이름이 확정된 사람별 참고 음성(최대 60초)을 받아 기기에서 만듭니다.")
            }
            .task { await refreshSpeech() }
        }
    }

    private var footer: String {
        switch config.engine {
        case .assemblyai: return "서버가 AssemblyAI로 받아씁니다(유료). 화자 추정은 서버가 합니다."
        case .local: return "서버 컴퓨터(faster-whisper)가 받아씁니다. 느리지만 무료."
        case .device: return "이 기기에서 받아씁니다(무료, iOS 26 애플 음성인식 + 화자 구분). 화면이 꺼져도 이어서 처리하고 끝나면 알려 드려요. 공유 메뉴로 보낸 파일은 말글 앱을 열면 시작됩니다."
        }
    }

    private func refreshSpeech() async {
        guard #available(iOS 26.0, *) else { return }
        switch await SpeechEngine.assetState() {
        case .installed: speechState = "준비됨"; speechInstalled = true
        case .downloading: speechState = "받는 중"; speechInstalled = false
        case .notInstalled: speechState = "받지 않음"; speechInstalled = false
        case .unsupported: speechState = "이 기기에서 지원 안 됨"; speechInstalled = true   // 버튼 숨김
        }
        diarizerReady = DiarizerEngine.modelsOnDisk
    }

    private func installSpeech() async {
        guard #available(iOS 26.0, *) else { return }
        speechBusy = true
        speechProgress = nil
        defer { speechBusy = false }
        do {
            try await SpeechEngine.installAssets { p in Task { @MainActor in speechProgress = p } }
            message = nil
        } catch { message = error.localizedDescription }
        await refreshSpeech()
    }

    private func prepareDiarizer() async {
        diarizerBusy = true
        defer { diarizerBusy = false }
        do { try await DiarizerEngine.shared.prepare(); message = nil }
        catch { message = "화자 구분 모델 받기 실패: \(error.localizedDescription)" }
        diarizerReady = DiarizerEngine.modelsOnDisk
    }
}

/// 기기 처리 실험: 받아쓴 회의를 복제해 기기로 다시 받아쓰고(원본은 그대로) 결과·속도·목소리 유사도를 확인, 판정 기준 조정
struct DeviceLabView: View {
    @EnvironmentObject private var config: AppConfig
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var device: OnDeviceJobCenter
    @EnvironmentObject private var router: Router

    @State private var picked: Int?
    @State private var busy = false
    @State private var info: String?

    private var done: [Meeting] { store.meetings.filter { $0.isDone && !$0.title.hasPrefix("[기기 실험]") } }

    var body: some View {
        Form {
            Section {
                Picker("회의", selection: $picked) {
                    Text("선택").tag(Int?.none)
                    ForEach(done) { m in Text(m.title).lineLimit(1).tag(Int?.some(m.id)) }
                }
                Button {
                    Task { await runClone() }
                } label: {
                    HStack { Text("복제해서 기기로 받아쓰기"); Spacer(); if busy { ProgressView() } }
                }
                .disabled(picked == nil || busy || device.isBusy)
                if let info { Text(info).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("시험")
            } footer: {
                Text("원본은 건드리지 않고 '[기기 실험]' 복제 회의에 기기 결과를 저장합니다. 원본 회의의 발언은 목소리 참고 음성에서 빼고 비교해요. 다 보면 목록에서 복제 회의를 지우세요.")
            }

            ForEach(device.jobs) { j in
                Section("진행 중") {
                    Text(j.title).font(.subheadline).lineLimit(1)
                    DeviceJobLine(job: j)
                }
            }

            if let r = device.lastReport {
                Section("마지막 결과") {
                    Button(r.title) { router.tab = .meetings; router.meetingID = r.meetingID }
                    LabeledContent("오디오 길이", value: Fmt.duration(Int(r.audioSeconds)))
                    LabeledContent("화자 구분", value: secs(r.diarizeSeconds))
                    LabeledContent("받아쓰기", value: secs(r.transcribeSeconds) + speed(r))
                    LabeledContent("목소리 비교", value: secs(r.voiceSeconds))
                    LabeledContent("화자 수 · 발언 · 글자", value: "\(r.speakers)명 · \(r.segments)개 · \(r.characters)자")
                    ForEach(r.voiceLines, id: \.self) { Text($0).font(.caption.monospacedDigit()) }
                }
            }

            Section {
                slider("강한 일치", value: $config.voiceStrong, range: 0.3...0.95)
                slider("중간 일치(서버 내용과 같을 때)", value: $config.voiceWeak, range: 0.2...0.9)
                slider("1·2위 차이", value: $config.voiceMargin, range: 0...0.4)
                Button("기본값으로") {
                    config.voiceStrong = AppConfig.defaultVoice.strong
                    config.voiceWeak = AppConfig.defaultVoice.weak
                    config.voiceMargin = AppConfig.defaultVoice.margin
                }
            } header: {
                Text("기기 목소리 판정 기준")
            } footer: {
                Text("유사도가 '강한 일치' 이상이고 2위와 '차이' 이상 벌어지면 그 사람(추정)으로 표시합니다. 기기 모델은 서버와 달라 같은 사람도 점수가 다를 수 있어요. 위 '마지막 결과'의 유사도를 보고 본인은 넘고 다른 사람은 못 넘는 값으로 맞추세요.")
            }
        }
        .navigationTitle("기기 처리 실험")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: 0.01)
        }
    }

    private func secs(_ s: Double) -> String { s < 1 ? "-" : (s < 90 ? String(format: "%.0f초", s) : String(format: "%.1f분", s / 60)) }
    private func speed(_ r: DeviceRunReport) -> String {
        guard r.transcribeSeconds > 1, r.audioSeconds > 0 else { return "" }
        return String(format: " (실시간의 %.0f배)", r.audioSeconds / r.transcribeSeconds)
    }

    private func runClone() async {
        guard let id = picked, let m = store.meetings.first(where: { $0.id == id }) else { return }
        busy = true
        defer { busy = false }
        do {
            let clone = try await API.shared.cloneMeeting(id, prefix: "[기기 실험]")
            device.requestNotificationPermission()
            device.enqueueTranscribe(meetingID: clone, title: "[기기 실험] \(m.title)", excludeMeeting: id,
                                     speakerMode: config.speakerMode.usesDeviceVoice ? config.speakerMode : .device)
            info = "복제 회의 #\(clone)에서 처리 시작"
            await store.refresh()
        } catch {
            info = error.localizedDescription
        }
    }
}

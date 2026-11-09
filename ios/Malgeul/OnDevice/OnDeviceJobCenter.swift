import Foundation
import UIKit
import BackgroundTasks
import UserNotifications

/// 기기 받아쓰기·기기 화자 추정 작업 큐 (한 번에 하나씩).
/// 앱이 백그라운드로 가도 iOS 26의 '계속 처리' 작업으로 이어서 처리하고, 끝나면 알림.
struct DeviceJob: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case transcribe, speakers }
    enum State: String, Codable { case queued, running, failed, waitingUpload }

    /// 기기에서 먼저 받아쓴 결과(업로드 끝나면 서버에 저장)
    struct Pending: Codable, Equatable {
        var segments: [DeviceSegment]
        var duration: Double
        var engine: String
        var voiceJSON: Data?
    }

    var id = UUID()
    var kind: Kind
    var meetingID: Int
    var title: String
    /// 홈 디렉터리 기준 상대 경로(앱이 가진 원본 오디오). 없으면 서버 오디오를 받음
    var localRelPath: String?
    var replace: Bool?
    /// 목소리 참고 음성에서 뺄 회의 (복제 시험 때 원본)
    var excludeMeeting: Int?
    var speakerMode: String?
    var state: State = .queued
    var progress: Double = 0
    var message: String?
    var createdAt: Date?
    /// '내 녹음' 항목 (기기에서 먼저 받아쓰고 함께 올리기). 이때 meetingID는 업로드 전까지 0
    var recordingID: String?
    var pending: Pending?

    var localURL: URL? { localRelPath.map { URL(fileURLWithPath: NSHomeDirectory()).appending(path: $0) } }
    var mode: SpeakerMode { SpeakerMode(rawValue: speakerMode ?? "") ?? .server }
}

/// 마지막 기기 처리 결과 (설정 > 기기 처리 실험 화면 표시용)
struct DeviceRunReport: Codable, Equatable {
    var meetingID: Int
    var title: String
    var audioSeconds: Double
    var diarizeSeconds: Double
    var transcribeSeconds: Double
    var voiceSeconds: Double
    var speakers: Int
    var segments: Int
    var characters: Int
    /// 라벨별 상위 3명 유사도 "Speaker A: 홍길동 0.81, 김철수 0.42"
    var voiceLines: [String]
    var finishedAt: Date
}

@MainActor
final class OnDeviceJobCenter: ObservableObject {
    static let shared = OnDeviceJobCenter()
    static let bgPrefix = "kr.b-612.malgeul.ondevice"

    @Published private(set) var jobs: [DeviceJob] = []
    @Published var lastReport: DeviceRunReport?
    @Published var lastError: String?
    /// 방금 끝난 작업 (회의 id, 서버에 보내기 직전 시각) — 상세 화면이 화자 식별 결과를 기다렸다가 대본을 다시 불러옴
    struct Finished: Equatable { var meetingID: Int; var submittedAt: Date }
    @Published private(set) var finished: Finished?

    private var worker: Task<Void, Never>?
    private var bgTask: AnyObject?          // BGContinuedProcessingTask (iOS 26)
    private var uiBgTask: UIBackgroundTaskIdentifier = .invalid
    private var lastPost = Date.distantPast

    static var workDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "ondevice", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var jobsFile: URL { workDir.appending(path: "jobs.json") }
    private static var reportFile: URL { workDir.appending(path: "last_report.json") }

    private init() {
        if let d = try? Data(contentsOf: Self.jobsFile), let j = try? JSONDecoder().decode([DeviceJob].self, from: d) {
            // 앱이 꺼지며 멈춘 작업은 대기로 되돌림
            jobs = j.map { var x = $0; if x.state == .running { x.state = .queued; x.message = "다시 시작 대기" }; return x }
        }
        if let d = try? Data(contentsOf: Self.reportFile) { lastReport = try? JSONDecoder().decode(DeviceRunReport.self, from: d) }
    }

    func job(for meetingID: Int) -> DeviceJob? { meetingID > 0 ? jobs.first { $0.meetingID == meetingID } : nil }
    func job(recording id: String) -> DeviceJob? { jobs.first { $0.recordingID == id } }

    /// '내 녹음' 파일을 기기에서 먼저 받아쓰고, 끝나면 오디오와 대본을 함께 올림
    func enqueueLocalFirst(_ r: Recording) {
        guard AppConfig.deviceTranscribeAvailable else { lastError = DeviceEngineError.unsupportedOS.localizedDescription; return }
        if let j = job(recording: r.id), j.state != .failed { return }
        jobs.removeAll { $0.recordingID == r.id }
        jobs.append(DeviceJob(kind: .transcribe, meetingID: 0, title: r.title, localRelPath: Self.homeRelative(r.fileURL),
                              speakerMode: AppConfig.shared.speakerMode.rawValue, message: "대기 중", createdAt: Date(),
                              recordingID: r.id))
        save()
        kick()
    }

    /// 업로드 완료 → 미뤄 둔 기기 결과 저장
    func uploaded(_ jobID: UUID, meetingID: Int) {
        guard let j = jobs.first(where: { $0.id == jobID }), let p = j.pending else { return }
        set(jobID) { $0.meetingID = meetingID; $0.message = "서버에 대본 저장" }
        save()
        Task {
            do {
                let voice = p.voiceJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                try await API.shared.submitDeviceResult(meetingID, segments: p.segments, duration: p.duration, engine: p.engine,
                                                        speakerMode: j.mode, voice: voice, replace: false)
                remove(jobID, keepFile: true)
                finished = Finished(meetingID: meetingID, submittedAt: Date())
                notify(title: "기기 받아쓰기 완료", body: j.title)
                await MeetingStore.shared.refresh()
            } catch {
                set(jobID) { $0.state = .failed; $0.message = "대본 저장 실패: \(error.localizedDescription)" }
                save()
            }
        }
    }

    /// 같은 파일이 이미 서버에 있음 → 기기 결과는 버림
    func uploadDuplicate(_ jobID: UUID, existingID: Int?) {
        guard jobs.contains(where: { $0.id == jobID }) else { return }
        remove(jobID, keepFile: true)
        lastError = "이미 서버에 같은 파일이 있어 기기 받아쓰기 결과를 저장하지 않았어요." + (existingID.map { " (회의 #\($0))" } ?? "")
    }
    var isBusy: Bool { jobs.contains { $0.state == .running } }

    private func save() {
        if let d = try? JSONEncoder().encode(jobs) { try? d.write(to: Self.jobsFile, options: .atomic) }
    }
    private func set(_ id: UUID, _ change: (inout DeviceJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    // MARK: 공개 API

    /// 받아쓰기 작업 추가. localFile은 작업 폴더로 복사해 둠(원본이 지워져도 처리 가능)
    func enqueueTranscribe(meetingID: Int, title: String, localFile: URL? = nil, replace: Bool = false,
                           excludeMeeting: Int? = nil, speakerMode: SpeakerMode? = nil) {
        guard AppConfig.deviceTranscribeAvailable else { lastError = DeviceEngineError.unsupportedOS.localizedDescription; return }
        if let j = job(for: meetingID), j.state != .failed { return }
        jobs.removeAll { $0.meetingID == meetingID }
        var rel: String?
        if let localFile {
            let dest = Self.workDir.appending(path: "\(meetingID)-\(UUID().uuidString.prefix(8)).\(localFile.pathExtension.isEmpty ? "m4a" : localFile.pathExtension)")
            if (try? FileManager.default.linkItem(at: localFile, to: dest)) != nil || (try? FileManager.default.copyItem(at: localFile, to: dest)) != nil {
                rel = Self.homeRelative(dest)
            }
        }
        jobs.append(DeviceJob(kind: .transcribe, meetingID: meetingID, title: title, localRelPath: rel, replace: replace,
                              excludeMeeting: excludeMeeting, speakerMode: (speakerMode ?? AppConfig.shared.speakerMode).rawValue,
                              message: "대기 중", createdAt: Date()))
        save()
        kick()
    }

    /// 이미 받아쓴 회의의 익명 화자를 기기 목소리로 다시 추정
    func enqueueSpeakers(meetingID: Int, title: String) {
        if let j = job(for: meetingID), j.state != .failed { return }
        jobs.removeAll { $0.meetingID == meetingID }
        let m = AppConfig.shared.speakerMode
        jobs.append(DeviceJob(kind: .speakers, meetingID: meetingID, title: title,
                              speakerMode: (m.usesDeviceVoice ? m : .device).rawValue, message: "대기 중", createdAt: Date()))
        save()
        kick()
    }

    func retry(_ id: UUID) {
        guard let j = jobs.first(where: { $0.id == id }) else { return }
        // 결과는 이미 있고 저장만 실패 → 저장만 다시
        if j.pending != nil, j.meetingID > 0 { set(id) { $0.state = .waitingUpload }; uploaded(id, meetingID: j.meetingID); return }
        set(id) { $0.state = .queued; $0.progress = 0; $0.message = "대기 중" }
        save()
        kick()
    }

    func cancel(_ id: UUID) {
        guard let j = jobs.first(where: { $0.id == id }) else { return }
        if j.state == .running { worker?.cancel() }
        remove(id)
        Task { await API.shared.deviceProgress(j.meetingID, pct: nil, message: nil, done: true) }
    }

    /// 앱이 열릴 때: 공유 확장이 남긴 파일·대기 목록 + 멈춘 작업 이어서
    func resume() {
        for (r, action) in RecordingStore.shared.importShared() {
            switch action {
            case .deviceThenUpload: enqueueLocalFirst(r)
            case .upload: RecordingStore.shared.upload(r, autoTranscribe: false)
            case .keep: break
            }
        }
        for id in DeviceQueue.take() {
            enqueueTranscribe(meetingID: id, title: MeetingStore.shared.meetings.first { $0.id == id }?.title ?? "회의 \(id)")
        }
        kick()
    }

    // MARK: 실행

    private func kick() {
        guard worker == nil, let next = jobs.first(where: { $0.state == .queued }) else { return }
        worker = Task { [weak self] in
            await self?.run(next.id)
            guard let self else { return }
            self.worker = nil
            self.kick()
        }
    }

    private func remove(_ id: UUID, keepFile: Bool = false) {
        if !keepFile, let j = jobs.first(where: { $0.id == id }), let u = j.localURL, u.path.hasPrefix(Self.workDir.path) {
            try? FileManager.default.removeItem(at: u)
        }
        jobs.removeAll { $0.id == id }
        save()
    }

    private func progress(_ id: UUID, _ p: Double, _ msg: String) {
        set(id) { $0.progress = p; $0.message = msg }
        updateBackground(progress: p, message: msg)
        guard let j = jobs.first(where: { $0.id == id }), j.meetingID > 0, Date().timeIntervalSince(lastPost) > 3 else { return }
        lastPost = Date()
        Task { await API.shared.deviceProgress(j.meetingID, pct: p, message: "기기: \(msg) \(Int(p * 100))%") }
    }

    private func run(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        set(id) { $0.state = .running; $0.message = "준비 중"; $0.progress = 0 }
        save()
        beginBackground(job)
        defer { endBackground() }
        let started = Date()
        do {
            switch job.kind {
            case .transcribe: try await runTranscribe(job)
            case .speakers: try await runSpeakers(job)
            }
            // 먼저 받아쓰고 올리는 작업: 업로드가 끝날 때까지 남겨 둠
            if job.meetingID == 0 { return }
            await API.shared.deviceProgress(job.meetingID, pct: nil, message: nil, done: true)
            notify(title: job.kind == .transcribe ? "기기 받아쓰기 완료" : "기기 화자 추정 요청 완료", body: job.title)
            remove(id)
            finished = Finished(meetingID: job.meetingID, submittedAt: started)
            await MeetingStore.shared.refresh()
        } catch {
            if job.meetingID > 0 { await API.shared.deviceProgress(job.meetingID, pct: nil, message: nil, done: true) }
            if Task.isCancelled || error.isCancellation || (error as? DeviceEngineError) == .cancelled { return }
            let msg = error.localizedDescription
            set(id) { $0.state = .failed; $0.message = msg }
            save()
            lastError = msg
            notify(title: "기기 처리 실패", body: "\(job.title): \(msg)")
        }
    }

    /// 오디오 파일: 앱이 가진 원본(읽을 수 있을 때) → 없으면 서버 오디오(압축 끝날 때까지 기다림)
    private func audioURL(_ job: DeviceJob) async throws -> URL {
        if let u = job.localURL, FileManager.default.fileExists(atPath: u.path), AudioTools.readable(u) { return u }
        for attempt in 0..<60 {
            do { return try await API.shared.audioFile(job.meetingID) }
            catch APIError.http(404, _) where attempt < 59 {
                progress(job.id, 0, "서버 오디오 준비를 기다리는 중")
                try await Task.sleep(for: .seconds(10))
            }
        }
        throw APIError.http(404, "오디오 없음")
    }

    private func runTranscribe(_ job: DeviceJob) async throws {
        guard #available(iOS 26.0, *) else { throw DeviceEngineError.unsupportedOS }
        let id = job.id
        let url = try await audioURL(job)
        let duration = AudioTools.duration(url) ?? 0

        progress(id, 0.02, "화자 구분 모델 준비")
        try await DiarizerEngine.shared.prepare()
        try Task.checkCancellation()

        progress(id, 0.05, "화자 구분")
        let t0 = Date()
        let dia = try await DiarizerEngine.shared.diarize(url: url) { p in
            Task { @MainActor in OnDeviceJobCenter.shared.progress(id, 0.05 + 0.15 * p, "화자 구분") }
        }
        let diarizeSec = Date().timeIntervalSince(t0)
        try Task.checkCancellation()

        progress(id, 0.2, "한국어 음성 모델 확인")
        try await SpeechEngine.installAssets()
        progress(id, 0.25, "받아쓰기")
        let t1 = Date()
        let words = try await SpeechEngine.transcribe(url: url, duration: duration) { p in
            Task { @MainActor in OnDeviceJobCenter.shared.progress(id, 0.25 + 0.65 * p, "받아쓰기") }
        }
        let transcribeSec = Date().timeIntervalSince(t1)
        try Task.checkCancellation()

        let relabeled = Aligner.relabel(dia.turns)
        let segments = Aligner.align(words: words, turns: dia.turns)
        guard !segments.isEmpty else { throw APIError.http(0, "받아쓴 내용이 없습니다 (말소리를 찾지 못함)") }

        var voice: [String: Any]?
        var voiceLines: [String] = []
        var voiceSec = 0.0
        if job.mode.usesDeviceVoice {
            progress(id, 0.9, "목소리 비교")
            let t2 = Date()
            var labelEmb: [String: [Float]] = [:]
            for (raw, e) in dia.embeddings { if let l = relabeled.map[raw] { labelEmb[l] = e } }
            let used = Set(segments.map(\.speaker))
            labelEmb = labelEmb.filter { used.contains($0.key) }
            let people = try await VoiceProfiles.shared.ensure(exclude: job.excludeMeeting ?? (job.meetingID > 0 ? job.meetingID : nil)) { p, m in
                Task { @MainActor in OnDeviceJobCenter.shared.progress(id, 0.9 + 0.06 * p, m) }
            }
            let v = VoiceProfiles.voicePayload(labelEmbeddings: labelEmb, people: people)
            voice = v.payload
            voiceLines = Self.lines(v.scores)
            voiceSec = Date().timeIntervalSince(t2)
        }

        let engine = "\(SpeechEngine.engineName)+\(DiarizerEngine.engineName)"
        if job.meetingID == 0 {
            // 아직 서버에 없는 '내 녹음' → 결과를 보관하고 오디오 업로드, 끝나면 uploaded()가 저장
            let p = DeviceJob.Pending(segments: segments, duration: duration, engine: engine,
                                      voiceJSON: voice.flatMap { try? JSONSerialization.data(withJSONObject: $0) })
            set(id) { $0.pending = p; $0.state = .waitingUpload; $0.progress = 1; $0.message = "오디오 올리는 중" }
            save()
            if let rid = job.recordingID, let r = RecordingStore.shared.items.first(where: { $0.id == rid }) {
                RecordingStore.shared.upload(r, autoTranscribe: false, deviceResultJob: id)
            } else {
                throw APIError.http(0, "내 녹음에서 파일을 찾을 수 없습니다")
            }
        } else {
            progress(id, 0.97, "서버에 저장")
            try await API.shared.submitDeviceResult(job.meetingID, segments: segments, duration: duration, engine: engine,
                                                    speakerMode: job.mode, voice: voice, replace: job.replace ?? false)
        }
        saveReport(DeviceRunReport(meetingID: job.meetingID, title: job.title, audioSeconds: duration, diarizeSeconds: diarizeSec,
                                   transcribeSeconds: transcribeSec, voiceSeconds: voiceSec, speakers: Set(segments.map(\.speaker)).count,
                                   segments: segments.count, characters: segments.reduce(0) { $0 + $1.text.count },
                                   voiceLines: voiceLines, finishedAt: Date()))
    }

    /// 기존 대본의 익명(또는 이전 자동 추정) 화자별로 발언 구간을 잘라 목소리 임베딩 → 서버 판정
    private func runSpeakers(_ job: DeviceJob) async throws {
        let id = job.id
        progress(id, 0.02, "대본 불러오기")
        let detail = try await API.shared.meeting(job.meetingID)
        let info = try? await API.shared.speakerID(job.meetingID)
        // 이전 자동 추정 라벨 → 원래 익명 라벨
        var back: [String: String] = [:]
        for a in info?.result?["assigned"]?.array ?? [] {
            if let from = a["from"]?.string, let to = a["to"]?.string { back[to] = from }
        }
        var ranges: [String: [(Double, Double)]] = [:]
        for s in detail.segments {
            let label: String? = SpeakerLabel.isAnon(s.speaker) ? s.speaker : back[s.speaker]
            guard let label, let a = s.startMs, let b = s.endMs, b - a >= 1000 else { continue }
            ranges[label, default: []].append((Double(a) / 1000, Double(b) / 1000))
        }
        guard !ranges.isEmpty else { throw APIError.http(0, "추정할 익명 화자가 없습니다") }

        progress(id, 0.1, "오디오 받기")
        let url = try await audioURL(job)
        var labelEmb: [String: [Float]] = [:]
        let labels = ranges.keys.sorted()
        for (i, label) in labels.enumerated() {
            try Task.checkCancellation()
            progress(id, 0.15 + 0.5 * Double(i) / Double(labels.count), "\(label) 목소리 분석")
            let rs = ranges[label]!.sorted { ($0.1 - $0.0) > ($1.1 - $1.0) }
            let wav = Self.workDir.appending(path: "label-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            let secs = try AudioTools.extract(url, ranges: rs, maxSeconds: 60, to: wav)
            guard secs >= 3, let e = try await DiarizerEngine.shared.embedSingle(url: wav) else { continue }
            labelEmb[label] = e
        }
        guard !labelEmb.isEmpty else { throw APIError.http(0, "목소리를 분석할 만큼 긴 발언이 없습니다") }

        let people = try await VoiceProfiles.shared.ensure(exclude: job.meetingID) { p, m in
            Task { @MainActor in OnDeviceJobCenter.shared.progress(id, 0.65 + 0.3 * p, m) }
        }
        let v = VoiceProfiles.voicePayload(labelEmbeddings: labelEmb, people: people)
        progress(id, 0.97, "서버에 판정 요청")
        try await API.shared.rerunSpeakerIDWithVoice(job.meetingID, mode: job.mode, voice: v.payload)
        var r = lastReport ?? DeviceRunReport(meetingID: job.meetingID, title: job.title, audioSeconds: 0, diarizeSeconds: 0,
                                              transcribeSeconds: 0, voiceSeconds: 0, speakers: labelEmb.count, segments: detail.segments.count,
                                              characters: 0, voiceLines: [], finishedAt: Date())
        r.meetingID = job.meetingID; r.title = job.title; r.voiceLines = Self.lines(v.scores); r.finishedAt = Date()
        saveReport(r)
    }

    private static func lines(_ s: [String: [(name: String, sim: Double)]]) -> [String] {
        s.keys.sorted().map { k in
            "\(k): " + (s[k] ?? []).prefix(3).map { "\($0.name) \(String(format: "%.2f", $0.sim))" }.joined(separator: ", ")
        }
    }

    private func saveReport(_ r: DeviceRunReport) {
        lastReport = r
        if let d = try? JSONEncoder().encode(r) { try? d.write(to: Self.reportFile, options: .atomic) }
    }

    static func homeRelative(_ u: URL) -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let p = u.standardizedFileURL.path
        return p.hasPrefix(home) ? String(p.dropFirst(home.count)) : p
    }

    // MARK: 백그라운드 계속 처리 · 알림

    private func beginBackground(_ job: DeviceJob) {
        uiBgTask = UIApplication.shared.beginBackgroundTask(withName: "ondevice") { [weak self] in
            Task { @MainActor in self?.endUIBackground() }
        }
        if #available(iOS 26.0, *) {
            let ident = "\(Self.bgPrefix).\(job.id.uuidString)"
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: ident, using: nil) { task in
                guard let t = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                Task { @MainActor in
                    let c = OnDeviceJobCenter.shared
                    c.bgTask = t
                    t.progress.totalUnitCount = 100
                    t.expirationHandler = { Task { @MainActor in OnDeviceJobCenter.shared.worker?.cancel() } }
                }
            }
            guard ok else { return }
            let req = BGContinuedProcessingTaskRequest(identifier: ident, title: job.kind == .transcribe ? "기기 받아쓰기" : "기기 화자 추정",
                                                       subtitle: job.title)
            req.strategy = .fail
            try? BGTaskScheduler.shared.submit(req)
        }
    }

    private func updateBackground(progress p: Double, message: String) {
        if #available(iOS 26.0, *), let t = bgTask as? BGContinuedProcessingTask {
            t.progress.completedUnitCount = Int64(p * 100)
            t.updateTitle(t.title, subtitle: message)
        }
    }

    private func endBackground() {
        if #available(iOS 26.0, *), let t = bgTask as? BGContinuedProcessingTask {
            t.setTaskCompleted(success: true)
        }
        bgTask = nil
        endUIBackground()
    }

    private func endUIBackground() {
        if uiBgTask != .invalid { UIApplication.shared.endBackgroundTask(uiBgTask); uiBgTask = .invalid }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

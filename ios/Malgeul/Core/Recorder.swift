import Foundation
import AVFoundation
import SwiftUI

struct Recording: Codable, Identifiable, Equatable {
    var id: String            // 파일 이름
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var meetingID: Int?
    var uploadedAt: Date?
    /// 애플워치 녹음: 녹음 시작 위치 (예전 기록에는 없음)
    var place: String?
    var latitude: Double?
    var longitude: Double?
    var fromWatch: Bool?

    var fileURL: URL { RecordingStore.folder.appending(path: id) }
    var fileSize: Int? { (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue }
}

/// 기기에 남는 녹음 목록 (문서 폴더 '녹음' — 파일 앱에서도 보임)
@MainActor
final class RecordingStore: ObservableObject {
    static let shared = RecordingStore()

    @Published private(set) var items: [Recording] = []

    nonisolated static var folder: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "녹음", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var indexFile: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appending(path: "recordings.json")
    }

    nonisolated static let audioExts: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "flac", "mp4", "mov", "m4v", "aif", "aiff", "ogg", "webm"]

    private init() { reload() }

    /// 공유 확장이 App Group 전달함에 넣어 둔 파일을 '내 녹음'으로 가져옴. 가져온 항목과 처리 방식을 돌려줌
    @discardableResult
    func importShared() -> [(Recording, ShareAction)] {
        var out: [(Recording, ShareAction)] = []
        for item in SharedInbox.items() {
            let ext = (item.meta.filename as NSString).pathExtension.isEmpty ? "m4a" : (item.meta.filename as NSString).pathExtension
            var base = item.meta.title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
            if base.isEmpty { base = "공유한 녹음" }
            var name = "\(base).\(ext)"
            var n = 2
            while FileManager.default.fileExists(atPath: Self.folder.appending(path: name).path) { name = "\(base) \(n).\(ext)"; n += 1 }
            let dest = Self.folder.appending(path: name)
            do { try FileManager.default.moveItem(at: item.file, to: dest) } catch {
                guard (try? FileManager.default.copyItem(at: item.file, to: dest)) != nil else { continue }
            }
            try? FileManager.default.removeItem(at: item.dir)
            let dur = (try? AVAudioPlayer(contentsOf: dest))?.duration ?? AudioTools.duration(dest) ?? 0
            let r = Recording(id: name, title: base, startedAt: item.meta.recordedAt ?? .now, duration: dur)
            items.removeAll { $0.id == name }
            add(r)
            items.sort { $0.startedAt > $1.startedAt }
            out.append((r, ShareAction(rawValue: item.meta.action) ?? .keep))
        }
        return out
    }

    /// 색인과 실제 파일을 맞춤: 파일 앱에서 지운 건 빼고, 색인에 없는 m4a(예: 비정상 종료)는 추가
    func reload() {
        var list = (try? Data(contentsOf: Self.indexFile)).flatMap { try? JSONDecoder().decode([Recording].self, from: $0) } ?? []
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path)) ?? []
        list.removeAll { !files.contains($0.id) }
        for f in files where Self.audioExts.contains((f as NSString).pathExtension.lowercased()) && !list.contains(where: { $0.id == f }) {
            let url = Self.folder.appending(path: f)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let dur = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
            list.append(Recording(id: f, title: (f as NSString).deletingPathExtension,
                                  startedAt: (attrs?[.creationDate] as? Date) ?? .now, duration: dur))
        }
        items = list.sorted { $0.startedAt > $1.startedAt }
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: Self.indexFile, options: .atomic) }
    }

    func add(_ r: Recording) { items.insert(r, at: 0); save() }

    /// 워치가 보낸 녹음 (파일은 이미 녹음 폴더에 있음) → 목록에 넣고 서버 설정이 있으면 바로 올림
    func addFromWatch(id: String, startedAt: Date, duration: TimeInterval, place: String?, latitude: Double?, longitude: Double?) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 HH:mm"
        var title = "워치 녹음 \(f.string(from: startedAt))"
        if let place { title += " · \(place)" }
        var dur = duration
        if dur <= 0 { dur = (try? AVAudioPlayer(contentsOf: Self.folder.appending(path: id)))?.duration ?? 0 }
        let r = Recording(id: id, title: title, startedAt: startedAt, duration: dur,
                          place: place, latitude: latitude, longitude: longitude, fromWatch: true)
        items.removeAll { $0.id == id }
        add(r)
        items.sort { $0.startedAt > $1.startedAt }
        if AppConfig.shared.isConfigured {
            upload(r, autoTranscribe: AppConfig.shared.autoTranscribeRecordings)
        }
    }

    func rename(_ id: String, title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
        save()
    }

    func markUploaded(_ id: String, meetingID: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].meetingID = meetingID
        items[i].uploadedAt = .now
        save()
        if AppConfig.shared.deleteAfterUpload { delete(id) }
    }

    func delete(_ id: String) {
        guard let r = items.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: r.fileURL)
        items.removeAll { $0.id == id }
        save()
    }

    func upload(_ r: Recording, autoTranscribe: Bool, deviceResultJob: UUID? = nil) {
        let safe = r.title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let ext = (r.id as NSString).pathExtension.isEmpty ? "m4a" : (r.id as NSString).pathExtension
        UploadCenter.shared.enqueue(file: r.fileURL, filename: (safe.isEmpty ? "회의 녹음" : safe) + "." + ext,
                                    recordedAt: r.startedAt, autoTranscribe: autoTranscribe, recordingID: r.id,
                                    deviceResultJob: deviceResultJob)
    }
}

/// 회의 녹음기. 화면이 꺼지거나 다른 앱으로 가도 계속 녹음(백그라운드 오디오), 전화 등 끼어들기 후 자동 이어 녹음.
@MainActor
final class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = Recorder()

    enum State { case idle, recording, paused }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 48)
    @Published var permissionDenied = false
    @Published var lastError: String?
    /// 방금 끝난 녹음 (완료 시트 표시용)
    @Published var finished: Recording?
    @Published private(set) var interrupted = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt = Date()
    private var fileName = ""
    private var starting = false
    private var safety = RecordingSafety()
    private static let journalKey = "unfinishedRecording"

    var isActive: Bool { state != .idle }

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(onInterruption(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    func start(requiresLiveActivity: Bool = false) async {
        guard state == .idle, !starting else { return }
        starting = true
        defer { starting = false }
        lastError = nil
        if requiresLiveActivity {
            // 잠금 화면 실행에서는 권한 창이나 앱 열기를 시도하지 않는다.
            guard AVAudioApplication.shared.recordPermission == .granted else {
                permissionDenied = true
                return
            }
        } else {
            await InterruptionNotificationManager.shared.requestPermission()
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else { permissionDenied = true; return }
        }
        permissionDenied = false
        var stage = "녹음 표시 생성"
        let session = AVAudioSession.sharedInstance()
        startedAt = .now
        let titleFormat = DateFormatter()
        titleFormat.locale = Locale(identifier: "ko_KR")
        titleFormat.dateFormat = "M월 d일 HH:mm 시작"
        do {
            try RecordingLaunch.start(requiresActivity: requiresLiveActivity, prepareActivity: {
                LiveRecording.shared.start(title: titleFormat.string(from: startedAt), startedAt: startedAt)
                if let error = LiveRecording.shared.lastStartError { stage += " (\(error))" }
                return LiveRecording.shared.isVisible
            }, activateRecording: {
                stage = "오디오 설정"
                // 백그라운드에서 다른 앱 오디오를 끊으려 하지 않는다. 무음 재생·상시 마이크 점유는 하지 않음.
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
                // AVAudioRecorder가 준비·녹음할 때 세션을 활성화한다. 단축어에서 수동 활성화를 선행하지 않는다.
                stage = "녹음 파일 준비"
                let f = DateFormatter()
                f.locale = Locale(identifier: "ko_KR")
                f.dateFormat = "yyyy-MM-dd HH.mm.ss"
                fileName = "녹음 \(f.string(from: startedAt))-\(UUID().uuidString.prefix(8)).m4a"
                let url = RecordingStore.folder.appending(path: fileName)
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 24_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 48_000,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                let r = try AVAudioRecorder(url: url, settings: settings)
                r.delegate = self
                r.isMeteringEnabled = true
                guard r.prepareToRecord() else { throw RecordingIntentError.failed("녹음 파일을 준비하지 못했습니다.") }
                stage = "마이크 녹음 시작"
                guard r.record() else { throw RecordingIntentError.failed("녹음을 시작할 수 없습니다.") }
                recorder = r
                elapsed = 0
                levels = Array(repeating: 0, count: levels.count)
                state = .recording
                safety.begin()
                UserDefaults.standard.set(fileName, forKey: Self.journalKey)
                startTimer()
                print("[RecordingStart] active appState=\(UIApplication.shared.applicationState.rawValue) live=\(LiveRecording.shared.isVisible) mix=\(session.categoryOptions.contains(.mixWithOthers))")
            }, cleanup: {
                LiveRecording.shared.end()
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            })
        } catch {
            let detail = error as NSError
            lastError = "녹음 시작 실패 [\(stage)] (\(detail.domain):\(detail.code), 앱 상태 \(UIApplication.shared.applicationState.rawValue)): \(detail.localizedDescription)"
            UserDefaults.standard.set(lastError, forKey: "lastRecordingStartError")
            print("[RecordingStart] \(lastError ?? "")")
        }
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
        interrupted = false
        safety.pause()
        LiveRecording.shared.update(.paused, elapsed: currentElapsed)
    }

    /// 잠금 화면 버튼: 일시정지 ↔ 계속
    func togglePause() {
        switch state {
        case .recording: pause()
        case .paused: resume()
        case .idle: break
        }
    }

    private var currentElapsed: TimeInterval {
        if let r = recorder, r.currentTime > 0 { return r.currentTime }
        return elapsed
    }

    /// 앱이 꺼지는 중 (강제 종료 등) — 파일을 마무리하고 잠금 화면에 '멈춤' 표시
    func appWillTerminate() {
        guard let r = recorder else { return }
        let t = currentElapsed
        r.stop()
        LiveRecording.shared.endAsStopped(elapsed: t)
    }

    func resume() {
        guard state == .paused, let r = recorder else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            guard r.record() else { throw RecordingIntentError.failed("녹음을 이어갈 수 없습니다.") }
            state = .recording
            interrupted = false
            safety.resume()
            LiveRecording.shared.update(.recording, elapsed: currentElapsed)
        } catch { handleFailure(reason: "녹음 재개 실패: \(error.localizedDescription)") }
    }

    /// 녹음 끝내기 → 녹음 목록에 추가하고 완료 시트에 넘김
    func stop(unexpected: Bool = false) {
        guard let r = recorder else { return }
        let dur = r.currentTime > 0 ? r.currentTime : elapsed
        safety.stop()
        r.delegate = nil
        r.stop()
        recorder = nil
        UserDefaults.standard.removeObject(forKey: Self.journalKey)
        timer?.invalidate()
        timer = nil
        state = .idle
        interrupted = false
        if unexpected { LiveRecording.shared.endAsStopped(elapsed: dur) } else { LiveRecording.shared.end() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 HH:mm"
        let rec = Recording(id: fileName, title: "회의 녹음 \(f.string(from: startedAt))", startedAt: startedAt, duration: dur)
        RecordingStore.shared.add(rec)
        finished = rec
    }

    /// 녹음 버리기 (파일 삭제)
    func discard() {
        guard let r = recorder else { return }
        safety.stop()
        r.delegate = nil
        r.stop()
        r.deleteRecording()
        UserDefaults.standard.removeObject(forKey: Self.journalKey)
        recorder = nil
        timer?.invalidate()
        timer = nil
        state = .idle
        interrupted = false
        LiveRecording.shared.end()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    #if DEBUG
    func debugStopUnderlyingRecorder() { recorder?.stop() }
    #endif

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let r = recorder else { return }
        elapsed = r.currentTime > 0 ? r.currentTime : elapsed
        // 잠금 화면 표시: 실제로 녹음이 이어지는지 확인해 주기적으로 갱신
        switch state {
        case .recording:
            guard r.isRecording else {
                handleFailure(reason: "녹음이 예기치 않게 멈췄습니다. 저장된 녹음을 확인해 주세요.")
                return
            }
            LiveRecording.shared.update(.recording, elapsed: elapsed)
        case .paused: LiveRecording.shared.update(interrupted ? .interrupted : .paused, elapsed: elapsed)
        case .idle: break
        }
        guard state == .recording else { return }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)            // -160 ~ 0
        let level = max(0, min(1, (db + 55) / 55))
        levels.removeFirst()
        levels.append(level)
    }

    /// 파일을 먼저 마무리하고 목록에 보존한다. 같은 종료에 대한 콜백은 무시한다.
    func handleFailure(reason: String) {
        guard recorder != nil, safety.fail() else { return }
        lastError = reason
        InterruptionNotificationManager.shared.notifyInterruption(reason: reason)
        stop(unexpected: true)
    }

    func recoverUnfinishedRecording() {
        guard !isActive, UserDefaults.standard.string(forKey: Self.journalKey) != nil else { return }
        RecordingStore.shared.reload()
        UserDefaults.standard.removeObject(forKey: Self.journalKey)
        lastError = "지난 녹음이 정상 종료되지 않았습니다. 내 녹음에서 복구된 파일을 확인해 주세요."
        InterruptionNotificationManager.shared.notifyInterruption(reason: lastError!)
    }

    nonisolated func audioRecorderDidFinishRecording(_ source: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recorder === source else { return }
            self.handleFailure(reason: flag ? "녹음이 예기치 않게 끝났습니다. 파일을 저장했습니다." : "녹음을 마치지 못했습니다. 저장된 파일을 확인해 주세요.")
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ source: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription ?? "알 수 없는 인코더 오류"
        Task { @MainActor in
            guard self.recorder === source else { return }
            self.handleFailure(reason: "녹음 오류: \(message)")
        }
    }

    @objc private nonisolated func onInterruption(_ n: Notification) {
        guard let info = n.userInfo, let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
        Task { @MainActor in
            switch type {
            case .began:
                if self.state == .recording {
                    self.recorder?.pause()
                    self.state = .paused
                    self.interrupted = true
                    if self.safety.interrupt() {
                        InterruptionNotificationManager.shared.notifyInterruption(reason: "전화 또는 다른 오디오 사용으로 녹음이 잠시 중단됐습니다. 재개 여부를 확인해 주세요.")
                    }
                    LiveRecording.shared.update(.interrupted, elapsed: self.currentElapsed)
                }
            case .ended:
                if self.interrupted && opts.contains(.shouldResume) { self.resume() }
            @unknown default: break
            }
        }
    }
}

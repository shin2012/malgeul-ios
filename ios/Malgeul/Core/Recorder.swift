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
final class Recorder: NSObject, ObservableObject {
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

    var isActive: Bool { state != .idle }

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(onInterruption(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    func start() async {
        guard state == .idle else { return }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { permissionDenied = true; return }
        permissionDenied = false
        do {
            let s = AVAudioSession.sharedInstance()
            // 블루투스 이어폰 마이크(HFP)는 음질이 낮아 회의 녹음엔 기기 내장 마이크를 씀
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try s.setActive(true)

            startedAt = .now
            let f = DateFormatter()
            f.locale = Locale(identifier: "ko_KR")
            f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            fileName = "녹음 \(f.string(from: startedAt)).m4a"
            let url = RecordingStore.folder.appending(path: fileName)
            // 음성 회의용: AAC 모노 24kHz 48kbps (1시간 ≈ 21MB). 서버가 어차피 16kHz로 다시 압축함.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else { throw NSError(domain: "malgeul", code: 1, userInfo: [NSLocalizedDescriptionKey: "녹음을 시작할 수 없습니다"]) }
            recorder = r
            elapsed = 0
            levels = Array(repeating: 0, count: levels.count)
            state = .recording
            startTimer()
        } catch {
            lastError = error.localizedDescription
            try? AVAudioSession.sharedInstance().setActive(false)
        }
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused, let r = recorder else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if r.record() { state = .recording; interrupted = false }
    }

    /// 녹음 끝내기 → 녹음 목록에 추가하고 완료 시트에 넘김
    func stop() {
        guard let r = recorder else { return }
        let dur = r.currentTime > 0 ? r.currentTime : elapsed
        r.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        state = .idle
        interrupted = false
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
        r.stop()
        r.deleteRecording()
        recorder = nil
        timer?.invalidate()
        timer = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

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
        guard state == .recording else { return }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)            // -160 ~ 0
        let level = max(0, min(1, (db + 55) / 55))
        levels.removeFirst()
        levels.append(level)
    }

    @objc private nonisolated func onInterruption(_ n: Notification) {
        guard let info = n.userInfo, let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
        Task { @MainActor in
            switch type {
            case .began:
                if self.state == .recording { self.state = .paused; self.interrupted = true }
            case .ended:
                if self.interrupted && opts.contains(.shouldResume) { self.resume() }
            @unknown default: break
            }
        }
    }
}

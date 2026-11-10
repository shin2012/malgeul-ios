import Foundation
import AVFoundation
import WatchConnectivity

/// 워치에서 만든 녹음 한 건. 파일은 폰으로 보낸 뒤 지우고 기록만 남김.
struct WatchRecording: Codable, Identifiable, Equatable {
    enum Transfer: String, Codable { case waiting, sending, sent, failed }

    var id: String                 // 파일 이름
    var startedAt: Date
    var duration: TimeInterval
    var place: String?
    var latitude: Double?
    var longitude: Double?
    var transfer: Transfer = .waiting
    var message: String?

    var fileURL: URL { WatchRecorder.folder.appending(path: id) }
}

/// 녹음 → 폰으로 전송. 화면이 꺼져도 녹음은 계속됨(백그라운드 오디오).
@MainActor
final class WatchRecorder: NSObject, ObservableObject {
    static let shared = WatchRecorder()

    enum State { case idle, recording }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var items: [WatchRecording] = []
    @Published private(set) var livePlace: String?
    @Published var lastError: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var current: WatchRecording?
    private let locator = Locator()

    nonisolated static var folder: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "녹음", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var indexFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "recordings.json")
    }

    private override init() {
        super.init()
        if let d = try? Data(contentsOf: Self.indexFile), let list = try? JSONDecoder().decode([WatchRecording].self, from: d) {
            items = list
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: Self.indexFile, options: .atomic) }
    }

    private func set(_ id: String, _ change: (inout WatchRecording) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        save()
    }

    // MARK: - 녹음

    func start() async {
        guard state == .idle else { return }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { lastError = "마이크 권한이 필요합니다. 워치 설정 > 개인정보 보호에서 허용해 주세요."; return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.record, mode: .default)
            try s.setActive(true)

            let now = Date()
            let f = DateFormatter()
            f.locale = Locale(identifier: "ko_KR")
            f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let name = "워치 녹음 \(f.string(from: now)).m4a"
            // 음성 회의용: AAC 모노 24kHz 32kbps (1시간 ≈ 14MB)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let r = try AVAudioRecorder(url: Self.folder.appending(path: name), settings: settings)
            guard r.record() else { throw NSError(domain: "malgeul", code: 1, userInfo: [NSLocalizedDescriptionKey: "녹음을 시작할 수 없습니다"]) }
            recorder = r
            current = WatchRecording(id: name, startedAt: now, duration: 0)
            elapsed = 0
            livePlace = nil
            state = .recording
            startTimer()
            locator.start { [weak self] fix in
                MainActor.assumeIsolated { self?.applyFix(fix) }   // 위치·주소 콜백은 메인 스레드
            }
        } catch {
            lastError = error.localizedDescription
            try? AVAudioSession.sharedInstance().setActive(false)
        }
    }

    func stop() {
        guard let r = recorder, var rec = current else { return }
        rec.duration = r.currentTime > 0 ? r.currentTime : elapsed
        r.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        current = nil
        items.insert(rec, at: 0)
        save()
        let id = rec.id
        // 장소를 아직 못 찾았으면 잠깐 기다렸다가 보냄 (최대 10초)
        Task {
            for _ in 0..<20 {
                if items.first(where: { $0.id == id })?.place != nil || !locator.isBusy { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            locator.cancel()
            send(id)
        }
    }

    private func applyFix(_ fix: Locator.Fix) {
        livePlace = fix.place
        if var c = current {
            c.place = fix.place; c.latitude = fix.latitude; c.longitude = fix.longitude
            current = c
        } else if let first = items.first, first.transfer == .waiting, first.place == nil {
            // 정지 직후 도착한 위치
            set(first.id) { $0.place = fix.place; $0.latitude = fix.latitude; $0.longitude = fix.longitude }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.recorder else { return }
                self.elapsed = r.currentTime
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - 폰으로 보내기

    func send(_ id: String) {
        guard let rec = items.first(where: { $0.id == id }) else { return }
        guard FileManager.default.fileExists(atPath: rec.fileURL.path) else {
            set(id) { $0.transfer = .failed; $0.message = "파일이 없습니다" }
            return
        }
        let s = WCSession.default
        guard s.activationState == .activated else {
            set(id) { $0.transfer = .waiting; $0.message = "폰 연결 대기 중" }
            return
        }
        // 이미 보내는 중이면 다시 넣지 않음
        if s.outstandingFileTransfers.contains(where: { ($0.file.metadata?["id"] as? String) == id }) {
            set(id) { $0.transfer = .sending; $0.message = nil }
            return
        }
        var meta: [String: Any] = [
            "kind": "watch-recording",
            "id": rec.id,
            "recordedAt": ISO8601DateFormatter().string(from: rec.startedAt),
            "duration": rec.duration,
        ]
        if let p = rec.place { meta["place"] = p }
        if let la = rec.latitude, let lo = rec.longitude { meta["latitude"] = la; meta["longitude"] = lo }
        s.transferFile(rec.fileURL, metadata: meta)
        set(id) { $0.transfer = .sending; $0.message = nil }
    }

    /// 앱이 켜질 때·폰과 연결될 때: 못 보낸 녹음 다시 보내기
    func sendPending() {
        for r in items where r.transfer != .sent { send(r.id) }
    }

    func delete(_ id: String) {
        if let rec = items.first(where: { $0.id == id }) {
            WCSession.default.outstandingFileTransfers
                .filter { ($0.file.metadata?["id"] as? String) == id }
                .forEach { $0.cancel() }
            try? FileManager.default.removeItem(at: rec.fileURL)
        }
        items.removeAll { $0.id == id }
        save()
    }

    fileprivate func transferFinished(id: String, error: Error?) {
        if let error {
            set(id) { $0.transfer = .failed; $0.message = error.localizedDescription }
        } else {
            set(id) { $0.transfer = .sent; $0.message = nil }
            if let rec = items.first(where: { $0.id == id }) { try? FileManager.default.removeItem(at: rec.fileURL) }
        }
    }

    // MARK: - WatchConnectivity

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
}

extension WatchRecorder: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in self.sendPending() }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let id = fileTransfer.file.metadata?["id"] as? String else { return }
        Task { @MainActor in self.transferFinished(id: id, error: error) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in
            for r in self.items where r.transfer == .waiting || r.transfer == .failed { self.send(r.id) }
        }
    }
}

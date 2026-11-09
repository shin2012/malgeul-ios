import Foundation

struct UploadJob: Codable, Identifiable, Equatable {
    enum State: String, Codable { case analyzing, uploading, finishing, failed }

    var id = UUID()
    /// 홈 디렉터리 기준 상대 경로 (앱 업데이트 때 컨테이너 경로가 바뀌어도 유지)
    var sourceRelPath: String
    var filename: String
    var size: Int64 = 0
    var state: State = .analyzing
    var progress: Double = 0
    var message: String?
    var viaTailscale = false
    var recordedAt: Date?
    var autoTranscribe = false
    var recordingID: String?
    var removeSourceWhenDone = false
    /// 업로드가 끝나면 이 기기에서 받아쓰기 (설정 '받아쓰기 방식 = 이 기기')
    var deviceTranscribe: Bool?
    /// 기기에서 먼저 받아쓴 결과를 이 업로드가 끝나면 함께 저장 (OnDeviceJobCenter 작업 id)
    var deviceResultJob: String?

    var sourceURL: URL { URL(fileURLWithPath: NSHomeDirectory()).appending(path: sourceRelPath) }
    var title: String { (filename as NSString).deletingPathExtension }
}

/// 파일 업로드: 중복 확인(SHA-256) → 경로 선택(100MB 초과는 Tailscale 직통) → 백그라운드 URLSession 업로드.
/// 앱이 백그라운드로 가거나 시스템이 앱을 내려도 업로드는 계속됨.
@MainActor
final class UploadCenter: NSObject, ObservableObject {
    static let shared = UploadCenter()
    static let sessionID = "kr.b-612.malgeul.upload"
    static let hundredMB = UploadKit.hundredMB

    @Published private(set) var jobs: [UploadJob] = []
    /// 중복 파일 알림 (기존 회의 제목)
    @Published var duplicateTitle: String?
    @Published var errorAlert: String?

    var backgroundCompletion: (() -> Void)?
    private var responses: [Int: Data] = [:]
    private var session: URLSession!

    private static var jobsFile: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appending(path: "upload_jobs.json")
    }
    static var workDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "uploads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private override init() {
        super.init()
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.timeoutIntervalForRequest = 600
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
        if let d = try? Data(contentsOf: Self.jobsFile), let j = try? JSONDecoder().decode([UploadJob].self, from: d) {
            jobs = j
        }
        reconcile()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(jobs) { try? d.write(to: Self.jobsFile, options: .atomic) }
    }

    private func set(_ id: UUID, _ change: (inout UploadJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        save()
    }

    /// 앱이 다시 켜졌을 때: 진행 중이던 작업 중 세션에 없는 것은 실패로 표시(다시 시도 가능)
    private func reconcile() {
        session.getAllTasks { tasks in
            let live = Set(tasks.compactMap { $0.taskDescription })
            Task { @MainActor in
                for j in self.jobs where j.state != .failed && !live.contains(j.id.uuidString) {
                    self.set(j.id) { $0.state = .failed; $0.message = "앱이 종료되어 업로드가 중단되었습니다" }
                }
            }
        }
    }

    // MARK: - 공개 API

    /// 파일 가져오기·다른 앱에서 열기: 앱 안으로 복사한 뒤 업로드 (원본 파일은 그대로 둠)
    func enqueueImported(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = Self.workDir.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appending(path: url.lastPathComponent)
            let coordinator = NSFileCoordinator()
            var coordErr: NSError?
            var copyErr: Error?
            coordinator.coordinate(readingItemAt: url, options: .forUploading, error: &coordErr) { readURL in
                do { try FileManager.default.copyItem(at: readURL, to: dest) } catch { copyErr = error }
            }
            if let e = coordErr ?? copyErr as NSError? { throw e }
            enqueue(file: dest, filename: url.lastPathComponent, removeSource: true)
        } catch {
            errorAlert = "파일을 읽을 수 없습니다: \(error.localizedDescription)"
        }
    }

    func enqueue(file: URL, filename: String, recordedAt: Date? = nil, autoTranscribe: Bool = false,
                 recordingID: String? = nil, removeSource: Bool = false, deviceResultJob: UUID? = nil) {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        var rel = file.standardizedFileURL.path
        if rel.hasPrefix(home) { rel = String(rel.dropFirst(home.count)) }
        // 받아쓰기 방식이 '이 기기'면 서버 자동 받아쓰기 대신 업로드 후 기기에서
        let device = autoTranscribe && AppConfig.shared.engine == .device && AppConfig.deviceTranscribeAvailable && deviceResultJob == nil
        let job = UploadJob(sourceRelPath: rel, filename: filename, recordedAt: recordedAt,
                            autoTranscribe: autoTranscribe && !device && deviceResultJob == nil,
                            recordingID: recordingID, removeSourceWhenDone: removeSource, deviceTranscribe: device ? true : nil,
                            deviceResultJob: deviceResultJob?.uuidString)
        jobs.insert(job, at: 0)
        save()
        start(job.id)
    }

    func retry(_ id: UUID) {
        set(id) { $0.state = .analyzing; $0.progress = 0; $0.message = nil }
        start(id)
    }

    func cancel(_ id: UUID) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == id.uuidString }.forEach { $0.cancel() }
        }
        finish(id, removeSource: true)
    }

    func isUploading(recordingID: String) -> UploadJob? { jobs.first { $0.recordingID == recordingID } }

    // MARK: - 단계

    private func start(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        Task {
            let src = job.sourceURL
            guard FileManager.default.fileExists(atPath: src.path) else {
                set(id) { $0.state = .failed; $0.message = "원본 파일이 없습니다" }
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.int64Value ?? 0
            set(id) { $0.size = size; $0.state = .analyzing; $0.message = "중복 파일 여부 확인 중..." }

            // 1) 경로: Tailscale 직통이 열려 있으면 그쪽(웹과 동일), 100MB 초과인데 안 열리면 중단
            let ts = await API.shared.probeTailscale()
            if !ts && size > Self.hundredMB {
                set(id) {
                    $0.state = .failed
                    $0.message = "파일 크기가 \(size / 1024 / 1024)MB로 100MB를 초과합니다. Tailscale 연결 후 다시 시도해주세요."
                }
                return
            }
            let server = ts ? AppConfig.shared.tailscaleServer : AppConfig.shared.server

            // 2) 중복 확인
            let hash = await Task.detached(priority: .userInitiated) { UploadKit.sha256(of: src) }.value
            if let hash, let dup = try? await API.shared.checkHash(hash, server: server), dup.duplicate {
                duplicateTitle = dup.existing?.title ?? "(제목 없음)"
                if let dj = job.deviceResultJob.flatMap(UUID.init) { OnDeviceJobCenter.shared.uploadDuplicate(dj, existingID: dup.existing?.id) }
                finish(id, removeSource: true)
                return
            }

            // 3) 멀티파트 본문 파일 만들기 → 백그라운드 업로드
            do {
                let body = Self.workDir.appending(path: "\(id.uuidString).body")
                let boundary = "malgeul-\(UUID().uuidString)"
                let fname = job.filename
                // 녹음 시각·자동 받아쓰기는 서버가 업로드와 함께 처리 (앱이 꺼져 있어도 됨)
                var fields: [String: String] = [:]
                if let at = job.recordedAt { fields["recorded_at"] = DateParse.isoString(at) }
                if job.autoTranscribe { fields["auto_transcribe"] = "1" }
                let f = fields
                try await Task.detached(priority: .userInitiated) {
                    try UploadKit.writeMultipart(source: src, filename: fname, fields: f, boundary: boundary, to: body)
                }.value
                var req = try API.shared.request("meetings/upload", method: "POST", server: server)
                req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 600
                let task = session.uploadTask(with: req, fromFile: body)
                task.taskDescription = id.uuidString
                set(id) { $0.state = .uploading; $0.viaTailscale = ts; $0.message = nil; $0.progress = 0 }
                task.resume()
            } catch {
                set(id) { $0.state = .failed; $0.message = "업로드 실패: \(error.localizedDescription)" }
            }
        }
    }

    private func finish(_ id: UUID, removeSource: Bool) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: Self.workDir.appending(path: "\(id.uuidString).body"))
        if removeSource && job.removeSourceWhenDone {
            try? FileManager.default.removeItem(at: job.sourceURL.deletingLastPathComponent())
        }
        jobs.removeAll { $0.id == id }
        save()
    }

    private func completed(_ id: UUID, status: Int, data: Data, error: Error?) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if let error {
            if error.isCancellation { return }
            set(id) { $0.state = .failed; $0.message = "업로드 실패: \(error.localizedDescription)" }
            return
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status), let obj else {
            let msg = (obj?["error"] as? String) ?? (status == 413 ? "파일이 너무 큽니다 (HTTP 413)" : "HTTP \(status)")
            set(id) { $0.state = .failed; $0.message = "업로드 실패: \(msg)" }
            return
        }
        if obj["duplicate"] as? Bool == true {
            duplicateTitle = ((obj["existing"] as? [String: Any])?["title"] as? String) ?? "(제목 없음)"
            if let dj = job.deviceResultJob.flatMap(UUID.init) {
                OnDeviceJobCenter.shared.uploadDuplicate(dj, existingID: ((obj["existing"] as? [String: Any])?["id"] as? NSNumber)?.intValue)
            }
            finish(id, removeSource: true)
            return
        }
        guard let meetingID = (obj["id"] as? NSNumber)?.intValue else {
            set(id) { $0.state = .failed; $0.message = (obj["error"] as? String) ?? "업로드 실패" }
            return
        }
        if let rid = job.recordingID { RecordingStore.shared.markUploaded(rid, meetingID: meetingID) }
        if let dj = job.deviceResultJob.flatMap(UUID.init) {
            OnDeviceJobCenter.shared.uploaded(dj, meetingID: meetingID)
        } else if job.deviceTranscribe == true {
            OnDeviceJobCenter.shared.enqueueTranscribe(meetingID: meetingID, title: (obj["title"] as? String) ?? job.title,
                                                       localFile: job.sourceURL)
        }
        finish(id, removeSource: true)
        Task { await MeetingStore.shared.refresh() }
    }
}

extension UploadCenter: URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                                totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let s = task.taskDescription, let id = UUID(uuidString: s), totalBytesExpectedToSend > 0 else { return }
        let p = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in
            guard let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            // 저장은 상태가 바뀔 때만 (진행률마다 디스크 쓰기 방지)
            self.jobs[i].progress = p
            if p >= 1, self.jobs[i].state == .uploading { self.jobs[i].state = .finishing; self.save() }
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tid = dataTask.taskIdentifier
        Task { @MainActor in self.responses[tid, default: Data()].append(data) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let tid = task.taskIdentifier
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let desc = task.taskDescription
        Task { @MainActor in
            let data = self.responses.removeValue(forKey: tid) ?? Data()
            guard let desc, let id = UUID(uuidString: desc) else { return }
            self.completed(id, status: status, data: data, error: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

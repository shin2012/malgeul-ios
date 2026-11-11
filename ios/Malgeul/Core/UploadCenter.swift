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
    var recordedAt: Date?
    var autoTranscribe = false
    var recordingID: String?
    var removeSourceWhenDone = false
    /// 업로드가 끝나면 이 기기에서 받아쓰기 (설정 '받아쓰기 방식 = 이 기기')
    var deviceTranscribe: Bool?
    /// 기기에서 먼저 받아쓴 결과를 이 업로드가 끝나면 함께 저장 (OnDeviceJobCenter 작업 id)
    var deviceResultJob: String?
    /// 조각 업로드 상태 (서버 업로드 id, 조각 크기·개수, 보내는 중인 조각, 올리는 파일 — 압축본이면 작업 폴더)
    var uploadId: String?
    var chunkSize: Int64?
    var chunks: Int?
    var chunkIndex: Int?
    var uploadRelPath: String?
    var uploadSize: Int64?

    var sourceURL: URL { URL(fileURLWithPath: NSHomeDirectory()).appending(path: sourceRelPath) }
    var title: String { (filename as NSString).deletingPathExtension }
}

/// 파일 업로드: 중복 확인(SHA-256) → 음성 압축(이미 작으면 생략) → 조각 업로드(50MB씩, 백그라운드 URLSession, 끊기면 이어서).
/// 앱이 백그라운드로 가거나 시스템이 앱을 내려도 업로드는 계속됨.
@MainActor
final class UploadCenter: NSObject, ObservableObject {
    static let shared = UploadCenter()
    static let sessionID = "kr.b-612.malgeul.upload"

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
            let live = Set(tasks.compactMap { $0.taskDescription?.split(separator: "|").first.map(String.init) })
            Task { @MainActor in
                for j in self.jobs where j.state != .failed && !live.contains(j.id.uuidString) {
                    self.set(j.id) { $0.state = .failed; $0.message = j.uploadId == nil ? "앱이 종료되어 업로드가 중단되었습니다" : "업로드가 중단되었습니다 · 다시 시도하면 이어서 올립니다" }
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
            tasks.filter { $0.taskDescription?.hasPrefix(id.uuidString) == true }.forEach { $0.cancel() }
        }
        finish(id, removeSource: true)
    }

    func isUploading(recordingID: String) -> UploadJob? { jobs.first { $0.recordingID == recordingID } }

    // MARK: - 단계

    /// 올릴 파일: 압축본(작업 폴더) 또는 원본
    private func uploadFile(_ job: UploadJob) -> URL {
        if let r = job.uploadRelPath { return URL(fileURLWithPath: NSHomeDirectory()).appending(path: r) }
        return job.sourceURL
    }
    private func partURL(_ id: UUID, _ i: Int) -> URL { Self.workDir.appending(path: "\(id.uuidString).\(i).part") }

    private func start(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        Task {
            let src = job.sourceURL
            guard FileManager.default.fileExists(atPath: src.path) else {
                set(id) { $0.state = .failed; $0.message = "원본 파일이 없습니다" }
                return
            }
            // 끊겼던 조각 업로드면 서버에 남은 조각부터 이어서
            if let uid = job.uploadId, FileManager.default.fileExists(atPath: uploadFile(job).path),
               let st = try? await API.shared.data("uploads/\(uid)"),
               let o = try? JSONSerialization.jsonObject(with: st) as? [String: Any],
               let got = o["received"] as? [Int] {
                let next = (0..<(job.chunks ?? 0)).first { !got.contains($0) }
                set(id) { $0.state = .uploading; $0.message = nil }
                if let next { sendChunk(id, next) } else { sendComplete(id) }
                return
            }
            set(id) { $0.uploadId = nil; $0.uploadRelPath = nil }

            let size = UploadKit.fileSize(src)
            set(id) { $0.size = size; $0.state = .analyzing; $0.message = "중복 파일 여부 확인 중..." }

            // 1) 중복 확인 (압축 전 원본 기준 — 서버도 이 해시로 저장)
            let hash = await Task.detached(priority: .userInitiated) { UploadKit.sha256(of: src) }.value
            if let hash, let dup = try? await API.shared.checkHash(hash, server: AppConfig.shared.server), dup.duplicate {
                duplicateTitle = dup.existing?.title ?? "(제목 없음)"
                if let dj = job.deviceResultJob.flatMap(UUID.init) { OnDeviceJobCenter.shared.uploadDuplicate(dj, existingID: dup.existing?.id) }
                finish(id, removeSource: true)
                return
            }

            // 2) 올리기 전 압축 (이미 작은 음성 파일이면 그대로). 실패하면 원본을 올림
            var up = src
            var fname = job.filename
            if await UploadKit.needsShrink(src) {
                set(id) { $0.message = "음성 압축 중..." }
                let small = Self.workDir.appending(path: "\(id.uuidString).m4a")
                do {
                    try await UploadKit.shrinkAudio(src, to: small)
                    up = small
                    fname = UploadKit.shrunkName(fname)
                } catch {
                    try? FileManager.default.removeItem(at: small)
                }
            }
            let upSize = UploadKit.fileSize(up)
            let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
            var rel = up.standardizedFileURL.path
            if rel.hasPrefix(home) { rel = String(rel.dropFirst(home.count)) }

            // 3) 조각 업로드 시작 (서버가 조각 크기를 정함, 보통 50MB — 압축본은 대개 1조각)
            do {
                let body = UploadKit.initBody(filename: fname, size: upSize, sha256: hash, recordedAt: job.recordedAt,
                                              autoTranscribe: job.autoTranscribe)
                let d = try await API.shared.data("uploads", method: "POST", json: body)
                let o = (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
                if o["duplicate"] as? Bool == true {
                    completed(id, status: 200, data: d, error: nil)
                    return
                }
                guard let uid = o["uploadId"] as? String, let cs = (o["chunkSize"] as? NSNumber)?.int64Value,
                      let n = (o["chunks"] as? NSNumber)?.intValue else { throw APIError.badResponse }
                set(id) {
                    $0.uploadId = uid; $0.chunkSize = cs; $0.chunks = n; $0.uploadRelPath = rel
                    $0.uploadSize = upSize; $0.size = upSize
                    $0.state = .uploading; $0.message = nil; $0.progress = 0
                }
                sendChunk(id, 0)
            } catch {
                set(id) { $0.state = .failed; $0.message = "업로드 실패: \(error.localizedDescription)" }
            }
        }
    }

    /// 조각 하나를 파일로 떼어 백그라운드 세션으로 보냄 (앱이 꺼져 있어도 진행, 끝나면 다음 조각)
    private func sendChunk(_ id: UUID, _ i: Int) {
        guard let job = jobs.first(where: { $0.id == id }), let uid = job.uploadId, let cs = job.chunkSize else { return }
        do {
            let part = partURL(id, i)
            try UploadKit.writeChunk(of: uploadFile(job), index: i, chunkSize: cs, to: part)
            var req = try API.shared.request("uploads/\(uid)/\(i)", method: "PUT")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 600
            let task = session.uploadTask(with: req, fromFile: part)
            task.taskDescription = "\(id.uuidString)|\(i)"
            set(id) { $0.chunkIndex = i; $0.state = .uploading }
            task.resume()
        } catch {
            set(id) { $0.state = .failed; $0.message = "조각 준비 실패: \(self.describe(error))" }
        }
    }

    /// 조각을 다 보냈으면 서버에서 합치기 → 회의 생성 (응답은 일반 업로드와 같음)
    private func sendComplete(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), let uid = job.uploadId else { return }
        do {
            let body = Self.workDir.appending(path: "\(id.uuidString).body")
            try Data("{}".utf8).write(to: body)
            var req = try API.shared.request("uploads/\(uid)/complete", method: "POST")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 600
            let task = session.uploadTask(with: req, fromFile: body)
            task.taskDescription = "\(id.uuidString)|done"
            set(id) { $0.state = .finishing; $0.progress = 1 }
            task.resume()
        } catch {
            set(id) { $0.state = .failed; $0.message = "업로드 실패: \(error.localizedDescription)" }
        }
    }

    private func describe(_ e: Error) -> String {
        let ns = e as NSError
        return "\(e.localizedDescription) (\(ns.domain) \(ns.code))"
    }

    /// 조각 하나가 끝남
    private func chunkDone(_ id: UUID, _ i: Int, status: Int, data: Data, error: Error?) {
        try? FileManager.default.removeItem(at: partURL(id, i))
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if let error {
            if error.isCancellation { return }
            NSLog("[upload] 조각 %d 실패: %@", i, describe(error))
            set(id) { $0.state = .failed; $0.message = "업로드 실패: \(self.describe(error)) · 다시 시도하면 이어서 올립니다" }
            return
        }
        guard (200..<300).contains(status) else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String ?? "HTTP \(status)"
            set(id) { $0.state = .failed; $0.message = "업로드 실패: \(msg)" }
            return
        }
        if i + 1 < (job.chunks ?? 0) { sendChunk(id, i + 1) } else { sendComplete(id) }
    }

    private func finish(_ id: UUID, removeSource: Bool) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: Self.workDir.appending(path: "\(id.uuidString).body"))
        try? FileManager.default.removeItem(at: Self.workDir.appending(path: "\(id.uuidString).m4a"))
        for i in 0..<(job.chunks ?? 0) { try? FileManager.default.removeItem(at: partURL(id, i)) }
        if let uid = job.uploadId { Task { _ = try? await API.shared.data("uploads/\(uid)", method: "DELETE") } }
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
        guard let s = task.taskDescription, totalBytesExpectedToSend > 0 else { return }
        let parts = s.split(separator: "|")
        guard let id = UUID(uuidString: String(parts[0])), parts.count == 2, let ci = Int(parts[1]) else { return }
        Task { @MainActor in
            guard let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            let j = self.jobs[i]
            let total = Double(j.uploadSize ?? totalBytesExpectedToSend)
            let before = Double(Int64(ci) * (j.chunkSize ?? 0))
            // 저장은 상태가 바뀔 때만 (진행률마다 디스크 쓰기 방지)
            self.jobs[i].progress = min(1, (before + Double(totalBytesSent)) / max(total, 1))
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
            guard let desc else { return }
            let parts = desc.split(separator: "|")
            guard let id = UUID(uuidString: String(parts[0])) else { return }
            if parts.count == 2, let ci = Int(parts[1]) {
                self.chunkDone(id, ci, status: status, data: data, error: error)
            } else {
                self.completed(id, status: status, data: data, error: error)
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

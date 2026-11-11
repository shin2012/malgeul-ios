import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AVFoundation

/// 음성 메모·파일 등 다른 앱의 공유 메뉴 → '말글' → 바로 업로드
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel()
        model.close = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load(from: extensionContext) }
    }
}

struct SharedFile: Identifiable {
    let id = UUID()
    var url: URL          // 확장 임시 폴더로 복사한 파일
    var originalName: String
    var size: Int64
}

@MainActor
final class ShareModel: NSObject, ObservableObject, URLSessionTaskDelegate {
    enum Phase: Equatable { case loading, ready, sending, done, failed(String) }

    @Published var files: [SharedFile] = []
    @Published var title = ""
    @Published var autoTranscribe = UserDefaults.standard.bool(forKey: "shareAutoTranscribe") {
        didSet { UserDefaults.standard.set(autoTranscribe, forKey: "shareAutoTranscribe") }
    }
    @Published var phase: Phase = .loading
    @Published var status = ""
    @Published var progress: Double = 0
    /// 조각 업로드 진행률 계산용 (앞 조각까지 비율, 이번 조각 비율)
    private var chunkBase = 0.0
    private var chunkShare = 1.0
    @Published var results: [String] = []
    var close: () -> Void = {}

    var configured: Bool { SharedSettings.isConfigured }
    let deviceMode = TranscribeEngine.current == .device
    /// 처리 방식 (앱 설정값으로 시작, 이번 공유만 바꿀 수 있음)
    @Published var action: ShareAction = {
        let a = ShareAction.current
        if a == .deviceThenUpload, #unavailable(iOS 26.0) { return .keep }
        return SharedInbox.available ? a : .upload
    }()
    let inboxAvailable = SharedInbox.available
    static var deviceAvailable: Bool { if #available(iOS 26.0, *) { return true }; return false }
    var copyMode: Bool { action != .upload && inboxAvailable }
    var canSend: Bool { !files.isEmpty && phase != .loading && (copyMode || configured) }

    private static let types = [UTType.audio, UTType.movie, UTType.audiovisualContent]

    func load(from ctx: NSExtensionContext?) async {
        let providers = (ctx?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        let dir = FileManager.default.temporaryDirectory.appending(path: "share-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for p in providers {
            guard let type = Self.types.first(where: { p.hasItemConformingToTypeIdentifier($0.identifier) })
                    ?? (p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL : nil) else { continue }
            if let f = await copy(p, type: type, to: dir) { files.append(f) }
        }
        if let f = files.first, files.count == 1 { title = (f.originalName as NSString).deletingPathExtension }
        phase = files.isEmpty ? .failed("보낼 수 있는 음성·동영상 파일이 없습니다.") : .ready
    }

    /// 공유된 파일은 콜백 안에서만 열 수 있어 즉시 임시 폴더로 복사
    private func copy(_ p: NSItemProvider, type: UTType, to dir: URL) async -> SharedFile? {
        await withCheckedContinuation { (c: CheckedContinuation<SharedFile?, Never>) in
            if type == .fileURL {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    c.resume(returning: url.flatMap { Self.copyFile($0, suggested: p.suggestedName, to: dir) })
                }
                return
            }
            p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                c.resume(returning: url.flatMap { Self.copyFile($0, suggested: p.suggestedName, to: dir) })
            }
        }
    }

    nonisolated private static func copyFile(_ src: URL, suggested: String?, to dir: URL) -> SharedFile? {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let ext = src.pathExtension
        var name = src.lastPathComponent
        if let s = suggested, !s.isEmpty { name = (s as NSString).pathExtension.isEmpty && !ext.isEmpty ? "\(s).\(ext)" : s }
        let dest = dir.appending(path: name)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: src, to: dest) } catch { return nil }
        return SharedFile(url: dest, originalName: name, size: UploadKit.fileSize(dest))
    }

    /// 앱으로 복사(App Group 전달함) — 서버로 올리지 않음. 말글 앱이 열릴 때 '내 녹음'으로 가져감
    private func copyToApp() async {
        for f in files {
            let name = uploadName(f)
            let recorded = await Self.recordedDate(f.url)
            do {
                try SharedInbox.put(f.url, meta: .init(title: (name as NSString).deletingPathExtension, filename: name,
                                                       recordedAt: recorded, action: action.rawValue))
            } catch {
                phase = .failed("\(f.originalName): \(error.localizedDescription)")
                return
            }
        }
        phase = .done
        status = action == .deviceThenUpload
            ? "말글 앱에 담았어요. 앱을 열면 이 기기에서 받아쓰고 함께 올립니다."
            : "말글 앱 '내 녹음'에 담았어요."
        try? await Task.sleep(for: .seconds(1.4))
        close()
    }

    /// 녹음 시각: 파일 메타데이터(음성 메모가 기록) → 없으면 파일 생성 시각
    nonisolated static func recordedDate(_ url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate), let d = try? await item.load(.dateValue) { return d }
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    func send() {
        if copyMode {
            phase = .sending
            status = "말글 앱으로 복사하는 중..."
            Task { await copyToApp() }
            return
        }
        phase = .sending
        results = []
        Task {
            let base = SharedSettings.server
            for (i, f) in files.enumerated() {
                let label = files.count > 1 ? "(\(i + 1)/\(files.count)) " : ""
                do {
                    let name = uploadName(f)
                    status = "\(label)중복 파일 여부 확인 중..."
                    progress = 0
                    if let dup = try await checkDuplicate(f.url, base: base) {
                        results.append("이미 같은 파일이 있습니다: \(dup)")
                        continue
                    }
                    status = "\(label)올리는 중..."
                    // 올리기 전 음성 압축 (이미 작은 음성 파일이면 그대로, 실패하면 원본)
                    var up = f.url
                    var upName = name
                    var small: URL?
                    if await UploadKit.needsShrink(f.url) {
                        status = "\(label)음성 압축 중..."
                        let s = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
                        if (try? await UploadKit.shrinkAudio(f.url, to: s)) != nil {
                            small = s; up = s; upName = UploadKit.shrunkName(name)
                        } else {
                            try? FileManager.default.removeItem(at: s)
                        }
                        status = "\(label)올리는 중..."
                    }
                    defer { if let small { try? FileManager.default.removeItem(at: small) } }
                    let t = try await upload(f, from: up, name: upName, base: base)
                    results.append("✓ \(t)")
                } catch {
                    results.append("⚠️ \(f.originalName): \(error.localizedDescription)")
                }
            }
            let failed = results.contains { $0.hasPrefix("⚠️") }
            if failed {
                phase = .failed(results.joined(separator: "\n"))
            } else {
                phase = .done
                status = !autoTranscribe ? "보냈어요. 말글 앱에서 받아쓰기를 시작하세요."
                    : (deviceMode ? "보냈어요. 말글 앱을 열면 이 기기에서 받아쓰기가 시작됩니다." : "보냈어요. 서버 압축이 끝나면 받아쓰기가 시작됩니다.")
                try? await Task.sleep(for: .seconds(1.6))
                close()
            }
        }
    }

    private func uploadName(_ f: SharedFile) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard files.count == 1, !t.isEmpty else { return f.originalName }
        let ext = (f.originalName as NSString).pathExtension
        return ext.isEmpty ? t : "\(t).\(ext)"
    }

    private func request(_ path: String, base: String, method: String = "GET") throws -> URLRequest {
        guard let u = SharedSettings.apiURL(path, server: base) else { throw ShareError("서버 주소가 올바르지 않습니다") }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.setValue("Bearer \(SharedSettings.token)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func checkDuplicate(_ url: URL, base: String) async throws -> String? {
        guard let hash = await Task.detached(priority: .userInitiated, operation: { UploadKit.sha256(of: url) }).value else { return nil }
        let (d, resp) = try await URLSession.shared.data(for: try request("meetings/check-hash?hash=\(hash)", base: base))
        try Self.check(resp, d)
        let o = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        guard o?["duplicate"] as? Bool == true else { return nil }
        return ((o?["existing"] as? [String: Any])?["title"] as? String) ?? "(제목 없음)"
    }

    /// 조각 업로드 (서버가 정한 크기, 보통 50MB — Cloudflare 100MB 한도). 중복 판단은 압축 전 원본 해시
    private func upload(_ f: SharedFile, from source: URL, name: String, base: String) async throws -> String {
        let hash = await Task.detached(priority: .userInitiated) { UploadKit.sha256(of: f.url) }.value
        let size = UploadKit.fileSize(source)
        let recorded = await Self.recordedDate(f.url)
        var r0 = try request("uploads", base: base, method: "POST")
        r0.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r0.httpBody = try JSONSerialization.data(withJSONObject: UploadKit.initBody(
            filename: name, size: size, sha256: hash, recordedAt: recorded, autoTranscribe: autoTranscribe && !deviceMode))
        let (d0, resp0) = try await URLSession.shared.data(for: r0)
        try Self.check(resp0, d0)
        let o0 = (try JSONSerialization.jsonObject(with: d0) as? [String: Any]) ?? [:]
        if o0["duplicate"] as? Bool == true {
            return "이미 같은 파일이 있습니다: \(((o0["existing"] as? [String: Any])?["title"] as? String) ?? "")"
        }
        guard let uid = o0["uploadId"] as? String, let cs = (o0["chunkSize"] as? NSNumber)?.int64Value,
              let n = (o0["chunks"] as? NSNumber)?.intValue else { throw ShareError("서버 응답 오류") }
        let part = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: part) }
        for i in 0..<n {
            try await Task.detached(priority: .userInitiated) {
                try UploadKit.writeChunk(of: source, index: i, chunkSize: cs, to: part)
            }.value
            var r = try request("uploads/\(uid)/\(i)", base: base, method: "PUT")
            r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            r.timeoutInterval = 600
            chunkBase = Double(Int64(i) * cs) / Double(max(size, 1))
            chunkShare = Double(UploadKit.fileSize(part)) / Double(max(size, 1))
            var tries = 0
            while true {
                do {
                    let (d, resp) = try await URLSession.shared.upload(for: r, fromFile: part, delegate: self)
                    try Self.check(resp, d)
                    break
                } catch {
                    tries += 1
                    if tries >= 3 { throw error }
                    try await Task.sleep(for: .seconds(2 * tries))
                }
            }
        }
        var rc = try request("uploads/\(uid)/complete", base: base, method: "POST")
        rc.setValue("application/json", forHTTPHeaderField: "Content-Type")
        rc.httpBody = Data("{}".utf8)
        rc.timeoutInterval = 600
        let (d, resp) = try await URLSession.shared.data(for: rc)
        try Self.check(resp, d)
        let o = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        if o?["duplicate"] as? Bool == true {
            return "이미 같은 파일이 있습니다: \(((o?["existing"] as? [String: Any])?["title"] as? String) ?? "")"
        }
        if autoTranscribe && deviceMode, let id = (o?["id"] as? NSNumber)?.intValue { DeviceQueue.add(id) }
        return (o?["title"] as? String) ?? name
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                                totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let p = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in self.progress = min(1, self.chunkBase + self.chunkShare * p) }
    }

    static func check(_ resp: URLResponse, _ d: Data) throws {
        guard let h = resp as? HTTPURLResponse else { throw ShareError("응답 오류") }
        guard (200..<300).contains(h.statusCode) else {
            if h.statusCode == 401 { throw ShareError("앱 토큰이 올바르지 않습니다. 말글 앱 설정을 확인해 주세요.") }
            let msg = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["error"] as? String
            throw ShareError(msg ?? "HTTP \(h.statusCode)")
        }
    }
}

struct ShareError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                if !model.configured && !model.copyMode {
                    Section {
                        Label("말글 앱 설정에서 먼저 서버를 연결해 주세요.", systemImage: "key")
                            .foregroundStyle(.secondary)
                    }
                }
                Section(model.files.count > 1 ? "파일 \(model.files.count)개" : "파일") {
                    if model.phase == .loading {
                        HStack { ProgressView(); Text("파일 읽는 중...").foregroundStyle(.secondary) }
                    }
                    ForEach(model.files) { f in
                        LabeledContent {
                            Text(size(f.size)).monospacedDigit()
                        } label: {
                            Label(f.originalName, systemImage: "waveform").lineLimit(1)
                        }
                    }
                }
                if model.files.count == 1 {
                    Section("제목") {
                        TextField("회의 제목", text: $model.title)
                    }
                }
                Section {
                    Picker("처리", selection: $model.action) {
                        ForEach(ShareAction.allCases) { a in
                            if a == .upload || model.inboxAvailable {
                                if a != .deviceThenUpload || ShareModel.deviceAvailable { Text(a.label).tag(a) }
                            }
                        }
                    }
                    if model.action == .upload {
                        Toggle(model.deviceMode ? "업로드 후 이 기기에서 받아쓰기 (말글 앱을 열면 시작)" : "업로드 후 바로 받아쓰기 (AssemblyAI)",
                               isOn: $model.autoTranscribe)
                    }
                } footer: {
                    if !model.inboxAvailable {
                        Text("앱 그룹이 아직 준비되지 않아 바로 올리기만 할 수 있어요.")
                    } else if model.action == .upload {
                        Text("다 보낼 때까지 이 화면을 열어 두세요. 100MB가 넘는 파일은 음성만 압축해서 올려요.")
                    } else {
                        Text("서버로 올리지 않고 말글 앱으로 복사만 합니다. 기본값은 말글 앱 설정 > 처리 방식에서 바꿀 수 있어요.")
                    }
                }
                if model.phase == .sending || model.phase == .done {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.status).font(.subheadline)
                            if model.phase == .sending { ProgressView(value: model.progress) }
                        }
                    }
                }
                if case .failed(let m) = model.phase {
                    Section { Text(m).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("말글로 보내기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.phase == .done ? "닫기" : "취소") { model.close() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    switch model.phase {
                    case .sending: ProgressView()
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                    default:
                        Button(model.copyMode ? "담기" : "보내기") { model.send() }
                            .fontWeight(.semibold)
                            .disabled(!model.canSend)
                    }
                }
            }
        }
        .tint(Color(red: 0x34 / 255, green: 0x51 / 255, blue: 0xD1 / 255))
    }

    private func size(_ b: Int64) -> String {
        b >= 1_048_576 ? String(format: "%.1f MB", Double(b) / 1_048_576) : String(format: "%.0f KB", Double(b) / 1024)
    }
}

import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @Published var results: [String] = []
    var close: () -> Void = {}

    var configured: Bool { SharedSettings.isConfigured }

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

    func send() {
        phase = .sending
        results = []
        Task {
            let server = SharedSettings.server
            let ts = SharedSettings.tailscale
            status = "연결 확인 중..."
            let viaTS = await UploadKit.probe(ts)
            let base = viaTS ? ts : server
            for (i, f) in files.enumerated() {
                let label = files.count > 1 ? "(\(i + 1)/\(files.count)) " : ""
                do {
                    let name = uploadName(f)
                    if !viaTS && f.size > UploadKit.hundredMB {
                        results.append("⚠️ \(name): \(f.size / 1024 / 1024)MB로 100MB를 초과합니다. Tailscale 연결 후 다시 시도해주세요.")
                        continue
                    }
                    status = "\(label)중복 파일 여부 확인 중..."
                    progress = 0
                    if let dup = try await checkDuplicate(f.url, base: base) {
                        results.append("이미 같은 파일이 있습니다: \(dup)")
                        continue
                    }
                    status = "\(label)올리는 중..."
                    let t = try await upload(f, name: name, base: base)
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
                status = autoTranscribe ? "보냈어요. 서버 압축이 끝나면 받아쓰기가 시작됩니다." : "보냈어요. 말글 앱에서 받아쓰기를 시작하세요."
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

    private func upload(_ f: SharedFile, name: String, base: String) async throws -> String {
        let body = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).body")
        defer { try? FileManager.default.removeItem(at: body) }
        let boundary = "malgeul-\(UUID().uuidString)"
        let fields = autoTranscribe ? ["auto_transcribe": "1"] : [:]
        let src = f.url
        try await Task.detached(priority: .userInitiated) {
            try UploadKit.writeMultipart(source: src, filename: name, fields: fields, boundary: boundary, to: body)
        }.value
        var r = try request("meetings/upload", base: base, method: "POST")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 600
        let (d, resp) = try await URLSession.shared.upload(for: r, fromFile: body, delegate: self)
        try Self.check(resp, d)
        let o = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        if o?["duplicate"] as? Bool == true {
            return "이미 같은 파일이 있습니다: \(((o?["existing"] as? [String: Any])?["title"] as? String) ?? "")"
        }
        return (o?["title"] as? String) ?? name
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                                totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let p = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in self.progress = p }
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
                if !model.configured {
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
                    Toggle("업로드 후 바로 받아쓰기 (AssemblyAI)", isOn: $model.autoTranscribe)
                } footer: {
                    Text("다 보낼 때까지 이 화면을 열어 두세요. 큰 파일은 Tailscale에 연결되어 있을 때만 올릴 수 있어요(100MB 초과).")
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
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    default:
                        Button("보내기") { model.send() }
                            .fontWeight(.semibold)
                            .disabled(model.files.isEmpty || !model.configured || model.phase == .loading)
                    }
                }
            }
        }
        .tint(Color(red: 0xD4 / 255, green: 0x62 / 255, blue: 0x2A / 255))
    }

    private func size(_ b: Int64) -> String {
        b >= 1_048_576 ? String(format: "%.1f MB", Double(b) / 1_048_576) : String(format: "%.0f KB", Double(b) / 1024)
    }
}

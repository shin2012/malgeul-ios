import SwiftUI
import QuickLook

/// 문서(회의록/출장복명서)·화자 식별 상태. 진행 중이면 4초마다 갱신.
@MainActor
final class DocModel: ObservableObject {
    @Published var report: ReportInfo?
    @Published var speaker: SpeakerIDInfo?
    var onSpeakerFinished: (() -> Void)?

    private var meetingID = 0
    private var pollTask: Task<Void, Never>?
    private var prevSpeakerStatus: String?
    /// 받아쓰기 직후: 서버 화자 식별이 (제목 분석 뒤에) 끝날 때까지 기다림 — 이 시각 이후 결과가 나오면 대본 다시 불러옴
    private var waitingSince: Date?
    private var waitDeadline = Date.distantPast

    var busy: Bool { report?.status == "processing" || speaker?.status == "processing" || waitingSince != nil }

    /// 기기 받아쓰기·화자 재추정 직후 호출
    func watchSpeaker(since: Date) async {
        waitingSince = since
        waitDeadline = Date().addingTimeInterval(240)
        await refresh()
    }

    func start(_ id: Int) async {
        meetingID = id
        await refresh()
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    func refresh() async {
        guard meetingID > 0 else { return }
        async let r = try? API.shared.report(meetingID)
        async let s = try? API.shared.speakerID(meetingID)
        let (rr, ss) = await (r, s)
        if let rr { report = rr }
        if let ss {
            if prevSpeakerStatus == "processing", let st = ss.status, st != "processing" { onSpeakerFinished?() }
            else if let since = waitingSince, let st = ss.status, st != "processing",
                    let at = ss.result?["at"]?.string.flatMap(DateParse.iso), at >= since.addingTimeInterval(-5) {
                waitingSince = nil
                onSpeakerFinished?()
            }
            prevSpeakerStatus = ss.status
            speaker = ss
        }
        if waitingSince != nil && Date() > waitDeadline { waitingSince = nil; onSpeakerFinished?() }
        schedule()
    }

    private func schedule() {
        guard busy else { pollTask?.cancel(); pollTask = nil; return }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.pollTask = nil
            await self.refresh()
        }
    }

    func generate(type: String) async {
        report = { var r = report ?? ReportInfo(status: "processing"); r.status = "processing"; r.errorMessage = nil; return r }()
        do {
            try await API.shared.generateReport(meetingID, type: type)
        } catch {
            var r = report ?? ReportInfo(status: "error")
            r.status = "error"
            r.errorMessage = error.localizedDescription
            report = r
            return
        }
        await refresh()
    }

    func rerunSpeaker() async {
        speaker = SpeakerIDInfo(status: "processing")
        prevSpeakerStatus = "processing"
        try? await API.shared.rerunSpeakerID(meetingID)
        await refresh()
    }
}

private let typeLabel: [(String, String)] = [("auto", "자동 판별"), ("meeting", "회의록"), ("trip", "출장복명서")]
private func typeName(_ t: String?) -> String { typeLabel.first { $0.0 == t }?.1 ?? "문서" }

struct DocPanelView: View {
    let meetingID: Int
    @ObservedObject var doc: DocModel
    @Environment(\.dismiss) private var dismiss

    @State private var type = "auto"
    @State private var confirmRegenerate = false
    @State private var confirmSpeaker = false
    @State private var showReport = false
    @State private var previewURL: URL?
    @State private var shareURL: URL?
    @State private var downloading: String?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                reportSection
                speakerSection
            }
            .navigationTitle("문서")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
            .navigationDestination(isPresented: $showReport) {
                ReportWebView(meetingID: meetingID, onSaved: { Task { await doc.refresh() } })
            }
            .refreshable { await Task { await doc.refresh() }.value }
            .task { await doc.refresh() }
            .quickLookPreview($previewURL)
            .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { item in
                ShareSheet(items: [item.url])
            }
            .confirmationDialog("직접 고쳐 저장한 수정본이 있습니다.\n다시 작성하면 수정본은 사라집니다. 계속할까요?",
                                isPresented: $confirmRegenerate, titleVisibility: .visible) {
                Button("다시 작성", role: .destructive) { Task { await doc.generate(type: type) } }
            }
            .confirmationDialog("화자 식별을 다시 실행할까요?\n(이전에 자동으로 붙인 \"○○(추정)\" 이름은 원래 라벨로 되돌린 뒤 다시 판단합니다)",
                                isPresented: $confirmSpeaker, titleVisibility: .visible) {
                Button(doc.speaker?.status == nil ? "식별 실행" : "다시 식별") { Task { await doc.rerunSpeaker() } }
            }
            .alert("오류", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("확인", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    // MARK: 회의록 · 출장복명서

    private var reportSection: some View {
        let r = doc.report
        return Section {
            Picker("유형", selection: $type) {
                ForEach(typeLabel, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)

            Button {
                if r?.status == "done" && r?.editedAt != nil { confirmRegenerate = true }
                else { Task { await doc.generate(type: type) } }
            } label: {
                HStack {
                    if r?.status == "processing" { ProgressView().padding(.trailing, 4) }
                    Text(r?.status == "processing" ? "작성 중… (1~2분)" : r?.status == "done" ? "다시 작성" : "작성하기")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(r?.status == "processing")

            if r?.status == "error" {
                Text("실패: \(r?.errorMessage ?? "")").font(.footnote).foregroundStyle(.red)
            }
            if r?.status == "done" {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(typeName(r?.type)).fontWeight(.semibold)
                        if r?.editedAt != nil {
                            Text("수정본").font(.caption.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentMalgeul.opacity(0.12), in: Capsule())
                                .foregroundStyle(.accentMalgeul)
                        }
                    }
                    if let s = r?.subject { Text(s).font(.subheadline).foregroundStyle(.secondary) }
                }
                Button { showReport = true } label: { Label("보기·편집", systemImage: "doc.richtext") }
                Button { Task { await download(pdf: true, share: false) } } label: {
                    HStack { Label("PDF", systemImage: "doc.viewfinder"); Spacer(); if downloading == "pdf" { ProgressView() } }
                }
                Button { Task { await download(pdf: true, share: true) } } label: {
                    Label("PDF 공유·저장", systemImage: "square.and.arrow.up")
                }
                Button { Task { await download(pdf: false, share: true) } } label: {
                    HStack { Label("HTML 저장", systemImage: "chevron.left.forwardslash.chevron.right"); Spacer(); if downloading == "html" { ProgressView() } }
                }
            }
        } header: {
            Text("회의록 · 출장복명서 자동 작성")
        } footer: {
            if r?.status == "done" {
                Text("보기 화면에서 글자를 고친 뒤 ‘저장’을 누르면 수정본이 그대로 저장되어 PDF·HTML 다운로드에도 쓰입니다.")
            }
        }
    }

    // MARK: 화자 자동 식별

    private var speakerSection: some View {
        let s = doc.speaker
        let res = s?.result
        let isNew = !(res?["voice"]?["by_label"]?.isNull ?? true) || !(res?["unresolved"]?.isNull ?? true)
        let assigned = res?["assigned"]?.array ?? []
        return Section("화자 자동 식별") {
            Text(statusText(s, res: res, isNew: isNew, assigned: assigned))
                .font(.subheadline)

            if isNew && s?.status == "done" && !assigned.isEmpty {
                ForEach(Array(assigned.enumerated()), id: \.offset) { _, a in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(a["from"]?.string ?? "") → \(a["to"]?.string ?? "")").font(.subheadline.weight(.semibold))
                        Text([a["basis"]?.string, a["similarity"]?.double.map { String(format: "목소리 %.2f", $0) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let ev = a["evidence"]?[0]?.string {
                            Text("“\(ev)”").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            }
            if isNew && s?.status == "done", let un = res?["unresolved"]?.object, !un.isEmpty {
                Text("미확정: " + un.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value.string ?? ""))" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !isNew && s?.status == "done", let scores = res?["voice"]?["scores"]?.array, !scores.isEmpty {
                Text("목소리 유사도: " + scores.prefix(3).map { "\($0["speaker"]?.string ?? "") \(String(format: "%.2f", $0["similarity"]?.double ?? 0))" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !isNew && s?.status == "done", let ev = res?["content"]?["evidence"]?.array, !ev.isEmpty {
                ForEach(Array(ev.prefix(3).enumerated()), id: \.offset) { _, e in
                    Text("• \(e.string ?? "")").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(s?.status == nil ? "식별 실행" : "다시 식별") { confirmSpeaker = true }
                .disabled(s?.status == "processing")
        }
    }

    private func statusText(_ s: SpeakerIDInfo?, res: JSONValue?, isNew: Bool, assigned: [JSONValue]) -> String {
        switch s?.status {
        case "processing": return "내용·목소리 분석 중… (수 분 소요)"
        case "skipped":
            if res?["basis"]?.string == "이미 지정됨" {
                return "이미 지정됨 (\((res?["decided"]?.array ?? []).compactMap(\.string).joined(separator: ", ")))"
            }
            return res?["basis"]?.string ?? "건너뜀"
        case "error": return "오류: \(res?["error"]?.string ?? "")"
        case "done":
            if !assigned.isEmpty {
                return isNew ? "\(assigned.count)명 찾음"
                    : "\(assigned.compactMap { $0["from"]?.string }.joined(separator: ", ")) → 신요섭(추정) · \(res?["basis"]?.string ?? "")"
            }
            return "찾지 못함" + (isNew ? "" : " · \(res?["basis"]?.string ?? "")")
        default: return "아직 실행 전"
        }
    }

    private func download(pdf: Bool, share: Bool) async {
        downloading = pdf ? "pdf" : "html"
        defer { downloading = nil }
        do {
            let url = try await API.shared.downloadReport(meetingID, pdf: pdf)
            if share { shareURL = url } else { previewURL = url }
        } catch {
            errorText = (pdf ? "PDF" : "HTML") + " 받기 실패: " + error.localizedDescription
        }
    }
}

struct ShareItem: Identifiable { let url: URL; var id: String { url.path } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

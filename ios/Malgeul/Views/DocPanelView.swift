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

/// 회의록 패널 (웹과 같은 구성: 카드 + 미리보기)
struct DocPanelView: View {
    let meetingID: Int
    @ObservedObject var doc: DocModel

    @State private var type = "auto"
    @State private var chooser = false
    @State private var confirmRegenerate = false
    @State private var showReport = false
    @State private var previewURL: URL?
    @State private var shareURL: URL?
    @State private var downloading: String?
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let r = doc.report {
                    if r.status == "none" { createCard } else { reportCard(r) }
                    if r.status == "done", let pv = r.preview { preview(r, pv) }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.mgBg)
        .refreshable { await Task { await doc.refresh() }.value }
        .task { await doc.refresh() }
        .navigationDestination(isPresented: $showReport) {
            ReportWebView(meetingID: meetingID, onSaved: { Task { await doc.refresh() } })
        }
        .quickLookPreview($previewURL)
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { (item: ShareItem) in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog("어떤 문서로 다시 작성할까요?", isPresented: $chooser, titleVisibility: .visible) {
            ForEach(typeLabel, id: \.0) { (t: (String, String)) in
                Button(t.1) { type = t.0; regenerate() }
            }
        } message: { Text("지금 문서는 새로 작성한 문서로 바뀝니다.") }
        .confirmationDialog("직접 고쳐 저장한 수정본이 있습니다.\n다시 작성하면 수정본은 사라집니다. 계속할까요?",
                            isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("다시 작성", role: .destructive) { Task { await doc.generate(type: type) } }
        }
        .alert("오류", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func regenerate() {
        if doc.report?.status == "done" && doc.report?.editedAt != nil { confirmRegenerate = true }
        else { Task { await doc.generate(type: type) } }
    }

    private var card: some Shape { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    private var createCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("회의록 만들기").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.mgFg)
            Text("대화 내용으로 판매운영부 양식 문서를 작성합니다. 1~2분 걸립니다.")
                .font(.system(size: 14)).foregroundStyle(Color.mgFg3).padding(.top, 3)
            WebSegmented(selection: $type, options: typeLabel).padding(.vertical, 14)
            Button("작성하기") { Task { await doc.generate(type: type) } }
                .buttonStyle(WebButtonStyle(full: true))
        }
        .padding(16)
        .overlay(card.stroke(Color.mgLine, lineWidth: 1))
    }

    private func reportCard(_ r: ReportInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text").font(.system(size: 18))
                    .foregroundStyle(Color.accentMalgeul)
                    .frame(width: 40, height: 40)
                    .background(Color.mgAccentWeak, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(typeName(r.type)).font(.system(size: 16, weight: .bold)).foregroundStyle(Color.mgFg)
                        if r.editedAt != nil { Pill(text: "수정본") }
                    }
                    Group {
                        switch r.status {
                        case "processing": Text("작성 중… 1~2분 걸립니다")
                        case "error": Text("작성 실패 · \(r.errorMessage ?? "")").foregroundStyle(Color.mgDanger)
                        default: Text(Fmt.when(DateParse.iso(r.editedAt ?? r.updatedAt ?? "")) + (r.editedAt != nil ? " 수정" : " 작성"))
                        }
                    }
                    .font(.system(size: 13.5)).foregroundStyle(Color.mgFg3).lineLimit(2)
                }
                Spacer(minLength: 0)
                if r.status == "processing" {
                    ProgressView()
                } else {
                    Menu {
                        if r.status == "done" {
                            Button { Task { await download(pdf: true, share: true) } } label: { Label("PDF 공유·저장", systemImage: "square.and.arrow.up") }
                            Button { Task { await download(pdf: false, share: true) } } label: { Label("HTML로 저장", systemImage: "arrow.down.doc") }
                        }
                        Button { chooser = true } label: { Label("다시 작성", systemImage: "arrow.clockwise") }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.mgFg2)
                            .frame(width: 40, height: 40).contentShape(Rectangle())
                    }
                    .accessibilityLabel("더 보기")
                }
            }
            if r.status == "done" {
                HStack(spacing: 8) {
                    Button("보기·편집") { showReport = true }.buttonStyle(WebButtonStyle(full: true))
                    Button {
                        Task { await download(pdf: true, share: false) }
                    } label: {
                        if downloading == "pdf" { ProgressView().controlSize(.small) } else { Text("PDF") }
                    }
                    .buttonStyle(WebButtonStyle(kind: .ghost))
                }
            }
            if r.status == "error" {
                Button("다시 시도") { chooser = true }.buttonStyle(WebButtonStyle(full: true))
            }
        }
        .padding(16)
        .overlay(card.stroke(Color.mgLine, lineWidth: 1))
    }

    private func preview(_ r: ReportInfo, _ pv: ReportPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let s = r.subject {
                Text(s).font(.system(size: 17, weight: .bold)).foregroundStyle(Color.mgFg).lineSpacing(3)
            }
            if let p = pv.purpose, !p.isEmpty {
                Text(p).font(.system(size: 14.5)).foregroundStyle(Color.mgFg2).lineSpacing(4).padding(.top, 6)
            }
            ForEach(Array(pv.sections.enumerated()), id: \.offset) { (_: Int, sec: ReportPreview.Section) in
                VStack(alignment: .leading, spacing: 6) {
                    Text(sec.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mgFg3).padding(.bottom, 2)
                    ForEach(Array(sec.items.enumerated()), id: \.offset) { (_: Int, it: ReportPreview.Item) in
                        bullet(it.text, size: 14.5, color: Color(hex: 0x27272A), dot: true)
                        ForEach(Array(it.children.enumerated()), id: \.offset) { (_: Int, c: String) in
                            bullet(c, size: 14, color: Color.mgFg2, dot: false).padding(.leading, 14)
                        }
                    }
                    if let co = sec.callout, let t = co.text, !t.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(co.label ?? "결정").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Color.accentMalgeul)
                            Text(t).font(.system(size: 14.5)).foregroundStyle(Color.mgFg).lineSpacing(3)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.mgBg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.top, 4)
                    }
                }
                .padding(.top, 20)
            }
            if r.editedAt != nil {
                Text("직접 고친 내용은 ‘보기·편집’에서 확인하세요. 이 미리보기는 처음 작성본 기준입니다.")
                    .font(.system(size: 12.5)).foregroundStyle(Color.mgFg4).padding(.top, 20)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 18)
        .textSelection(.enabled)
    }

    private func bullet(_ text: String, size: CGFloat, color: Color, dot: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if dot { Circle().fill(Color.mgFg4).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { d in d[.bottom] + size * 0.32 } }
            else { Rectangle().fill(Color.mgFg4).frame(width: 6, height: 1).alignmentGuide(.firstTextBaseline) { d in d[.bottom] + size * 0.35 } }
            Text(text).font(.system(size: size)).foregroundStyle(color).lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
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

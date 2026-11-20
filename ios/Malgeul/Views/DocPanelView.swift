import SwiftUI
import QuickLook

/// 문서화(녹음당 여러 문서)·화자 식별 상태. 진행 중이면 4초마다 갱신.
@MainActor
final class DocModel: ObservableObject {
    @Published var docs: [DocItem]?
    @Published var speaker: SpeakerIDInfo?
    @Published var config: DocConfig?
    @Published var settings: DocSettings?
    var onSpeakerFinished: (() -> Void)?

    private var meetingID = 0
    private var pollTask: Task<Void, Never>?
    private var prevSpeakerStatus: String?
    /// 받아쓰기 직후: 서버 화자 식별이 (제목 분석 뒤에) 끝날 때까지 기다림 — 이 시각 이후 결과가 나오면 대본 다시 불러옴
    private var waitingSince: Date?
    private var waitDeadline = Date.distantPast

    var writing: Bool { docs?.contains { $0.status == "processing" } ?? false }
    var busy: Bool { writing || ["queued", "processing"].contains(speaker?.status ?? "") || waitingSince != nil }

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

    func loadConfig() async {
        async let c = try? API.shared.docConfig()
        async let s = try? API.shared.docSettings()
        let (cc, ss) = await (c, s)
        if let cc { config = cc }
        if let ss { settings = ss }
    }

    func refresh() async {
        guard meetingID > 0 else { return }
        if config == nil { await loadConfig() }
        async let r = try? API.shared.docs(meetingID)
        async let s = try? API.shared.speakerID(meetingID)
        let (rr, ss) = await (r, s)
        if let rr { docs = rr } else if docs == nil { docs = [] }
        if let ss {
            if ["queued", "processing"].contains(prevSpeakerStatus ?? ""), let st = ss.status, !["queued", "processing"].contains(st) {
                waitingSince = nil
                onSpeakerFinished?()
            }
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

    /// 새 문서 또는 같은 문서 다시 작성. 실패하면 오류 문구
    func create(template: String?, docID: Int? = nil) async -> String? {
        do {
            try await API.shared.createDoc(meetingID, template: template, docID: docID)
        } catch { return error.localizedDescription }
        await refresh()
        return nil
    }

    func delete(_ d: DocItem) async -> String? {
        do { try await API.shared.deleteDoc(meetingID, docID: d.id) } catch { return error.localizedDescription }
        docs?.removeAll { $0.id == d.id }
        return nil
    }

    func rerunSpeaker() async {
        speaker = SpeakerIDInfo(status: "processing")
        prevSpeakerStatus = "processing"
        try? await API.shared.rerunSpeakerID(meetingID)
        await refresh()
    }
}

let docFormatLabel: [(String, String)] = [("pdf", "PDF"), ("html", "HTML"), ("docx", "Word"), ("hwpx", "한글")]
func docFormatName(_ f: String) -> String { docFormatLabel.first { $0.0 == f }?.1 ?? "PDF" }

/// 다시 작성 확인 대상
struct DocRewrite: Identifiable { let template: String?; let doc: DocItem; var id: Int { doc.id } }

/// 문서화 패널 (웹과 같은 구성: 만들기 카드 + 문서 목록 + 미리보기)
struct DocPanelView: View {
    let meetingID: Int
    @ObservedObject var doc: DocModel

    @State private var picker = false
    @State private var openID: Int?
    @State private var viewing: Int?
    @State private var previewURL: URL?
    @State private var shareURL: URL?
    @State private var downloading: String?
    @State private var errorText: String?
    @State private var confirmRewrite: DocRewrite?
    @State private var confirmDelete: DocItem?

    private var types: [DocTypeInfo] { doc.config?.types ?? [] }
    private func name(_ k: String) -> String { types.first { $0.key == k }?.name ?? (k == "recommend" ? "추천" : "문서") }
    private var favorites: [String] { (doc.settings?.favorites ?? ["meeting", "trip"]).filter { k in types.contains { $0.key == k } } }
    private var format: String { doc.settings?.format ?? "pdf" }
    private var shown: DocItem? { (doc.docs ?? []).first { $0.id == openID && $0.status == "done" } ?? (doc.docs ?? []).first { $0.status == "done" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                makeCard
                if let list = doc.docs {
                    ForEach(list) { (d: DocItem) in docCard(d) }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
                if let d = shown, let pv = d.preview { preview(d, pv) }
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.mgBg)
        .refreshable { await Task { await doc.loadConfig(); await doc.refresh() }.value }
        .task { await doc.refresh() }
        .navigationDestination(item: $viewing) { (docID: Int) in
            ReportWebView(meetingID: meetingID, path: "meetings/\(meetingID)/docs/\(docID).html", onSaved: { Task { await doc.refresh() } })
        }
        .quickLookPreview($previewURL)
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { (item: ShareItem) in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $picker) { typePicker }
        .modifier(DocDialogs(confirmRewrite: $confirmRewrite, errorText: $errorText, name: name) { c in
            Task { await run(template: c.template, docID: c.doc.id) }
        })
        .alert("문서 삭제", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { (d: DocItem) in
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) { Task { if let e = await doc.delete(d) { errorText = e } } }
        } message: { (d: DocItem) in
            Text("‘\(name(d.type))’ 문서\(d.subject.map { "(\($0))" } ?? "")를 정말 삭제하시겠습니까? 되돌릴 수 없습니다.")
        }
    }

    private var card: some Shape { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    // MARK: 만들기

    private func create(_ template: String) {
        picker = false
        // 한 녹음에서는 한 번에 한 문서만 작성
        if doc.writing { errorText = "작성 중인 문서가 끝난 뒤에 만들 수 있습니다."; return }
        let list = doc.docs ?? []
        let same = template == "recommend"
            ? list.first { $0.requested == "recommend" }
            : (list.first { $0.type == template && $0.requested != "recommend" } ?? list.first { $0.type == template })
        if let same {
            confirmRewrite = DocRewrite(template: template, doc: same)
            return
        }
        Task { await run(template: template, docID: nil) }
    }
    private func run(template: String?, docID: Int?) async {
        if let e = await doc.create(template: template, docID: docID) { errorText = e }
    }

    private var makeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("문서 만들기").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.mgFg)
            Text(doc.writing ? "작성 중인 문서가 끝나면 다른 문서를 만들 수 있습니다." : "대화 내용으로 양식에 맞춘 문서를 작성합니다. 1~2분 걸립니다.")
                .font(.system(size: 14)).foregroundStyle(Color.mgFg3).padding(.top, 3)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                makeButton(icon: "sparkles", title: "추천", sub: "알맞은 양식 자동 선택", rec: true) { create("recommend") }
                ForEach(favorites, id: \.self) { (k: String) in
                    makeButton(icon: "doc.text", title: name(k), sub: types.first { $0.key == k }?.desc ?? "") { create(k) }
                }
                makeButton(icon: "square.grid.2x2", title: "다른 양식…", sub: "양식 \(types.isEmpty ? 11 : types.count)종") { picker = true }
            }
            .padding(.top, 14)
            .disabled(doc.writing)
            .opacity(doc.writing ? 0.45 : 1)
        }
        .padding(16)
        .overlay(card.stroke(Color.mgLine, lineWidth: 1))
    }

    private func makeButton(icon: String, title: String, sub: String, rec: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(rec ? Color.accentMalgeul : Color.mgFg)
                    Text(sub).font(.system(size: 12)).foregroundStyle(Color.mgFg3).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(rec ? Color.accentMalgeul : Color.mgFg2)
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rec ? Color.mgAccentWeak : Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(rec ? Color.accentMalgeul : Color.mgLine2, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var typePicker: some View {
        NavigationStack {
            List {
                Button { create("recommend") } label: {
                    pickerRow(icon: "sparkles", title: "추천", sub: "모든 양식 중 가장 알맞은 양식으로 작성", rec: true, pills: [])
                }
                ForEach(types) { (t: DocTypeInfo) in
                    Button { create(t.key) } label: {
                        pickerRow(icon: "doc.text", title: t.name, sub: "\(t.desc) · \(t.sections.joined(separator: " · "))", rec: false,
                                  pills: (favorites.contains(t.key) ? ["즐겨찾기"] : []) + ((doc.docs ?? []).contains { $0.type == t.key } ? ["있음"] : []))
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("양식 고르기")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { picker = false } } }
        }
        .presentationDetents([.large])
    }

    private func pickerRow(icon: String, title: String, sub: String, rec: Bool, pills: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(rec ? Color.accentMalgeul : Color.mgFg2).frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(rec ? Color.accentMalgeul : Color.mgFg)
                    ForEach(pills, id: \.self) { (p: String) in Pill(text: p) }
                }
                Text(sub).font(.system(size: 12.5)).foregroundStyle(Color.mgFg3).lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: 문서 카드

    private func stateText(_ d: DocItem) -> String {
        if d.status == "processing" {
            if d.phase == "queued" { return "차례를 기다리는 중…" }
            if d.requested == "recommend" && d.type == "recommend" { return "알맞은 양식을 고르는 중…" }
            return "작성 중… 1~2분 걸립니다"
        }
        return Fmt.when(DateParse.iso(d.editedAt ?? d.updatedAt ?? "")) + (d.editedAt != nil ? " 수정" : " 작성")
    }

    @ViewBuilder
    private func docMenu(_ d: DocItem) -> some View {
        Menu {
            if d.status == "done" {
                ForEach(["pdf", "docx", "hwpx", "html"], id: \.self) { (x: String) in
                    Button { Task { await download(d, ext: x, share: true) } } label: { Label("\(docFormatName(x))로 공유·저장", systemImage: "square.and.arrow.up") }
                }
                Divider()
            }
            Button { confirmRewrite = DocRewrite(template: nil, doc: d) } label: { Label("다시 작성", systemImage: "arrow.clockwise") }
                .disabled(doc.writing)
            Button(role: .destructive) { confirmDelete = d } label: { Label("삭제", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.mgFg2)
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .accessibilityLabel("더 보기")
    }

    private func docCard(_ d: DocItem) -> some View {
        let on = shown?.id == d.id
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: d.requested == "recommend" ? "sparkles" : "doc.text").font(.system(size: 18))
                    .foregroundStyle(Color.accentMalgeul)
                    .frame(width: 40, height: 40)
                    .background(Color.mgAccentWeak, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name(d.type)).font(.system(size: 16, weight: .bold)).foregroundStyle(Color.mgFg)
                        if d.requested == "recommend" && d.type != "recommend" { Pill(text: "추천") }
                        if d.editedAt != nil { Pill(text: "수정본") }
                    }
                    if d.status == "done", let s = d.subject, !s.isEmpty {
                        Text(s).font(.system(size: 14)).foregroundStyle(Color.mgFg2).lineLimit(1)
                    }
                    Group {
                        if d.status == "error" { Text("작성 실패 · \(d.errorMessage ?? "")").foregroundStyle(Color.mgDanger) }
                        else { Text(stateText(d)) }
                    }
                    .font(.system(size: 13.5)).foregroundStyle(Color.mgFg3).lineLimit(2)
                }
                Spacer(minLength: 0)
                if d.status == "processing" { ProgressView() } else { docMenu(d) }
            }
            if d.status == "done" {
                HStack(spacing: 8) {
                    Button("보기·편집") { viewing = d.id }.buttonStyle(WebButtonStyle(full: true))
                    Button {
                        Task { await download(d, ext: format, share: format != "pdf") }
                    } label: {
                        if downloading == "\(d.id).\(format)" { ProgressView().controlSize(.small) } else { Text(docFormatName(format)) }
                    }
                    .buttonStyle(WebButtonStyle(kind: .ghost))
                }
            }
            if d.status == "error" {
                Button("다시 시도") { Task { await run(template: nil, docID: d.id) } }.buttonStyle(WebButtonStyle(full: true))
            }
        }
        .padding(16)
        .overlay(card.stroke(on ? Color.accentMalgeul : Color.mgLine, lineWidth: on ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { if d.status == "done" { openID = d.id } }
    }

    // MARK: 미리보기

    private func preview(_ d: DocItem, _ pv: ReportPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(name(d.type)) 미리보기").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.accentMalgeul).padding(.bottom, 4)
            if let s = d.subject {
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
            if d.editedAt != nil {
                Text("직접 고친 내용은 ‘보기·편집’에서 확인하세요. 이 미리보기는 처음 작성본 기준입니다.")
                    .font(.system(size: 12.5)).foregroundStyle(Color.mgFg4).padding(.top, 20)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
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

    private func download(_ d: DocItem, ext: String, share: Bool) async {
        downloading = "\(d.id).\(ext)"
        defer { downloading = nil }
        do {
            let url = try await API.shared.downloadDoc(meetingID, docID: d.id, ext: ext)
            if share { shareURL = url } else { previewURL = url }
        } catch {
            errorText = "\(docFormatName(ext)) 받기 실패: " + error.localizedDescription
        }
    }
}

/// 다시 작성 확인·오류 창 (body 타입 검사 시간을 줄이려고 분리)
private struct DocDialogs: ViewModifier {
    @Binding var confirmRewrite: DocRewrite?
    @Binding var errorText: String?
    let name: (String) -> String
    let onConfirm: (DocRewrite) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(confirmRewrite.map { "이미 있는 ‘\($0.template == "recommend" ? "추천" : name($0.doc.type))’ 문서를 새로 작성할까요?" } ?? "",
                                isPresented: Binding(get: { confirmRewrite != nil }, set: { if !$0 { confirmRewrite = nil } }),
                                titleVisibility: .visible, presenting: confirmRewrite) { (c: DocRewrite) in
                Button("새로 작성", role: .destructive) { onConfirm(c) }
            } message: { (c: DocRewrite) in
                Text(c.doc.editedAt != nil ? "직접 고친 수정본은 사라집니다." : "지금 문서는 새로 작성한 문서로 바뀝니다.")
            }
            .alert("오류", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("확인", role: .cancel) {}
            } message: { Text(errorText ?? "") }
    }
}

struct ShareItem: Identifiable { let url: URL; var id: String { url.path } }

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#endif

import SwiftUI

enum DetailTab: String, CaseIterable { case script, doc, chat
    var label: String { switch self { case .script: "대화"; case .doc: "회의록"; case .chat: "AI 질문" } }
}

/// ⋯ 시트에서 고른 동작 (시트가 닫힌 뒤 실행)
enum MeetingAction { case copyText, shareText, shareAudio, sharePDF, talkShare, rename, recordedAt, redoDevice, speakersDevice, delete }

/// 회의 상세 (클로바노트·다글로 구성)
/// 위: 녹음 시각·길이 / 큰 제목 / 펼치면 참석자·키워드 → 탭(대화 | 회의록 | AI 질문) → 아래: 플레이어
struct MeetingDetailView: View {
    let meetingID: Int

    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var device: OnDeviceJobCenter
    @StateObject private var doc = DocModel()
    @AppStorage("mg_detail_tab") private var tab: DetailTab = .script

    @State private var detail: MeetingDetail?
    @State private var loadError: String?
    @State private var expanded = false
    @State private var searching = false
    @State private var search = ""
    @State private var follow = true
    @State private var rename: Segment?
    @State private var newName = ""
    @State private var showActions = false
    @State private var pending: MeetingAction?
    @State private var showTalkShare = false
    @State private var renamingTitle = false
    @State private var titleText = ""
    @State private var editingDate: Meeting?
    @State private var confirmDelete = false
    @State private var confirmRedo = false
    @State private var shareURL: URL?
    @State private var working = false
    @State private var toast: String?
    @FocusState private var searchFocused: Bool

    private var meeting: Meeting? { detail?.meeting ?? store.meetings.first { $0.id == meetingID } }
    private var segments: [Segment] { detail?.segments ?? [] }
    private var speakers: [String] {
        var seen = Set<String>(), out: [String] = []
        for s in segments where !seen.contains(s.speaker) { seen.insert(s.speaker); out.append(s.speaker) }
        return out
    }
    private var shown: [Segment] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? segments : segments.filter { $0.text.localizedCaseInsensitiveContains(q) || $0.speaker.localizedCaseInsensitiveContains(q) }
    }
    /// 재생 위치의 문장
    private var activeSeq: Int? {
        guard player.meetingID == meetingID, player.isPlaying || player.position > 0 else { return nil }
        let ms = Int(player.position * 1000)
        var ans: Int?
        for s in segments { if (s.startMs ?? 0) <= ms { ans = s.seq } else { break } }
        return ans
    }

    var body: some View {
        dialogs2(dialogs1(content))
    }

    @ViewBuilder private var content: some View {
        if let m = meeting, detail != nil || loadError == nil {
            VStack(spacing: 0) {
                header(m)
                tabStrip
                Divider()
                Group {
                    switch tab {
                    case .script: scriptPane
                    case .doc: DocPanelView(meetingID: meetingID, doc: doc, embedded: true)
                    case .chat: ChatView(meetingID: meetingID, compact: true)
                    }
                }
                .frame(maxHeight: .infinity)
                if tab == .script && detail != nil { PlayerBar(fallback: m.durationSeconds) }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.black.opacity(0.8), in: Capsule())
                        .padding(.bottom, 120)
                        .transition(.opacity)
                }
            }
        } else if let loadError {
            ContentUnavailableView("회의를 찾을 수 없습니다.", systemImage: "exclamationmark.triangle", description: Text(loadError))
        } else {
            ProgressView("불러오는 중...")
        }
    }

    // MARK: 머리

    private func header(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let j = device.job(for: meetingID) { DeviceJobLine(job: j).padding(.bottom, 4) }
            HStack(spacing: 6) {
                Text(Fmt.when(m.recordedOrCreated))
                if let d = m.durationSeconds, d > 0 { Text("· \(Fmt.durationKo(d))") }
            }
            .font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)

            HStack(alignment: .top, spacing: 8) {
                Text(m.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(expanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { beginRenameTitle() }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "접기" : "참석자·키워드 보기")
            }

            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    if !speakers.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("참석자 \(speakers.count)명").font(.subheadline.weight(.semibold))
                                Spacer()
                                Button("대화 점유율") { showTalkShare = true }.font(.subheadline)
                            }
                            Text(speakers.map { SpeakerName($0).display }.joined(separator: ", "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if !m.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("주요 키워드").font(.subheadline.weight(.semibold))
                            FlowLayout(spacing: 6) {
                                ForEach(m.tags, id: \.self) { t in
                                    Text(t).font(.subheadline)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .foregroundStyle(Color.accentMalgeul)
                                        .background(Color.accentMalgeul.opacity(0.1), in: Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(.top, 6)
                .transition(.opacity)
            } else if !speakers.isEmpty {
                Button { withAnimation { expanded = true } } label: {
                    HStack(spacing: 8) {
                        HStack(spacing: -6) {
                            ForEach(speakers.prefix(4), id: \.self) { sp in
                                SpeakerAvatar(initial: SpeakerName(sp).initial, size: 24)
                                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            }
                        }
                        Text("참석자 \(speakers.count)명").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    VStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Text(t.label)
                            if t == .doc && doc.report?.status == "processing" { ProgressView().controlSize(.mini) }
                        }
                        .font(.body.weight(tab == t ? .bold : .regular))
                        .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                        Rectangle().fill(tab == t ? Color.primary : Color.clear).frame(height: 2.5)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: 대화

    private var scriptPane: some View {
        VStack(spacing: 0) {
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("대화에서 찾기", text: $search).focused($searchFocused).submitLabel(.search)
                    if !search.isEmpty { Text("\(shown.count)건").font(.footnote).foregroundStyle(.secondary).monospacedDigit() }
                    Button("닫기") { search = ""; searching = false }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if segments.isEmpty {
                            Text("받아쓴 내용이 없습니다.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                        }
                        let list = shown
                        ForEach(Array(list.enumerated()), id: \.element.seq) { (i: Int, seg: Segment) in
                            SegmentRow(seg: seg,
                                       head: i == 0 || list[i - 1].speaker != seg.speaker || !search.isEmpty,
                                       active: seg.seq == activeSeq, query: search,
                                       onSpeakerTap: { newName = seg.speaker; rename = seg },
                                       onTap: { seekTo(seg) })
                                .id(seg.seq)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in if player.isPlaying { follow = false } })
                .onChange(of: activeSeq) { _, s in
                    guard let s, follow, player.isPlaying else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(s, anchor: .center) }
                }
                .overlay(alignment: .bottom) {
                    if player.isPlaying && !follow, let s = activeSeq {
                        Button {
                            follow = true
                            withAnimation { proxy.scrollTo(s, anchor: .center) }
                        } label: {
                            Label("재생 위치로", systemImage: "scope").font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 10)
                    }
                }
            }
        }
    }

    private func seekTo(_ seg: Segment) {
        follow = true
        Task { await player.playMeeting(from: Double(seg.startMs ?? 0) / 1000) }
    }

    // MARK: 화면 막대 · 시트

    private func dialogs1<V: View>(_ v: V) -> some View {
        v
            .navigationTitle(meeting?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        tab = .script
                        searching.toggle()
                        if searching { searchFocused = true } else { search = "" }
                    } label: { Label("찾기", systemImage: "magnifyingglass") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showActions = true } label: { Label("더 보기", systemImage: "ellipsis") }
                }
            }
            .sheet(isPresented: $showActions, onDismiss: runPending) {
                MeetingActionsSheet(hasReport: doc.report?.status == "done") { (a: MeetingAction) in
                    pending = a
                    showActions = false
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showTalkShare) {
                TalkShareView(segments: segments) { (sp: String) in
                    showTalkShare = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        newName = sp
                        rename = segments.first { $0.speaker == sp }
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { (item: ShareItem) in
                ShareSheet(items: [item.url])
            }
            .sheet(item: $editingDate) { (m: Meeting) in RecordedAtSheet(meeting: m) }
    }

    private func dialogs2<V: View>(_ v: V) -> some View {
        v
            .alert("화자 이름 변경", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } }), presenting: rename) { (seg: Segment) in
                TextField("이름", text: $newName)
                Button("‘\(SpeakerName(seg.speaker).name)’ 전체 변경") { doRename(seg, all: true) }
                Button("이 발언만 변경") { doRename(seg, all: false) }
                Button("취소", role: .cancel) {}
            } message: { (_: Segment) in Text("소속은 괄호에 적으세요. 예: 홍길동(영업부)") }
            .alert("제목 바꾸기", isPresented: $renamingTitle) {
                TextField("제목", text: $titleText)
                Button("저장") { saveTitle() }
                Button("취소", role: .cancel) {}
            }
            .confirmationDialog("이 노트를 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("삭제", role: .destructive) { Task { await deleteMeeting() } }
            } message: { Text("녹음 파일·대화·회의록이 모두 지워지고 되돌릴 수 없습니다.") }
            .confirmationDialog("이 기기에서 다시 받아쓸까요?", isPresented: $confirmRedo, titleVisibility: .visible) {
                Button("다시 받아쓰기") {
                    device.requestNotificationPermission()
                    device.enqueueTranscribe(meetingID: meetingID, title: meeting?.title ?? "", replace: true)
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("지금 대본과 고친 화자 이름이 새 결과로 바뀝니다. 이전 대본은 서버에 보관돼요.")
            }
            .onChange(of: device.finished) { _, f in
                guard let f, f.meetingID == meetingID else { return }
                Task { await load(); await doc.watchSpeaker(since: f.submittedAt) }
            }
            .task(id: meetingID) {
                if let d = DiskCache.load(key: "meeting_\(meetingID)"), let m = try? JSONDecoder().decode(MeetingDetail.self, from: d) {
                    detail = m
                }
                await load()
                if router.debugOpenChat { router.debugOpenChat = false; tab = .chat }
                if router.debugOpenDoc { router.debugOpenDoc = false; tab = .doc }
                doc.onSpeakerFinished = { Task { await load() } }
                await doc.start(meetingID)
                if let t = detail?.meeting.transcribedAt, Date().timeIntervalSince(t) < 240 { await doc.watchSpeaker(since: t) }
            }
            .onDisappear { player.leaveMeeting(meetingID); doc.stop() }
    }

    // MARK: 동작

    private func runPending() {
        guard let a = pending else { return }
        pending = nil
        switch a {
        case .talkShare: showTalkShare = true
        case .copyText:
            UIPasteboard.general.string = transcriptText()
            showToast("대화 내용을 복사했습니다")
        case .shareText:
            let url = FileManager.default.temporaryDirectory.appending(path: "\(safeName).txt")
            try? transcriptText().write(to: url, atomically: true, encoding: .utf8)
            shareURL = url
        case .shareAudio:
            showToast("녹음 파일을 준비하는 중…")
            Task {
                do {
                    let src = try await API.shared.audioFile(meetingID)
                    let url = FileManager.default.temporaryDirectory.appending(path: "\(safeName).mp3")
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.copyItem(at: src, to: url)
                    shareURL = url
                } catch { showToast("녹음 파일을 받지 못했습니다") }
            }
        case .sharePDF:
            showToast("회의록 PDF를 준비하는 중…")
            Task {
                do { shareURL = try await API.shared.downloadReport(meetingID, pdf: true) }
                catch { showToast("회의록 PDF를 받지 못했습니다") }
            }
        case .rename: beginRenameTitle()
        case .recordedAt: editingDate = meeting
        case .redoDevice: confirmRedo = true
        case .speakersDevice:
            device.requestNotificationPermission()
            device.enqueueSpeakers(meetingID: meetingID, title: meeting?.title ?? "")
            showToast("기기에서 화자를 다시 추정합니다")
        case .delete: confirmDelete = true
        }
    }

    private var safeName: String {
        (meeting?.title ?? "말글").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    private func transcriptText() -> String {
        let head = "\(meeting?.title ?? "")\n\(Fmt.when(meeting?.recordedOrCreated))\n\n"
        return head + segments.map { "[\(Fmt.timestamp($0.startMs) ?? "")] \(SpeakerName($0.speaker).display): \($0.text)" }.joined(separator: "\n")
    }

    private func showToast(_ s: String) {
        withAnimation { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { if toast == s { toast = nil } } }
    }

    private func beginRenameTitle() { titleText = meeting?.title ?? ""; renamingTitle = true }

    private func saveTitle() {
        let t = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != meeting?.title else { return }
        store.patch(meetingID) { $0.title = t }
        detail?.meeting.title = t
        Task { try? await API.shared.setTitle(meetingID, t); await store.refresh() }
    }

    private func deleteMeeting() async {
        player.leaveMeeting(meetingID)
        try? await API.shared.deleteMeeting(meetingID)
        store.remove([meetingID])
        router.meetingID = nil
        await store.refresh()
    }

    private func load() async {
        do {
            let d = try await API.shared.meeting(meetingID)
            detail = d
            loadError = nil
            player.prepareMeeting(meetingID, title: d.meeting.title, duration: d.meeting.durationSeconds)
        } catch {
            if detail == nil && !error.isCancellation { loadError = error.localizedDescription }
        }
    }

    private func doRename(_ seg: Segment, all: Bool) {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != seg.speaker else { return }
        Task {
            try? await API.shared.renameSpeaker(meetingID, old: seg.speaker, new: n, seq: seg.seq, all: all)
            await load()
        }
    }
}

// MARK: - 대화 한 줄

struct SegmentRow: View {
    let seg: Segment
    let head: Bool
    let active: Bool
    var query = ""
    var onSpeakerTap: () -> Void
    var onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if head { speakerLine.padding(.top, 16) }
            highlighted
                .font(.body)
                .lineSpacing(5)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(active ? Color.accentMalgeul.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                .contextMenu {
                    Button { onTap() } label: { Label("여기부터 재생", systemImage: "play") }
                    Button { UIPasteboard.general.string = seg.text } label: { Label("복사", systemImage: "doc.on.doc") }
                    Button { onSpeakerTap() } label: { Label("화자 이름 변경", systemImage: "person.text.rectangle") }
                }
                .padding(.leading, 32)
        }
    }

    private var speakerLine: some View {
        let sp = SpeakerName(seg.speaker)
        return HStack(spacing: 10) {
            SpeakerAvatar(initial: sp.initial, size: 30)
            Button(action: onSpeakerTap) {
                HStack(spacing: 6) {
                    Text(sp.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if !sp.org.isEmpty { Text(sp.org).font(.footnote).foregroundStyle(.secondary) }
                    if sp.guess {
                        Text("추정").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(.separator), lineWidth: 1))
                    }
                }
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityHint("화자 이름 변경")
            if let ts = Fmt.timestamp(seg.startMs) {
                Text(ts).font(.footnote).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
    }

    private var highlighted: Text {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Text(seg.text) }
        var a = AttributedString(seg.text)
        var from = a.startIndex
        while from < a.endIndex, let r = a[from...].range(of: q, options: .caseInsensitive) {
            a[r].backgroundColor = Color.yellow.opacity(0.45)
            from = r.upperBound
        }
        return Text(a)
    }
}

// MARK: - 플레이어

struct PlayerBar: View {
    let fallback: Int?
    @EnvironmentObject private var player: AudioPlayer
    @State private var dragging: Double?

    private var total: Double { player.duration > 0 ? player.duration : Double(fallback ?? 0) }

    var body: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(get: { dragging ?? player.position }, set: { dragging = $0 }),
                   in: 0...max(total, 1)) { (editing: Bool) in
                if !editing, let d = dragging { player.seek(to: d); dragging = nil }
            }
            .tint(.accentMalgeul)
            HStack {
                Text(Fmt.clock(dragging ?? player.position)).foregroundStyle(Color.accentMalgeul)
                Spacer()
                Text(Fmt.clock(total)).foregroundStyle(.secondary)
            }
            .font(.caption).monospacedDigit()
            HStack {
                Button { player.cycleRate() } label: {
                    Text(rateText).font(.subheadline.weight(.semibold)).monospacedDigit().frame(width: 52, height: 40)
                }
                .accessibilityLabel("재생 속도")
                Spacer()
                Button { player.skip(-10) } label: { Image(systemName: "gobackward.10").font(.title2).frame(width: 48, height: 44) }
                    .accessibilityLabel("10초 뒤로")
                Spacer()
                Button { Task { await player.toggleMeeting() } } label: {
                    ZStack {
                        Circle().fill(Color.accentMalgeul).frame(width: 52, height: 52)
                        if player.meetingLoading { ProgressView().tint(.white) }
                        else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2).foregroundStyle(.white) }
                    }
                }
                .accessibilityLabel(player.isPlaying ? "일시정지" : "재생")
                Spacer()
                Button { player.skip(10) } label: { Image(systemName: "goforward.10").font(.title2).frame(width: 48, height: 44) }
                    .accessibilityLabel("10초 앞으로")
                Spacer()
                Color.clear.frame(width: 52, height: 40)
            }
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var rateText: String {
        let r = player.rate
        return r == r.rounded() ? "\(Int(r))x" : String(format: "%gx", r)
    }
}

// MARK: - 줄바꿈 배치 (키워드 칩)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > w { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, w), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

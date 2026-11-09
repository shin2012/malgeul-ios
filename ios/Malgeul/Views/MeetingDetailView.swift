import SwiftUI

enum DetailTab: String, CaseIterable { case script, doc, chat }
enum SidePane: String { case doc, chat }

/// 회의 상세 — 웹 상세 화면과 같은 구성
/// 머리: 큰 제목 · 녹음 시각 · 길이 · 참석자 · #태그
/// 넓은 화면(900pt 이상): 대화 | 오른쪽 패널(회의록 · AI 질문). 좁으면 대화 · 회의록 · AI 질문 탭
/// 아래: 플레이어 (재생 중 문장 강조 · 따라가기)
struct MeetingDetailView: View {
    let meetingID: Int

    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var device: OnDeviceJobCenter
    @StateObject private var doc = DocModel()
    @AppStorage("mg_detail_tab") private var tab: DetailTab = .script
    @AppStorage("mg_side") private var side: SidePane = .doc

    @State private var detail: MeetingDetail?
    @State private var loadError: String?
    @State private var finding = false
    @State private var findText = ""
    @State private var findIndex = 0
    @State private var follow = true
    @State private var rename: Segment?
    @State private var newName = ""
    @State private var showSpeakers = false
    @State private var renamingTitle = false
    @State private var titleText = ""
    @State private var editingDate: Meeting?
    @State private var confirmDelete = false
    @State private var confirmRedo = false
    @State private var shareURL: URL?
    @State private var toast: String?
    @FocusState private var findFocused: Bool

    private var meeting: Meeting? { detail?.meeting ?? store.meetings.first { $0.id == meetingID } }
    private var segments: [Segment] { detail?.segments ?? [] }
    private var speakers: [String] {
        var c: [String: Int] = [:]
        for s in segments { c[s.speaker, default: 0] += 1 }
        return c.sorted { $0.value > $1.value }.map(\.key)
    }
    /// 대화에서 찾기 — 일치하는 문장 위치
    private var hits: [Int] {
        let q = findText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return segments.filter { $0.text.localizedCaseInsensitiveContains(q) }.map(\.seq)
    }
    private var activeSeq: Int? {
        guard player.meetingID == meetingID, player.isPlaying || player.position > 0 else { return nil }
        let ms = Int(player.position * 1000)
        var lo = 0, hi = segments.count - 1, ans: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if (segments[mid].startMs ?? 0) <= ms { ans = segments[mid].seq; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    var body: some View {
        dialogs2(dialogs1(content))
    }

    @ViewBuilder private var content: some View {
        if let m = meeting, detail != nil || loadError == nil {
            GeometryReader { geo in
                let wide = geo.size.width >= 900
                VStack(spacing: 0) {
                    header(m)
                    Rectangle().fill(Color.mgLine).frame(height: 1)
                    if wide {
                        HStack(spacing: 0) {
                            scriptPane
                            Rectangle().fill(Color.mgLine).frame(width: 1)
                            VStack(spacing: 0) {
                                WebSegmented(selection: $side, options: [(.doc, "회의록"), (.chat, "AI 질문")],
                                             badge: doc.report?.status == "processing" ? .doc : nil)
                                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
                                if side == .doc { DocPanelView(meetingID: meetingID, doc: doc) }
                                else { ChatView(meetingID: meetingID, compact: true) }
                            }
                            .frame(width: min(440, geo.size.width * 0.4))
                        }
                    } else {
                        WebSegmented(selection: $tab, options: [(.script, "대화"), (.doc, "회의록"), (.chat, "AI 질문")],
                                     badge: doc.report?.status == "processing" ? .doc : nil)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        Rectangle().fill(Color.mgLine).frame(height: 1)
                        Group {
                            switch tab {
                            case .script: scriptPane
                            case .doc: DocPanelView(meetingID: meetingID, doc: doc)
                            case .chat: ChatView(meetingID: meetingID, compact: true)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                    if detail != nil && (wide || tab == .script) {
                        PlayerBar(fallback: m.durationSeconds, compact: geo.size.width < 500)
                    }
                }
            }
            .background(Color.mgBg)
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.system(size: 14)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Color.mgFg, in: Capsule())
                        .padding(.bottom, 96)
                        .transition(.opacity)
                }
            }
        } else if let loadError {
            ContentUnavailableView("노트를 불러오지 못했습니다", systemImage: "exclamationmark.triangle", description: Text(loadError))
        } else {
            ProgressView()
        }
    }

    // MARK: 머리

    private func header(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let j = device.job(for: meetingID) { DeviceJobLine(job: j).padding(.bottom, 4) }
            Text(m.title)
                .font(.system(size: 21, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(Color.mgFg)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { beginRenameTitle() }
                .accessibilityHint("눌러서 제목 바꾸기")
            HStack(spacing: 12) {
                Text(Fmt.when(m.recordedOrCreated))
                if let d = m.durationSeconds, d > 0 { Text(Fmt.durationKo(d)) }
                if !speakers.isEmpty {
                    Button { showSpeakers = true } label: {
                        HStack(spacing: 6) {
                            HStack(spacing: -6) {
                                ForEach(speakers.prefix(4), id: \.self) { (sp: String) in
                                    SpeakerAvatar(initial: SpeakerName(sp).initial, size: 22)
                                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                }
                            }
                            Text("\(speakers.count)명").foregroundStyle(Color.mgFg2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("참석자 \(speakers.count)명, 대화 점유율")
                }
            }
            .font(.system(size: 13.5)).monospacedDigit().foregroundStyle(Color.mgFg3).lineLimit(1)
            if !m.tags.isEmpty {
                Text(m.tags.map { "#\($0)" }.joined(separator: "  "))
                    .font(.system(size: 13.5)).foregroundStyle(Color.mgFg2).lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    // MARK: 대화

    private var scriptPane: some View {
        VStack(spacing: 0) {
            if finding { findBar }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if segments.isEmpty {
                            Text("받아쓴 내용이 없습니다.").foregroundStyle(Color.mgFg3).frame(maxWidth: .infinity).padding(.top, 60)
                        }
                        let list = segments
                        let q = finding ? findText.trimmingCharacters(in: .whitespaces) : ""
                        let cur = hits.isEmpty ? nil : hits[min(findIndex, hits.count - 1)]
                        ForEach(Array(list.enumerated()), id: \.element.seq) { (i: Int, seg: Segment) in
                            SegmentRow(seg: seg, head: isHead(i, list), active: seg.seq == activeSeq,
                                       current: seg.seq == cur, query: q,
                                       onSpeakerTap: { newName = SpeakerName.editable(seg.speaker); rename = seg },
                                       onTap: { seekTo(seg) })
                                .id(seg.seq)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in if player.isPlaying { follow = false } })
                .onChange(of: activeSeq) { _, s in
                    guard let s, follow, player.isPlaying else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(s, anchor: .center) }
                }
                .onChange(of: findIndex) { _, _ in scrollToHit(proxy) }
                .onChange(of: findText) { _, _ in findIndex = 0; scrollToHit(proxy) }
                .overlay(alignment: .bottom) {
                    if player.isPlaying && !follow, let s = activeSeq {
                        Button {
                            follow = true
                            withAnimation { proxy.scrollTo(s, anchor: .center) }
                        } label: {
                            Label("재생 위치로", systemImage: "scope")
                                .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Color.mgFg2)
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(Color.white, in: Capsule())
                                .overlay(Capsule().stroke(Color.mgLine, lineWidth: 1))
                                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 14)
                    }
                }
            }
        }
    }

    private func isHead(_ i: Int, _ list: [Segment]) -> Bool {
        if i == 0 { return true }
        let p = list[i - 1], s = list[i]
        return p.speaker != s.speaker || ((s.startMs ?? 0) - (p.endMs ?? 0)) > 120_000
    }

    private var findBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(Color.mgFg3)
            TextField("대화에서 찾기", text: $findText)
                .focused($findFocused).submitLabel(.search)
                .onSubmit { if !hits.isEmpty { findIndex = (findIndex + 1) % hits.count } }
                .padding(.leading, 4)
            if !findText.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(hits.isEmpty ? "없음" : "\(min(findIndex, hits.count - 1) + 1)/\(hits.count)")
                    .font(.system(size: 13)).monospacedDigit().foregroundStyle(Color.mgFg3)
            }
            Button { findIndex = (findIndex - 1 + hits.count) % max(hits.count, 1) } label: {
                Image(systemName: "chevron.up").frame(width: 36, height: 36)
            }.disabled(hits.isEmpty).accessibilityLabel("이전")
            Button { findIndex = (findIndex + 1) % max(hits.count, 1) } label: {
                Image(systemName: "chevron.down").frame(width: 36, height: 36)
            }.disabled(hits.isEmpty).accessibilityLabel("다음")
            Button("닫기") { finding = false; findText = "" }.font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(Color.mgFg2)
        .tint(Color.accentMalgeul)
        .padding(.leading, 20).padding(.trailing, 12).padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgLine).frame(height: 1) }
    }

    private func scrollToHit(_ proxy: ScrollViewProxy) {
        guard !hits.isEmpty else { return }
        proxy.scrollTo(hits[min(findIndex, hits.count - 1)], anchor: .center)
    }

    private func seekTo(_ seg: Segment) {
        follow = true
        Task { await player.playMeeting(from: Double(seg.startMs ?? 0) / 1000) }
    }

    // MARK: 막대 · 시트

    private func dialogs1<V: View>(_ v: V) -> some View {
        v
            .navigationTitle(meeting?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbarBackground(Color.white, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if !(tab == .script) { tab = .script }
                        finding.toggle()
                        if finding { findFocused = true } else { findText = "" }
                    } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("대화에서 찾기")
                }
                ToolbarItem(placement: .topBarTrailing) { moreMenu }
            }
            .sheet(isPresented: $showSpeakers) {
                SpeakersSheet(meetingID: meetingID, segments: segments, doc: doc) { (old: String, new: String) in
                    Task {
                        try? await API.shared.renameSpeaker(meetingID, old: old, new: new, seq: 0, all: true)
                        await load()
                        showToast("이름을 바꿨습니다")
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

    private var moreMenu: some View {
        Menu {
            Button { beginRenameTitle() } label: { Label("제목 바꾸기", systemImage: "pencil") }
            Button { editingDate = meeting } label: { Label("녹음 시각 바꾸기", systemImage: "calendar") }
            Button { showSpeakers = true } label: { Label("참석자 · 대화 점유율", systemImage: "person.2") }
            Divider()
            Button {
                UIPasteboard.general.string = transcriptText()
                showToast("대화 내용을 복사했습니다")
            } label: { Label("대화 내용 복사", systemImage: "doc.on.doc") }
            Button { shareText() } label: { Label("대화 내용 저장 (.txt)", systemImage: "square.and.arrow.down") }
            Button { shareAudio() } label: { Label("녹음 파일 저장", systemImage: "waveform") }
            Divider()
            if AppConfig.deviceTranscribeAvailable {
                Button { confirmRedo = true } label: { Label("이 기기에서 다시 받아쓰기", systemImage: "iphone.and.arrow.forward") }
            }
            Button {
                device.requestNotificationPermission()
                device.enqueueSpeakers(meetingID: meetingID, title: meeting?.title ?? "")
                showToast("기기에서 화자를 다시 추정합니다")
            } label: { Label("기기 목소리로 화자 다시 추정", systemImage: "person.wave.2") }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label("삭제", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("더 보기")
    }

    private func dialogs2<V: View>(_ v: V) -> some View {
        v
            .alert("화자 이름", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } }), presenting: rename) { (seg: Segment) in
                TextField("이름 (예: 홍길동(소속))", text: $newName)
                Button("‘\(SpeakerName(seg.speaker).name)’ 전체 바꾸기") { doRename(seg, all: true) }
                Button("이 발언만") { doRename(seg, all: false) }
                Button("취소", role: .cancel) {}
            } message: { (seg: Segment) in Text("지금: \(seg.speaker)") }
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
                if router.debugOpenChat { router.debugOpenChat = false; tab = .chat; side = .chat }
                if router.debugOpenDoc { router.debugOpenDoc = false; tab = .doc; side = .doc }
                doc.onSpeakerFinished = { Task { await load() } }
                await doc.start(meetingID)
                if let t = detail?.meeting.transcribedAt, Date().timeIntervalSince(t) < 240 { await doc.watchSpeaker(since: t) }
            }
            .onDisappear { player.leaveMeeting(meetingID); doc.stop() }
    }

    // MARK: 동작

    private var safeName: String {
        (meeting?.title ?? "말글").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    private func transcriptText() -> String {
        let head = "\(meeting?.title ?? "")\n\(Fmt.when(meeting?.recordedOrCreated))\n\n"
        return head + segments.map { "[\(Fmt.timestamp($0.startMs) ?? "")] \(SpeakerName($0.speaker).display): \($0.text)" }.joined(separator: "\n")
    }

    private func shareText() {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(safeName).txt")
        try? transcriptText().write(to: url, atomically: true, encoding: .utf8)
        shareURL = url
    }

    private func shareAudio() {
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
    }

    private func showToast(_ s: String) {
        withAnimation { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { withAnimation { if toast == s { toast = nil } } }
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
            showToast("이름을 바꿨습니다")
        }
    }
}

// MARK: - 대화 한 줄 (웹과 같은 모양)

struct SegmentRow: View {
    let seg: Segment
    let head: Bool
    let active: Bool
    var current = false
    var query = ""
    var onSpeakerTap: () -> Void
    var onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if head { speakerLine.padding(.top, 18).padding(.bottom, 2) }
            highlighted
                .font(.system(size: 16))
                .lineSpacing(6)
                .foregroundStyle(Color(hex: 0x27272A))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(active ? Color.mgAccentWeak : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    if current { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.mgMark, lineWidth: 2) }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                .contextMenu {
                    Button { onTap() } label: { Label("여기부터 재생", systemImage: "play") }
                    Button { UIPasteboard.general.string = seg.text } label: { Label("복사", systemImage: "doc.on.doc") }
                    Button { onSpeakerTap() } label: { Label("화자 이름 바꾸기", systemImage: "person.text.rectangle") }
                }
                .padding(.leading, 30)
        }
    }

    private var speakerLine: some View {
        let sp = SpeakerName(seg.speaker)
        return HStack(spacing: 10) {
            SpeakerAvatar(initial: sp.initial, size: 30)
            Button(action: onSpeakerTap) {
                HStack(spacing: 6) {
                    Text(sp.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.mgFg)
                    if !sp.org.isEmpty { Text(sp.org).font(.system(size: 13)).foregroundStyle(Color.mgFg3) }
                    if sp.guess { Pill(text: "추정") }
                }
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityHint("화자 이름 바꾸기")
            if let ts = Fmt.timestamp(seg.startMs) {
                Text(ts).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Color.mgFg4)
            }
        }
    }

    private var highlighted: Text {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Text(seg.text) }
        var a = AttributedString(seg.text)
        var from = a.startIndex
        while from < a.endIndex, let r = a[from...].range(of: q, options: .caseInsensitive) {
            a[r].backgroundColor = Color.mgMark
            from = r.upperBound
        }
        return Text(a)
    }
}

// MARK: - 플레이어 (웹과 같은 한 줄)

struct PlayerBar: View {
    let fallback: Int?
    var compact = false
    @EnvironmentObject private var player: AudioPlayer
    @State private var dragging: Double?

    private var total: Double { player.duration > 0 ? player.duration : Double(fallback ?? 0) }

    var body: some View {
        HStack(spacing: compact ? 2 : 6) {
            Button { player.skip(-10) } label: {
                Image(systemName: "gobackward.10").font(.system(size: 20)).frame(width: 40, height: 40)
            }
            .accessibilityLabel("10초 뒤로")
            Button { Task { await player.toggleMeeting() } } label: {
                ZStack {
                    Circle().fill(Color.accentMalgeul).frame(width: 44, height: 44)
                    if player.meetingLoading { ProgressView().tint(.white) }
                    else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18)).foregroundStyle(.white) }
                }
            }
            .accessibilityLabel(player.isPlaying ? "일시정지" : "재생")
            Button { player.skip(10) } label: {
                Image(systemName: "goforward.10").font(.system(size: 20)).frame(width: 40, height: 40)
            }
            .accessibilityLabel("10초 앞으로")
            Text(Fmt.clock(dragging ?? player.position)).font(.system(size: 13)).monospacedDigit()
                .foregroundStyle(Color.mgFg2).frame(minWidth: 44)
            Slider(value: Binding(get: { dragging ?? player.position }, set: { dragging = $0 }),
                   in: 0...max(total, 1)) { (editing: Bool) in
                if !editing, let d = dragging { player.seek(to: d); dragging = nil }
            }
            .tint(Color.accentMalgeul)
            if !compact {
                Text(Fmt.clock(total)).font(.system(size: 13)).monospacedDigit().foregroundStyle(Color.mgFg3).frame(minWidth: 44)
            }
            Button { player.cycleRate() } label: {
                Text(rateText).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Color.mgFg2)
                    .padding(.horizontal, 10).frame(minWidth: 48, minHeight: 30)
                    .overlay(Capsule().stroke(Color.mgLine2, lineWidth: 1))
            }
            .accessibilityLabel("재생 속도 \(rateText)")
        }
        .foregroundStyle(Color.mgFg2)
        .buttonStyle(.plain)
        .padding(.horizontal, compact ? 8 : 16)
        .frame(height: 68)
        .background(Color.white)
        .overlay(alignment: .top) { Rectangle().fill(Color.mgLine).frame(height: 1) }
    }

    private var rateText: String {
        let r = player.rate
        return r == r.rounded() ? "\(Int(r))×" : String(format: "%g×", r)
    }
}

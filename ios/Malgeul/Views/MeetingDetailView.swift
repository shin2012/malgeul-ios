import SwiftUI

/// 회의 상세: 화자별 스크립트 + 구간 재생 + 화자 이름 변경, 오른쪽(아이패드)/시트(아이폰) 채팅, 문서 패널
struct MeetingDetailView: View {
    let meetingID: Int

    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var device: OnDeviceJobCenter
    @Environment(\.horizontalSizeClass) private var hsize
    @AppStorage("mt_chat_open") private var chatOpenPref = true
    @StateObject private var doc = DocModel()

    @State private var detail: MeetingDetail?
    @State private var loadError: String?
    @State private var chatOpen = false
    @State private var showDoc = false
    @State private var rename: Segment?
    @State private var newName = ""
    @State private var search = ""
    @State private var confirmRedo = false

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

    var body: some View {
        Group {
            if let detail {
                script(detail)
            } else if let loadError {
                ContentUnavailableView("회의를 찾을 수 없습니다.", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView("불러오는 중...")
            }
        }
        .inspector(isPresented: $chatOpen) {
            ChatView(meetingID: meetingID)
                .inspectorColumnWidth(min: 280, ideal: 380, max: 700)
                .presentationDetents([.medium, .large])
        }
        // 툴바·제목·검색은 inspector 뒤에 붙여야 본문 쪽 내비게이션 막대에 표시됨
        .searchable(text: $search, placement: .toolbar, prompt: "스크립트 검색")
        .navigationTitle(detail?.meeting.title ?? store.meetings.first { $0.id == meetingID }?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if detail?.meeting.isDone == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if AppConfig.deviceTranscribeAvailable {
                            Button { confirmRedo = true } label: { Label("이 기기에서 다시 받아쓰기", systemImage: "iphone.and.arrow.forward") }
                        }
                        Button {
                            device.requestNotificationPermission()
                            device.enqueueSpeakers(meetingID: meetingID, title: detail?.meeting.title ?? "")
                        } label: { Label("기기 목소리로 화자 다시 추정", systemImage: "person.wave.2") }
                    } label: {
                        Label("기기 처리", systemImage: device.job(for: meetingID) == nil ? "iphone" : "iphone.badge.play")
                    }
                    .disabled(device.job(for: meetingID).map { $0.state != .failed } ?? false)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showDoc = true } label: {
                        Label("문서", systemImage: doc.busy ? "doc.badge.clock" : "doc.text")
                    }
                    .accessibilityHint("회의록·출장복명서 생성, 화자 자동 식별")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    chatOpen.toggle()
                    if hsize == .regular { chatOpenPref = chatOpen }
                } label: {
                    Label(chatOpen ? "채팅 숨기기" : "채팅 열기", systemImage: chatOpen ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                }
            }
        }
        .confirmationDialog("이 기기에서 다시 받아쓸까요?", isPresented: $confirmRedo, titleVisibility: .visible) {
            Button("다시 받아쓰기") {
                device.requestNotificationPermission()
                device.enqueueTranscribe(meetingID: meetingID, title: detail?.meeting.title ?? "", replace: true)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("지금 대본과 고친 화자 이름이 새 결과로 바뀝니다. 이전 대본은 서버에 보관돼요.")
        }
        .safeAreaInset(edge: .top) {
            if let j = device.job(for: meetingID) {
                DeviceJobLine(job: j).padding(.horizontal).padding(.vertical, 6).background(.bar)
            }
        }
        .onChange(of: device.finished) { _, f in
            guard let f, f.meetingID == meetingID else { return }
            Task {
                await load()
                await doc.watchSpeaker(since: f.submittedAt)
            }
        }
        .sheet(isPresented: $showDoc) {
            DocPanelView(meetingID: meetingID, doc: doc)
                .presentationDetents([.medium, .large])
        }
        .alert("화자 이름 변경", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } }), presenting: rename) { seg in
            TextField("이름", text: $newName)
            Button("'\(seg.speaker)' 전체 변경") { doRename(seg, all: true) }
            Button("이 발언만 변경") { doRename(seg, all: false) }
            Button("취소", role: .cancel) {}
        }
        .task(id: meetingID) {
            if hsize == .regular { chatOpen = chatOpenPref }
            if let d = DiskCache.load(key: "meeting_\(meetingID)"), let m = try? JSONDecoder().decode(MeetingDetail.self, from: d) {
                detail = m
            }
            await load()
            if router.debugOpenChat { router.debugOpenChat = false; chatOpen = true }
            if router.debugOpenDoc { router.debugOpenDoc = false; showDoc = true }
            doc.onSpeakerFinished = { Task { await load() } }
            await doc.start(meetingID)
            // 받아쓴 지 얼마 안 됐으면 서버 화자 식별이 끝날 때까지 지켜봄(끝나면 이름 반영)
            if let t = detail?.meeting.transcribedAt, Date().timeIntervalSince(t) < 240 { await doc.watchSpeaker(since: t) }
        }
        .onDisappear { player.stop(); doc.stop() }
    }

    private func script(_ d: MeetingDetail) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                if !speakers.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(speakers, id: \.self) { sp in
                                let c = SpeakerPalette.color(sp, in: speakers)
                                Text(sp)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .foregroundStyle(c)
                                    .background(c.opacity(0.1), in: Capsule())
                                    .overlay(Capsule().stroke(c, lineWidth: 1))
                            }
                        }
                    }
                }
                if segments.isEmpty {
                    Text("전사 내용이 없습니다.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                }
                ForEach(shown) { seg in
                    SegmentRow(meetingID: meetingID, seg: seg, color: SpeakerPalette.color(seg.speaker, in: speakers)) {
                        newName = seg.speaker
                        rename = seg
                    }
                }
            }
            .padding()
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await Task { await load() }.value }
    }

    private func load() async {
        do {
            let d = try await API.shared.meeting(meetingID)
            detail = d
            loadError = nil
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

struct SegmentRow: View {
    let meetingID: Int
    let seg: Segment
    let color: Color
    var onSpeakerTap: () -> Void
    @EnvironmentObject private var player: AudioPlayer

    private var key: String { "seg-\(meetingID)-\(seg.seq)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onSpeakerTap) {
                    Text(seg.speaker)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .foregroundStyle(color)
                        .background(color.opacity(0.1), in: Capsule())
                        .overlay(Capsule().stroke(color, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityHint("화자 이름 변경")

                if let start = seg.startMs, let ts = Fmt.timestamp(start) {
                    Button {
                        Task { await player.toggleSegment(meetingID: meetingID, seq: seg.seq, startMs: start, endMs: seg.endMs) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(ts).monospacedDigit()
                            if player.loadingKey == key {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: player.playingKey == key ? "pause.fill" : "play.fill").font(.system(size: 9))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(player.playingKey == key ? Color.accentMalgeul : Color.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.secondary.opacity(player.playingKey == key ? 0.15 : 0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.playingKey == key ? "정지" : "이 구간 재생")
                }
            }
            Text(seg.text)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
    }
}

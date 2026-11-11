import SwiftUI
import UniformTypeIdentifiers

struct MeetingsSplitView: View {
    @EnvironmentObject private var router: Router
    /// 아이패드에서 목록을 늘 보이게 (세로 화면에서도 사라지지 않음). 사용자가 직접 접으면 그대로 둠
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            MeetingListView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460)
        } detail: {
            NavigationStack {
                if let id = router.meetingID {
                    MeetingDetailView(meetingID: id).id(id)
                } else {
                    ContentUnavailableView("노트를 고르세요", systemImage: "text.bubble",
                                           description: Text("받아쓰기가 끝난 노트를 누르면 대화·회의록·AI 질문이 열립니다."))
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct MeetingListView: View {
    @EnvironmentObject private var config: AppConfig
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var uploads: UploadCenter
    @EnvironmentObject private var device: OnDeviceJobCenter
    @Environment(\.horizontalSizeClass) private var hsize

    @State private var search = ""
    @State private var filter: ListFilter = .all
    @State private var selecting = false
    @State private var multi = Set<Int>()
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var importing = false
    @State private var askTranscribe: Meeting?
    @State private var compressingAlert = false
    @State private var renaming: Meeting?
    @State private var renameText = ""
    @State private var editingDate: Meeting?
    @State private var deleteOne: Meeting?
    @State private var errorText: String?


    private var filtered: [Meeting] {
        var all = store.meetings
        switch filter {
        case .all: break
        case .pending: all = all.filter { !$0.isDone }
        case .tag(let t): all = all.filter { $0.tags.contains(t) }
        case .group(let g, _): all = all.filter { $0.groupId == g }
        }
        return store.sorted(matching(all))
    }

    /// 두 번 이상 쓰인 태그 (많은 순)
    private var topTags: [(String, Int)] {
        var c: [String: Int] = [:]
        for m in store.meetings { for t in m.tags { c[t, default: 0] += 1 } }
        return c.filter { $0.value > 1 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(14).map { ($0.key, $0.value) }
    }

    private func matching(_ all: [Meeting]) -> [Meeting] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return all }
        return all.filter { (m: Meeting) -> Bool in
            if m.title.localizedCaseInsensitiveContains(q) { return true }
            if m.tags.contains(where: { $0.localizedCaseInsensitiveContains(q) }) { return true }
            return (m.originalFilename ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        dialogs2(dialogs1(main))
    }

    @ViewBuilder private var state: some View {
        if !config.isConfigured {
            ContentUnavailableView {
                Label("로그인 필요", systemImage: "person.crop.circle")
            } description: {
                Text("로그인하면 노트 목록이 나타납니다.\n녹음은 로그인 없이도 할 수 있어요.")
            } actions: {
                Button("로그인") { router.showLogin = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if !store.loaded {
            ProgressView("불러오는 중...")
        } else {
            list
        }
    }

    private var main: some View {
        state
            .navigationTitle(filter.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.white, for: .navigationBar)
            .toolbar { toolbar }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie, .mpeg4Movie, .mpeg4Audio],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { urls.forEach { uploads.enqueueImported($0) } }
            }
            .task(id: config.token) {
                if config.isConfigured { await store.refresh(); device.resume() }
            }
    }

    private func dialogs1<V: View>(_ v: V) -> some View {
        v
            .confirmationDialog("아직 받아쓰기가 되지 않았습니다. 방식을 선택해주세요.",
                                isPresented: Binding(get: { askTranscribe != nil }, set: { if !$0 { askTranscribe = nil } }),
                                titleVisibility: .visible, presenting: askTranscribe) { (m: Meeting) in
                // 설정의 기본 방식이 맨 위
                ForEach(engineOrder, id: \.self) { (e: TranscribeEngine) in
                    Button(engineButton(e)) { transcribe(m, engine: e) }
                }
                Button("취소", role: .cancel) {}
            }
            .alert("파일 압축 처리 중입니다. 잠시 후 다시 시도해주세요.", isPresented: $compressingAlert) {
                Button("확인", role: .cancel) {}
            }
            .alert("제목 수정", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                   presenting: renaming) { (m: Meeting) in
                TextField("제목", text: $renameText)
                Button("저장") { saveTitle(m) }
                Button("취소", role: .cancel) {}
            }
            .sheet(item: $editingDate) { (m: Meeting) in RecordedAtSheet(meeting: m) }
    }

    private func dialogs2<V: View>(_ v: V) -> some View {
        v
            .confirmationDialog("이 회의를 삭제할까요?", isPresented: Binding(get: { deleteOne != nil }, set: { if !$0 { deleteOne = nil } }),
                                titleVisibility: .visible, presenting: deleteOne) { (m: Meeting) in
                Button("삭제", role: .destructive) { Task { await delete([m.id]) } }
            } message: { (m: Meeting) in Text(m.title) }
            .confirmationDialog("선택한 \(multi.count)개를 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("\(multi.count)개 삭제", role: .destructive) { Task { await delete(multi) } }
            }
            .alert("오류", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("확인", role: .cancel) {}
            } message: { Text(errorText ?? "") }
    }

    // MARK: 목록

    @ViewBuilder private var list: some View {
        if selecting {
            List(selection: $multi) { content(selectable: true) }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.mgBg)
                .environment(\.editMode, .constant(.active))
        } else {
            List(selection: $router.meetingID) {
                filterChips
                content(selectable: false)
            }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.mgBg)
                .safeAreaInset(edge: .bottom) { fab }
                .refreshable { await Task { await store.refresh() }.value }
                .searchable(text: $search, prompt: "제목·태그 검색")
                .overlay {
                    if store.meetings.isEmpty && uploads.jobs.isEmpty {
                        ContentUnavailableView {
                            Label("업로드된 회의가 없습니다", systemImage: "mic")
                        } description: {
                            Text("녹음하거나 음성 파일을 추가하세요 · MP3, M4A, WAV, MP4 등 지원 · 업로드 시 자동 압축")
                        } actions: {
                            Button("녹음하기") { startRecording() }.buttonStyle(.borderedProminent)
                            Button("파일 추가") { importing = true }
                        }
                    } else if !search.isEmpty && filtered.isEmpty {
                        ContentUnavailableView.search(text: search)
                    }
                }
        }
    }

    @ViewBuilder private func content(selectable: Bool) -> some View {
        if let err = store.lastError {
            Section {
                Label(err, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.secondary)
            }
        }
        if !uploads.jobs.isEmpty && !selectable {
            Section("업로드") {
                ForEach(uploads.jobs) { UploadJobRow(job: $0) }
            }
        }
        let groups = monthGroups(filtered)
        ForEach(Array(groups.enumerated()), id: \.offset) { (gi: Int, g: (String, [Meeting])) in
            Section {
                ForEach(g.1) { m in
                    row(m, selectable: selectable)
                }
            } header: {
                if !g.0.isEmpty {
                    Text(g.0).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mgFg3).textCase(nil)
                        .padding(.top, 8)
                }
            } footer: {
                if gi == groups.count - 1 && !filtered.isEmpty {
                    Text("노트 \(filtered.count)개 · 총 \(Fmt.totalDuration(filtered.reduce(0) { $0 + ($1.durationSeconds ?? 0) }))")
                        .font(.system(size: 13)).monospacedDigit().foregroundStyle(Color.mgFg4)
                        .frame(maxWidth: .infinity).padding(.top, 20).padding(.bottom, 12)
                }
            }
            // 묶음 아래 구분선은 그리지 않음 (맨 아래 요약 밑에 짧은 선이 생기던 문제)
            .listSectionSeparator(.hidden)
        }
    }

    // MARK: 웹과 같은 부분들

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("전체", n: store.meetings.count, on: filter == .all) { filter = .all }
                let busy = store.meetings.filter { !$0.isDone }.count
                if busy > 0 { chip("처리 전·중", n: busy, on: filter == .pending) { filter = .pending } }
                // 그룹이 둘 이상일 때만 그룹 칩
                if store.groups.count > 1 {
                    ForEach(store.groups) { (g: MeetingGroup) in
                        let on = filter == .group(g.id, g.name)
                        chip(g.name, n: store.meetings.filter { $0.groupId == g.id }.count, on: on) { filter = on ? .all : .group(g.id, g.name) }
                    }
                }
                ForEach(topTags, id: \.0) { (t: (String, Int)) in
                    chip("#\(t.0)", n: t.1, on: filter == .tag(t.0)) { filter = filter == .tag(t.0) ? .all : .tag(t.0) }
                }
            }
            .padding(.horizontal, 16)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .selectionDisabled()
    }

    private func chip(_ label: String, n: Int, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label).lineLimit(1)
                Text("\(n)").monospacedDigit().foregroundStyle(on ? Color.accentMalgeul.opacity(0.7) : Color.mgFg4)
            }
            .font(.system(size: 14, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Color.accentMalgeul : Color.mgFg2)
            .padding(.horizontal, 12).frame(height: 32)
            .background(on ? Color.mgAccentWeak : Color.mgBg2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 오른쪽 아래 녹음 · 올리기 (웹 모바일과 같음)
    @ViewBuilder private var fab: some View {
        if config.isConfigured && !selecting {
            HStack(spacing: 10) {
                Spacer()
                RecordFabButton { startRecording() }
                Button { importing = true } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .medium)).foregroundStyle(Color.mgFg2)
                        .frame(width: 52, height: 52)
                        .background(Color.white, in: Circle())
                        .overlay(Circle().stroke(Color.mgLine, lineWidth: 1))
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                }
                .accessibilityLabel("파일 올리기")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    /// 날짜순 정렬일 때 월별로 묶음 (다른 정렬은 한 묶음)
    private func monthGroups(_ list: [Meeting]) -> [(String, [Meeting])] {
        guard store.sortKey == .createdAt || store.sortKey == .recordedAt else { return [("", list)] }
        var out: [(String, [Meeting])] = []
        for m in list {
            let d = (store.sortKey == .createdAt ? m.createdAt : m.recordedOrCreated) ?? .distantPast
            let label = Fmt.groupLabel(d)
            if out.last?.0 == label { out[out.count - 1].1.append(m) } else { out.append((label, [m])) }
        }
        return out
    }

    @ViewBuilder private func row(_ m: Meeting, selectable: Bool) -> some View {
        let base = MeetingRow(meeting: m)
        Group {
            if selectable || m.isDone {
                // 완료된 회의 → 선택하면 상세(스크립트)로 이동
                base.tag(m.id)
            } else {
                Button { tapUnfinished(m) } label: { base }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
            }
        }
        .listRowBackground(router.meetingID == m.id && !selectable ? Color.mgAccentWeak : Color.white)
        .listRowSeparatorTint(Color.mgLine)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleteOne = m } label: { Label("삭제", systemImage: "trash") }
            Button { beginRename(m) } label: { Label("제목", systemImage: "pencil") }.tint(.gray)
        }
        .swipeActions(edge: .leading) {
            Button { editingDate = m } label: { Label("녹음 시각", systemImage: "calendar") }.tint(.accentMalgeul)
        }
        .contextMenu {
            Button { beginRename(m) } label: { Label("제목 수정", systemImage: "pencil") }
            Button { editingDate = m } label: { Label("녹음 시각 수정", systemImage: "calendar") }
            if !m.isDone && !m.isProcessing {
                Button { tapUnfinished(m) } label: { Label("받아쓰기", systemImage: "waveform") }
            }
            if store.groups.count > 1 {
                Menu {
                    ForEach(store.groups) { (g: MeetingGroup) in
                        Button { moveGroup(m, g) } label: {
                            if m.groupId == g.id { Label(g.name, systemImage: "checkmark") } else { Text(g.name) }
                        }
                    }
                } label: { Label("그룹 옮기기", systemImage: "folder") }
            }
            Divider()
            Button(role: .destructive) { deleteOne = m } label: { Label("삭제", systemImage: "trash") }
        }
    }

    private func moveGroup(_ m: Meeting, _ g: MeetingGroup) {
        guard m.groupId != g.id else { return }
        Task {
            do {
                try await API.shared.moveMeeting(m.id, toGroup: g.id)
                var x = m; x.groupId = g.id; store.update(x)
                await store.loadGroups()
            } catch { errorText = error.localizedDescription }
        }
    }

    // MARK: 툴바

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { router.tab = .settings } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("설정")
        }
        if config.isConfigured {
            if !selecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("정렬 기준", selection: $store.sortKey) {
                            ForEach(SortKey.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("순서", selection: $store.ascending) {
                            Label("최근 것부터", systemImage: "arrow.down").tag(false)
                            Label("오래된 것부터", systemImage: "arrow.up").tag(true)
                        }
                        Divider()
                        Button { startRecording() } label: { Label("녹음하기", systemImage: "mic") }
                        Button { importing = true } label: { Label("파일 올리기", systemImage: "square.and.arrow.up") }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("정렬")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(selecting ? "완료" : "선택") {
                    withAnimation { selecting.toggle(); multi.removeAll() }
                }
                .disabled(store.meetings.isEmpty)
            }
            if selecting {
                ToolbarItem(placement: .bottomBar) {
                    Button(multi.count == filtered.count ? "선택 해제" : "전체 선택") {
                        multi = multi.count == filtered.count ? [] : Set(filtered.map(\.id))
                    }
                }
                ToolbarItem(placement: .status) {
                    Text("\(multi.count)개 선택").font(.system(size: 14)).foregroundStyle(Color.mgFg2)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text(deleting ? "삭제 중…" : "삭제").foregroundStyle(Color.mgDanger)
                    }
                    .disabled(multi.isEmpty || deleting)
                }
            }
        }
    }

    // MARK: 동작

    private func startRecording() {
        router.tab = .record
        router.startRecordingRequest = true
    }

    private var engineOrder: [TranscribeEngine] {
        var all: [TranscribeEngine] = AppConfig.deviceTranscribeAvailable ? [.device, .assemblyai, .local] : [.assemblyai, .local]
        if let i = all.firstIndex(of: config.engine) { all.insert(all.remove(at: i), at: 0) }
        return all
    }

    private func engineButton(_ e: TranscribeEngine) -> String {
        switch e {
        case .assemblyai: return "클라우드 (AssemblyAI)"
        case .local: return "이 서버 (로컬)"
        case .device: return "이 기기에서"
        }
    }

    private func tapUnfinished(_ m: Meeting) {
        if device.job(for: m.id).map({ $0.state != .failed }) == true { return }
        if m.isProcessing { return }
        if m.isCompressing { compressingAlert = true; return }
        askTranscribe = m
    }

    private func transcribe(_ m: Meeting, engine: TranscribeEngine) {
        if engine == .device {
            device.requestNotificationPermission()
            device.enqueueTranscribe(meetingID: m.id, title: m.title)
            return
        }
        Task {
            do {
                try await API.shared.startTranscribe(m.id, local: engine == .local)
                store.patch(m.id) { $0.status = "processing"; $0.errorMessage = nil }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func beginRename(_ m: Meeting) { renameText = m.title; renaming = m }

    private func saveTitle(_ m: Meeting) {
        let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != m.title else { return }
        store.patch(m.id) { $0.title = t }
        Task {
            do { try await API.shared.setTitle(m.id, t) } catch { errorText = error.localizedDescription }
            await store.refresh()
        }
    }

    private func delete(_ ids: Set<Int>) async {
        deleting = true
        defer { deleting = false }
        await withTaskGroup(of: Void.self) { g in
            for id in ids { g.addTask { try? await API.shared.deleteMeeting(id) } }
        }
        if let cur = router.meetingID, ids.contains(cur) { router.meetingID = nil }
        store.remove(ids)
        multi.removeAll()
        selecting = false
        await store.refresh()
    }
}

// MARK: - 행

struct MeetingRow: View {
    let meeting: Meeting
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var device: OnDeviceJobCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(meeting.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(meeting.isDone ? Color.mgFg : Color.mgFg2)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if meeting.status == "error" {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color.mgDanger).font(.system(size: 14))
                }
            }
            if let job = device.job(for: meeting.id) {
                DeviceJobLine(job: job)
            } else if meeting.isProcessing {
                TranscribeProgressLine(meetingID: meeting.id)
            } else if meeting.status == "error" {
                Text("받아쓰기 실패\(meeting.errorMessage.map { " · \($0)" } ?? "")")
                    .font(.system(size: 13.5)).foregroundStyle(Color.mgDanger).lineLimit(1)
            } else {
                meta
            }
            if !meeting.tags.isEmpty {
                TagRow(tags: meeting.tags)
            }
        }
        .padding(.vertical, 12)
    }

    private var meta: some View {
        HStack(spacing: 10) {
            Text(Fmt.when(meeting.recordedOrCreated))
            if (meeting.durationSeconds ?? 0) > 0 { Text(Fmt.duration(meeting.durationSeconds)) }
            if meeting.isCompressing {
                HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("파일 준비 중") }
            } else if meeting.status == "pending" {
                Text("받아쓰기 전").fontWeight(.medium).foregroundStyle(Color.accentMalgeul)
            } else if meeting.isDone && meeting.aiAnalyzed == 0 {
                Text("정리 중…")
            }
        }
        .lineLimit(1)
        .monospacedDigit()
        .font(.system(size: 13.5))
        .foregroundStyle(Color.mgFg3)
    }
}

/// 아이콘과 글자를 붙여서 한 줄로
struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title.fixedSize()
        }
    }
}

struct StatusBadge: View {
    let status: String
    var body: some View {
        // 완료·대기는 표시하지 않음 (처리 중·오류만)
        if status == "processing" || status == "error" { badge }
    }
    private var badge: some View {
        Text(StatusInfo.label(status))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(StatusInfo.color(status))
            .background(StatusInfo.color(status).opacity(0.12), in: Capsule())
    }
}

struct TagRow: View {
    let tags: [String]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(tags.prefix(3).enumerated()), id: \.offset) { (_: Int, t: String) in
                Text("#\(t)")
            }
            if tags.count > 3 { Text("+\(tags.count - 3)").foregroundStyle(Color.mgFg4) }
        }
        .font(.system(size: 13.5))
        .foregroundStyle(Color.mgFg2)
        .lineLimit(1)
            }
}

/// 받아쓰기 진행(SSE) + 취소
struct TranscribeProgressLine: View {
    let meetingID: Int
    @EnvironmentObject private var store: MeetingStore
    @State private var message = "전사 중..."
    @State private var confirmCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView().progressViewStyle(.linear)
            HStack {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("취소", role: .destructive) { confirmCancel = true }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
        .task(id: meetingID) { await follow() }
        .confirmationDialog("전사를 취소할까요?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("전사 취소", role: .destructive) {
                Task {
                    try? await API.shared.cancelTranscribe(meetingID)
                    await store.refresh()
                }
            }
        }
    }

    private func follow() async {
        while !Task.isCancelled {
            do {
                for try await ev in API.shared.transcribeProgress(meetingID) {
                    let type = ev["type"] as? String
                    if type == "progress", let m = ev["message"] as? String { message = m }
                    if type == "done" || type == "error" { await store.refresh(); return }
                }
                await store.refresh()
                return
            } catch {
                if error.isCancellation { return }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

/// 기기 받아쓰기·화자 추정 진행 + 취소/다시 시도
struct DeviceJobLine: View {
    let job: DeviceJob
    @EnvironmentObject private var device: OnDeviceJobCenter
    @State private var confirmCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if job.state == .failed {
                Text("기기 처리 실패: \(job.message ?? "")").font(.caption).foregroundStyle(.red)
                HStack {
                    Button("다시 시도") { device.retry(job.id) }.buttonStyle(.bordered).controlSize(.small)
                    Button("지우기", role: .destructive) { device.cancel(job.id) }.buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                ProgressView(value: job.state == .queued ? 0 : job.progress).progressViewStyle(.linear)
                HStack {
                    Image(systemName: "iphone").font(.caption2).foregroundStyle(.secondary)
                    Text(job.state == .queued ? "기기 처리 대기 중" : "\(job.message ?? "처리 중") \(Int(job.progress * 100))%")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("취소", role: .destructive) { confirmCancel = true }
                        .font(.caption).buttonStyle(.borderless)
                }
            }
        }
        .confirmationDialog("기기 처리를 취소할까요?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("처리 취소", role: .destructive) { device.cancel(job.id) }
        }
    }
}

struct UploadJobRow: View {
    let job: UploadJob
    @EnvironmentObject private var uploads: UploadCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: job.state == .failed ? "exclamationmark.triangle.fill" : "arrow.up.circle")
                    .foregroundStyle(job.state == .failed ? Color.red : Color.accentMalgeul)
                Text(job.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if job.state == .uploading {
                    Text("\(Int(job.progress * 100))%").font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(.accentMalgeul)
                }
            }
            switch job.state {
            case .analyzing:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(job.message ?? "파일 분석 중").font(.caption).foregroundStyle(.secondary) }
            case .uploading:
                ProgressView(value: job.progress)
                Text("대용량 파일은 시간이 걸릴 수 있습니다 · \(Fmt.size(Int(job.size)))").font(.caption2).foregroundStyle(.secondary)
            case .finishing:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("서버에 저장하는 중...").font(.caption).foregroundStyle(.secondary) }
            case .failed:
                Text(job.message ?? "업로드 실패").font(.caption).foregroundStyle(.red)
                HStack {
                    Button("다시 시도") { uploads.retry(job.id) }.buttonStyle(.bordered).controlSize(.small)
                    Button("지우기", role: .destructive) { uploads.cancel(job.id) }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .swipeActions {
            Button(role: .destructive) { uploads.cancel(job.id) } label: { Label("취소", systemImage: "xmark") }
        }
    }
}

struct StatsFooter: View {
    @EnvironmentObject private var store: MeetingStore
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text("노트 \(store.meetings.count)개")
                if store.totalDuration > 0 { Text("총 \(Fmt.totalDuration(store.totalDuration))") }
            }
        }
        .monospacedDigit()
        .padding(.top, 4)
    }
}

/// 녹음 시각 수정
struct RecordedAtSheet: View {
    let meeting: Meeting
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("녹음 시각", selection: $date)
                        .datePickerStyle(.graphical)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("녹음 시각 수정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "저장 중…" : "저장") { save() }.disabled(saving)
                }
            }
            .onAppear { date = meeting.recordedOrCreated ?? .now }
        }
        .presentationDetents([.large])
    }

    private func save() {
        saving = true
        Task {
            do {
                let r = try await API.shared.setRecordedAt(meeting.id, date)
                store.patch(meeting.id) { $0.recordedAt = r ?? date }
                dismiss()
            } catch {
                self.error = "녹음 시각 변경 실패: \(error.localizedDescription)"
            }
            saving = false
        }
    }
}

enum ListFilter: Equatable {
    case all, pending, tag(String), group(Int, String)
    var title: String {
        switch self {
        case .all: return "전체 노트"
        case .pending: return "처리 전·중"
        case .tag(let t): return "#\(t)"
        case .group(_, let n): return n
        }
    }
}


/// 목록 오른쪽 아래 녹음 버튼. 녹음 중이면 같은 자리에 진행 상태를 보여 줌
/// (녹음기 시간 갱신이 목록 전체를 다시 그리지 않도록 따로 둠)
private struct RecordFabButton: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var router: Router
    let onStart: () -> Void

    var body: some View {
        if recorder.isActive {
            // 녹음 중이면 같은 자리에 진행 상태 (누르면 녹음 화면)
            Button { router.tab = .record } label: {
                HStack(spacing: 8) {
                    Circle().fill(Color.white).frame(width: 8, height: 8)
                        .opacity(recorder.state == .recording ? 1 : 0.5)
                    Text(recorder.state == .recording ? "녹음 중" : "일시정지")
                    Text(Fmt.clock(recorder.elapsed)).monospacedDigit()
                }
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 20).frame(height: 52)
                .background(recorder.state == .recording ? Color.mgDanger : Color.orange, in: Capsule())
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            }
            .accessibilityLabel("녹음 화면 열기")
        } else {
            Button { onStart() } label: {
                Label("녹음", systemImage: "mic.fill")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .padding(.leading, 18).padding(.trailing, 22).frame(height: 52)
                    .background(Color.accentMalgeul, in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            }
        }
    }
}

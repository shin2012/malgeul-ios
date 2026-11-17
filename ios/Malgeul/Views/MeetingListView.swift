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
    @EnvironmentObject private var recordings: RecordingStore
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var uploads: UploadCenter
    @EnvironmentObject private var device: OnDeviceJobCenter
    @Environment(\.horizontalSizeClass) private var hsize
    @Environment(\.scenePhase) private var scenePhase

    @State private var search = ""
    @State private var filter: ListFilter = .all
    @State private var selecting = false
    @State private var multi = Set<Int>()
    @State private var deletion = TwoTapDeletion()
    @State private var deleting = false
    @State private var pendingExpanded = true
    @State private var importing = false
    @State private var askTranscribe: Meeting?
    @State private var compressingAlert = false
    @State private var renaming: Meeting?
    @State private var renameText = ""
    @State private var editingDate: Meeting?
    @State private var errorText: String?


    private var filtered: [Meeting] {
        var all = store.meetings
        switch filter {
        case .all: break
        case .pending: all = all.filter { !$0.isSettled || device.job(for: $0.id) != nil }
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
        if !config.isConfigured && localRecordings.isEmpty {
            ContentUnavailableView {
                Label("로그인 필요", systemImage: "person.crop.circle")
            } description: {
                Text("로그인하면 노트 목록이 나타납니다.\n녹음은 로그인 없이도 할 수 있어요.")
            } actions: {
                Button("로그인") { router.showLogin = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if !store.loaded && localRecordings.isEmpty {
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
            .onChange(of: multi) { _, _ in deletion.reset() }
            .onChange(of: filter) { _, _ in deletion.reset() }
            .onChange(of: selecting) { _, _ in deletion.reset() }
            .onDisappear { deletion.reset() }
            .onChange(of: scenePhase) { _, phase in
                store.setForeground(phase == .active)
                if phase == .active && config.isConfigured { Task { await store.refresh() } }
            }
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
                    if store.meetings.isEmpty && uploads.jobs.isEmpty && localRecordings.isEmpty {
                        ContentUnavailableView {
                            Label("업로드된 회의가 없습니다", systemImage: "mic")
                        } description: {
                            Text("녹음하거나 음성 파일을 추가하세요 · MP3, M4A, WAV, MP4 등 지원 · 업로드 시 자동 압축")
                        } actions: {
                            Button("녹음하기") { startRecording() }.buttonStyle(.borderedProminent)
                            Button("파일 추가") { importing = true }
                        }
                    } else if !search.isEmpty && filtered.isEmpty && localRecordings.isEmpty {
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
        let shown = displayedEntries.filter { !selectable || meetingFor($0) != nil }
        let pending = shown.filter { isPending($0) }
        if !pending.isEmpty {
            Section {
                if pendingExpanded || selecting {
                    ForEach(pending) { entry in projectedRow(entry, selectable: selectable) }
                }
            } header: {
                Button { withAnimation { pendingExpanded.toggle() } } label: {
                    HStack {
                        Text("녹음·처리 중 \(pending.count)")
                        Spacer()
                        Image(systemName: pendingExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mgFg3).textCase(nil).padding(.top, 8)
                }
                .buttonStyle(.plain)
            }
            .listSectionSeparator(.hidden)
        }
        let displayedCount = shown.count
        let displayedDuration = shown.reduce(0) { $0 + durationFor($1) }
        let ready = shown.filter { !isPending($0) }.compactMap { meetingFor($0) }
        let groups = monthGroups(ready)
        ForEach(Array(groups.enumerated()), id: \.offset) { (gi: Int, g: (String, [Meeting])) in
            Section {
                ForEach(g.1) { m in
                    row(m, selectable: selectable).id(store.displayAliases[m.id] ?? "meeting-\(m.id)")
                }
            } header: {
                if gi == 0 || !g.0.isEmpty {
                    Text(gi == 0 ? (g.0.isEmpty ? "정리된 노트" : "정리된 노트 · " + g.0) : g.0).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mgFg3).textCase(nil)
                        .padding(.top, 8)
                }
            } footer: {
                if gi == groups.count - 1 && !filtered.isEmpty {
                    Text("노트 \(displayedCount)개 · 총 \(Fmt.totalDuration(displayedDuration))")
                        .font(.system(size: 13)).monospacedDigit().foregroundStyle(Color.mgFg4)
                        .frame(maxWidth: .infinity).padding(.top, 20).padding(.bottom, 12)
                }
            }
            // 묶음 아래 구분선은 그리지 않음 (맨 아래 요약 밑에 짧은 선이 생기던 문제)
            .listSectionSeparator(.hidden)
        }
        if ready.isEmpty && !shown.isEmpty {
            Text("녹음과 노트 \(displayedCount)개 · 총 \(Fmt.totalDuration(displayedDuration))")
                .font(.system(size: 13)).foregroundStyle(Color.mgFg3)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
    }

    // MARK: 웹과 같은 부분들

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                let busy = allEntries.filter { isPending($0) }.count
                chip("전체", n: allEntries.count, on: filter == .all) { filter = .all }
                if busy > 0 { chip("녹음·처리 중", n: busy, on: filter == .pending) { filter = .pending } }
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
        if !selecting {
            HStack(spacing: 10) {
                Spacer()
                RecordFabButton(onStart: { startRecording() }, onUpload: { importing = true })
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
        SwipeDeleteRow(target: "meeting-\(m.id)", confirmation: $deletion, disabled: deleting || selectable,
                       background: router.meetingID == m.id && !selectable ? Color.mgAccentWeak : (m.isSettled ? Color.white : Color.mgBg2),
                       onDelete: { Task { await delete([m.id]) } }) {
            HStack(alignment: .top, spacing: 0) {
                if selectable || m.isDone {
                    MeetingRow(meeting: m)
                } else {
                    Button { tapUnfinished(m) } label: { MeetingRow(meeting: m) }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                }
                if !selectable { NoteRowMenu(onClose: { deletion.reset() }) { meetingActions(m) }.padding(.top, 2) }
            }
        }
        .tag(m.id)
        .listRowBackground(router.meetingID == m.id && !selectable ? Color.mgAccentWeak : (m.isSettled ? Color.white : Color.mgBg2))
        .listRowSeparatorTint(Color.mgLine)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }

    @ViewBuilder private func meetingActions(_ m: Meeting) -> some View {
            NoteActionButton { beginRename(m) } label: { Label("제목 수정", systemImage: "pencil") }
            NoteActionButton { editingDate = m } label: { Label("녹음 시각 수정", systemImage: "calendar") }
            if !m.isDone && !m.isProcessing {
                NoteActionButton { tapUnfinished(m) } label: { Label("받아쓰기", systemImage: "waveform") }
            }
            if store.groups.count > 1 {
                Menu {
                    ForEach(store.groups) { (g: MeetingGroup) in
                        NoteActionButton { moveGroup(m, g) } label: {
                            if m.groupId == g.id { Label(g.name, systemImage: "checkmark") } else { Text(g.name) }
                        }
                    }
                    .labelStyle(.titleAndIcon)
                } label: {
                    Label("그룹 옮기기", systemImage: "folder")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            TwoTapDeleteButton(target: "meeting-\(m.id)", confirmation: $deletion) {
                Task { await delete([m.id]) }
            }.disabled(deleting)
            Text("서버의 노트와 음성을 삭제합니다.")
                .font(.system(size: 12)).foregroundStyle(Color.mgFg3)
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
                    TwoTapDeleteButton(target: "multi-" + multi.sorted().map(String.init).joined(separator: ","), confirmation: $deletion,
                                       title: deleting ? "삭제 중…" : "삭제") {
                        let ids = multi
                        Task { await delete(ids) }
                    }
                    .disabled(multi.isEmpty || deleting)
                }
            }
        }
    }

    private var allEntries: [NoteListProjection.Row] {
        let serverIDs = Set(store.meetings.map(\.id))
        return NoteListProjection.rows(
            locals: recordings.items.filter { r in
                r.meetingID == nil || !store.loaded || store.lastError != nil || r.meetingID.map { serverIDs.contains($0) } == true
            }.map { .init(id: $0.id, meetingID: $0.meetingID) },
            uploads: uploads.jobs.map { .init(id: $0.id.uuidString, recordingID: $0.recordingID, meetingID: $0.meetingID) },
            meetingIDs: store.sorted(store.meetings).map(\.id), aliases: store.displayAliases)
    }

    private func meetingFor(_ entry: NoteListProjection.Row) -> Meeting? {
        entry.meetingID.flatMap { id in store.meetings.first { $0.id == id } }
    }
    private func recordingFor(_ entry: NoteListProjection.Row) -> Recording? {
        entry.recordingID.flatMap { id in recordings.items.first { $0.id == id } }
    }
    private func uploadFor(_ entry: NoteListProjection.Row) -> UploadJob? {
        entry.uploadID.flatMap { id in uploads.jobs.first { $0.id.uuidString == id } }
    }
    private func isPending(_ entry: NoteListProjection.Row) -> Bool {
        guard let m = meetingFor(entry) else { return true }
        return !m.isSettled || device.job(for: m.id) != nil
    }
    private func durationFor(_ entry: NoteListProjection.Row) -> Int {
        meetingFor(entry)?.durationSeconds ?? recordingFor(entry).map { Int($0.duration) } ?? 0
    }
    private func titleFor(_ entry: NoteListProjection.Row) -> String {
        meetingFor(entry)?.title ?? recordingFor(entry)?.title ?? uploadFor(entry)?.title ?? "제목 없음"
    }
    private var displayedEntries: [NoteListProjection.Row] {
        let allowed = Set(filtered.map(\.id))
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let sortKey = store.sortKey
        let ascending = store.ascending
        return allEntries.filter { entry in
            if let m = meetingFor(entry) { return allowed.contains(m.id) }
            guard filter == .all || filter == .pending else { return false }
            return q.isEmpty || titleFor(entry).localizedCaseInsensitiveContains(q)
        }.sorted { a, b in
            if sortKey == .title {
                let result = titleFor(a).localizedStandardCompare(titleFor(b))
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
            func value(_ e: NoteListProjection.Row) -> Double {
                let m = meetingFor(e), r = recordingFor(e), u = uploadFor(e)
                switch sortKey {
                case .duration: return Double(durationFor(e))
                case .size: return Double(m?.fileSizeBytes ?? r?.fileSize ?? Int(u?.size ?? 0))
                case .cost: return m?.costUsd ?? -1
                default:
                    let d = sortKey == .createdAt ? m?.createdAt : m?.recordedOrCreated
                    return (d ?? r?.startedAt ?? u?.recordedAt ?? .distantPast).timeIntervalSince1970
                }
            }
            if sortKey == .status {
                let x = meetingFor(a)?.status ?? "pending", y = meetingFor(b)?.status ?? "pending"
                if x != y { return ascending ? x < y : x > y }
            }
            let x = value(a), y = value(b)
            return x == y ? a.id < b.id : (ascending ? x < y : x > y)
        }
    }
    private var localRecordings: [Recording] {
        displayedEntries.filter { meetingFor($0) == nil }.compactMap { recordingFor($0) }
    }

    @ViewBuilder private func projectedRow(_ entry: NoteListProjection.Row, selectable: Bool) -> some View {
        if let m = meetingFor(entry) {
            row(m, selectable: selectable)
        } else if let r = recordingFor(entry), !selectable {
            PendingRecordingListRow(recording: r, deletion: $deletion).selectionDisabled()
        } else if let job = uploadFor(entry), !selectable {
            UploadJobRow(job: job).selectionDisabled().listRowBackground(Color.mgBg2)
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
        var succeeded = Set<Int>()
        for id in ids {
            do { try await API.shared.deleteMeeting(id); succeeded.insert(id) }
            catch { errorText = "삭제하지 못했습니다: \(error.localizedDescription)" }
        }
        if let cur = router.meetingID, succeeded.contains(cur) { router.meetingID = nil }
        store.remove(succeeded)
        multi.subtract(succeeded)
        if multi.isEmpty { selecting = false }
        await store.refresh()
    }
}

// MARK: - 행

struct MeetingRow: View {
    let meeting: Meeting
    @EnvironmentObject private var device: OnDeviceJobCenter

    var body: some View {
        NoteRowContent(title: meeting.title, compact: !meeting.isSettled) {
            if let job = device.job(for: meeting.id) {
                NoteRowMetadata(date: meeting.recordedOrCreated, duration: meeting.durationSeconds)
                DeviceJobLine(job: job)
            } else if meeting.isProcessing {
                NoteRowMetadata(date: meeting.recordedOrCreated, duration: meeting.durationSeconds)
                TranscribeProgressLine(meetingID: meeting.id)
            } else if meeting.status == "error" {
                NoteRowMetadata(date: meeting.recordedOrCreated, duration: meeting.durationSeconds)
                Text("받아쓰기 실패\(meeting.errorMessage.map { " · \($0)" } ?? "")")
                    .font(.system(size: 13.5)).foregroundStyle(Color.mgDanger).lineLimit(2)
            } else {
                NoteRowMetadata(date: meeting.recordedOrCreated, duration: meeting.durationSeconds, status: statusText)
            }
            if meeting.isSettled && !meeting.tags.isEmpty { TagRow(tags: meeting.tags) }
        }
    }

    private var statusText: String? {
        if meeting.isCompressing { return "파일 준비 중" }
        if meeting.status == "pending" { return "받아쓰기 전" }
        if let label = meeting.postProcessingLabel { return label + (meeting.needsPostProcessing ? " · 대본 보기" : "") }
        return nil
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
        NoteRowContent(title: job.title, compact: true) {
            NoteRowMetadata(date: job.recordedAt, duration: nil)
            switch job.state {
            case .analyzing:
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(job.message ?? "파일 준비 중") }
                    .font(.system(size: 13)).foregroundStyle(Color.mgFg3)
            case .uploading:
                HStack {
                    Text("업로드 중")
                    Spacer()
                    Text("\(Int(job.progress * 100))%").monospacedDigit()
                }.font(.system(size: 13)).foregroundStyle(Color.mgFg3)
                ProgressView(value: job.progress)
            case .finishing:
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("서버에 저장 중") }
                    .font(.system(size: 13)).foregroundStyle(Color.mgFg3)
            case .failed:
                Text(job.message ?? "업로드 실패").font(.system(size: 13)).foregroundStyle(Color.mgDanger)
                HStack {
                    Button("다시 시도") { uploads.retry(job.id) }.buttonStyle(.borderless)
                    Button("업로드 취소") { uploads.cancel(job.id) }.buttonStyle(.borderless)
                }.font(.system(size: 13))
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
        case .pending: return "녹음·처리 중"
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
    let onUpload: () -> Void

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
            .contextMenu { Button(action: onUpload) { Label("파일 업로드", systemImage: "square.and.arrow.up") } }
        } else {
            Menu {
                Button(action: onStart) { Label("녹음", systemImage: "mic") }
                Button(action: onUpload) { Label("파일 업로드", systemImage: "square.and.arrow.up") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentMalgeul, in: Circle())
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            }
            .accessibilityLabel("새로 추가")
            .accessibilityIdentifier("new-note-button")
        }
    }
}

import Foundation
import SwiftUI

enum SortKey: String, CaseIterable, Identifiable {
    case createdAt, recordedAt, title, status, duration, size, cost
    var id: String { rawValue }
    var label: String {
        switch self {
        case .createdAt: return "등록일"
        case .recordedAt: return "녹음 시각"
        case .title: return "제목"
        case .status: return "상태"
        case .duration: return "길이"
        case .size: return "크기"
        case .cost: return "비용"
        }
    }
}

/// 회의 목록 상태. 저장된 응답으로 먼저 그리고, 서버에서 새로 받아 교체.
@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var loaded = false
    @Published var lastError: String?
    @Published var krwRate: Double?
    @Published private(set) var groups: [MeetingGroup] = []
    @Published var sortKey: SortKey = SortKey(rawValue: UserDefaults.standard.string(forKey: "sortKey") ?? "") ?? .createdAt {
        didSet { UserDefaults.standard.set(sortKey.rawValue, forKey: "sortKey") }
    }
    @Published var ascending: Bool = UserDefaults.standard.bool(forKey: "sortAsc") {
        didSet { UserDefaults.standard.set(ascending, forKey: "sortAsc") }
    }

    private var pollTask: Task<Void, Never>?

    private init() {
        if let d = DiskCache.load(key: "meetings"), let list = try? JSONDecoder().decode([Meeting].self, from: d) {
            meetings = list
            loaded = true
        }
        if let d = DiskCache.load(key: "groups"), let g = try? JSONDecoder().decode([MeetingGroup].self, from: d) { groups = g }
    }

    func loadGroups() async {
        if let g = try? await API.shared.groups() { groups = g }
    }

    /// 로그아웃 시 화면·캐시 비움
    func clear() {
        meetings = []; groups = []; loaded = false
        DiskCache.remove(key: "meetings"); DiskCache.remove(key: "groups")
    }

    func refresh() async {
        do {
            let d = try await API.shared.meetingsRaw()
            let list = try JSONDecoder().decode([Meeting].self, from: d)
            DiskCache.save(d, key: "meetings")
            meetings = list
            lastError = nil
        } catch {
            if !error.isCancellation { lastError = error.localizedDescription }
        }
        loaded = true
        schedulePolling()
        await loadGroups()
        if krwRate == nil { krwRate = await API.shared.exchangeRate() }
    }

    func update(_ m: Meeting) {
        if let i = meetings.firstIndex(where: { $0.id == m.id }) { meetings[i] = m } else { meetings.insert(m, at: 0) }
    }

    func patch(_ id: Int, _ change: (inout Meeting) -> Void) {
        if let i = meetings.firstIndex(where: { $0.id == id }) { change(&meetings[i]) }
    }

    func remove(_ ids: Set<Int>) { meetings.removeAll { ids.contains($0.id) } }

    /// 압축 중(audio_ready=0) 또는 AI 분석 대기(done, ai_analyzed=0) 항목이 있으면 3초마다 다시 받음
    private func schedulePolling() {
        let needs = meetings.contains { $0.audioReady == 0 || ($0.isDone && $0.aiAnalyzed == 0) }
        guard needs else { pollTask?.cancel(); pollTask = nil; return }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.pollTask = nil
            await self.refresh()
        }
    }

    func sorted(_ list: [Meeting]) -> [Meeting] {
        func key(_ m: Meeting) -> Double? {
            switch sortKey {
            case .createdAt: return m.createdAt?.timeIntervalSince1970
            case .recordedAt: return m.recordedAt?.timeIntervalSince1970
            case .duration: return m.durationSeconds.map(Double.init)
            case .size: return m.fileSizeBytes.map(Double.init)
            case .cost: return m.costUsd
            default: return nil
            }
        }
        return list.sorted { a, b in
            switch sortKey {
            case .title:
                let r = a.title.localizedStandardCompare(b.title)
                return ascending ? r == .orderedAscending : r == .orderedDescending
            case .status:
                return ascending ? a.status < b.status : a.status > b.status
            default:
                // 값이 없는 항목은 항상 뒤로
                guard let x = key(a) else { return false }
                guard let y = key(b) else { return true }
                return ascending ? x < y : x > y
            }
        }
    }

    var doneCount: Int { meetings.filter(\.isDone).count }
    var totalCost: Double { meetings.reduce(0) { $0 + ($1.costUsd ?? 0) } }
    var totalDuration: Int { meetings.reduce(0) { $0 + ($1.durationSeconds ?? 0) } }
}

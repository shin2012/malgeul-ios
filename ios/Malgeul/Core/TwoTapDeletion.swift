import Foundation

/// 같은 대상의 삭제를 4초 안에 두 번 눌렀을 때만 허용한다.
struct TwoTapDeletion {
    private(set) var target: String?
    private var armedAt: Date = .distantPast
    func isArmed(_ id: String, at now: Date = .now) -> Bool {
        target == id && now.timeIntervalSince(armedAt) >= 0 && now.timeIntervalSince(armedAt) < 4
    }
    mutating func tap(_ id: String, at now: Date = .now) -> Bool {
        if isArmed(id, at: now) { reset(); return true }
        target = id; armedAt = now
        return false
    }
    mutating func reset() { target = nil; armedAt = .distantPast }
}

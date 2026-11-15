import Foundation

/// 실제 녹음기와 순수 로직 시험이 함께 쓰는 중단 알림 정책.
struct RecordingSafety {
    private enum Phase { case idle, recording, paused, interrupted, failed }
    private var phase = Phase.idle

    mutating func begin() { phase = .recording }
    mutating func pause() { phase = .paused }
    mutating func resume() { phase = .recording }
    mutating func stop() { phase = .idle }
    mutating func interrupt() -> Bool {
        guard phase == .recording else { return false }
        phase = .interrupted
        return true
    }
    mutating func fail() -> Bool {
        guard phase != .idle, phase != .failed else { return false }
        phase = .failed
        return true
    }
    static func toggleShouldStop(isActive: Bool) -> Bool { isActive }
}

import Foundation
import ActivityKit

/// 녹음 상태를 잠금 화면·다이내믹 아일랜드(라이브 액티비티)에 띄움.
/// 녹음 중엔 30초마다 '아직 녹음 중'을 확인해 갱신하고, 2분 넘게 소식이 없으면 위젯이 '상태 확인 안 됨'으로 바뀜
/// (앱이 강제로 꺼졌을 때 계속 녹음 중인 것처럼 보이지 않게).
@MainActor
final class LiveRecording {
    static let shared = LiveRecording()

    private var activity: Activity<RecordingActivityAttributes>?
    private var lastPush = Date.distantPast
    private var lastPhase: RecordingActivityAttributes.ContentState.Phase?
    private static let staleAfter: TimeInterval = 120
    private static let heartbeat: TimeInterval = 30

    private init() {}

    /// 앱 시작 때: 지난번(앱 강제 종료 등)에 남은 표시 정리
    func cleanUpLeftovers(recording: Bool) {
        guard !recording else { return }
        for a in Activity<RecordingActivityAttributes>.activities where a.id != activity?.id {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func start(title: String, startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = nil
        cleanUpLeftovers(recording: false)
        let state = content(.recording, elapsed: 0)
        do {
            activity = try Activity.request(attributes: .init(title: title, startedAt: startedAt),
                                            content: .init(state: state, staleDate: .now + Self.staleAfter))
            lastPush = .now
            lastPhase = .recording
        } catch {
            activity = nil
        }
    }

    /// 상태가 바뀌었거나 heartbeat 시간이 지났으면 갱신
    func update(_ phase: RecordingActivityAttributes.ContentState.Phase, elapsed: TimeInterval, force: Bool = false) {
        guard let activity else { return }
        let due = Date.now.timeIntervalSince(lastPush) >= Self.heartbeat
        guard force || phase != lastPhase || (phase == .recording && due) else { return }
        lastPush = .now
        lastPhase = phase
        // 녹음 중일 때만 '확인 안 됨' 기한을 둠 (일시정지는 멈춘 그대로가 맞는 상태)
        let stale: Date? = phase == .recording ? .now + Self.staleAfter : nil
        let c = ActivityContent(state: content(phase, elapsed: elapsed), staleDate: stale)
        Task { await activity.update(c) }
    }

    /// 녹음 정상 종료·버리기 → 바로 내림
    func end() {
        guard let activity else { return }
        self.activity = nil
        lastPhase = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// 앱이 꺼지는 중: '멈춤'으로 바꿔 잠금 화면에 잠시 남김
    func endAsStopped(elapsed: TimeInterval) {
        guard let activity else { return }
        self.activity = nil
        let c = ActivityContent(state: content(.stopped, elapsed: elapsed), staleDate: nil)
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await activity.end(c, dismissalPolicy: .after(.now + 15 * 60))
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 1.5)
    }

    private func content(_ phase: RecordingActivityAttributes.ContentState.Phase, elapsed: TimeInterval) -> RecordingActivityAttributes.ContentState {
        .init(phase: phase, timerStart: .now - elapsed, elapsed: elapsed, checkedAt: .now)
    }
}

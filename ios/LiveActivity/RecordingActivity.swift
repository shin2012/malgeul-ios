import Foundation
import ActivityKit
import AppIntents

/// 잠금 화면·다이내믹 아일랜드에 띄우는 녹음 상태 (앱과 위젯 확장이 함께 씀)
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording      // 녹음 중
            case paused         // 직접 일시정지
            case interrupted    // 전화 등으로 멈춤 (끝나면 자동으로 이어 녹음)
            case stopped        // 녹음이 예기치 않게 멈춤
        }
        var phase: Phase
        /// 녹음 중일 때 타이머 기준 시각 (= 지금 - 녹음된 길이)
        var timerStart: Date
        /// 일시정지·멈춤일 때 보여 줄 녹음 길이(초)
        var elapsed: TimeInterval
        /// 앱이 마지막으로 녹음이 계속되는 걸 확인한 시각
        var checkedAt: Date
    }

    var title: String
    var startedAt: Date
}

/// 잠금 화면 버튼 → 앱 안에서 실행 (LiveActivityIntent는 앱 프로세스에서 돌아감)
enum LiveRecordingCommand: String {
    case togglePause
    case stop
}

enum LiveRecordingActions {
    @MainActor static var handler: ((LiveRecordingCommand) -> Void)?
    @MainActor static func execute(_ command: LiveRecordingCommand) throws {
        guard let handler else {
            throw NSError(domain: "malgeul.recording", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "녹음기에 연결하지 못했습니다. 말글 앱을 열어 주세요."])
        }
        handler(command)
    }
}

struct ToggleRecordingPauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "녹음 일시정지/계속"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    func perform() async throws -> some IntentResult {
        try await MainActor.run { try LiveRecordingActions.execute(.togglePause) }
        return .result()
    }
}

struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "녹음 종료"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    func perform() async throws -> some IntentResult {
        try await MainActor.run { try LiveRecordingActions.execute(.stop) }
        return .result()
    }
}

enum LiveFormat {
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

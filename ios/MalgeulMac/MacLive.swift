#if os(macOS)
import Foundation
import AppIntents

/// Mac에는 잠금 화면 라이브 액티비티가 없다. 녹음기가 부르는 자리는 그대로 두고 아무것도 하지 않는다.
struct RecordingActivityAttributes {
    struct ContentState {
        enum Phase: String, Codable, Hashable { case recording, paused, interrupted, stopped }
    }
}

@MainActor
final class LiveRecording {
    static let shared = LiveRecording()
    var isVisible: Bool { false }
    private(set) var lastStartError: String?
    func cleanUpLeftovers(recording: Bool) {}
    func start(title: String, startedAt: Date, elapsed: TimeInterval = 0) {}
    func update(_ phase: RecordingActivityAttributes.ContentState.Phase, elapsed: TimeInterval, force: Bool = false) {}
    func end() {}
    func endAsStopped(elapsed: TimeInterval) {}
}

enum RecordingIntentError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}

/// 단축어·Spotlight: 녹음 시작·종료 (Mac은 앱을 열고 실행)
struct ToggleRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "녹음 시작·종료"
    static let description = IntentDescription("말글에서 녹음을 시작하거나 저장하고 종료합니다.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let recorder = Recorder.shared
        if RecordingSafety.toggleShouldStop(isActive: recorder.isActive) {
            recorder.stop()
        } else {
            await recorder.start()
            guard recorder.isActive else {
                throw RecordingIntentError.failed(recorder.permissionDenied ? "시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 말글을 허용해 주세요." : recorder.lastError ?? "녹음을 시작하지 못했습니다.")
            }
        }
        return .result()
    }
}

struct MalgeulAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleRecordingIntent(), phrases: [
            "\(.applicationName) 녹음 토글",
            "\(.applicationName) 녹음 시작 또는 종료"
        ], shortTitle: "녹음 시작·종료", systemImageName: "mic.fill")
    }
}
#endif

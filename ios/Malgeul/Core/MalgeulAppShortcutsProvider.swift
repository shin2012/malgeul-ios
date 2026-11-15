import Foundation
import AppIntents
import ActivityKit

struct MalgeulAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleRecordingIntent(), phrases: [
            "\(.applicationName) 녹음 토글",
            "\(.applicationName) 녹음 시작 또는 종료"
        ], shortTitle: "녹음 시작·종료", systemImageName: "mic.fill")
    }
}

/// 앱을 열지 않고 시작·종료한다. 마이크가 실제 시작될 때까지 perform을 반환하지 않는다.
struct ToggleRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "녹음 시작·종료"
    static let description = IntentDescription("앱을 열지 않고 녹음을 시작하거나 저장하고 종료합니다.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.background]

    @MainActor
    func perform() async throws -> some IntentResult {
        let recorder = Recorder.shared
        if RecordingSafety.toggleShouldStop(isActive: recorder.isActive) {
            recorder.stop()
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                throw RecordingIntentError.failed("처음 한 번 말글의 라이브 액티비티를 허용해 주세요. 앱은 자동으로 열지 않습니다.")
            }
            await recorder.start(requiresLiveActivity: true)
            guard recorder.isActive else {
                throw RecordingIntentError.failed(recorder.permissionDenied ? "처음 한 번 말글 앱에서 마이크 권한을 허용해 주세요." : recorder.lastError ?? "녹음을 시작하지 못했습니다.")
            }
        }
        return .result()
    }
}

enum RecordingIntentError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}

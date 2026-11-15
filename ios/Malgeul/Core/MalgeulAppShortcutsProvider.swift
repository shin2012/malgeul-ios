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

/// 오디오 녹음 인텐트는 앱 프로세스에서 실행한다. 일시정지 상태도 '종료' 대상이다.
struct ToggleRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "녹음 시작·종료"
    static let description = IntentDescription("대기 중이면 녹음을 시작하고, 녹음 또는 일시정지 중이면 저장하고 종료합니다.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        let recorder = Recorder.shared
        if RecordingSafety.toggleShouldStop(isActive: recorder.isActive) {
            recorder.stop()
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                throw RecordingIntentError.failed("말글의 라이브 액티비티를 허용한 뒤 다시 실행해 주세요.")
            }
            await recorder.start()
            guard recorder.isActive else {
                throw RecordingIntentError.failed(recorder.permissionDenied ? "말글 앱에서 마이크 권한을 허용해 주세요." : recorder.lastError ?? "녹음을 시작하지 못했습니다.")
            }
            guard LiveRecording.shared.isVisible else {
                recorder.stop()
                throw RecordingIntentError.failed("잠금 화면 녹음 표시를 만들지 못했습니다. 앱에서 녹음을 시작해 주세요.")
            }
        }
        return .result()
    }
}

enum RecordingIntentError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}

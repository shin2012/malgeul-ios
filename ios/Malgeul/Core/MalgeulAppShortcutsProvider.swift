import Foundation
import AppIntents
import ActivityKit
import UIKit

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
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult {
        let recorder = Recorder.shared
        if RecordingSafety.toggleShouldStop(isActive: recorder.isActive) {
            recorder.stop()
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                throw RecordingIntentError.failed("말글의 라이브 액티비티를 허용한 뒤 다시 실행해 주세요.")
            }
            try await RecordingLaunch.start(
                isForeground: { UIApplication.shared.applicationState == .active },
                requestForeground: {
                    if #available(iOS 26.0, *) {
                        try await continueInForeground(alwaysConfirm: false)
                    } else {
                        try await requestToContinueInForeground()
                    }
                },
                waitForForeground: {
                    let deadline = Date.now.addingTimeInterval(10)
                    while UIApplication.shared.applicationState != .active {
                        guard Date.now < deadline else {
                            throw RecordingIntentError.failed("말글 화면이 열리지 않았습니다. 앱을 열고 다시 실행해 주세요.")
                        }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                },
                activateRecording: {
                    Router.shared.tab = .record
                    await recorder.start()
                })
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

// iOS 18·기존 버전의 동적 전경 전환 호환 경로.
@available(*, deprecated)
extension ToggleRecordingIntent: ForegroundContinuableIntent {}

enum RecordingIntentError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}

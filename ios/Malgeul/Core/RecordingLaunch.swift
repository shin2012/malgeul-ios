import Foundation

/// 단축어의 앱 실행 상태와 오디오 세션 활성화 사이의 경계.
enum RecordingLaunch {
    @MainActor
    static func start(isForeground: () -> Bool,
                      requestForeground: () async throws -> Void,
                      waitForForeground: () async throws -> Void,
                      activateRecording: () async throws -> Void) async throws {
        if !isForeground() {
            try await requestForeground()
            try await waitForForeground()
        }
        try await activateRecording()
    }
}

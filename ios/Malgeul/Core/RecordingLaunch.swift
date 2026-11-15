import Foundation

/// 라이브 액티비티와 마이크 활성화의 순서를 함께 관리한다.
enum RecordingLaunch {
    enum LaunchError: LocalizedError {
        case missingActivity
        var errorDescription: String? { "녹음 표시를 만들지 못했습니다. 라이브 액티비티 허용 상태를 확인해 주세요." }
    }
    @MainActor
    static func start(requiresActivity: Bool,
                      prepareActivity: () -> Bool,
                      activateRecording: () throws -> Void,
                      cleanup: () -> Void) throws {
        do {
            let visible = prepareActivity()
            guard !requiresActivity || visible else { throw LaunchError.missingActivity }
            try activateRecording()
        } catch {
            cleanup()
            throw error
        }
    }
}

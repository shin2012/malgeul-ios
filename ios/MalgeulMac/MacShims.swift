#if os(macOS)
import AppKit
import AVFoundation

// iOS 전용 API를 Mac에서 같은 이름으로 흉내 낸다(공통 코드 수정 최소화). Mac 타깃에만 들어간다.

/// UIApplication 대용: 앱 상태·외부 링크 열기·백그라운드 작업(Mac에선 앱이 계속 실행되므로 할 일 없음)
@MainActor
final class UIApplication {
    static let shared = UIApplication()
    enum State: Int { case active = 0, inactive = 1, background = 2 }
    var applicationState: State { NSApp?.isActive == true ? .active : .background }
    static let openSettingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    func open(_ url: URL, options: [String: Any] = [:], completionHandler: ((Bool) -> Void)? = nil) {
        let ok = NSWorkspace.shared.open(url)
        completionHandler?(ok)
    }
    @discardableResult func open(_ url: URL) async -> Bool { NSWorkspace.shared.open(url) }
    func beginBackgroundTask(withName name: String?, expirationHandler: (() -> Void)?) -> UIBackgroundTaskIdentifier { .invalid }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {}
}

struct UIBackgroundTaskIdentifier: Equatable {
    let rawValue: Int
    static let invalid = UIBackgroundTaskIdentifier(rawValue: 0)
}

@MainActor
final class UIDevice {
    static let current = UIDevice()
    var name: String { Host.current().localizedName ?? "Mac" }
}

@MainActor
final class UIPasteboard {
    static let general = UIPasteboard()
    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }
}

extension NSColor {
    static var tertiarySystemFill: NSColor { .quaternaryLabelColor }
}

/// AVAudioSession 대용: Mac에는 오디오 세션이 없어 설정만 기억하고 실제로는 아무것도 하지 않는다.
final class AVAudioSession: @unchecked Sendable {
    private static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }

    enum Category { case playAndRecord, playback, record, ambient }
    enum Mode { case `default`, spokenAudio, measurement }
    struct CategoryOptions: OptionSet, Sendable {
        let rawValue: UInt
        static let mixWithOthers = CategoryOptions(rawValue: 1)
        static let duckOthers = CategoryOptions(rawValue: 2)
        static let defaultToSpeaker = CategoryOptions(rawValue: 8)
        static let allowBluetoothA2DP = CategoryOptions(rawValue: 32)
    }
    struct SetActiveOptions: OptionSet, Sendable {
        let rawValue: UInt
        static let notifyOthersOnDeactivation = SetActiveOptions(rawValue: 1)
    }
    enum InterruptionType: UInt { case ended = 0, began = 1 }
    struct InterruptionOptions: OptionSet, Sendable {
        let rawValue: UInt
        static let shouldResume = InterruptionOptions(rawValue: 1)
    }
    static let interruptionNotification = Notification.Name("MalgeulMacAudioInterruption")

    private(set) var categoryOptions: CategoryOptions = []
    func setCategory(_ category: Category, mode: Mode = .default, options: CategoryOptions = []) throws { categoryOptions = options }
    func setActive(_ active: Bool, options: SetActiveOptions = []) throws {}
}

let AVAudioSessionInterruptionTypeKey = "AVAudioSessionInterruptionTypeKey"
let AVAudioSessionInterruptionOptionKey = "AVAudioSessionInterruptionOptionKey"
#endif

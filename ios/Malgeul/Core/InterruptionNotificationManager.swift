import Foundation
import UserNotifications

/// 권한 요청은 녹음 시작 때만 한다. 중단 시점에 권한 창을 띄우지 않는다.
@MainActor
final class InterruptionNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = InterruptionNotificationManager()
    private(set) var submittedCount = 0
    private override init() { super.init() }

    func install() { UNUserNotificationCenter.current().delegate = self }

    func requestPermission() async {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "recordingSelfTest") { return }
        #endif
        do {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
        } catch { print("[RecordingNotification] permission failed: \(error)") }
    }

    func notifyInterruption(reason: String) {
        submittedCount += 1
        let content = UNMutableNotificationContent()
        content.title = "녹음이 중단됐어요"
        content.body = reason
        content.sound = .default
        content.userInfo = ["route": "record"]
        let request = UNNotificationRequest(identifier: "recording-interruption", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            print("[RecordingNotification] \(error.map { "failed: \($0)" } ?? "submitted")")
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.userInfo["route"] as? String == "record" {
            Task { @MainActor in Router.shared.tab = .record }
        }
        completionHandler()
    }
}

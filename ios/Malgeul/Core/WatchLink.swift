import Foundation
import UIKit
import WatchConnectivity

/// 애플워치 녹음 받기: 워치가 보낸 파일을 '내 녹음'에 넣고 서버로 올림
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    /// 이 메서드가 끝나면 시스템이 파일을 지우므로 여기서 바로 옮김
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let meta = file.metadata ?? [:]
        guard meta["kind"] as? String == "watch-recording" else { return }
        let original = (meta["id"] as? String) ?? file.fileURL.lastPathComponent
        let ext = (original as NSString).pathExtension.isEmpty ? "m4a" : (original as NSString).pathExtension
        let base = (original as NSString).deletingPathExtension
        var name = "\(base).\(ext)"
        var n = 2
        while FileManager.default.fileExists(atPath: RecordingStore.folder.appending(path: name).path) {
            name = "\(base) \(n).\(ext)"; n += 1
        }
        let dest = RecordingStore.folder.appending(path: name)
        do { try FileManager.default.moveItem(at: file.fileURL, to: dest) } catch {
            guard (try? FileManager.default.copyItem(at: file.fileURL, to: dest)) != nil else { return }
        }
        let at = (meta["recordedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .now
        let dur = (meta["duration"] as? Double) ?? 0
        let place = (meta["place"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let la = meta["latitude"] as? Double, lo = meta["longitude"] as? Double

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // 앱이 백그라운드에서 깨어났을 때 업로드 준비(중복 확인·본문 만들기)가 끝날 시간을 확보
                var bg = UIBackgroundTaskIdentifier.invalid
                bg = UIApplication.shared.beginBackgroundTask(withName: "watch-recording") {
                    UIApplication.shared.endBackgroundTask(bg)
                }
                RecordingStore.shared.addFromWatch(id: name, startedAt: at, duration: dur, place: place, latitude: la, longitude: lo)
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) { UIApplication.shared.endBackgroundTask(bg) }
            }
        }
    }
}

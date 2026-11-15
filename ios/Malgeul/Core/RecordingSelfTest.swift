#if DEBUG
import Foundation
import AVFoundation
import AppIntents

/// CI 전용: 실제 AVAudioRecorder·인텐트·저장 경로를 실행한다.
/// 통화 신호는 주입하며, 실제 전화 수신과 물리 동작 버튼은 실기기 시험이 필요하다.
@MainActor
enum RecordingSelfTest {
    static func run() async {
        var checks: [[String: Any]] = []
        func check(_ value: Bool, _ name: String) { checks.append(["name": name, "passed": value]) }
        let r = Recorder.shared
        let notifications = InterruptionNotificationManager.shared
        let initial = RecordingStore.shared.items.count
        let before = notifications.submittedCount
        do {
            if UserDefaults.standard.bool(forKey: "recordingDeniedTest") {
                do { _ = try await ToggleRecordingIntent().perform(); check(false, "권한 거부 시 인텐트 실패") }
                catch { check(r.permissionDenied && !r.isActive, "마이크 권한 거부 시 녹음하지 않고 실패 전달") }
            } else {
                _ = try await ToggleRecordingIntent().perform()
                try await Task.sleep(for: .seconds(1.2))
                check(r.state == .recording && r.elapsed > 0, "토글 인텐트 실제 녹음 시작")
                check(LiveRecording.shared.isVisible, "녹음 라이브 액티비티 생성")
                _ = try await ToggleRecordingPauseIntent().perform()
                check(r.state == .paused, "잠금 화면 일시정지 인텐트")
                _ = try await ToggleRecordingIntent().perform()
                check(!r.isActive, "일시정지 중 토글은 종료")
                check(RecordingStore.shared.items.count == initial + 1, "종료 후 목록 저장은 한 번")
                let saved = RecordingStore.shared.items.first!
                check((try? AVAudioPlayer(contentsOf: saved.fileURL))?.duration ?? 0 > 0, "저장한 AAC 파일 재생 가능")
                _ = try await StopRecordingIntent().perform()
                check(RecordingStore.shared.items.count == initial + 1, "반복 종료는 중복 저장하지 않음")
                check(notifications.submittedCount == before, "정상 일시정지·종료는 중단 알림 없음")

                _ = try await ToggleRecordingIntent().perform()
                try await Task.sleep(for: .seconds(0.5))
                let info: [String: Any] = [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
                NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), userInfo: info)
                try await Task.sleep(for: .seconds(0.2))
                check(r.state == .paused && r.interrupted, "주입한 통화 중단은 일시정지")
                check(notifications.submittedCount == before + 1, "통화 중단 알림 요청")
                NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), userInfo: info)
                try await Task.sleep(for: .seconds(0.2))
                check(notifications.submittedCount == before + 1, "같은 중단 반복 시 알림 중복 없음")
                _ = try await StopRecordingIntent().perform()
                check(!r.isActive && RecordingStore.shared.items.count == initial + 2, "중단 상태에서도 잠금 화면 종료·저장")

                _ = try await ToggleRecordingIntent().perform()
                try await Task.sleep(for: .seconds(0.5))
                r.debugStopUnderlyingRecorder()
                try await Task.sleep(for: .seconds(0.5))
                check(!r.isActive, "예상치 못한 실제 녹음기 종료 감지")
                check(RecordingStore.shared.items.count == initial + 3, "중단 파일 보존")
                check(notifications.submittedCount == before + 2, "종료 콜백·타이머가 알림을 중복하지 않음")
            }
        } catch { check(false, "실행 오류: \(error)") }
        if r.isActive { r.stop() }
        let report: [String: Any] = ["checks": checks, "failed": checks.filter { ($0["passed"] as? Bool) != true }.count,
            "limitations": ["물리 동작 버튼 및 잠금 상태에서의 시스템 인텐트 라우팅 미시험", "통화 신호는 주입", "알림 요청 경로만 시험, 배너·소리는 실기기 확인 필요"]]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "recording-selftest.json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
#endif

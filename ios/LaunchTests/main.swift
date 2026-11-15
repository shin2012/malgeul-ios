import Foundation

@MainActor
func run() async -> Int32 {
    var failed = 0
    var count = 0
    func check(_ condition: Bool, _ message: String) {
        count += 1
        if !condition { failed += 1 }
        print("\(condition ? "PASS" : "FAIL") \(message)")
    }
    enum TestError: Error { case cancelled, notActive }

    // 실제 오류를 재현하는 경계: 전경 활성화 전에 오디오를 시작하면 세션이 거부된다.
    var foreground = false
    var events: [String] = []
    do {
        try await RecordingLaunch.start(isForeground: { foreground }, requestForeground: {
            events.append("request")
        }, waitForForeground: {
            events.append("active")
            foreground = true
        }, activateRecording: {
            guard foreground else { throw NSError(domain: "NSOSStatusErrorDomain", code: 560557684,
                userInfo: [NSLocalizedDescriptionKey: "Session activation failed"]) }
            events.append("record")
        })
        check(events == ["request", "active", "record"], "잠금 화면·홈 화면 실행: 전경 요청 → 활성화 확인 → 녹음")
    } catch { check(false, "백그라운드 시작 실패: \(error.localizedDescription)") }

    events = []
    do {
        try await RecordingLaunch.start(isForeground: { true }, requestForeground: { events.append("unexpected") },
            waitForForeground: { events.append("unexpected") }, activateRecording: { events.append("record") })
        check(events == ["record"], "이미 앱이 전경이면 추가 전환 없이 시작")
    } catch { check(false, "전경 실행 오류") }

    var activated = false
    do {
        try await RecordingLaunch.start(isForeground: { false }, requestForeground: { throw TestError.cancelled },
            waitForForeground: {}, activateRecording: { activated = true })
        check(false, "사용자 전경 전환 취소를 전달해야 함")
    } catch { check(!activated, "잠금 해제·전경 전환 취소 시 녹음하지 않음") }

    activated = false
    do {
        try await RecordingLaunch.start(isForeground: { false }, requestForeground: {},
            waitForForeground: { throw TestError.notActive }, activateRecording: { activated = true })
        check(false, "전경 활성화 실패를 전달해야 함")
    } catch { check(!activated, "앱이 활성화되지 않으면 오디오 세션에 접근하지 않음") }

    print("LAUNCH_CHECKS=\(count) FAILURES=\(failed)")
    return failed == 0 ? 0 : 1
}
exit(await run())

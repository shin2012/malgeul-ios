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
    enum TestError: Error { case activationFailed }
    var events: [String] = []
    var visible = false
    do {
        try RecordingLaunch.start(requiresActivity: true, prepareActivity: {
            events.append("activity")
            visible = true
            return visible
        }, activateRecording: {
            guard visible else { throw TestError.activationFailed }
            events.append("record")
        }, cleanup: { events.append("cleanup") })
        check(events == ["activity", "record"], "녹음 표시 생성 후 오디오 활성화, 전경 전환 단계 없음")
    } catch { check(false, "정상 시작 경계 실패") }

    events = []
    do {
        try RecordingLaunch.start(requiresActivity: true, prepareActivity: { false },
            activateRecording: { events.append("unexpected") }, cleanup: { events.append("cleanup") })
        check(false, "표시 생성 실패를 전달해야 함")
    } catch { check(events == ["cleanup"], "단축어 표시 생성 실패 시 마이크를 켜지 않고 정리") }

    events = []
    do {
        try RecordingLaunch.start(requiresActivity: false, prepareActivity: { false },
            activateRecording: { events.append("record") }, cleanup: { events.append("cleanup") })
        check(events == ["record"], "앱 안의 녹음은 표시 권한 없이도 기존대로 시작")
    } catch { check(false, "앱 내 녹음 회귀") }

    events = []
    do {
        try RecordingLaunch.start(requiresActivity: true, prepareActivity: { events.append("activity"); return true },
            activateRecording: { throw TestError.activationFailed }, cleanup: { events.append("cleanup") })
        check(false, "세션 실패를 전달해야 함")
    } catch TestError.activationFailed {
        check(events == ["activity", "cleanup"], "세션 실패 시 표시·세션 정리, 앱 열기 우회 없음")
    } catch { check(false, "원래 세션 오류 보존 실패") }

    print("LAUNCH_CHECKS=\(count) FAILURES=\(failed)")
    return failed == 0 ? 0 : 1
}
exit(await run())

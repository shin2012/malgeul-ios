import Foundation

var failures = 0
var checks = 0
func check(_ value: Bool, _ label: String) {
    checks += 1
    print("\(value ? "PASS" : "FAIL") \(label)")
    if !value { failures += 1 }
}

// 실제 앱에 포함되는 정책을 시험한다. 별도 시험용 구현을 두지 않는다.
var safety = RecordingSafety()
safety.begin()
check(safety.interrupt(), "전화 중단은 알림")
check(!safety.interrupt(), "같은 중단은 한 번만 알림")
safety.resume()
check(safety.interrupt(), "재개 이후 새로운 중단은 다시 알림")
safety.stop()
check(!safety.fail(), "정상 종료 이후 지연된 오류는 무시")
safety.begin()
safety.pause()
check(!safety.interrupt(), "직접 일시정지 중에는 통화 알림 없음")
safety.resume()
check(safety.fail(), "재개 후 예기치 않은 종료는 알림")
check(!safety.fail(), "종료 콜백과 타이머 중복은 무시")
safety.begin()
safety.pause()
check(safety.fail(), "일시정지 중 인코더 오류도 알림")
safety.stop()
check(!safety.interrupt(), "버린 녹음은 알림 없음")
check(RecordingSafety.toggleShouldStop(isActive: false) == false, "대기 중 토글은 시작")
check(RecordingSafety.toggleShouldStop(isActive: true), "녹음·일시정지 중 토글은 종료")
print("CHECKS=\(checks) FAILURES=\(failures)")
exit(failures == 0 ? 0 : 1)

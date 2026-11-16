import Foundation

var gate = TwoTapDeletion()
let now = Date(timeIntervalSince1970: 100)
func check(_ ok: Bool, _ message: String) { precondition(ok, message); print("PASS: \(message)") }
check(!gate.tap("a", at: now), "첫 누름은 삭제하지 않음")
check(gate.isArmed("a", at: now), "첫 누름 후 확인 문구")
check(!gate.tap("b", at: now.addingTimeInterval(1)), "다른 대상은 새로 확인")
check(!gate.isArmed("a", at: now.addingTimeInterval(1)), "이전 대상 해제")
check(gate.tap("b", at: now.addingTimeInterval(2)), "같은 대상 두 번째 누름만 삭제")
check(!gate.tap("b", at: now.addingTimeInterval(3)), "삭제 후 다시 첫 누름")
check(!gate.tap("b", at: now.addingTimeInterval(8)), "시간 초과 후 첫 누름")
gate.reset()
check(!gate.isArmed("b", at: now.addingTimeInterval(8)), "화면 이탈 시 해제")

import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    print("PASS \(message)")
}
let locals = [NoteListProjection.Local(id: "audio.m4a", meetingID: nil)]
let uploads = [NoteListProjection.Upload(id: "job-1", recordingID: "audio.m4a", meetingID: nil)]
let rows = NoteListProjection.rows(locals: locals, uploads: uploads, meetingIDs: [], aliases: [:])
expect(rows.count == 1, "업로드 작업과 기기 녹음은 한 행")
expect(rows[0].recordingID == "audio.m4a" && rows[0].uploadID == "job-1", "원래 녹음 행에 작업 연결")
expect(rows[0].id == "local-audio.m4a", "업로드 시작 전후 표시 ID 유지")
let duplicateJobs = [NoteListProjection.Upload(id: "job-1", recordingID: "audio.m4a", meetingID: nil),
                     NoteListProjection.Upload(id: "job-2", recordingID: "audio.m4a", meetingID: nil)]
expect(NoteListProjection.rows(locals: locals, uploads: duplicateJobs, meetingIDs: [], aliases: [:]).count == 1, "같은 녹음의 업로드 작업이 둘이어도 표시 행은 하나")
expect(NoteListProjection.rows(locals: [], uploads: duplicateJobs, meetingIDs: [], aliases: [:]).count == 1, "로컬 목록이 없어도 동일 recordingID 작업을 한 행으로 합침")
let linked = [NoteListProjection.Local(id: "audio.m4a", meetingID: 10)]
let server = NoteListProjection.rows(locals: linked, uploads: [], meetingIDs: [10], aliases: [:])
expect(server.count == 1 && server[0].meetingID == 10, "업로드 완료 후 서버 행과 중복 없음")
expect(server[0].id == rows[0].id, "서버 연결 후에도 같은 표시 ID")
let imported = NoteListProjection.rows(locals: [], uploads: [.init(id: "file-job", recordingID: nil, meetingID: nil)], meetingIDs: [], aliases: [:])
let importedDone = NoteListProjection.rows(locals: [], uploads: [], meetingIDs: [20], aliases: [20: imported[0].id])
expect(imported.count == 1 && importedDone[0].id == imported[0].id, "외부 파일도 완료 후 표시 ID 유지")
expect(NoteListProjection.rows(locals: linked, uploads: [], meetingIDs: [], aliases: [:]).count == 1, "서버 재조회 실패해도 연결된 로컬 항목 유지")
expect(NoteListProjection.rows(locals: [.init(id: "one.m4a", meetingID: nil), .init(id: "two.m4a", meetingID: nil)], uploads: [], meetingIDs: [], aliases: [:]).count == 2, "다른 파일은 임의로 합치지 않음")
// 실제 사례: 예전에 실패한 업로드 작업이 남은 채 같은 녹음을 다시 올려 서버 노트가 생김
// → 남은 작업 행과 서버 노트 행이 같은 표시 ID("local-…")를 가져 SwiftUI가 노트 행을 두 번 그림
let staleJob = [NoteListProjection.Upload(id: "old-job", recordingID: "rec.m4a", meetingID: nil)]
for locals in [[NoteListProjection.Local(id: "rec.m4a", meetingID: 81)], []] {
    let r = NoteListProjection.rows(locals: locals, uploads: staleJob, meetingIDs: [81], aliases: [81: "local-rec.m4a"])
    expect(r.count == 1 && r[0].meetingID == 81, "남은 업로드 작업이 있어도 서버 노트는 한 행 (로컬 \(locals.count))")
    expect(Set(r.map(\.id)).count == r.count, "표시 ID 중복 없음 (로컬 \(locals.count))")
}
let noAlias = NoteListProjection.rows(locals: [.init(id: "rec.m4a", meetingID: 81)], uploads: staleJob, meetingIDs: [81], aliases: [:])
expect(noAlias.count == 1 && noAlias[0].meetingID == 81, "별칭이 없어도 같은 녹음의 남은 작업은 서버 노트에 합침")
let unlinkedLocal = NoteListProjection.rows(locals: [.init(id: "rec.m4a", meetingID: nil)], uploads: [], meetingIDs: [81], aliases: [81: "local-rec.m4a"])
expect(unlinkedLocal.count == 1 && unlinkedLocal[0].meetingID == 81, "녹음 연결이 저장되지 않았어도 같은 표시 ID면 한 행")
func meeting(_ extra: String = "") -> Meeting {
    try! JSONDecoder().decode(Meeting.self, from: Data(("{\"id\":1,\"title\":\"회의\",\"status\":\"done\",\"ai_analyzed\":1" + extra + "}").utf8))
}
expect(meeting(",\"speaker_id_status\":\"processing\"").needsPostProcessing, "화자 추정 중에도 처리 중 분류")
expect(meeting(",\"speaker_id_status\":\"queued\"").needsPostProcessing, "화자 추정 대기도 처리 중")
expect(meeting(",\"processing_phase\":\"analyzing\"").postProcessingLabel == "제목·태그 정리 중", "실제 분석 단계 표시")
expect(meeting(",\"speaker_id_status\":\"skipped\"").isSettled, "화자 추정 사용 안 함은 무한 대기하지 않음")
expect(meeting(",\"speaker_id_status\":\"error\"").isSettled, "화자 추정 실패해도 대본 사용 가능")
expect(meeting().isSettled, "과거 화자 상태가 없는 노트는 처리 중으로 추측하지 않음")
var legacy = meeting(); legacy.aiAnalyzed = 0
expect(!legacy.needsPostProcessing, "과거 분석 실패 값만으로 계속 처리 중 표시하지 않음")


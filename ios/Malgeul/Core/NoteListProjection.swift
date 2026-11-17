import Foundation

/// 기기 녹음·업로드·서버 회의의 정체성만 합친다. 제목이 같다는 이유로 합치지 않는다.
enum NoteListProjection {
    struct Local { let id: String; let meetingID: Int? }
    struct Upload { let id: String; let recordingID: String?; let meetingID: Int? }
    struct Row: Identifiable, Equatable {
        let id: String
        var meetingID: Int?
        var recordingID: String?
        var uploadID: String?
    }

    static func rows(locals: [Local], uploads: [Upload], meetingIDs: [Int], aliases: [Int: String]) -> [Row] {
        var result: [Row] = []
        let serverIDs = Set(meetingIDs)
        for local in locals {
            // 이미 연결된 로컬 파일은 서버 행으로 나타낸다. 아직 목록에 도착하지 않으면 유지한다.
            if let id = local.meetingID, serverIDs.contains(id) { continue }
            guard !result.contains(where: { $0.recordingID == local.id }) else { continue }
            result.append(Row(id: "local-" + local.id, meetingID: local.meetingID, recordingID: local.id))
        }
        for upload in uploads {
            if let i = result.firstIndex(where: {
                (upload.recordingID != nil && $0.recordingID == upload.recordingID)
                || (upload.meetingID != nil && $0.meetingID == upload.meetingID)
            }) {
                result[i].uploadID = upload.id
                if let id = upload.meetingID { result[i].meetingID = id }
            } else if upload.meetingID.map({ serverIDs.contains($0) }) != true {
                result.append(Row(id: upload.recordingID.map { "local-" + $0 } ?? "upload-" + upload.id,
                                  meetingID: upload.meetingID, recordingID: upload.recordingID, uploadID: upload.id))
            }
        }
        for id in meetingIDs {
            if let i = result.firstIndex(where: { $0.meetingID == id }) {
                result.remove(at: i)
            }
            guard !result.contains(where: { $0.meetingID == id }) else { continue }
            let local = locals.first { $0.meetingID == id }
            let upload = uploads.first { $0.meetingID == id || (local != nil && $0.recordingID == local?.id) }
            result.append(Row(id: aliases[id] ?? local.map { "local-" + $0.id } ?? "meeting-\(id)",
                              meetingID: id, recordingID: local?.id, uploadID: upload?.id))
        }
        return result
    }
}

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
        var placed = Set<Int>()
        for id in meetingIDs where placed.insert(id).inserted {
            let local = locals.first { $0.meetingID == id }
            let rowID = aliases[id] ?? local.map { "local-" + $0.id } ?? "meeting-\(id)"
            // 표시 ID가 "local-<녹음>"이면 그 녹음의 남은 행(실패한 옛 업로드 작업 등)도 같은 노트다.
            let recordingID = local?.id ?? (rowID.hasPrefix("local-") ? String(rowID.dropFirst(6)) : nil)
            // 같은 노트·같은 녹음·같은 표시 ID 행은 모두 서버 노트 한 행으로 합친다.
            // (남겨 두면 표시 ID가 겹쳐 SwiftUI가 노트 행을 두 번 그림)
            result.removeAll { $0.meetingID == id || $0.id == rowID || (recordingID != nil && $0.recordingID == recordingID) }
            let upload = uploads.first { $0.meetingID == id || (recordingID != nil && $0.recordingID == recordingID) }
            result.append(Row(id: rowID, meetingID: id, recordingID: local?.id, uploadID: upload?.id))
        }
        return result
    }
}

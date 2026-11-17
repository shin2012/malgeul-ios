import Foundation

#if DEBUG
/// 실제 앱 저장 경로를 쓰는 중립적인 시험 파일. 배포 빌드에는 포함되지 않는다.
@MainActor
func installNoteUITestFixture(recordingStore: RecordingStore) {
    let id = "note-ui-fixture.wav"
    recordingStore.delete(id)
    let sampleCount = 16_000
    var data = Data()
    func text(_ s: String) { data.append(contentsOf: s.utf8) }
    func word(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    func long(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    text("RIFF"); long(UInt32(36 + sampleCount * 2)); text("WAVEfmt "); long(16)
    word(1); word(1); long(16_000); long(32_000); word(2); word(16)
    text("data"); long(UInt32(sampleCount * 2)); data.append(Data(repeating: 0, count: sampleCount * 2))
    do {
        try data.write(to: RecordingStore.folder.appending(path: id), options: .atomic)
        recordingStore.add(Recording(id: id, title: "화면 시험 녹음", startedAt: .now, duration: 1))
    } catch { assertionFailure("시험 녹음 생성 실패: \(error)") }
}
#endif

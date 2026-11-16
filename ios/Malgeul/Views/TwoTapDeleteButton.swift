import SwiftUI

/// 확인 창 대신 같은 버튼을 한 번 더 누르는 삭제 제어.
struct TwoTapDeleteButton: View {
    let target: String
    @Binding var confirmation: TwoTapDeletion
    var title = "삭제"
    let action: () -> Void

    var body: some View {
        Button {
            if confirmation.tap(target) { action() }
        } label: {
            Label(confirmation.isArmed(target) ? "한 번 더 눌러 삭제" : title, systemImage: "trash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.mgDanger)
        }
        .buttonStyle(.borderless)
        .task(id: confirmation.target) {
            guard confirmation.target == target else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            if confirmation.target == target { confirmation.reset() }
        }
    }
}

/// 전체 노트와 녹음 목록에서 같은 행·메뉴·삭제 동작을 사용한다.
struct PendingRecordingListRow: View {
    let recording: Recording
    @EnvironmentObject private var recordings: RecordingStore
    @EnvironmentObject private var uploads: UploadCenter
    @EnvironmentObject private var config: AppConfig
    @EnvironmentObject private var device: OnDeviceJobCenter
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var router: Router
    @Binding var deletion: TwoTapDeletion
    @State private var renaming = false
    @State private var title = ""

    private var target: String { "local-\(recording.id)" }
    private var playing: Bool { player.playingKey == "rec-\(recording.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                RecordingRow(recording: recording)
                NoteRowMenu { actions }.padding(.top, 2)
            }
            if deletion.isArmed(target) {
                TwoTapDeleteButton(target: target, confirmation: $deletion) { deleteRecording() }
                    .padding(.bottom, 12)
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color.white)
        .listRowSeparatorTint(Color.mgLine)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { requestDelete() } label: { Label("삭제", systemImage: "trash") }.tint(Color.mgDanger)
            Button { beginRename() } label: { Label("제목", systemImage: "pencil") }.tint(.gray)
        }
        .swipeActions(edge: .leading) {
            if canUpload && recording.meetingID == nil {
                Button { upload(auto: config.autoTranscribeRecordings) } label: { Label("업로드", systemImage: "arrow.up.circle") }
                    .tint(Color.accentMalgeul)
            }
        }
        .contextMenu { actions }
        .alert("제목 수정", isPresented: $renaming) {
            TextField("제목", text: $title)
            Button("저장") {
                let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { recordings.rename(recording.id, title: text) }
            }
            Button("취소", role: .cancel) {}
        }
    }

    @ViewBuilder private var actions: some View {
        Button { player.toggleFile(recording.fileURL, key: "rec-\(recording.id)") } label: {
            Label(playing ? "재생 정지" : "재생", systemImage: playing ? "stop" : "play")
        }
        if let id = recording.meetingID {
            Button { router.meetingID = id; router.tab = .meetings } label: { Label("열기", systemImage: "text.bubble") }
        }
        Button { beginRename() } label: { Label("제목 수정", systemImage: "pencil") }
        if canUpload {
            Button { upload(auto: false) } label: {
                Label(recording.meetingID == nil ? "업로드" : "다시 업로드", systemImage: "arrow.up.circle")
            }
            Button { upload(auto: true) } label: { Label("업로드 후 바로 받아쓰기", systemImage: "waveform") }
            if AppConfig.deviceTranscribeAvailable && recording.meetingID == nil && device.job(recording: recording.id) == nil {
                Button {
                    device.requestNotificationPermission()
                    device.enqueueLocalFirst(recording)
                } label: { Label("이 기기에서 받아쓰고 함께 올리기", systemImage: "iphone") }
            }
        }
        ShareLink(item: recording.fileURL) { Label("공유", systemImage: "square.and.arrow.up") }
        Divider()
        Button { requestDelete() } label: { Label("삭제", systemImage: "trash") }
    }

    private var canUpload: Bool {
        config.isConfigured && uploads.isUploading(recordingID: recording.id) == nil
    }
    private func upload(auto: Bool) { recordings.upload(recording, autoTranscribe: auto) }
    private func beginRename() { title = recording.title; renaming = true }
    private func requestDelete() { if deletion.tap(target) { deleteRecording() } }
    private func deleteRecording() {
        if playing { player.stop() }
        recordings.delete(recording.id)
    }
}

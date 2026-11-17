import SwiftUI

/// 확인 창 대신 같은 버튼을 한 번 더 누르는 삭제 제어.
struct TwoTapDeleteButton: View {
    let target: String
    @Binding var confirmation: TwoTapDeletion
    var title = "삭제"
    let action: () -> Void
    @Environment(\.noteMenuDismiss) private var closeMenu

    var body: some View {
        Button {
            if confirmation.tap(target) { closeMenu(); action() }
        } label: {
            ZStack(alignment: .leading) {
                Label("한 번 더 눌러 삭제", systemImage: "trash").hidden().accessibilityHidden(true)
                Label(confirmation.isArmed(target) ? "한 번 더 눌러 삭제" : title, systemImage: "trash")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.mgDanger)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("delete-confirm-button")
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
        SwipeDeleteRow(target: target, confirmation: $deletion,
                       disabled: uploads.isUploading(recordingID: recording.id) != nil,
                       background: Color.mgBg2, onDelete: { deleteRecording() }) {
            HStack(alignment: .top, spacing: 0) {
                RecordingRow(recording: recording)
                NoteRowMenu(onClose: { deletion.reset() }) { actions }.padding(.top, 2)
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color.mgBg2)
        .listRowSeparatorTint(Color.mgLine)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
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
        NoteActionButton { player.toggleFile(recording.fileURL, key: "rec-\(recording.id)") } label: {
            Label(playing ? "재생 정지" : "재생", systemImage: playing ? "stop" : "play")
        }
        if let id = recording.meetingID {
            NoteActionButton { router.meetingID = id; router.tab = .meetings } label: { Label("열기", systemImage: "text.bubble") }
        }
        NoteActionButton { beginRename() } label: { Label("제목 수정", systemImage: "pencil") }
        if canUpload {
            NoteActionButton { upload(auto: false) } label: {
                Label(recording.meetingID == nil ? "업로드" : "다시 업로드", systemImage: "arrow.up.circle")
            }
            NoteActionButton { upload(auto: true) } label: { Label("업로드 후 바로 받아쓰기", systemImage: "waveform") }
            if AppConfig.deviceTranscribeAvailable && recording.meetingID == nil && device.job(recording: recording.id) == nil {
                NoteActionButton {
                    device.requestNotificationPermission()
                    device.enqueueLocalFirst(recording)
                } label: { Label("이 기기에서 받아쓰고 함께 올리기", systemImage: "iphone") }
            }
        }
        ShareLink(item: recording.fileURL) { Label("공유", systemImage: "square.and.arrow.up") }
        Divider()
        TwoTapDeleteButton(target: target, confirmation: $deletion) { deleteRecording() }
            .disabled(uploads.isUploading(recordingID: recording.id) != nil)
        Text("기기에 저장된 녹음만 삭제합니다.")
            .font(.system(size: 12)).foregroundStyle(Color.mgFg3)
    }

    private var canUpload: Bool {
        config.isConfigured && uploads.isUploading(recordingID: recording.id) == nil
    }
    private func upload(auto: Bool) { recordings.upload(recording, autoTranscribe: auto) }
    private func beginRename() { title = recording.title; renaming = true }
    private func deleteRecording() {
        if playing { player.stop() }
        recordings.delete(recording.id)
    }
}

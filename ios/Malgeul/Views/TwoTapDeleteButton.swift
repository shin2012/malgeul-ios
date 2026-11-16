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

/// 업로드 전 녹음도 전체 목록에서 바로 확인·재생·업로드할 수 있다.
struct PendingRecordingListRow: View {
    let recording: Recording
    @EnvironmentObject private var recordings: RecordingStore
    @EnvironmentObject private var uploads: UploadCenter
    @EnvironmentObject private var config: AppConfig
    @EnvironmentObject private var device: OnDeviceJobCenter
    @EnvironmentObject private var player: AudioPlayer
    @Binding var deletion: TwoTapDeletion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RecordingRow(recording: recording)
            if let job = device.job(recording: recording.id) {
                DeviceJobLine(job: job)
            } else {
                Text("받아쓰기 전 · 기기에 보관됨")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.mgFg2)
            }
            HStack {
                if config.isConfigured && uploads.isUploading(recordingID: recording.id) == nil {
                    Button("업로드") { recordings.upload(recording, autoTranscribe: config.autoTranscribeRecordings) }
                        .buttonStyle(.borderless).font(.system(size: 13, weight: .medium))
                }
                Spacer()
                TwoTapDeleteButton(target: "local-\(recording.id)", confirmation: $deletion) {
                    if player.playingKey == "rec-\(recording.id)" { player.stop() }
                    recordings.delete(recording.id)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

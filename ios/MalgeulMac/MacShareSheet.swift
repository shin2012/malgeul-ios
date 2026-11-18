#if os(macOS)
import SwiftUI
import AppKit

/// iOS 공유 시트 대신: 파일 저장·Finder에서 보기·공유
struct ShareSheet: View {
    let items: [Any]
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    private var url: URL? { items.first as? URL }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(url?.lastPathComponent ?? "파일", systemImage: "doc").font(.headline)
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button("저장…") { save() }.keyboardShortcut(.defaultAction)
                if let url {
                    ShareLink(item: url) { Label("공유", systemImage: "square.and.arrow.up") }
                    Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        guard let url else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: url, to: dest)
            message = "저장했습니다: \(dest.lastPathComponent)"
        } catch { message = "저장 실패: \(error.localizedDescription)" }
    }
}
#endif

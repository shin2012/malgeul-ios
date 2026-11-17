import SwiftUI

/// 서버 노트와 기기 녹음이 공유하는 제목·본문·행 간격.
struct NoteRowContent<Details: View>: View {
    let title: String
    var compact = false
    @ViewBuilder let details: () -> Details

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: compact ? 15 : 16, weight: .semibold))
                .foregroundStyle(Color.mgFg)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            details()
        }
        .padding(.vertical, compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 날짜와 길이는 같은 줄, 상태는 필요한 경우에만 한 번 표시한다.
struct NoteRowMetadata: View {
    let date: Date?
    let duration: Int?
    var status: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(Fmt.when(date))
                if let duration { Text(Fmt.duration(duration)) }
            }
            .foregroundStyle(Color.mgFg3)
            .monospacedDigit()
            .lineLimit(1)
            if let status {
                Text(status).fontWeight(.medium).foregroundStyle(Color.mgFg2)
            }
        }
        .font(.system(size: 13.5))
    }
}

private struct NoteMenuDismissKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var noteMenuDismiss: () -> Void {
        get { self[NoteMenuDismissKey.self] }
        set { self[NoteMenuDismissKey.self] = newValue }
    }
}

/// 모든 팝오버 항목이 같은 아이콘 열과 44포인트 터치 행을 사용한다.
struct NoteMenuLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon.frame(width: 22, alignment: .center)
            configuration.title.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 일반 동작은 팝오버를 닫고, 삭제는 확인이 끝날 때까지 같은 자리에 남긴다.
struct NoteActionButton<LabelContent: View>: View {
    @Environment(\.noteMenuDismiss) private var close
    let action: () -> Void
    @ViewBuilder let label: () -> LabelContent
    var body: some View {
        Button { close(); action() } label: {
            label().frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 첫 삭제 누름에 자동으로 닫히는 시스템 Menu 대신 지속되는 앵커 팝오버.
struct NoteRowMenu<Actions: View>: View {
    var onClose: () -> Void = {}
    @ViewBuilder let actions: () -> Actions
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.mgFg3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("노트 메뉴")
        .accessibilityIdentifier("note-menu")
        .popover(isPresented: $open, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) { actions() }
                .frame(width: 260, alignment: .leading)
                .padding(12)
            .fixedSize(horizontal: true, vertical: true)
            .font(.system(size: 14))
            .foregroundStyle(Color.mgFg2)
            .labelStyle(NoteMenuLabelStyle())
            .buttonStyle(.plain)
            .environment(\.noteMenuDismiss, { open = false })
            .presentationCompactAdaptation(.popover)
            .onDisappear { onClose() }
        }
    }
}

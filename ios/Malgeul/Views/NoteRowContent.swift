import SwiftUI

/// 서버 노트와 기기 녹음이 공유하는 제목·본문·행 간격.
struct NoteRowContent<Details: View>: View {
    let title: String
    @ViewBuilder let details: () -> Details

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.mgFg)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            details()
        }
        .padding(.vertical, 12)
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

/// 모든 목록 행의 보조 동작은 같은 크기의 더 보기 버튼에 모은다.
struct NoteRowMenu<Actions: View>: View {
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        Menu { actions() } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.mgFg3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .menuStyle(.button)
        .accessibilityLabel("노트 메뉴")
    }
}

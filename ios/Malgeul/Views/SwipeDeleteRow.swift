import SwiftUI

/// 시스템 swipeActions는 누르면 닫히므로, 두 번 누르는 동안 유지되는 고정 삭제 영역을 쓴다.
struct SwipeDeleteRow<Content: View>: View {
    let target: String
    @Binding var confirmation: TwoTapDeletion
    var disabled = false
    var background: Color = .white
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var offset: CGFloat = 0
    @State private var dragStart: CGFloat?
    private let actionWidth: CGFloat = 120

    var body: some View {
        content()
            .frame(maxWidth: .infinity)
            .background(background)
            .offset(x: offset)
            .background(alignment: .trailing) {
                Button {
                    // 첫 누름에서는 위치·너비·펼친 상태를 절대 바꾸지 않는다.
                    if confirmation.tap(target) {
                        offset = 0
                        onDelete()
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "trash").font(.system(size: 18))
                        ZStack {
                            Text("한 번 더\n눌러 삭제").hidden().accessibilityHidden(true)
                            Text(confirmation.isArmed(target) ? "한 번 더\n눌러 삭제" : "삭제")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                    .frame(width: actionWidth, height: nil)
                    .frame(maxHeight: .infinity)
                    .background(Color.mgDanger)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled || offset == 0)
                .accessibilityIdentifier("swipe-delete-button")
                .accessibilityLabel(confirmation.isArmed(target) ? "한 번 더 눌러 삭제" : "삭제")
                .accessibilityHidden(offset == 0)
                .opacity(offset == 0 ? 0 : 1)
            }
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { value in
                        guard !disabled, abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                        if dragStart == nil { dragStart = offset; confirmation.reset() }
                        offset = min(0, max(-actionWidth, (dragStart ?? 0) + value.translation.width))
                    }
                    .onEnded { _ in
                        guard dragStart != nil else { return }
                        dragStart = nil
                        withAnimation(.easeOut(duration: 0.18)) { offset = offset < -40 ? -actionWidth : 0 }
                        if offset == 0 { confirmation.reset() }
                    }
            )
            .task(id: confirmation.target) {
                guard confirmation.target == target else { return }
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                if confirmation.target == target { confirmation.reset() }
            }
            .onChange(of: confirmation.target) { _, next in
                if let next, next != target { offset = 0 }
            }
            .onChange(of: disabled) { _, value in if value { offset = 0; confirmation.reset() } }
    }
}

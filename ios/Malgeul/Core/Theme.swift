import SwiftUI

/// 웹과 같은 색·모양. 흰 바탕 + 회색 단계 + 남색 하나
extension Color {
    static let mgBg = Color.white
    static let mgBg2 = Color(hex: 0xF7F7F8)
    static let mgBg3 = Color(hex: 0xEFEFF2)
    static let mgLine = Color(hex: 0xE8E8EC)
    static let mgLine2 = Color(hex: 0xD8D8DE)
    static let mgFg = Color(hex: 0x18181B)
    static let mgFg2 = Color(hex: 0x52525B)
    static let mgFg3 = Color(hex: 0x8B8B94)
    static let mgFg4 = Color(hex: 0xB4B4BC)
    static let mgAccentWeak = Color(hex: 0xEEF1FD)
    static let mgDanger = Color(hex: 0xE5484D)
    static let mgMark = Color(hex: 0xFFF1A8)
}

/// 웹의 분할 탭 (회색 바탕 + 흰 선택칸)
struct WebSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var badge: T? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { (i: Int) in
                let v = options[i].0
                let label = options[i].1
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = v }
                } label: {
                    HStack(spacing: 6) {
                        Text(label)
                        if badge == v { Circle().fill(Color.accentMalgeul).frame(width: 6, height: 6) }
                    }
                    .font(.system(size: 15, weight: selection == v ? .semibold : .medium))
                    .foregroundStyle(selection == v ? Color.mgFg : Color.mgFg2)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background {
                        if selection == v {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white)
                                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == v ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.mgBg3, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 웹 버튼 모양
struct WebButtonStyle: ButtonStyle {
    enum Kind { case primary, ghost, danger }
    var kind: Kind = .primary
    var small = false
    var full = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 14 : 15, weight: kind == .ghost ? .medium : .semibold))
            .foregroundStyle(kind == .ghost ? Color.mgFg2 : Color.white)
            .padding(.horizontal, small ? 12 : 16)
            .frame(minHeight: small ? 32 : 40)
            .frame(maxWidth: full ? .infinity : nil)
            .background {
                let r = RoundedRectangle(cornerRadius: small ? 8 : 10, style: .continuous)
                switch kind {
                case .primary: r.fill(Color.accentMalgeul.opacity(configuration.isPressed ? 0.85 : 1))
                case .danger: r.fill(Color.mgDanger)
                case .ghost: r.fill(configuration.isPressed ? Color.mgBg2 : Color.white).overlay(r.stroke(Color.mgLine2, lineWidth: 1))
                }
            }
            .opacity(enabled ? 1 : 0.45)
    }
}

/// 웹의 작은 테두리 표시 (예: 추정, 수정본)
struct Pill: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.mgFg3)
            .padding(.horizontal, 5).frame(height: 18)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.mgLine2, lineWidth: 1))
    }
}

/// 줄바꿈 배치 (칩 목록)
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > w { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, w), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // 줄마다 가운데 정렬
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > bounds.width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, sz)); x += sz.width + spacing
        }
        var y = bounds.minY
        for r in rows {
            let w = r.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(r.count - 1, 0))
            var xx = bounds.minX + max(0, (bounds.width - w) / 2)
            let h = r.map(\.1.height).max() ?? 0
            for (i, sz) in r {
                subviews[i].place(at: CGPoint(x: xx, y: y), proposal: ProposedViewSize(sz))
                xx += sz.width + spacing
            }
            y += h + spacing
        }
    }
}

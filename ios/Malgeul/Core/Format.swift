import Foundation
import SwiftUI

enum Fmt {
    static func duration(_ sec: Int?) -> String {
        guard let sec, sec > 0 else { return "—" }
        let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func totalDuration(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)시간 \(m)분" : "\(m)분"
    }

    static func size(_ b: Int?) -> String {
        guard let b, b > 0 else { return "—" }
        return b >= 1_048_576 ? String(format: "%.1f MB", Double(b) / 1_048_576) : String(format: "%.0f KB", Double(b) / 1024)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    static func date(_ d: Date?) -> String { d.map { dateFmt.string(from: $0) } ?? "—" }

    /// 웹과 같은 상대 시각: N초 전 / N분 전 / N시간 전 / N일 전
    static func relative(_ d: Date?, now: Date = .now) -> String {
        guard let d else { return "—" }
        let diff = max(0, Int(now.timeIntervalSince(d)))
        if diff < 60 { return "\(diff)초 전" }
        if diff < 3600 { return "\(diff / 60)분 전" }
        if diff < 86400 { return "\(diff / 3600)시간 전" }
        return "\(diff / 86400)일 전"
    }

    static func usd(_ v: Double) -> String { String(format: "$%.4f", v) }

    static func krw(_ usd: Double, rate: Double?) -> String? {
        guard let rate else { return nil }
        let n = NumberFormatter()
        n.numberStyle = .decimal
        n.locale = Locale(identifier: "ko_KR")
        return (n.string(from: NSNumber(value: Int((usd * rate).rounded()))) ?? "") + "원"
    }

    static func number(_ v: Double) -> String {
        let n = NumberFormatter()
        n.numberStyle = .decimal
        n.locale = Locale(identifier: "ko_KR")
        return n.string(from: NSNumber(value: Int(v.rounded()))) ?? ""
    }

    /// 스크립트 타임스탬프 (m:ss)
    static func timestamp(_ ms: Int?) -> String? {
        guard let ms else { return nil }
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

extension ShapeStyle where Self == Color {
    /// 웹과 같은 강조색 #D4622A
    static var accentMalgeul: Color { Color(red: 0xD4 / 255, green: 0x62 / 255, blue: 0x2A / 255) }
}

extension Color {

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// 웹과 같은 화자 색 순서
enum SpeakerPalette {
    static let colors: [UInt32] = [0xD4622A, 0x2563EB, 0x16A34A, 0x9333EA, 0xCA8A04, 0x0891B2, 0xDB2777, 0x65A30D]
    static func color(_ speaker: String, in all: [String]) -> Color {
        let i = all.firstIndex(of: speaker) ?? 0
        return Color(hex: colors[i % colors.count])
    }
}

/// 태그 색 (웹과 동일 5색 순환)
enum TagPalette {
    static let colors: [UInt32] = [0xD4622A, 0x2563EB, 0x16A34A, 0x9333EA, 0xCA8A04]
    static func color(_ i: Int) -> Color { Color(hex: colors[i % colors.count]) }
}

enum StatusInfo {
    static func label(_ s: String) -> String {
        switch s {
        case "pending": return "대기"
        case "processing": return "받아쓰기 중"
        case "done": return "완료"
        case "error": return "오류"
        default: return s
        }
    }
    static func color(_ s: String) -> Color {
        switch s {
        case "processing": return .blue
        case "done": return .green
        case "error": return .red
        default: return .secondary
        }
    }
}

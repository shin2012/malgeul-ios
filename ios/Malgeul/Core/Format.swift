import Foundation
import SwiftUI

enum Fmt {
    static func duration(_ sec: Int?) -> String {
        guard let sec, sec > 0 else { return "—" }
        let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 46분 34초 / 1시간 3분
    static func durationKo(_ sec: Int) -> String {
        let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
        if h > 0 { return "\(h)시간 \(m)분" }
        if m > 0 { return s > 0 ? "\(m)분 \(s)초" : "\(m)분" }
        return "\(s)초"
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

    private static let whenFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 (E) a h:mm"
        return f
    }()
    private static let whenYearFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 (E) a h:mm"
        return f
    }()
    /// 목록 날짜 묶음: 오늘 · 어제 · 이번 주 · 지난주 · 이번 달 · N월 (웹과 같음)
    static func groupLabel(_ d: Date, now: Date = .now) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "ko_KR")
        cal.firstWeekday = 2
        let day = cal.startOfDay(for: d), today = cal.startOfDay(for: now)
        let diff = cal.dateComponents([.day], from: day, to: today).day ?? 0
        if diff <= 0 { return "오늘" }
        if diff == 1 { return "어제" }
        let wk = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        if day >= wk { return "이번 주" }
        if let lastWk = cal.date(byAdding: .day, value: -7, to: wk), day >= lastWk { return "지난주" }
        let y = cal.component(.year, from: d), m = cal.component(.month, from: d)
        if y == cal.component(.year, from: now) && m == cal.component(.month, from: now) { return "이번 달" }
        return y == cal.component(.year, from: now) ? "\(m)월" : "\(y)년 \(m)월"
    }

    /// 11월 4일 (수) 오전 10:00 — 올해가 아니면 연도 포함 (웹과 같음)
    static func when(_ d: Date?) -> String {
        guard let d else { return "" }
        let sameYear = Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: .now)
        return (sameYear ? whenFmt : whenYearFmt).string(from: d)
    }

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
    /// 웹과 같은 강조색 #3451D1 (남색)
    static var accentMalgeul: Color { Color(red: 0x34 / 255, green: 0x51 / 255, blue: 0xD1 / 255) }
}

extension Color {

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// 화자 라벨 해석 (웹 parseSpeaker와 같음)
///  "김용섭이사(프레임아웃, 추정)" → 이름 "김용섭 이사", 소속 "프레임아웃", 추정
///  "Speaker A" → "화자 A"
struct SpeakerName {
    let name: String
    let org: String
    let guess: Bool
    let initial: String
    /// 이름(소속) — 추정 표시 없이
    var display: String { org.isEmpty ? name : "\(name)(\(org))" }

    /// 이름 고칠 때 입력칸에 넣을 값: 익명은 빈칸, '추정'만 떼고 원래 라벨
    static func editable(_ raw: String) -> String {
        if raw.range(of: #"^(?i)speaker\s+\w+$"#, options: .regularExpression) != nil { return "" }
        return raw.replacingOccurrences(of: #"\s*\(\s*추정\s*\)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #",\s*추정\)$"#, with: ")", options: .regularExpression)
    }

    init(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if let m = t.wholeMatch(of: #/(?i)speaker\s+([A-Z0-9]+)/#) {
            name = "화자 \(m.1)"; org = ""; guess = false; initial = String(m.1); return
        }
        var n = t, o = "", g = false
        if let m = t.wholeMatch(of: #/(.*?)\s*\((.*)\)\s*/#) {
            n = String(m.1)
            let parts = m.2.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            g = parts.contains("추정")
            o = parts.filter { $0 != "추정" }.joined(separator: ", ")
        }
        if let m = n.wholeMatch(of: #/([가-힣]{2,4}?)(이사|팀장|부장|과장|차장|대리|사원|실장|처장|본부장|대표|선생님|주임|책임|선임|수석|위원|소장|원장|교수|박사)/#) {
            n = "\(m.1) \(m.2)"
        }
        name = n.isEmpty ? t : n; org = o; guess = g
        initial = String((n.isEmpty ? t : n).prefix(1))
    }
}

/// 이니셜 원형 (회색)
struct SpeakerAvatar: View {
    let initial: String
    var size: CGFloat = 30
    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Color(.tertiarySystemFill), in: Circle())
    }
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
        case "processing": return .accentMalgeul
        case "error": return .red
        default: return .secondary
        }
    }
}

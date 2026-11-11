import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

// 잠금 화면·다이내믹 아일랜드 녹음 표시 화면 (위젯 확장이 쓰고, 앱은 DEBUG 점검 화면에서 같은 화면을 그림)

enum LiveColors {
    static let navy = Color(red: 0x34 / 255, green: 0x51 / 255, blue: 0xD1 / 255)
    /// 어두운 바탕용 밝은 남색
    static let navyLight = Color(red: 0x8F / 255, green: 0xA3 / 255, blue: 0xFF / 255)
    static let rec = Color(red: 0.93, green: 0.26, blue: 0.24)
    static func accent(_ s: ColorScheme) -> Color { s == .dark ? navyLight : navy }
}

/// 화면에 보일 상태 (앱이 한동안 확인을 못 하면 '확인 안 됨')
enum LiveShown {
    case recording(Date, TimeInterval), paused(TimeInterval), interrupted(TimeInterval), stopped(TimeInterval), unknown

    init(_ s: RecordingActivityAttributes.ContentState, stale: Bool) {
        switch s.phase {
        case .recording: self = stale ? .unknown : .recording(s.timerStart, s.elapsed)
        case .paused: self = .paused(s.elapsed)
        case .interrupted: self = .interrupted(s.elapsed)
        case .stopped: self = .stopped(s.elapsed)
        }
    }

    var label: String {
        switch self {
        case .recording: "녹음 중"
        case .paused: "일시정지됨"
        case .interrupted: "잠시 멈춤 · 통화 끝나면 이어 녹음"
        case .stopped: "녹음이 멈췄어요 · 앱을 열어 확인"
        case .unknown: "상태 확인 안 됨 · 앱을 열어 확인"
        }
    }

    var shortLabel: String {
        switch self {
        case .recording: "녹음 중"
        case .paused: "일시정지"
        case .interrupted: "잠시 멈춤"
        case .stopped: "멈춤"
        case .unknown: "확인 안 됨"
        }
    }

    func color(_ s: ColorScheme) -> Color {
        switch self {
        case .recording: LiveColors.rec
        case .paused, .interrupted: .orange
        case .stopped, .unknown: s == .dark ? Color(white: 0.7) : Color(white: 0.4)
        }
    }

    var symbol: String {
        switch self {
        case .recording: "mic.fill"
        case .paused, .interrupted: "pause.fill"
        case .stopped: "stop.fill"
        case .unknown: "exclamationmark.triangle.fill"
        }
    }

    var canToggle: Bool {
        switch self {
        case .recording, .paused: true
        default: false
        }
    }

    var isPaused: Bool { if case .paused = self { return true } else { return false } }
}

struct LiveTimeText: View {
    let shown: LiveShown
    /// 잠금 화면이 어두워진 상태(상시 표시)에선 초 단위 타이머 대신 앱이 마지막으로 알려 준 분을 보여 줌
    @Environment(\.isLuminanceReduced) private var dimmed
    var body: some View {
        switch shown {
        case .recording(let start, let elapsed):
            if dimmed {
                Text(elapsed < 60 ? "1분 미만" : "\(Int(elapsed / 60))분째")
            } else {
                Text(timerInterval: start...start.addingTimeInterval(24 * 3600), countsDown: false)
                    .monospacedDigit()
            }
        case .paused(let t), .interrupted(let t), .stopped(let t):
            Text(LiveFormat.duration(t)).monospacedDigit()
        case .unknown:
            Text("--:--").monospacedDigit()
        }
    }
}

struct LiveToggleButton: View {
    let shown: LiveShown
    let scheme: ColorScheme
    var body: some View {
        Button(intent: ToggleRecordingPauseIntent()) {
            HStack(spacing: 5) {
                Image(systemName: shown.isPaused ? "record.circle" : "pause.fill")
                Text(shown.isPaused ? "계속" : "일시정지")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(shown.isPaused ? LiveColors.rec : LiveColors.accent(scheme)))
        }
        .buttonStyle(.plain)
    }
}

/// 잠금 화면 (알림 목록 위 카드)
struct LiveLockScreenView: View {
    let state: RecordingActivityAttributes.ContentState
    let title: String
    let stale: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shown = LiveShown(state, stale: stale)
        let c = shown.color(scheme)
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(c.opacity(scheme == .dark ? 0.25 : 0.15))
                Image(systemName: shown.symbol).foregroundStyle(c)
                    .font(.system(size: 18, weight: .semibold))
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(shown.label).font(.footnote.weight(.semibold)).foregroundStyle(c).lineLimit(1)
                LiveTimeText(shown: shown).font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("말글 · \(title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if shown.canToggle { LiveToggleButton(shown: shown, scheme: scheme) }
        }
        .padding(16)
    }

    /// 잠금 화면 카드 바탕 (주간: 밝은 반투명, 다크: 어두운 반투명)
    static func background(_ s: ColorScheme) -> Color {
        s == .dark ? Color.black.opacity(0.55) : Color.white.opacity(0.8)
    }
}

/// 다이내믹 아일랜드 펼친 모양 왼쪽: 상태 아이콘 + 말글 · 상태 (바탕은 항상 검정)
struct LiveIslandLeading: View {
    let shown: LiveShown
    var body: some View {
        let c = shown.color(.dark)
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(c.opacity(0.25))
                Image(systemName: shown.symbol).foregroundStyle(c).font(.system(size: 15, weight: .semibold))
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("말글").font(.caption).foregroundStyle(Color(white: 0.6))
                Text(shown.shortLabel).font(.subheadline.weight(.semibold)).foregroundStyle(c).lineLimit(1)
            }
        }
        .frame(maxHeight: .infinity, alignment: .leading)
    }
}

/// 다이내믹 아일랜드 펼친 모양 아래: 녹음 제목·안내 + 일시정지/계속 버튼
struct LiveIslandExpandedBottom: View {
    let shown: LiveShown
    var title: String = ""
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if !title.isEmpty {
                    Text(title).font(.footnote).foregroundStyle(Color(white: 0.85)).lineLimit(1)
                }
                if !shown.canToggle {
                    Text(shown.label).font(.caption).foregroundStyle(Color(white: 0.6)).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if shown.canToggle { LiveToggleButton(shown: shown, scheme: .dark) }
        }
    }
}

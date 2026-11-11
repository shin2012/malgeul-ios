import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

@main
struct MalgeulWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

private let navy = Color(red: 0x34 / 255, green: 0x51 / 255, blue: 0xD1 / 255)
private let rec = Color(red: 0.90, green: 0.22, blue: 0.21)

/// 화면에 보일 상태 (앱이 한동안 확인을 못 하면 '확인 안 됨')
private enum Shown {
    case recording(Date), paused(TimeInterval), interrupted(TimeInterval), stopped(TimeInterval), unknown(Date)

    init(_ s: RecordingActivityAttributes.ContentState, stale: Bool) {
        switch s.phase {
        case .recording: self = stale ? .unknown(s.checkedAt) : .recording(s.timerStart)
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

    var color: Color {
        switch self {
        case .recording: rec
        case .paused, .interrupted: .orange
        case .stopped, .unknown: .gray
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

private struct TimeText: View {
    let shown: Shown
    var body: some View {
        switch shown {
        case .recording(let start):
            Text(start, style: .timer).monospacedDigit()
        case .paused(let t), .interrupted(let t), .stopped(let t):
            Text(LiveFormat.duration(t)).monospacedDigit()
        case .unknown:
            Text("--:--").monospacedDigit()
        }
    }
}

private struct ToggleButton: View {
    let shown: Shown
    var body: some View {
        Button(intent: ToggleRecordingPauseIntent()) {
            Label(shown.isPaused ? "계속" : "일시정지", systemImage: shown.isPaused ? "record.circle" : "pause.fill")
                .font(.subheadline.weight(.semibold))
                .labelStyle(.titleAndIcon)
        }
        .tint(shown.isPaused ? rec : navy)
    }
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            let shown = Shown(context.state, stale: context.isStale)
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(shown.color.opacity(0.15))
                    Image(systemName: shown.symbol).foregroundStyle(shown.color)
                        .font(.system(size: 18, weight: .semibold))
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shown.label).font(.footnote.weight(.semibold)).foregroundStyle(shown.color)
                    TimeText(shown: shown).font(.system(size: 30, weight: .semibold))
                    Text(context.attributes.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if shown.canToggle { ToggleButton(shown: shown) }
            }
            .padding(16)
            .activityBackgroundTint(Color.white.opacity(0.85))
            .activitySystemActionForegroundColor(navy)
            .widgetURL(URL(string: "malgeul://record"))
        } dynamicIsland: { context in
            let shown = Shown(context.state, stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("말글", systemImage: shown.symbol).foregroundStyle(shown.color).font(.subheadline.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimeText(shown: shown).font(.title3.weight(.semibold)).frame(maxWidth: 90, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(shown.label).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if shown.canToggle { ToggleButton(shown: shown) }
                    }
                }
            } compactLeading: {
                Image(systemName: shown.symbol).foregroundStyle(shown.color)
            } compactTrailing: {
                TimeText(shown: shown).frame(maxWidth: 52).foregroundStyle(shown.color)
            } minimal: {
                Image(systemName: shown.symbol).foregroundStyle(shown.color)
            }
            .widgetURL(URL(string: "malgeul://record"))
            .keylineTint(shown.color)
        }
    }
}

import SwiftUI
import WidgetKit
import ActivityKit

@main
struct MalgeulWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

/// 잠금 화면 카드: 주간/다크에 맞춰 바탕색을 고름
private struct LockScreenCard: View {
    let context: ActivityViewContext<RecordingActivityAttributes>
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LiveLockScreenView(state: context.state, title: context.attributes.title, stale: context.isStale)
            .activityBackgroundTint(LiveLockScreenView.background(scheme))
            .activitySystemActionForegroundColor(LiveColors.accent(scheme))
            .widgetURL(URL(string: "malgeul://record"))
    }
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenCard(context: context)
        } dynamicIsland: { context in
            let shown = LiveShown(context.state, stale: context.isStale)
            let c = shown.color(.dark)
            return DynamicIsland {
                // 펼친 모양: 왼쪽 아이콘·상태 / 오른쪽 시간 / 아래 제목·버튼 — 가장자리와 줄 사이 여백을 넉넉히
                DynamicIslandExpandedRegion(.leading) {
                    LiveIslandLeading(shown: shown)
                        .padding(.leading, 6).padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveTimeText(shown: shown).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: 110, maxHeight: .infinity, alignment: .trailing)
                        .padding(.trailing, 6).padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveIslandExpandedBottom(shown: shown, title: context.attributes.title)
                        .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 4)
                }
            } compactLeading: {
                Image(systemName: shown.symbol).foregroundStyle(c)
            } compactTrailing: {
                LiveTimeText(shown: shown).frame(maxWidth: 52).foregroundStyle(c)
            } minimal: {
                Image(systemName: shown.symbol).foregroundStyle(c)
            }
            .contentMargins(.all, 16, for: .expanded)
            .widgetURL(URL(string: "malgeul://record"))
            .keylineTint(c)
        }
    }
}

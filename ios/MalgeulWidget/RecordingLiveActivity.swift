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
                DynamicIslandExpandedRegion(.leading) {
                    Label("말글", systemImage: shown.symbol).foregroundStyle(c).font(.subheadline.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveTimeText(shown: shown).font(.title3.weight(.semibold)).foregroundStyle(.white)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveIslandExpandedBottom(shown: shown)
                }
            } compactLeading: {
                Image(systemName: shown.symbol).foregroundStyle(c)
            } compactTrailing: {
                LiveTimeText(shown: shown).frame(maxWidth: 52).foregroundStyle(c)
            } minimal: {
                Image(systemName: shown.symbol).foregroundStyle(c)
            }
            .widgetURL(URL(string: "malgeul://record"))
            .keylineTint(c)
        }
    }
}

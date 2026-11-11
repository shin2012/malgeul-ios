#if DEBUG
import SwiftUI
import ActivityKit

/// CI 점검용(DEBUG): 잠금 화면·다이내믹 아일랜드 녹음 표시를 상태별로 그려 봄 (-screen live / livedark)
struct LivePreviewView: View {
    @Environment(\.colorScheme) private var scheme

    private var samples: [(String, RecordingActivityAttributes.ContentState, Bool)] {
        let now = Date.now
        func st(_ p: RecordingActivityAttributes.ContentState.Phase, _ e: TimeInterval) -> RecordingActivityAttributes.ContentState {
            .init(phase: p, timerStart: now - e, elapsed: e, checkedAt: now)
        }
        return [
            ("녹음 중", st(.recording, 754), false),
            ("일시정지", st(.paused, 1830), false),
            ("통화로 멈춤", st(.interrupted, 2412), false),
            ("녹음 멈춤", st(.stopped, 3725), false),
            ("확인 끊김", st(.recording, 600), true),
        ]
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: scheme == .dark ? [Color(red: 0.08, green: 0.1, blue: 0.2), Color(red: 0.25, green: 0.1, blue: 0.3)]
                                                   : [Color(red: 0.55, green: 0.75, blue: 0.95), Color(red: 0.95, green: 0.8, blue: 0.7)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 10) {
                    Text(scheme == .dark ? "다크 모드" : "주간 모드").font(.headline).foregroundStyle(.white)
                    ForEach(samples, id: \.0) { s in
                        LiveLockScreenView(state: s.1, title: "11월 11일 14:05 시작", stale: s.2)
                            .background(.ultraThinMaterial)
                            .background(LiveLockScreenView.background(scheme))
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    // 다이내믹 아일랜드 펼침 · 좁은 모양
                    VStack(spacing: 8) {
                        HStack {
                            Label("말글", systemImage: "mic.fill").foregroundStyle(LiveColors.rec).font(.subheadline.weight(.semibold))
                            Spacer()
                            LiveTimeText(shown: .recording(.now - 754, 754)).font(.title3.weight(.semibold)).foregroundStyle(.white)
                        }
                        LiveIslandExpandedBottom(shown: .recording(.now - 754, 754))
                    }
                    .padding(16)
                    .background(Capsule(style: .continuous).fill(.black))
                    .environment(\.colorScheme, .dark)
                    HStack(spacing: 40) {
                        Image(systemName: "mic.fill").foregroundStyle(LiveColors.rec)
                        LiveTimeText(shown: .recording(.now - 754, 754)).foregroundStyle(LiveColors.rec).frame(maxWidth: 52)
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Capsule().fill(.black))
                }
                .padding(.horizontal, 12)
            }
        }
    }
}
#endif

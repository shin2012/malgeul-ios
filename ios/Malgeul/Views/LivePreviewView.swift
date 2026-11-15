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
                    // 다이내믹 아일랜드 펼침 (실제 여백 16 + 칸 여백과 같게)
                    ForEach([LiveShown.recording(.now - 754, 754), .paused(37265), .unknown], id: \.shortLabel) { sh in
                        VStack(spacing: 0) {
                            HStack(alignment: .center) {
                                LiveIslandLeading(shown: sh).padding(.leading, 6).padding(.top, 6)
                                Spacer()
                                LiveTimeText(shown: sh).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                    .frame(maxWidth: 110, alignment: .trailing).frame(height: 40)
                                    .padding(.trailing, 6).padding(.top, 6)
                            }
                            LiveIslandExpandedBottom(shown: sh, title: "11월 11일 14:05 시작")
                                .padding(.horizontal, 6).padding(.top, 8)
                        }
                        .padding(16)
                        .frame(maxWidth: 373)
                        .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(.black))
                    }
                    .environment(\.colorScheme, .dark)
                    ForEach(samples, id: \.0) { s in
                        LiveLockScreenView(state: s.1, title: "11월 11일 14:05 시작", stale: s.2)
                            .background(.ultraThinMaterial)
                            .background(LiveLockScreenView.background(scheme))
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    HStack(spacing: 40) {
                        Image(systemName: "mic.fill").foregroundStyle(LiveColors.rec)
                        LiveTimeText(shown: .recording(.now - 754, 754))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .foregroundStyle(LiveColors.rec).frame(maxWidth: 52)
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

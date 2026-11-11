import SwiftUI

enum AppTab: Hashable { case meetings, record, settings }

/// 화면 이동 상태 (탭 · 선택한 회의)
@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    @Published var tab: AppTab = .meetings
    @Published var meetingID: Int?
    /// 녹음 탭으로 가면서 바로 녹음 시작
    @Published var startRecordingRequest = false
    /// 스크린샷용(DEBUG): 상세 화면에서 채팅·문서 바로 열기
    var debugOpenChat = false
    var debugOpenDoc = false
}

#if DEBUG
/// CI 스크린샷용: -demoServer URL -demoToken T -screen 이름
@MainActor
enum DebugRoute {
    /// -screen live / livedark: 잠금 화면 표시 점검 화면
    static var livePreview: ColorScheme?

    static func apply() {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "demoServer") { AppConfig.shared.server = s; AppConfig.shared.tailscaleServer = "" }
        if let t = d.string(forKey: "demoToken") { AppConfig.shared.token = t }
        let r = Router.shared
        switch d.string(forKey: "screen") ?? "" {
        case "detail": r.meetingID = 5
        case "chat": r.meetingID = 5; r.debugOpenChat = true
        case "doc": r.meetingID = 5; r.debugOpenDoc = true
        case "record": r.tab = .record
        case "settings": r.tab = .settings
        case "live": livePreview = .light
        case "livedark": livePreview = .dark
        case "real", "realdark":
            // 실제 라이브 액티비티를 띄움 (녹음은 하지 않음)
            LiveRecording.shared.start(title: "11월 11일 14:05 시작", startedAt: .now - 754)
        default: break
        }
    }
}
#endif

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 백그라운드 업로드 세션을 앱 시작 때 다시 연결해 둠 (끝난 업로드 결과 수신)
        Task { @MainActor in _ = UploadCenter.shared }
        // 애플워치 녹음 받기 (앱이 꺼져 있으면 시스템이 백그라운드로 깨워 전달)
        WatchLink.shared.activate()
        // 잠금 화면 녹음 표시: 버튼 연결 + 지난번에 남은 표시 정리
        MainActor.assumeIsolated {
            LiveRecordingActions.handler = { cmd in
                switch cmd {
                case .togglePause: Recorder.shared.togglePause()
                }
            }
            LiveRecording.shared.cleanUpLeftovers(recording: Recorder.shared.isActive)
        }
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        MainActor.assumeIsolated { Recorder.shared.appWillTerminate() }
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in UploadCenter.shared.backgroundCompletion = completionHandler }
    }
}

@main
struct MalgeulApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var config = AppConfig.shared
    @StateObject private var router = Router.shared
    @StateObject private var store = MeetingStore.shared
    @StateObject private var uploads = UploadCenter.shared
    @StateObject private var recorder = Recorder.shared
    @StateObject private var recordings = RecordingStore.shared
    @StateObject private var player = AudioPlayer.shared
    @StateObject private var device = OnDeviceJobCenter.shared
    @StateObject private var voices = VoiceProfiles.shared

    init() {
        #if DEBUG
        DebugRoute.apply()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(config)
                .environmentObject(router)
                .environmentObject(store)
                .environmentObject(uploads)
                .environmentObject(recorder)
                .environmentObject(recordings)
                .environmentObject(player)
                .environmentObject(device)
                .environmentObject(voices)
                .tint(.accentMalgeul)
                .preferredColorScheme(.light)
                .onOpenURL(perform: handle)
                #if DEBUG
                .overlay {
                    if let sc = DebugRoute.livePreview {
                        LivePreviewView().environment(\.colorScheme, sc)
                    }
                }
                #endif
        }
    }

    private func handle(_ url: URL) {
        if url.isFileURL {
            // 다른 앱(음성 메모·파일 등)에서 '말글로 열기'/공유
            router.tab = .meetings
            uploads.enqueueImported(url)
            return
        }
        if config.handleSetupURL(url) {
            router.tab = .meetings
            Task { await store.refresh() }
            return
        }
        // malgeul://record (잠금 화면 녹음 표시를 누름)
        if url.scheme == "malgeul", url.host == "record" {
            router.tab = .record
            return
        }
        // malgeul://meeting/123
        if url.scheme == "malgeul", url.host == "meeting", let id = Int(url.lastPathComponent) {
            router.tab = .meetings
            router.meetingID = id
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var config: AppConfig
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var recordings: RecordingStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var uploads: UploadCenter
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var device: OnDeviceJobCenter

    @Environment(\.horizontalSizeClass) private var hsize

    var body: some View {
        root
            .onChange(of: scenePhase) { _, phase in
                // 앱으로 돌아오면 목록을 새로 받음 (다른 기기·웹에서 바뀐 내용 반영)
                guard phase == .active else { return }
                recordings.reload()
                Task {
                    if config.isConfigured { await store.refresh() }
                    OnDeviceJobCenter.shared.resume()   // 공유 확장이 넣어 둔 파일 가져오기 · 기기 받아쓰기 · 멈춘 작업 이어서
                }
            }
            .modifier(RootAlerts())
    }

    private var root: some View {
        MeetingsSplitView()
            .sheet(isPresented: Binding(get: { router.tab == .record }, set: { if !$0 { router.tab = .meetings } })) {
                RecordTabView()
            }
            .sheet(isPresented: Binding(get: { router.tab == .settings }, set: { if !$0 { router.tab = .meetings } })) {
                SettingsView()
            }
    }
}

/// 업로드·기기 처리·재생 오류 알림 (아이폰·아이패드 공통)
private struct RootAlerts: ViewModifier {
    @EnvironmentObject private var uploads: UploadCenter
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var device: OnDeviceJobCenter

    func body(content: Content) -> some View {
        content
        .alert("중복 파일", isPresented: Binding(get: { uploads.duplicateTitle != nil }, set: { if !$0 { uploads.duplicateTitle = nil } })) {
            Button("확인", role: .cancel) { uploads.duplicateTitle = nil }
        } message: {
            Text("이미 같은 파일이 업로드되어 있습니다.\n기존 파일: \(uploads.duplicateTitle ?? "")")
        }
        .alert("오류", isPresented: Binding(get: { uploads.errorAlert != nil }, set: { if !$0 { uploads.errorAlert = nil } })) {
            Button("확인", role: .cancel) { uploads.errorAlert = nil }
        } message: {
            Text(uploads.errorAlert ?? "")
        }
        .alert("기기 처리", isPresented: Binding(get: { device.lastError != nil }, set: { if !$0 { device.lastError = nil } })) {
            Button("확인", role: .cancel) { device.lastError = nil }
        } message: {
            Text(device.lastError ?? "")
        }
        .alert("재생", isPresented: Binding(get: { player.lastError != nil }, set: { if !$0 { player.lastError = nil } })) {
            Button("확인", role: .cancel) { player.lastError = nil }
        } message: {
            Text(player.lastError ?? "")
        }
    }
}

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
        default: break
        }
    }
}
#endif

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 백그라운드 업로드 세션을 앱 시작 때 다시 연결해 둠 (끝난 업로드 결과 수신)
        Task { @MainActor in _ = UploadCenter.shared }
        return true
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
                .onOpenURL(perform: handle)
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

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("회의", systemImage: "text.bubble", value: AppTab.meetings) {
                MeetingsSplitView()
            }
            .badge(uploads.jobs.filter { $0.state != .failed }.count)

            Tab("녹음", systemImage: recorder.isActive ? "record.circle.fill" : "mic", value: AppTab.record) {
                RecordTabView()
            }
            .badge(recorder.isActive ? Text("●") : nil)

            Tab("설정", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: scenePhase) { _, phase in
            // 앱으로 돌아오면 목록을 새로 받음 (다른 기기·웹에서 바뀐 내용 반영)
            guard phase == .active else { return }
            recordings.reload()
            if config.isConfigured {
                Task {
                    await store.refresh()
                    OnDeviceJobCenter.shared.resume()   // 공유 확장이 맡긴 기기 받아쓰기·멈춘 작업 이어서
                }
            }
        }
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

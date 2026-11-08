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
}

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
struct JulgloApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var config = AppConfig.shared
    @StateObject private var router = Router.shared
    @StateObject private var store = MeetingStore.shared
    @StateObject private var uploads = UploadCenter.shared
    @StateObject private var recorder = Recorder.shared
    @StateObject private var recordings = RecordingStore.shared
    @StateObject private var player = AudioPlayer.shared

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
                .tint(.accentJulglo)
                .onOpenURL(perform: handle)
        }
    }

    private func handle(_ url: URL) {
        if url.isFileURL {
            // 다른 앱(음성 메모·파일 등)에서 '줄글로로 열기'/공유
            router.tab = .meetings
            uploads.enqueueImported(url)
            return
        }
        if config.handleSetupURL(url) {
            router.tab = .meetings
            Task { await store.refresh() }
            return
        }
        // julglo://meeting/123
        if url.scheme == "julglo", url.host == "meeting", let id = Int(url.lastPathComponent) {
            router.tab = .meetings
            router.meetingID = id
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var uploads: UploadCenter
    @EnvironmentObject private var player: AudioPlayer

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
        .alert("재생", isPresented: Binding(get: { player.lastError != nil }, set: { if !$0 { player.lastError = nil } })) {
            Button("확인", role: .cancel) { player.lastError = nil }
        } message: {
            Text(player.lastError ?? "")
        }
    }
}

import SwiftUI
import AVFoundation

enum AppTab: Hashable { case meetings, record, settings }

/// 화면 이동 상태 (탭 · 선택한 회의)
@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    @Published var tab: AppTab = .meetings
    @Published var meetingID: Int?
    /// 녹음 탭으로 가면서 바로 녹음 시작
    @Published var startRecordingRequest = false
    /// 로그인 화면 (로그인 안 했으면 앱을 열 때 띄움)
    @Published var showLogin = false
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
        // demoServer는 SharedSettings.server가 직접 읽음
        if let t = d.string(forKey: "demoToken") {
            AppConfig.shared.token = t
            AppConfig.shared.user = AccountUser(id: 1, email: "demo@example.com", name: "시험 사용자", role: "admin")
        }
        let r = Router.shared
        switch d.string(forKey: "screen") ?? "" {
        case "detail": r.meetingID = 5
        case "chat": r.meetingID = 5; r.debugOpenChat = true
        case "doc": r.meetingID = 5; r.debugOpenDoc = true
        case "record": r.tab = .record
        case "settings": r.tab = .settings
        case "login": AppConfig.shared.signOut(); r.showLogin = true
        case "uploadtest":
            // 조각 업로드 시험: 1분짜리 wav(약 2.8MB)를 만들어 올림 → 압축 → 가짜 서버의 작은 조각(100KB)으로 여러 번 전송
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let url = FileManager.default.temporaryDirectory.appending(path: "업로드시험.wav")
                let fmt = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
                if let f = try? AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000,
                                                                        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]),
                   let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 24_000 * 60) {
                    buf.frameLength = 24_000 * 60
                    let p = buf.floatChannelData![0]
                    for i in 0..<Int(buf.frameLength) { p[i] = 0.3 * sinf(Float(i) / 24_000 * 2 * .pi * 440) }
                    try? f.write(from: buf)
                }
                UploadCenter.shared.enqueue(file: url, filename: "업로드시험.wav", recordedAt: .now, autoTranscribe: true)
            }
        case "live": livePreview = .light
        case "livedark": livePreview = .dark
        case "real", "realdark":
            // 실제 라이브 액티비티를 띄움 (녹음은 하지 않음)
            LiveRecording.shared.start(title: "11월 11일 14:05 시작", startedAt: .now - 754, elapsed: 754)
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
            .fullScreenCover(isPresented: $router.showLogin) { LoginView() }
            .onAppear { if !config.isConfigured { router.showLogin = true } else { Task { await API.shared.refreshMe() } } }
            .onChange(of: config.token) { _, t in
                // 로그아웃·로그인 풀림 → 목록 비우고 로그인 화면
                if t.isEmpty { store.clear(); router.tab = .meetings; router.showLogin = true }
            }
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

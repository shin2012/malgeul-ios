import Foundation
import AVFoundation
import MediaPlayer

/// 회의 전체 재생(상세 화면 하단 플레이어) · 내 녹음 듣기 공용 플레이어
@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayer()

    @Published private(set) var playingKey: String?
    @Published private(set) var loadingKey: String?
    @Published private(set) var position: TimeInterval = 0
    @Published var lastError: String?

    // 회의 플레이어 상태
    @Published private(set) var meetingID: Int?
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var meetingLoading = false
    @Published var rate: Float = Float(UserDefaults.standard.double(forKey: "playRate")) == 0 ? 1 : Float(UserDefaults.standard.double(forKey: "playRate"))

    private var player: AVAudioPlayer?
    private var stopAt: TimeInterval?
    private var timer: Timer?
    private var meetingTitle = ""
    private var remoteReady = false

    // MARK: 회의 전체 재생

    /// 상세 화면이 열릴 때 호출. 다른 회의면 멈추고 상태 초기화 (파일은 처음 재생할 때 받음)
    func prepareMeeting(_ id: Int, title: String, duration fallback: Int?) {
        meetingTitle = title
        guard meetingID != id else { return }
        stop()
        meetingID = id
        duration = TimeInterval(fallback ?? 0)
        position = 0
    }

    func toggleMeeting() async {
        if isPlaying { pauseMeeting(); return }
        await playMeeting(from: nil)
    }

    /// from == nil 이면 지금 위치에서 이어서
    func playMeeting(from: TimeInterval?) async {
        guard let id = meetingID else { return }
        let key = "meeting-\(id)"
        if playingKey == key, let p = player {
            if let from { p.currentTime = max(0, min(from, p.duration)); position = p.currentTime }
            activateSession()
            p.play(); isPlaying = true; startTimer(); updateNowPlaying()
            return
        }
        meetingLoading = true
        defer { meetingLoading = false }
        do {
            let url = try await API.shared.audioFile(id)
            guard meetingID == id else { return }
            let start = from ?? position
            try play(url: url, from: start, to: nil, key: key)
            duration = player?.duration ?? duration
            isPlaying = true
            setupRemote()
            updateNowPlaying()
        } catch {
            if !error.isCancellation { lastError = "재생 실패: \(error.localizedDescription)" }
        }
    }

    func pauseMeeting() {
        player?.pause()
        isPlaying = false
        timer?.invalidate(); timer = nil
        updateNowPlaying()
    }

    func seek(to t: TimeInterval) {
        let v = max(0, min(t, duration > 0 ? duration : t))
        position = v
        if let p = player, playingKey == "meeting-\(meetingID ?? -1)" { p.currentTime = v; updateNowPlaying() }
    }

    func skip(_ d: TimeInterval) { seek(to: (player?.currentTime ?? position) + d) }

    func cycleRate() {
        let rates: [Float] = [1, 1.25, 1.5, 2, 0.75]
        let i = rates.firstIndex(of: rate) ?? 0
        rate = rates[(i + 1) % rates.count]
        UserDefaults.standard.set(Double(rate), forKey: "playRate")
        if let p = player, playingKey?.hasPrefix("meeting-") == true { p.rate = rate }
        updateNowPlaying()
    }

    /// 상세 화면을 떠날 때
    func leaveMeeting(_ id: Int) {
        guard meetingID == id else { return }
        stop()
        meetingID = nil
        duration = 0
    }

    // MARK: 내 녹음 듣기

    func toggleFile(_ url: URL, key: String) {
        if playingKey == key { stop(); return }
        stop()
        meetingID = nil
        do { try play(url: url, from: 0, to: nil, key: key) } catch { lastError = "재생 실패: \(error.localizedDescription)" }
    }

    // MARK: 공통

    private func activateSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio)
        try? s.setActive(true)
    }

    private func play(url: URL, from: TimeInterval, to: TimeInterval?, key: String) throws {
        if Recorder.shared.isActive {
            lastError = "녹음 중에는 재생할 수 없어요."
            return
        }
        player?.stop()
        activateSession()
        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.enableRate = true
        p.rate = key.hasPrefix("meeting-") ? rate : 1
        p.prepareToPlay()
        p.currentTime = from
        stopAt = to
        guard p.play() else { throw NSError(domain: "malgeul", code: 2, userInfo: [NSLocalizedDescriptionKey: "재생할 수 없습니다"]) }
        player = p
        playingKey = key
        position = from
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let p = player else { return }
        position = p.currentTime
        if let stopAt, p.currentTime >= stopAt { stop() }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        playingKey = nil
        stopAt = nil
        isPlaying = false
        position = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if !Recorder.shared.isActive { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.playingKey?.hasPrefix("meeting-") == true {
                self.isPlaying = false
                self.timer?.invalidate(); self.timer = nil
                self.position = self.duration
            } else {
                self.stop()
            }
        }
    }

    // MARK: 잠금 화면 · 제어 센터

    private func setupRemote() {
        guard !remoteReady else { return }
        remoteReady = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in await self?.playMeeting(from: nil) }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pauseMeeting() }; return .success }
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-10) }; return .success }
        c.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(10) }; return .success }
    }

    private func updateNowPlaying() {
        guard playingKey?.hasPrefix("meeting-") == true else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: meetingTitle,
            MPMediaItemPropertyArtist: "말글",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player?.currentTime ?? position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
        ]
    }
}

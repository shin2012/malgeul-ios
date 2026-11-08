import Foundation
import AVFoundation

/// 스크립트 구간 재생 · 내 녹음 듣기 공용 플레이어
@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayer()

    @Published private(set) var playingKey: String?
    @Published private(set) var loadingKey: String?
    @Published private(set) var position: TimeInterval = 0
    @Published var lastError: String?

    private var player: AVAudioPlayer?
    private var stopAt: TimeInterval?
    private var timer: Timer?

    /// 회의 오디오의 한 구간 재생 (같은 구간을 다시 누르면 정지)
    func toggleSegment(meetingID: Int, seq: Int, startMs: Int, endMs: Int?) async {
        let key = "seg-\(meetingID)-\(seq)"
        if playingKey == key { stop(); return }
        stop()
        loadingKey = key
        defer { if loadingKey == key { loadingKey = nil } }
        do {
            let url = try await API.shared.audioFile(meetingID)
            guard loadingKey == key else { return }   // 받는 동안 다른 구간을 눌렀으면 무시
            try play(url: url, from: Double(startMs) / 1000, to: endMs.map { Double($0) / 1000 }, key: key)
        } catch {
            if !error.isCancellation { lastError = "재생 실패: \(error.localizedDescription)" }
        }
    }

    func toggleFile(_ url: URL, key: String) {
        if playingKey == key { stop(); return }
        stop()
        do { try play(url: url, from: 0, to: nil, key: key) } catch { lastError = "재생 실패: \(error.localizedDescription)" }
    }

    private func play(url: URL, from: TimeInterval, to: TimeInterval?, key: String) throws {
        if Recorder.shared.isActive {
            lastError = "녹음 중에는 재생할 수 없어요."
            return
        }
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback, mode: .spokenAudio)
        try s.setActive(true)
        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.prepareToPlay()
        p.currentTime = from
        stopAt = to
        guard p.play() else { throw NSError(domain: "julglo", code: 2, userInfo: [NSLocalizedDescriptionKey: "재생할 수 없습니다"]) }
        player = p
        playingKey = key
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
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
        position = 0
        if !Recorder.shared.isActive { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

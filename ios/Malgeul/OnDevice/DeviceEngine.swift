import Foundation
import AVFoundation
import CoreMedia
import Speech
import FluidAudio

// 기기 안에서 하는 처리: 화자 구분(FluidAudio) · 받아쓰기(애플 SpeechAnalyzer) · 목소리 임베딩 · 오디오 자르기

enum DeviceEngineError: LocalizedError, Equatable {
    case unsupportedOS, speechUnavailable, localeUnsupported, cancelled, unreadable(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedOS: return "기기 받아쓰기는 iOS 26 이상에서 쓸 수 있어요."
        case .speechUnavailable: return "이 기기는 애플 음성인식(기기 내 받아쓰기)을 지원하지 않아요."
        case .localeUnsupported: return "이 기기에서 한국어 기기 내 받아쓰기를 쓸 수 없어요."
        case .cancelled: return "취소됨"
        case .unreadable(let m): return "오디오를 읽을 수 없어요: \(m)"
        }
    }
}

// MARK: - 화자 구분 · 목소리 임베딩 (FluidAudio 오프라인 파이프라인: pyannote 분할 + WeSpeaker 임베딩)

actor DiarizerEngine {
    static let shared = DiarizerEngine()
    static let engineName = "fluidaudio-offline-0.9"
    private var models: OfflineDiarizerModels?

    /// 모델 파일이 기기에 있는지 (내려받기 전 상태 표시용)
    nonisolated static var modelsOnDisk: Bool {
        let d = OfflineDiarizerModels.defaultModelsDirectory()
        guard let e = FileManager.default.enumerator(at: d, includingPropertiesForKeys: nil) else { return false }
        for case let u as URL in e where u.pathExtension == "mlmodelc" { return true }
        return false
    }

    /// 처음 한 번 내려받고(약 100MB) 컴파일
    func prepare() async throws {
        if models != nil { return }
        models = try await OfflineDiarizerModels.load()
    }

    private func manager(speakers: Int?) async throws -> OfflineDiarizerManager {
        try await prepare()
        var config = OfflineDiarizerConfig.default
        if let n = speakers, n > 0 { config = config.withSpeakers(exactly: n) }
        let m = OfflineDiarizerManager(config: config)
        m.initialize(models: models!)
        return m
    }

    /// 화자 구간 + 화자별 평균 임베딩 (키 = 모델 내부 이름 S1, S2…)
    func diarize(url: URL, speakers: Int? = nil, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> (turns: [SpeakerTurn], embeddings: [String: [Float]]) {
        let m = try await manager(speakers: speakers)
        let r = try await m.process(url, progressCallback: { done, total in
            if total > 0 { onProgress?(min(1, Double(done) / Double(total))) }
        })
        let turns = r.segments.map { SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
        var emb = r.speakerDatabase ?? [:]
        if emb.isEmpty {
            // 화자 데이터베이스가 비면 구간 임베딩 평균으로
            var by: [String: [[Float]]] = [:]
            for s in r.segments where !s.embedding.isEmpty { by[s.speakerId, default: []].append(s.embedding) }
            for (k, v) in by { if let c = VoiceMath.centroid(v) { emb[k] = c } }
        }
        return (turns, emb)
    }

    /// 한 사람 목소리만 담긴 파일 → 임베딩 하나(가장 오래 말한 화자 기준)
    func embedSingle(url: URL) async throws -> [Float]? {
        let r = try await diarize(url: url, speakers: 1)
        var dur: [String: Double] = [:]
        for t in r.turns { dur[t.speaker, default: 0] += t.end - t.start }
        guard let top = dur.max(by: { $0.value < $1.value })?.key else { return r.embeddings.values.first }
        return r.embeddings[top]
    }
}

// MARK: - 받아쓰기 (SpeechAnalyzer + SpeechTranscriber, 한국어)

@available(iOS 26.0, *)
enum SpeechEngine {
    static let engineName = "apple-speech"
    static let localeID = "ko-KR"

    enum AssetState: Equatable { case unsupported, notInstalled, downloading, installed }

    static func locale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID))
    }

    static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    static func assetState() async -> AssetState {
        guard SpeechTranscriber.isAvailable, let loc = await locale() else { return .unsupported }
        let t = makeTranscriber(loc)
        switch await AssetInventory.status(forModules: [t]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .notInstalled
        default: return .unsupported
        }
    }

    /// 한국어 음성 모델 설치(시스템이 관리, 앱 용량에 포함 안 됨)
    static func installAssets(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard SpeechTranscriber.isAvailable else { throw DeviceEngineError.speechUnavailable }
        guard let loc = await locale() else { throw DeviceEngineError.localeUnsupported }
        let t = makeTranscriber(loc)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            let p = req.progress
            let obs = progress.map { cb in p.observe(\.fractionCompleted) { pr, _ in cb(pr.fractionCompleted) } }
            defer { obs?.invalidate() }
            try await req.downloadAndInstall()
        }
    }

    /// 파일 받아쓰기 → 시각이 붙은 조각들. onProgress: 0~1 (처리한 오디오 위치 기준)
    static func transcribe(url: URL, duration: Double, onProgress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        guard SpeechTranscriber.isAvailable else { throw DeviceEngineError.speechUnavailable }
        guard let loc = await locale() else { throw DeviceEngineError.localeUnsupported }
        try await installAssets()
        let transcriber = makeTranscriber(loc)
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw DeviceEngineError.unreadable(error.localizedDescription) }

        let collector = Task { () throws -> [TimedWord] in
            var words: [TimedWord] = []
            for try await result in transcriber.results {
                let rangeEnd = result.range.end.seconds
                var lastEnd = result.range.start.seconds.isFinite ? result.range.start.seconds : 0
                for run in result.text.runs {
                    let piece = String(result.text[run.range].characters)
                    if let tr = run.audioTimeRange, tr.start.seconds.isFinite {
                        let s = tr.start.seconds, e = tr.end.seconds.isFinite ? tr.end.seconds : s
                        words.append(TimedWord(text: piece, start: s, end: max(e, s)))
                        lastEnd = max(e, s)
                    } else {
                        // 시각 없는 조각(문장부호 등)은 앞 조각 끝에 붙임
                        words.append(TimedWord(text: piece, start: lastEnd, end: lastEnd))
                    }
                }
                if duration > 0, rangeEnd.isFinite { onProgress(min(1, rangeEnd / duration)) }
            }
            return words
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        let words = try await collector.value
        onProgress(1)
        return words
    }
}

// MARK: - 오디오 도구

enum AudioTools {
    /// 재생 길이(초). 읽을 수 없으면 nil
    static func duration(_ url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let sr = f.processingFormat.sampleRate
        return sr > 0 ? Double(f.length) / sr : nil
    }

    static func readable(_ url: URL) -> Bool { (try? AVAudioFile(forReading: url)) != nil }

    /// 여러 구간을 이어 붙여 16kHz 모노 wav로 저장 (화자별 목소리 임베딩용). 최대 maxSeconds
    static func extract(_ url: URL, ranges: [(Double, Double)], maxSeconds: Double = 60, to out: URL) throws -> Double {
        let src = try AVAudioFile(forReading: url)
        let inFmt = src.processingFormat
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw DeviceEngineError.unreadable("형식 변환 불가") }
        try? FileManager.default.removeItem(at: out)
        let dst = try AVAudioFile(forWriting: out, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                                               AVLinearPCMIsFloatKey: false],
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let sr = inFmt.sampleRate
        var total = 0.0
        for (s, e) in ranges {
            guard total < maxSeconds, e > s else { continue }
            let len = min(e - s, maxSeconds - total)
            let startFrame = AVAudioFramePosition(s * sr)
            let frames = AVAudioFrameCount(len * sr)
            guard startFrame < src.length, frames > 0,
                  let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: frames) else { continue }
            src.framePosition = startFrame
            try src.read(into: inBuf, frameCount: frames)
            let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * 16000 / sr) + 1024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { continue }
            conv.reset()
            var fed = false
            var err: NSError?
            conv.convert(to: outBuf, error: &err) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return inBuf
            }
            if let err { throw err }
            if outBuf.frameLength > 0 { try dst.write(from: outBuf) }
            total += Double(inBuf.frameLength) / sr
        }
        return total
    }
}

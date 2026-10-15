import AVFoundation
import Foundation
import UIKit

// All graph and queue operations run on the main thread, including completion cleanup.
final class LooiAudioOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var pending: [UUID: (Result<[String: Any], Error>) -> Void] = [:]
    private var playbackQueue = LooiPlaybackQueue()
    private var playbackEpoch = 0
    private var playbackTimer: Timer?
    private var startup: DispatchWorkItem?
    private var lastCompletion = ProcessInfo.processInfo.systemUptime
    private var recoveryAttempts = 0
    private var playedChunks = 0
    private var configurationObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var microphoneTapInstalled = false
    private var microphoneWanted = false
    private var microphoneGeneration = 0
    private var voiceProcessingEnabled = false
    private var interrupted = false
    private var reconfiguring = false
    private var microphoneFrame: ((Data, Double) -> Void)?
    private var microphoneState: ((String, String) -> Void)?
    var activate: (() throws -> Void)?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        player.volume = 1
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, !self.reconfiguring, !self.engine.isRunning else { return }
            if !self.playbackQueue.isEmpty && !self.interrupted { self.recoverPlayback() }
            if self.microphoneWanted && !self.interrupted { self.recoverMicrophone() }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                self.interrupted = true
                self.removeMicrophoneTap()
                self.engine.pause()
                self.stop(message: "系统暂时中断了音频")
                if self.microphoneWanted { self.microphoneState?("interrupted", "麦克风被系统暂时中断，可点击恢复采集。") }
            } else {
                self.interrupted = false
                let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                if self.microphoneWanted && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                    self.recoverMicrophone()
                }
            }
        }
    }

    deinit {
        playbackTimer?.invalidate(); startup?.cancel()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func prepare() throws -> [String: Any] {
        guard !interrupted else { throw failure("音频正被系统中断，请稍后恢复采集") }
        // Do not renegotiate AVAudioSession for every incoming speech chunk.
        if !engine.isRunning { try activate?(); engine.prepare(); try engine.start() }
        return status()
    }

    func startMicrophone(onFrame: @escaping (Data, Double) -> Void, onState: @escaping (String, String) -> Void) throws {
        reconfiguring = true
        defer { reconfiguring = false }
        interrupted = false
        removeMicrophoneTap()
        microphoneFrame = onFrame; microphoneState = onState; microphoneWanted = true
        do {
            try activate?()
            if !voiceProcessingEnabled {
                // Configure echo cancellation once before attaching the capture tap.
                engine.stop()
                stop(message: "正在切换到语音采集")
                try engine.inputNode.setVoiceProcessingEnabled(true)
                voiceProcessingEnabled = true
            }
            let input = engine.inputNode
            let sourceFormat = input.outputFormat(forBus: 0)
            guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
                  let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw failure("麦克风格式不可用，请检查音频设备后恢复采集")
            }
            let generation = microphoneGeneration
            input.installTap(onBus: 0, bufferSize: 2048, format: sourceFormat) { [weak self] buffer, _ in
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / sourceFormat.sampleRate)) + 64
                guard let pcm = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
                var supplied = false
                var conversionError: NSError?
                let result = converter.convert(to: pcm, error: &conversionError) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return buffer
                }
                guard result != .error, conversionError == nil, pcm.frameLength > 0,
                      let samples = pcm.int16ChannelData?[0] else { return }
                let count = Int(pcm.frameLength)
                let data = Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
                var sum: Double = 0
                for index in 0..<count { let value = Double(samples[index]) / 32768; sum += value * value }
                let level = sqrt(sum / Double(count))
                DispatchQueue.main.async {
                    guard let self, self.microphoneWanted, self.microphoneGeneration == generation else { return }
                    self.microphoneFrame?(data, level)
                }
            }
            microphoneTapInstalled = true
            if !engine.isRunning { engine.prepare(); try engine.start() }
            onState("started", "")
        } catch {
            removeMicrophoneTap(); microphoneWanted = false
            throw error
        }
    }

    private func removeMicrophoneTap() {
        microphoneGeneration += 1
        if microphoneTapInstalled { engine.inputNode.removeTap(onBus: 0); microphoneTapInstalled = false }
    }

    func stopMicrophone() {
        microphoneWanted = false
        removeMicrophoneTap()
        microphoneFrame = nil; microphoneState = nil
    }

    private func recoverMicrophone() {
        guard microphoneWanted, UIApplication.shared.applicationState == .active,
              let frame = microphoneFrame, let state = microphoneState else { return }
        state("interrupted", "音频设备发生变化，正在恢复采集…")
        do { try startMicrophone(onFrame: frame, onState: state) }
        catch { state("error", "采集恢复失败：\(error.localizedDescription)。请点击恢复采集。") }
    }

    func status() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        return ["route": session.currentRoute.outputs.map { $0.portName }.joined(separator: "、"),
                "volume": session.outputVolume, "running": engine.isRunning,
                "queuedChunks": pending.count, "playedChunks": playedChunks,
                "bufferedSeconds": Double(playbackQueue.queuedFrames) / format.sampleRate,
                "scheduledSeconds": Double(playbackQueue.scheduledFrames) / format.sampleRate,
                "playerRunning": player.isPlaying, "playbackRecoveries": recoveryAttempts]
    }

    func enqueue(data: Data, sampleRate: Double, completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        guard data.count > 0, data.count % 2 == 0, data.count <= 4_000_000,
              (8_000...96_000).contains(sampleRate) else { throw failure("收到的语音数据格式不正确") }
        _ = try prepare()
        let count = data.count / 2
        let outputCount = max(1, Int(Double(count) * format.sampleRate / sampleRate))
        guard playbackQueue.canAppend(outputCount) else {
            throw failure("语音缓冲异常积压，本轮回复已暂停，请重试或点击恢复采集")
        }
        var samples = [Float](repeating: 0, count: outputCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            func sample(_ index: Int) -> Float {
                let i = min(count - 1, max(0, index)) * 2
                return Float(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)) / 32768
            }
            for index in 0..<outputCount {
                let location = Double(index) * sampleRate / format.sampleRate
                let lower = Int(location), fraction = Float(location - Double(lower))
                samples[index] = sample(lower) * (1 - fraction) + sample(lower + 1) * fraction
            }
        }
        let wasEmpty = playbackQueue.isEmpty
        let id = UUID()
        guard playbackQueue.append(samples, request: id) else { throw failure("无法缓冲语音") }
        pending[id] = completion
        if wasEmpty {
            recoveryAttempts = 0; lastCompletion = ProcessInfo.processInfo.systemUptime
            // Absorb small network timing variations without delaying subsequent chunks.
            let work = DispatchWorkItem { [weak self] in self?.startup = nil; self?.pumpPlayback() }
            startup = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        } else if startup == nil { pumpPlayback() }
        if playbackTimer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkPlayback() }
            playbackTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func pumpPlayback() {
        guard !interrupted, !playbackQueue.isEmpty else { return }
        let epoch = playbackEpoch
        for chunk in playbackQueue.takeWindow() {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
                  let channel = buffer.floatChannelData?[0] else {
                stop(message: "无法创建语音播放缓冲区"); return
            }
            buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
            chunk.samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: source.count)
            }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, epoch == self.playbackEpoch else { return }
                    self.lastCompletion = ProcessInfo.processInfo.systemUptime
                    let finished = self.playbackQueue.complete(chunk.id)
                    if let finished, let callback = self.pending.removeValue(forKey: finished) {
                        self.playedChunks += 1; callback(.success(self.status()))
                    }
                    self.pumpPlayback()
                    if self.playbackQueue.isEmpty {
                        self.playbackTimer?.invalidate(); self.playbackTimer = nil
                    }
                }
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func checkPlayback() {
        guard !interrupted, !reconfiguring, startup == nil, !playbackQueue.isEmpty else { return }
        // Scheduled slices are at most 200 ms. Two seconds without a completion
        // indicates a stopped render path, rather than slow network delivery.
        if !engine.isRunning || !player.isPlaying || ProcessInfo.processInfo.systemUptime - lastCompletion > 2 {
            recoverPlayback()
        }
    }

    private func recoverPlayback() {
        guard !interrupted, !reconfiguring, !playbackQueue.isEmpty else { return }
        guard recoveryAttempts < 2 else {
            stop(message: "音频设备未能恢复播放，请检查输出设备后点击恢复采集"); return
        }
        recoveryAttempts += 1; playbackEpoch += 1
        // Keep the microphone tap and the Live connection. Replay only the small
        // unconfirmed window; never resubmit already completed audio.
        playbackQueue.recover(); player.stop()
        reconfiguring = true
        defer { reconfiguring = false }
        do {
            try activate?()
            engine.stop(); engine.prepare(); try engine.start()
            lastCompletion = ProcessInfo.processInfo.systemUptime
            pumpPlayback()
        } catch { stop(message: "播放恢复失败：\(error.localizedDescription)") }
    }

    func test(completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        var data = Data(capacity: 12_000)
        for index in 0..<6_000 {
            let envelope = min(1, Double(index) / 240) * min(1, Double(5_999 - index) / 480)
            let value = Int16(sin(Double(index) * 2 * .pi * 660 / 24_000) * envelope * 10_000)
            let bits = UInt16(bitPattern: value)
            data.append(UInt8(bits & 255)); data.append(UInt8(bits >> 8))
        }
        try enqueue(data: data, sampleRate: 24_000, completion: completion)
    }

    func stop(message: String = "播放已停止") {
        let callbacks = Array(pending.values)
        playbackEpoch += 1
        startup?.cancel(); startup = nil
        playbackTimer?.invalidate(); playbackTimer = nil
        pending.removeAll(); playbackQueue.clear()
        player.stop()
        callbacks.forEach { $0(.failure(failure(message))) }
    }

    func shutdown() {
        stopMicrophone(); stop(); engine.stop()
        if voiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            voiceProcessingEnabled = false
        }
    }

    private func failure(_ text: String) -> NSError {
        NSError(domain: "LOOIAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

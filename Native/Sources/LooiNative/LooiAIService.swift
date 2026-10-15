import Foundation
import Combine
import AVFoundation
import UIKit
import GoogleSignIn

@MainActor public func handleLooiURL(_ url: URL) -> Bool { GIDSignIn.sharedInstance.handle(url) }

@MainActor enum LooiCredentials {
    static func authorize() async throws {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String, !clientID.isEmpty,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { throw LooiError.message("请先配置 iOS Google OAuth 客户端 ID") }
        while let next = presenter.presentedViewController { presenter = next }
        GIDSignIn.sharedInstance.configuration = .init(clientID: clientID)
        _ = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter, hint: nil, additionalScopes: ["https://www.googleapis.com/auth/cloud-platform"])
    }
    static func token(_ config: LooiAIConfiguration) async throws -> String {
        if config.auth == "oauth" && config.provider == "vertex" {
            var user = GIDSignIn.sharedInstance.currentUser
            if user == nil { user = try await GIDSignIn.sharedInstance.restorePreviousSignIn() }
            guard let user else { throw LooiError.message("请先完成 Google 授权") }
            return try await user.refreshTokensIfNeeded().accessToken.tokenString
        }
        let key = try LooiKeychain.read(config.credentialRef)
        guard !key.isEmpty || config.provider == "ollama" else { throw LooiError.message("请在 AI 设置中填写 API Key") }
        return key
    }
}

@MainActor final class LooiLiveService: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var speaking = false
    @Published private(set) var microphone = false
    @Published private(set) var heard = ""
    @Published private(set) var reply = ""
    @Published private(set) var error = ""
    private(set) var sentVideoFrames = 0
    private(set) var receivedAudioChunks = 0
    @Published private(set) var turnComplete = false
    var onScenario: ((String) async throws -> Void)?
    var onCancel: (() -> Void)?
    var onImmediateStop: (() -> Void)?
    private let audio = LooiAudioOutput()
    private var socket: URLSessionWebSocketTask?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration)
    }()
    private var receiver: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var setup: CheckedContinuation<Void, Error>?
    private var setupTimeout: Task<Void, Never>?
    private var ping: Task<Void, Never>?
    private var generation = 0
    private var queuedMessages = 0
    private var audioBuffers = 0
    private var playbackGeneration = 0
    private var cancelledToolIDs = Set<String>()
    private var resumeHandle: String?
    private var previousConfig: LooiAIConfiguration?
    private var previousWasTest = false
    private var discardAudioUntilTurnComplete = false
    init() { audio.activate = { try Self.activateAudio() } }
    private static func activateAudio() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord || session.mode != .voiceChat {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        }
        try session.setActive(true)
        if session.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) { try session.overrideOutputAudioPort(.speaker) }
    }
    func start(_ config: LooiAIConfiguration, testOnly: Bool = false) async throws {
        stop(clearResume: false)
        if previousConfig != config || testOnly || previousWasTest { resumeHandle = nil }
        previousConfig = config; previousWasTest = testOnly; discardAudioUntilTurnComplete = false
        generation += 1; let token = generation
        connecting = true; error = ""; reply = ""; heard = ""; sentVideoFrames = 0; receivedAudioChunks = 0; turnComplete = false
        do {
            let credential = try await LooiCredentials.token(config)
            guard token == generation else { throw CancellationError() }
            var url = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
            var model = "models/\(try LooiAIRequest.identifier(config.liveModel.replacingOccurrences(of: "models/", with: "")))"
            if config.provider == "vertex" {
                guard config.endpointType != "express" else { throw LooiError.message("Express 端点不支持当前实时路径，请选择标准项目") }
                let region = try LooiAIRequest.identifier(config.region), project = try LooiAIRequest.identifier(config.projectId)
                let host = region == "global" ? "aiplatform.googleapis.com" : "\(region)-aiplatform.googleapis.com"
                url = "wss://\(host)/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent"
                model = "projects/\(project)/locations/\(region)/publishers/google/models/\(try LooiAIRequest.identifier(config.liveModel))"
            }
            var request = URLRequest(url: URL(string: url)!)
            request.setValue(config.auth == "oauth" ? "Bearer \(credential)" : credential, forHTTPHeaderField: config.auth == "oauth" ? "Authorization" : "x-goog-api-key")
            let task = session.webSocketTask(with: request); task.maximumMessageSize = 4_000_000; socket = task; task.resume()
            receiver = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        guard let self, token == self.generation else { return }
                        let data: Data
                        switch message { case .string(let text): data = Data(text.utf8); case .data(let value): data = value; @unknown default: continue }
                        try self.receive(data, token: token)
                    }
                } catch { guard let self, token == self.generation else { return }; self.fail("实时连接中断：\(error.localizedDescription)") }
            }
            guard let setupURL = Bundle.module.url(forResource: "LiveSetup", withExtension: "json"),
                  var wrapper = try JSONSerialization.jsonObject(with: Data(contentsOf: setupURL)) as? [String: Any],
                  var payload = wrapper["setup"] as? [String: Any] else { throw LooiError.message("实时配置资源缺失，请重新构建") }
            payload = LooiLiveConfiguration.setup(payload, model: model, testOnly: testOnly)
            if let resumeHandle { payload["sessionResumption"] = ["handle": resumeHandle] }
            wrapper["setup"] = payload
            try await withCheckedThrowingContinuation { continuation in
                setup = continuation
                setupTimeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard !Task.isCancelled, let self, token == self.generation else { return }; self.fail("实时会话准备超时，请检查网络与模型")
                }
                enqueue(wrapper, token: token)
            }
            guard token == generation else { throw CancellationError() }
            connected = true; connecting = false
            if !testOnly { try await startMicrophone(token: token) }
            ping = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    guard !Task.isCancelled, let self, token == self.generation else { return }
                    task.sendPing { _ in }
                }
            }
        } catch {
            if token == generation { fail(error.localizedDescription) }
            throw error
        }
    }
    private func startMicrophone(token: Int) async throws {
        let allowed = await withCheckedContinuation { continuation in AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) } }
        guard token == generation else { throw CancellationError() }
        guard allowed else { throw LooiError.message("请在 iPhone 设置中允许 LOOI 使用麦克风") }
        try audio.startMicrophone(onFrame: { [weak self] data, _ in
            self?.enqueue(["realtimeInput": ["audio": ["data": data.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]], token: token)
        }, onState: { [weak self] type, message in
            guard let self, token == self.generation else { return }
            self.microphone = type == "started"
            self.error = type == "started" ? "" : message
        })
        microphone = true
    }
    func recoverMicrophone() async throws { audio.stopMicrophone(); microphone = false; guard connected else { return }; try await startMicrophone(token: generation) }
    func sendFrame(_ jpeg: Data) { guard connected, queuedMessages < 6 else { return }; sentVideoFrames += 1; enqueue(["realtimeInput": ["video": ["data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]]], token: generation) }
    func sendText(_ text: String) { guard connected else { return }; enqueue(["clientContent": ["turns": [["role": "user", "parts": [["text": text]]]], "turnComplete": true]], token: generation) }
    private func enqueue(_ object: [String: Any], token: Int) {
        guard token == generation, let socket, let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        guard queuedMessages < 48 else { fail("网络发送过慢，请检查网络后恢复连接"); return }
        queuedMessages += 1; let preceding = writer
        writer = Task { [weak self] in
            await preceding?.value
            guard let self, token == self.generation, !Task.isCancelled else { return }
            do { try await socket.send(.string(text)); if token == self.generation { self.queuedMessages = max(0, self.queuedMessages - 1) } }
            catch { if token == self.generation { self.fail("实时发送失败：\(error.localizedDescription)") } }
        }
    }
    private func receive(_ data: Data, token: Int) throws {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let failure = message["error"] as? [String: Any] { throw LooiError.message(failure["message"] as? String ?? "AI 拒绝请求") }
        if message["setupComplete"] != nil { setupTimeout?.cancel(); let continuation = setup; setup = nil; continuation?.resume() }
        if let resume = message["sessionResumptionUpdate"] as? [String: Any], resume["resumable"] as? Bool != false, let handle = resume["newHandle"] as? String { resumeHandle = handle }
        let content = message["serverContent"] as? [String: Any] ?? [:]
        if content["interrupted"] as? Bool == true { playbackGeneration += 1; audio.stop(); audioBuffers = 0; speaking = false; discardAudioUntilTurnComplete = false }
        if let transcription = content["inputTranscription"] as? [String: Any], let text = transcription["text"] as? String {
            heard = String((heard + text).suffix(1500))
            if LooiAIRequest.isStopRequest(text) { onImmediateStop?() }
        }
        if let transcription = content["outputTranscription"] as? [String: Any], let text = transcription["text"] as? String { reply = String((reply + text).suffix(3000)) }
        if let model = content["modelTurn"] as? [String: Any], let parts = model["parts"] as? [[String: Any]] {
            for part in parts {
                guard !discardAudioUntilTurnComplete, let blob = part["inlineData"] as? [String: Any], let mime = blob["mimeType"] as? String, mime.hasPrefix("audio/pcm"),
                      let encoded = blob["data"] as? String, let pcm = Data(base64Encoded: encoded) else { continue }
                audioBuffers += 1; if !speaking { speaking = true }; receivedAudioChunks += 1; turnComplete = false
                let playback = playbackGeneration
                do { try audio.enqueue(data: pcm, sampleRate: 24_000) { [weak self] result in
                    guard let self, token == self.generation, playback == self.playbackGeneration else { return }
                    self.audioBuffers = max(0, self.audioBuffers - 1)
                    if self.speaking != (self.audioBuffers > 0) { self.speaking = self.audioBuffers > 0 }
                    if case let .failure(error) = result { self.playbackFailed(error) }
                } } catch { playbackFailed(error) }
            }
        }
        if content["turnComplete"] as? Bool == true { turnComplete = true; discardAudioUntilTurnComplete = false }
        if let tool = message["toolCall"] as? [String: Any], let calls = tool["functionCalls"] as? [[String: Any]] {
            Task { [weak self] in
                guard let self else { return }; var results: [[String: Any]] = []
                for call in calls {
                    guard token == self.generation else { return }
                    let id = call["id"] as? String ?? ""
                    if self.cancelledToolIDs.contains(id) { continue }
                    var response: [String: Any] = ["ok": true]
                    do {
                        guard call["name"] as? String == "run_scenario", let args = call["args"] as? [String: Any], let name = args["name"] as? String, let run = self.onScenario else { throw LooiError.message("未知动作请求") }
                        try await run(name)
                    } catch { response = ["ok": false, "reason": error.localizedDescription] }
                    if !self.cancelledToolIDs.contains(id) { results.append(["id": id, "name": call["name"] ?? "run_scenario", "response": response]) }
                }
                guard token == self.generation, !results.isEmpty else { return }; self.enqueue(["toolResponse": ["functionResponses": results]], token: token)
            }
        }
        if let cancellation = message["toolCallCancellation"] as? [String: Any] {
            cancelledToolIDs.formUnion(cancellation["ids"] as? [String] ?? []); onCancel?()
        }
    }
    private func playbackFailed(_ failure: Error) {
        // Avoid a stream of identical errors and broken sentence fragments after
        // a failed output. Camera, microphone and socket remain available.
        playbackGeneration += 1; discardAudioUntilTurnComplete = !turnComplete
        audioBuffers = 0; speaking = false
        audio.stop(); error = failure.localizedDescription
    }
    private func fail(_ reason: String) { let clean = LooiAIRequest.redact(reason); stop(clearResume: false); error = clean }
    func stop(clearResume: Bool = true) {
        generation += 1; connected = false; connecting = false; microphone = false; speaking = false; audioBuffers = 0; queuedMessages = 0
        playbackGeneration += 1; cancelledToolIDs.removeAll()
        setupTimeout?.cancel(); ping?.cancel(); receiver?.cancel(); writer?.cancel(); writer = nil
        let continuation = setup; setup = nil; continuation?.resume(throwing: CancellationError())
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        audio.shutdown(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if clearResume { resumeHandle = nil }
    }
    func testTone() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do { try audio.test { result in continuation.resume(with: result.map { _ in () }) } }
            catch { continuation.resume(throwing: error) }
        }
    }
}

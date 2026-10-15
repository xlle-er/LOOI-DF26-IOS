import SwiftUI
import Combine

@MainActor final class LooiAppModel: ObservableObject {
    enum Phase { case idle, starting, active, testing, stopping }
    @Published private(set) var phase: Phase = .idle
    @Published var notice = "就在这里，陪着你"
    @Published var textReply = ""
    @Published var cameraEnabled = true
    @Published private(set) var recovering = false
    let settings = LooiSettings()
    let body = LooiBluetooth()
    let camera = LooiCamera()
    let live = LooiLiveService()
    let face = LooiFaceHost()
    private var subscriptions = Set<AnyCancellable>()
    private var operation: Task<Void, Never>?
    private var textOperation: Task<Void, Never>?
    private var textToken = UUID()
    private var token = UUID()
    private var bodyFaultLatched = false
    private lazy var scenarioNames: Set<String> = {
        guard let url = Bundle.module.url(forResource: "LiveSetup", withExtension: "json"), let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let setup = object["setup"] as? [String: Any],
              let tools = setup["tools"] as? [[String: Any]], let functions = tools.first?["functionDeclarations"] as? [[String: Any]],
              let parameters = functions.first?["parameters"] as? [String: Any], let properties = parameters["properties"] as? [String: Any],
              let name = properties["name"] as? [String: Any], let values = name["enum"] as? [String] else { return [] }
        return Set(values)
    }()
    var isBusy: Bool { recovering || phase == .starting || phase == .testing || phase == .stopping }
    var isActive: Bool { phase == .active }
    init() {
        camera.onFrame = { [weak self] data in self?.live.sendFrame(data) }
        face.onPhoto = { [weak self] in guard let data = self?.camera.snapshot() else { throw LooiError.message("请先开启摄像头并等待画面") }; return data }
        face.onCommand = { [weak self] payload in
            guard let self else { throw CancellationError() }
            return try await self.sendBodyCommand(payload)
        }
        live.onScenario = { [weak self] name in
            guard let self, self.phase == .active else { throw LooiError.message("陪伴尚未开始") }
            try await self.face.run(name, allowMotion: self.settings.motionEnabled && self.body.isConnected)
        }
        live.onCancel = { [weak self] in self?.face.cancel(); Task { await self?.body.stopMotion() } }
        live.onImmediateStop = { [weak self] in self?.stopBodyImmediately() }
        body.onFault = { [weak self] text in
            guard let self, !self.bodyFaultLatched else { return }; self.bodyFaultLatched = true
            self.settings.motionEnabled = false; self.face.cancel(); self.notice = text + "；语音可继续"
        }
        body.onConnection = { [weak self] connected in if !connected { self?.settings.motionEnabled = false } else { self?.bodyFaultLatched = false }; self?.updateFace() }
        live.$speaking.combineLatest(live.$connecting).sink { [weak self] _, _ in
            Task { @MainActor in self?.updateFace() }
        }.store(in: &subscriptions)
        camera.$running.sink { [weak self] _ in Task { @MainActor in self?.updateFace() } }.store(in: &subscriptions)
    }
    private func updateFace() { face.state(connected: body.isConnected, speaking: live.speaking, thinking: live.connecting, cameraRunning: camera.running) }
    private func stopBodyImmediately() {
        settings.motionEnabled = false; face.cancel()
        Task { let confirmed = await body.stopMotion(); notice = confirmed ? "身体动作已停止，语音陪伴可继续。" : "停止指令未获确认，请检查机器人。" }
    }
    func start() {
        guard phase == .idle else { return }
        phase = .starting; token = UUID(); let current = token
        notice = "正在开始陪伴…"
        operation = Task {
            do {
                let config = settings.configuration
                if config.isLive { try await live.start(config) }
                guard current == token, !Task.isCancelled else { return }
                var cameraNotice = ""
                if cameraEnabled {
                    do { try await camera.start(front: camera.front) }
                    catch {
                        guard current == token, !Task.isCancelled else { return }
                        cameraEnabled = false; cameraNotice = "摄像头未开启，语音仍可继续。\(error.localizedDescription)"
                    }
                }
                guard current == token, !Task.isCancelled else { return }
                phase = .active; notice = !cameraNotice.isEmpty ? cameraNotice : config.isLive ? "可以直接说话，我在听。" : "陪伴已开始，可使用下方文字交流。"
                UIApplication.shared.isIdleTimerDisabled = true
            } catch {
                guard current == token else { return }
                live.stop(); camera.stop(); phase = .idle; notice = LooiAIRequest.redact(error.localizedDescription)
            }
        }
    }
    func stop() async {
        token = UUID(); operation?.cancel(); textOperation?.cancel(); textToken = UUID(); phase = .stopping
        recovering = false
        live.stop(); camera.stop(); face.cancel(); settings.motionEnabled = false
        UIApplication.shared.isIdleTimerDisabled = false
        body.stopScan(); let stopped = await body.stopMotion()
        phase = .idle; notice = stopped ? "陪伴已结束，麦克风和摄像头已关闭。" : "采集已关闭；身体停止未获确认，请检查机器人。"
    }
    func recoverCapture() {
        guard phase == .active, !recovering else { return }
        recovering = true; let current = token
        operation = Task {
            defer { if current == token { recovering = false } }
            do {
                if settings.configuration.isLive {
                    if live.connected { try await live.recoverMicrophone() } else { try await live.start(settings.configuration) }
                }
                guard current == token, !Task.isCancelled else { return }
                if cameraEnabled { try await camera.start(front: camera.front) }
                if current == token { notice = "采集已恢复，可以继续对话。" }
            } catch { if current == token { notice = error.localizedDescription } }
        }
    }
    func toggleCamera() {
        cameraEnabled.toggle()
        if !cameraEnabled { camera.stop(); return }
        operation = Task { do { try await camera.start(front: camera.front) } catch { cameraEnabled = false; notice = error.localizedDescription } }
    }
    func switchCamera() {
        operation = Task { do { try await camera.start(front: !camera.front); cameraEnabled = true } catch { notice = error.localizedDescription } }
    }
    func testSound() {
        let current = token
        operation = Task { do { try await live.testTone(); if current == token { notice = "提示音已输出，请确认手机媒体音量。" } } catch { if current == token { notice = error.localizedDescription } } }
    }
    func runScenario(_ name: String, manual: Bool = false) async throws {
        try await face.run(name, allowMotion: body.isConnected && (manual || settings.motionEnabled))
    }
    private func sendBodyCommand(_ payload: [String: Any]) async throws -> [String: Any] {
        let command = try LooiBodyProtocol.validated(payload, motionAllowed: settings.motionEnabled || phase == .testing)
        if command["type"] as? String == "stop" {
            guard await body.stopMotion() else { throw LooiError.message("身体停止未获确认") }; return ["ok": true]
        }
        return try await body.send(command)
    }
    func testMotion() {
        guard phase == .idle, body.isConnected else { notice = "请先连接自己的机器人，再结束陪伴进行测试"; return }
        phase = .testing; let current = UUID(); token = current
        notice = "正在测试轻微左右转动，请留出空间。"
        operation = Task {
            do { try await runScenario("look_left", manual: true); try await runScenario("look_right", manual: true); if token == current { notice = "动作测试完成，身体已确认指令。" } }
            catch { if token == current { notice = error.localizedDescription } }
            guard token == current else { return }
            await body.stopMotion(); if token == current { phase = .idle }
        }
    }
    func identifyRobot() {
        guard body.isConnected, phase == .idle else { return }
        token = UUID(); let current = token
        phase = .testing; notice = "机器人将轻轻点头，请确认是你的小伙伴。"
        operation = Task {
            do {
                _ = try await body.send(["type": "head_pitch", "pulse": 545, "duration_ms": 250])
                try await Task.sleep(nanoseconds: 350_000_000)
                guard current == token else { return }
                _ = try await body.send(["type": "head_pitch", "pulse": 570, "duration_ms": 250])
            } catch { if current == token { notice = error.localizedDescription } }
            if current == token && phase == .testing { phase = .idle }
        }
    }
    func testAI() {
        guard phase == .idle else { return }; phase = .testing; token = UUID(); let current = token
        notice = "正在测试 AI…"
        operation = Task {
            do {
                let config = settings.configuration
                if config.isLive {
                    try await live.start(config, testOnly: true); live.sendText(LooiConversationLanguage.testPrompt(fallback: LooiLocalization.shared.language))
                    let limit = Date().addingTimeInterval(25)
                    while !Task.isCancelled && current == token && Date() < limit {
                        if !live.error.isEmpty { throw LooiError.message(live.error) }
                        if live.receivedAudioChunks > 0 && !live.speaking && live.turnComplete { break }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    guard live.receivedAudioChunks > 0, live.turnComplete, !live.speaking else { throw LooiError.message("AI 测试未完成语音播放，请检查网络和模型") }
                    if current == token { notice = "AI 测试成功，语音已收到并播放。" }
                } else { let reply = try await textRequest(LooiConversationLanguage.testPrompt(fallback: LooiLocalization.shared.language)); if current == token { textReply = reply; notice = config.isOffline ? "离线陪伴已就绪。" : "AI 文本测试成功。" } }
            } catch { if current == token { notice = LooiAIRequest.redact(error.localizedDescription) } }
            guard current == token else { return }; live.stop(); phase = .idle
        }
    }
    func textRequest(_ text: String, image: Data? = nil, allowActions: Bool = false) async throws -> String {
        let config = settings.configuration
        if config.isOffline { return LooiConversationLanguage.offlineReply(to: text, fallback: LooiLocalization.shared.language) }
        let key = try await LooiCredentials.token(config)
        var instruction = "You are LOOI, a warm, concise desktop companion. " + LooiConversationLanguage.instruction(fallback: LooiLocalization.shared.language)
        if allowActions {
            instruction += "Return only JSON: {\"text\":\"your natural reply in the user’s language\",\"scenario\":null}. Choose a scenario only when the user explicitly asks for movement, and only from: \(scenarioNames.sorted().joined(separator: ",")). Body connected: \(body.isConnected). Motion allowed: \(settings.motionEnabled). If disconnected or movement is not permitted, scenario must be null. Never claim to have moved when movement is unavailable. Never mention internal scenario names."
        }
        let request = try LooiAIRequest.text(config, key: key, prompt: text, image: image, systemInstruction: instruction)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try LooiAIRequest.response(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: config.provider)
    }
    @discardableResult func sendText(_ text: String, includeImage: Bool = false) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if LooiAIRequest.isStopRequest(text) { stopBodyImmediately(); return true }
        if live.connected { live.sendText(text); return true }
        let image = includeImage ? camera.snapshot() : nil
        if includeImage && image == nil { notice = "请先开启摄像头并等待画面"; return false }
        let current = token
        textOperation?.cancel(); textToken = UUID(); let messageToken = textToken
        textOperation = Task {
            do {
                let raw = try await textRequest(text, image: image, allowActions: true)
                guard current == token, messageToken == textToken else { return }
                let reply = LooiAIRequest.companionReply(raw, allowedScenarios: scenarioNames); textReply = reply.text
                if let scenario = reply.scenario, phase == .active { try await face.run(scenario, allowMotion: settings.motionEnabled && body.isConnected) }
            }
            catch { if current == token && messageToken == textToken { notice = error.localizedDescription } }
        }
        return true
    }
}

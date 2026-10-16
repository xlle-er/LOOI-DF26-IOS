import Foundation

var passed = 0
func check(_ condition: Bool, _ name: String) {
    precondition(condition, name); passed += 1
}
func rejects(_ name: String, _ action: () throws -> Void) {
    do { try action(); preconditionFailure(name) } catch { passed += 1 }
}
check(LooiAIRequest.isStopRequest("请停下！"), "Mandarin immediate stop")
check(LooiAIRequest.isStopRequest("stop moving"), "English immediate stop")
check(!LooiAIRequest.isStopRequest("你好，今天天气如何"), "normal speech remains active")
let replyWithAction = LooiAIRequest.companionReply("```json\n{\"text\":\"好呀\",\"scenario\":\"look_left\"}\n```", allowedScenarios:["look_left"])
check(replyWithAction.text == "好呀" && replyWithAction.scenario == "look_left", "native text action decodes known scenarios")
check(LooiAIRequest.companionReply("{\"text\":\"你好\",\"scenario\":\"unsafe_custom_command\"}", allowedScenarios:["look_left"]).scenario == nil, "unknown text action cannot execute")
let motion = try LooiBodyProtocol.validated(["type": "motion", "linear": 2.0, "angular": -3.0, "duration_ms": 20_000, "ramp_ms": 9999], motionAllowed: true)
check(motion["linear"] as? Double == 0.4 && motion["angular"] as? Double == -0.4, "bounded wheel speed")
check(motion["duration_ms"] as? Int == 1000 && motion["ramp_ms"] as? Int == 500, "bounded duration and ramp")
rejects("disarmed movement") { _ = try LooiBodyProtocol.validated(["type":"motion", "linear":0.1, "angular":0.0], motionAllowed:false) }
rejects("NaN movement") { _ = try LooiBodyProtocol.validated(["type":"motion", "linear":Double.nan, "angular":0.0], motionAllowed:true) }
rejects("unsupported command") { _ = try LooiBodyProtocol.validated(["type":"flash_firmware"], motionAllowed:true) }
rejects("removed actuator command") { _ = try LooiBodyProtocol.validated(["type":"head_pitch"], motionAllowed:true) }
let stop = try LooiBodyProtocol.packet(["type":"stop"], id:"stop-id")
check(stop.first == 10 && stop.last == 10, "stop separates unfinished BLE JSON")
var decoder = LooiNotificationDecoder()
let ack = Data("{\"id\":\"same-id\",\"type\":\"ack\",\"label\":\"动作\"}\n".utf8)
let split = ack.count - 5
check(try decoder.append(Data(ack.prefix(split))).isEmpty, "fragment buffering")
let decoded = try decoder.append(Data(ack.suffix(ack.count - split)))
check(decoded.first?["label"] as? String == "动作", "split UTF8 preserved")
check(try decoder.append(Data("garbage\n{\"type\":\"pong\"}\n{\"type\":\"config\"}\n".utf8)).count == 2, "multiple notification frames")
rejects("oversized notification") { _ = try decoder.append(Data(repeating:65, count:65_537)) }
check(try decoder.append(Data("{\"type\":\"ack\"}\n".utf8)).count == 1, "decoder recovers after overflow")

let suite = "looi.native.tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName:suite)!
defer { defaults.removePersistentDomain(forName:suite) }
let legacy: [String:Any] = ["selected":"gemini", "profiles":["gemini":["provider":"gemini", "mode":"live", "liveModel":"models/my-existing-model"]]]
defaults.set(String(data:try JSONSerialization.data(withJSONObject:legacy), encoding:.utf8), forKey:"CapacitorStorage.looi.providers.v1")
let settings = LooiSettings(defaults:defaults)
check(settings.configuration.liveModel == "my-existing-model", "legacy custom live model preserved")
check(settings.configuration.model == "gemini-3.8-flash", "empty model gets provider default")
try settings.save(settings.configuration, key:"")
let restored = LooiSettings(defaults:defaults)
check(restored.configuration.liveModel == "my-existing-model", "native preferences persist without keychain rewrite")
check(restored.motionEnabled == false, "motion always starts disarmed")
for provider in LooiProvider.all where !provider.models.isEmpty {
    let config = LooiAIConfiguration.fresh(provider.id)
    check(config.model == provider.models.first, "default model \(provider.id)")
}
var gemini = LooiAIConfiguration.fresh("gemini")
let request = try LooiAIRequest.text(gemini, key:"test-key", prompt:"你好", image:Data([1,2]))
check(request.value(forHTTPHeaderField:"x-goog-api-key") == "test-key" && !request.url!.absoluteString.contains("test-key"), "key only in header")
let geminiBody = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
check((geminiBody["contents"] as! [[String:Any]]).count == 1, "native multimodal request")
var vertex = LooiAIConfiguration.fresh("vertex"); vertex.projectId = "test-project"; vertex.region = "global"; vertex.auth = "oauth"
let vertexRequest = try LooiAIRequest.text(vertex, key:"test-token", prompt:"hello")
check(vertexRequest.url!.host == "aiplatform.googleapis.com" && vertexRequest.value(forHTTPHeaderField:"Authorization") == "Bearer test-token", "Vertex global OAuth")
vertex.endpointType = "express"; vertex.auth = "apiKey"
check(try LooiAIRequest.text(vertex,key:"test",prompt:"hello").url!.path.contains("publishers/google/models"), "express model path")
let qwen = try LooiAIRequest.text(.fresh("qwen"), key:"test", prompt:"hello")
let qwenBody = try JSONSerialization.jsonObject(with:qwen.httpBody!) as! [String:Any]
check(qwenBody["enable_thinking"] as? Bool == false, "Qwen non-stream request disables thinking")
var ollama = LooiAIConfiguration.fresh("ollama"); ollama.baseUrl = "http://192.168.1.5:11434"
check(try LooiAIRequest.text(ollama,key:"",prompt:"hello").url!.path == "/api/chat", "Ollama native endpoint")
ollama.baseUrl = "http://example.com"
rejects("public cleartext credentials") { _ = try LooiAIRequest.text(ollama,key:"",prompt:"hello") }
ollama.baseUrl = "http://10.example.com"
rejects("DNS name cannot masquerade as LAN IPv4") { _ = try LooiAIRequest.text(ollama,key:"",prompt:"hello") }
let secret = "AI" + "zaExampleTestValue"
check(!LooiAIRequest.redact(secret).contains(secret), "diagnostics redact Google keys")
check(!LooiAIRequest.redact("Bearer test-token").contains("test-token"), "diagnostics redact tokens")
let response = try LooiAIRequest.response(Data("{\"choices\":[{\"message\":{\"content\":\"你好\"}}]}".utf8),status:200,provider:"groq")
check(response == "你好", "compatible provider response")
rejects("failed request cannot pass") { _ = try LooiAIRequest.response(Data("{}".utf8),status:403,provider:"gemini") }
// Burst delivery beyond the old 20-second cap must stay ordered while scheduling
// only 600 ms on the audio node. Completion and recovery must not leak requests.
var playback = LooiPlaybackQueue()
let requestID = UUID()
let thirtySeconds = [Float](repeating: 0.25, count: 24_000 * 30)
check(playback.append(thirtySeconds, request: requestID), "30-second burst buffers without the old queue error")
let firstWindow = playback.takeWindow()
check(firstWindow.count == 3 && playback.scheduledFrames == 14_400, "only 600 ms scheduled")
check(firstWindow.allSatisfy { $0.samples.count <= 4_800 }, "large packets split into 200 ms slices")
check(playback.complete(firstWindow[0].id) == nil, "partial request cannot complete early")
let framesBeforeRecovery = playback.queuedFrames
playback.recover()
check(playback.queuedFrames == framesBeforeRecovery && playback.scheduledFrames == 0, "recovery preserves unplayed samples")
check(playback.complete(firstWindow[1].id) == nil && playback.queuedFrames == framesBeforeRecovery, "stale completion cannot drain recovered queue")
var window = playback.takeWindow()
check(window.first?.id != firstWindow[1].id && window.first?.samples == firstWindow[1].samples, "recovery replays unconfirmed audio with new IDs")
var completions: [UUID] = []
while !window.isEmpty {
    for chunk in window { if let id = playback.complete(chunk.id) { completions.append(id) } }
    window = playback.takeWindow()
}
check(playback.isEmpty && completions == [requestID], "burst drains with exactly one final completion")
let tinyID = UUID(), nextID = UUID()
check(playback.append([0.1], request: tinyID) && playback.append([0.2], request: nextID), "separate short requests accepted")
let tiny = playback.takeWindow()
check(tiny.map { $0.request } == [tinyID, nextID], "network packet ordering retained")
check(playback.complete(tiny[0].id) == tinyID && playback.complete(tiny[1].id) == nextID, "independent completion accounting")
check(!playback.canAppend(LooiPlaybackQueue.capacity + 1), "memory remains bounded")
_ = playback.append([0.3], request: UUID()); let cancelled = playback.takeWindow(); playback.clear()
check(playback.complete(cancelled[0].id) == nil && playback.isEmpty, "late callback after stop is harmless")
var boundedPlayback = LooiPlaybackQueue()
let fullID = UUID()
check(boundedPlayback.append([Float](repeating: 0, count: LooiPlaybackQueue.capacity), request: fullID), "buffer accepts its capacity")
check(!boundedPlayback.append([1], request: UUID()) && boundedPlayback.queuedFrames == LooiPlaybackQueue.capacity, "overflow leaves existing audio intact")
boundedPlayback.clear()
check(boundedPlayback.append([1], request: UUID()), "new speech accepted after clearing a failed turn")
let originalLive: [String: Any] = ["generationConfig": ["responseModalities": ["AUDIO"], "temperature": 0.7], "tools": [["name": "robot"]], "systemInstruction": ["parts": [["text": "companion"]]]]
let testLive = LooiLiveConfiguration.setup(originalLive, model: "models/test", testOnly: true)
let testGeneration = testLive["generationConfig"] as! [String: Any]
check(testGeneration["maxOutputTokens"] as? Int == 256 && testGeneration["responseModalities"] as? [String] == ["AUDIO"], "AI test caps speech and preserves audio mode")
check((testLive["tools"] as? [Any])?.isEmpty == true && (testLive["sessionResumption"] as? [String: Any])?.isEmpty == true, "AI test isolates tools and previous conversation")
let regularLive = LooiLiveConfiguration.setup(originalLive, model: "models/regular", testOnly: false)
check((regularLive["generationConfig"] as? [String: Any])?["maxOutputTokens"] == nil && (regularLive["tools"] as? [Any])?.count == 1, "normal companion retains original configuration")
check(LooiLocalization.resolve(.system, preferred: ["zh-Hant-TW", "en-US"]) == "zh-Hans", "Chinese system locale resolves to Chinese")
check(LooiLocalization.resolve(.system, preferred: ["en-GB", "zh-Hans"]) == "en", "English system locale resolves to English")
check(LooiLocalization.resolve(.system, preferred: ["fr-FR"]) == "en", "unsupported interface language falls back to English")
check(LooiLocalization.resolve(.chinese, preferred: ["en"]) == "zh-Hans", "explicit app language overrides system locale")
check(LooiLocalization.string("退出陪伴", language: "en") == "Exit companion", "English localization resource is loaded")
check(LooiLocalization.string("退出陪伴", language: "zh-Hans") == "退出陪伴", "Chinese source is retained")
check(LooiLocalization.message("正在连接 我的桌面机器人…", language: "en") == "Connecting to 我的桌面机器人…", "dynamic robot name is never translated")
check(LooiLocalization.message("实时连接中断：连接失败", language: "en") == "Live connection interrupted: Connection failed", "nested known runtime error is localized")
check(LooiLocalization.message("播放恢复失败：custom server detail", language: "en") == "Playback recovery failed: custom server detail", "unknown error details remain intact")
let languageDefaults = UserDefaults(suiteName: "looi.language.tests.\(UUID().uuidString)")!
let languageStore = LooiLocalization(defaults: languageDefaults)
languageStore.selection = .english
check(LooiLocalization(defaults: languageDefaults).selection == .english, "language selection persists")
languageDefaults.removeObject(forKey: "looi.app.language")
let englishPolicy = LooiConversationLanguage.instruction(fallback: "en")
let chinesePolicy = LooiConversationLanguage.instruction(fallback: "zh-Hans")
check(englishPolicy.contains("latest spoken or typed message") && chinesePolicy.contains("latest spoken or typed message"), "user language wins in both UI languages")
check(englishPolicy.contains("explicitly requested") && englishPolicy.contains("every turn"), "explicit output-language requests and mid-session changes are supported")
check(englishPolicy.contains("English as the fallback") && chinesePolicy.contains("Simplified Chinese as the fallback"), "UI language is only a fallback")
check(LooiConversationLanguage.offlineReply(to: "Hello, how are you today?", fallback: "zh-Hans").hasPrefix("Hello"), "offline English input wins over Chinese interface")
check(LooiConversationLanguage.offlineReply(to: "你好，今天过得怎么样？", fallback: "en").hasPrefix("你好"), "offline Chinese input wins over English interface")
let multilingualLive: [String: Any] = ["generationConfig": ["speechConfig": ["languageCode": "zh-CN"]], "systemInstruction": ["parts": [["text": "Identity. <language_style>Always speak Mandarin.</language_style> Keep motion rules."]]]]
let multilingualSetup = LooiLiveConfiguration.setup(multilingualLive, model: "models/test", testOnly: false)
let languageParts = (multilingualSetup["systemInstruction"] as! [String: Any])["parts"] as! [[String: Any]]
let liveInstruction = languageParts.compactMap { $0["text"] as? String }.joined()
check(!liveInstruction.contains("Always speak Mandarin") && liveInstruction.contains("Keep motion rules") && liveInstruction.contains("latest spoken"), "Live policy removes forced language and preserves safety rules")
check(((multilingualSetup["generationConfig"] as! [String: Any])["speechConfig"] as! [String: Any])["languageCode"] == nil, "Live speech language is not pinned to interface")
let separatedRequest = try LooiAIRequest.text(gemini, key: "test-key", prompt: "Hello", systemInstruction: chinesePolicy)
let separatedBody = try JSONSerialization.jsonObject(with: separatedRequest.httpBody!) as! [String: Any]
check(separatedBody["systemInstruction"] != nil && (((separatedBody["contents"] as! [[String: Any]])[0]["parts"] as! [[String: Any]])[0]["text"] as? String) == "Hello", "Gemini policy is separate from raw user text")
let separatedCompatible = try LooiAIRequest.text(.fresh("qwen"), key: "test-key", prompt: "Hello", systemInstruction: chinesePolicy)
let separatedMessages = (try JSONSerialization.jsonObject(with: separatedCompatible.httpBody!) as! [String: Any])["messages"] as! [[String: Any]]
check(separatedMessages[0]["role"] as? String == "system" && separatedMessages[1]["content"] as? String == "Hello", "compatible providers receive system and user roles separately")
let firmwareDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let firmwareBytes = Data([0xe9] + Array(repeating: UInt8(0), count: 63))
let firmwareManifest: [String: Any] = ["version": "2.0.0", "chip": "ESP32-S3", "partition": "app3M_fat9M_16MB", "size": 64, "sha256": "27585a5e85e1a2afcb9718bcfd03a0fd8822b4cfdfd06862e3a2c0cfd1c092eb"]
var n8Manifest = firmwareManifest
n8Manifest["board"] = "n8r8"; n8Manifest["partition"] = "looi_8m"
try LooiFirmwareCache.verify(firmwareBytes, manifest: n8Manifest)
n8Manifest["board"] = "n16r8"
rejects("8MB release cannot claim a 16MB board") { try LooiFirmwareCache.verify(firmwareBytes, manifest: n8Manifest) }
let firmwareCache = LooiFirmwareCache(directory: firmwareDirectory)
try firmwareCache.save(firmwareBytes, manifest: firmwareManifest)
check(try LooiFirmwareCache(directory: firmwareDirectory).read()?.bytes == firmwareBytes, "verified firmware survives cache recreation without networking")
var corruptFirmware = firmwareBytes; corruptFirmware[3] = 1
rejects("bad download cannot replace prepared firmware") { try firmwareCache.save(corruptFirmware, manifest: firmwareManifest) }
check(try firmwareCache.read()?.bytes == firmwareBytes, "failed download preserves prepared package")
try corruptFirmware.write(to: firmwareDirectory.appendingPathComponent("27585a5e85e1a2afcb9718bcfd03a0fd8822b4cfdfd06862e3a2c0cfd1c092eb.bin"))
rejects("corrupted cached image is rejected before upload") { _ = try firmwareCache.read() }
try FileManager.default.removeItem(at: firmwareDirectory)

check(LooiFirmwareCache.allowsUpdate([:]), "legacy packages use stable channel")
check(!LooiFirmwareCache.allowsUpdate(["channel":"preview"]), "preview packages require explicit opt-in")
check(LooiFirmwareCache.allowsUpdate(["channel":"preview"], includePreview:true), "preview opt-in allows matching cached preview")
check(!LooiFirmwareCache.allowsUpdate(["channel":"unknown"], includePreview:true), "unknown update channels rejected")
print("Native Swift checks passed: \(passed)")

import Foundation
import Combine
import CryptoKit
import Darwin

@MainActor final class LooiDeviceWifi: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    static let manifestURL = URL(string: "https://github.com/xlle-er/LOOI-DF26-Firmware/releases/latest/download/looi-s3-manifest.json")!
    private let firmwareCache = LooiFirmwareCache(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LOOIFirmware"))
    @Published private(set) var prepared: [String: Any]?
    override init() { super.init(); prepared = try? firmwareCache.read()?.manifest }
    @Published private(set) var devices: [String: String] = [:]
    @Published private(set) var info: [String: Any] = [:]
    @Published private(set) var connected = false
    var onChange: (() -> Void)?
    var onLost: (() -> Void)?
    private var host = "", password = "", token = ""
    private let clientID = UUID().uuidString
    private var heartbeat: Task<Void, Never>?
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var epoch = 0, motionEpoch = 0
    private var controlToken = 0
    static func localHost(_ input: String) throws -> String {
        let h = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "http://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }), parts[0] == 10 || parts[0] == 192 && parts[1] == 168 || parts[0] == 172 && (16...31).contains(parts[1]) else { throw LooiError.message("请输入局域网 IPv4 地址") }
        return h
    }
    func connect(_ address: String, password: String) async throws {
        disconnect(); host = try Self.localHost(address); self.password = password
        let status = try await refresh()
        guard status["chip"] as? String == "ESP32-S3" else { throw LooiError.message("设备型号不兼容") }
        connected = true
        onChange?()
        let current = epoch
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, self.connected, self.epoch == current else { return }
                do {
                    if self.info["control_owner"] as? String == "http:\(self.clientID)", self.controlToken != 0 {
                        let renewing = self.controlToken
                        do { _ = try await self.command(["type": "control_renew"]) } catch { if self.controlToken == renewing { self.controlToken = 0 } }
                    }
                    _ = try await self.refresh()
                } catch {
                    if self.epoch == current { self.disconnect(); self.onLost?() }; return
                }
            }
        }
    }
    func disconnect() { epoch += 1; motionEpoch += 1; controlToken = 0; heartbeat?.cancel(); heartbeat = nil; connected = false; onChange?() }
    @discardableResult func refresh() async throws -> [String: Any] {
        let value = try await request("/api/status")
        guard let token = value["csrf_token"] as? String else { throw LooiError.message("设备响应无效") }
        self.token = token; info = value;
        if let board = (value["hardware_profile"] as? [String: Any])?["board"] as? String, ["n16r8", "n8r8"].contains(board) { UserDefaults.standard.set(board, forKey: "looi.hardware.board") }; onChange?(); return value
    }
    func command(_ payload: [String: Any], timeout: TimeInterval = 8) async throws -> [String: Any] {
        let type = payload["type"] as? String ?? ""
        if type == "stop" { motionEpoch += 1; controlToken = 0; return try await checkedRequest(payload, timeout: timeout) }
        let current = motionEpoch
        try Task.checkCancellation()
        if type == "motion" && controlToken == 0 {
            let claim = try await checkedRequest(["type": "control_acquire"], timeout: timeout)
            guard current == motionEpoch else { throw CancellationError() }
            controlToken = claim["control_token"] as? Int ?? 0
        }
        try Task.checkCancellation()
        var object = payload; object["control_token"] = controlToken
        let result = try await checkedRequest(object, timeout: timeout)
        guard current == motionEpoch else { throw CancellationError() }
        if type == "control_acquire" { controlToken = result["control_token"] as? Int ?? 0 }
        if ["calibration_set", "wifi_configure", "wifi_forget", "ota_start", "control_release", "firmware_check", "firmware_install", "hardware_set"].contains(type) { controlToken = 0 }
        return result
    }
    private func checkedRequest(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var object = payload; object["id"] = UUID().uuidString
        let result = try await request("/api/command", payload: object, timeout: timeout)
        guard result["type"] as? String != "error", result["accepted"] as? Bool != false else { throw LooiError.message(result["message"] as? String ?? "设备拒绝指令") }
        return result
    }
    private func request(_ path: String, payload: [String: Any]? = nil, timeout: TimeInterval = 8) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://\(host)\(path)")!)
        request.timeoutInterval = timeout; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Basic " + Data("admin:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "X-Looi-Client")
        if let payload { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: payload); request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue(token, forHTTPHeaderField: "X-OTA-Token") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw LooiError.message("设备网络请求失败，请检查管理密码和连接") }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LooiError.message("设备响应无效") }
        return value
    }
    func upload(_ bytes: Data, name: String, expectedSHA: String? = nil, closeHotspot: Bool = true, progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws {
        guard connected else { throw LooiError.message("请先通过 Wi-Fi 连接设备") }
        guard (32...3145728).contains(bytes.count), name.hasSuffix(".bin"), bytes.first == 0xe9 else { throw LooiError.message("请选择 ESP32-S3 应用 .bin，最大 3 MB") }
        if info["hardware_protocol"] as? Int == 1 {
            let board = (info["hardware_profile"] as? [String: Any])?["board"] as? String ?? ""
            let partition = info["partition"] as? String ?? ""
            let marker = Data("LOOI_HW_V1|\(board)|1|\(partition)|END".utf8)
            guard bytes.range(of: marker) != nil else { throw LooiError.message("固件与接线配置协议或板型不兼容") }
        }
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard expectedSHA == nil || expectedSHA?.lowercased() == sha else { throw LooiError.message("固件 SHA-256 校验失败") }
        heartbeat?.cancel(); _ = try await command(["type": "ota_start", "close_ap_after_update": closeHotspot])
        let boundary = "LOOI-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"firmware\"; filename=\"looi-s3.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body.append(bytes); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "http://\(host)/update")!)
        request.httpMethod = "POST"; request.timeoutInterval = 180
        for (key, value) in ["Authorization": "Basic " + Data("admin:\(password)".utf8).base64EncodedString(), "X-OTA-Token": token, "X-Looi-Client": clientID, "X-Firmware-Size": String(bytes.count), "X-Firmware-SHA256": sha, "Content-Type": "multipart/form-data; boundary=\(boundary)"] { request.setValue(value, forHTTPHeaderField: key) }
        let delegate = LooiReleaseRedirects(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.upload(for: request, from: body)
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200, value?["accepted"] as? Bool == true else { throw LooiError.message(value?["message"] as? String ?? "固件上传失败") }
        disconnect()
    }
    func release(includePreview: Bool = false) async throws -> [String: Any] {
        let board = UserDefaults.standard.string(forKey: "looi.hardware.board") ?? "n16r8"
        let url = board == "n8r8" ? URL(string: Self.manifestURL.absoluteString.replacingOccurrences(of: "looi-s3-manifest", with: "looi-s3-n8r8-manifest"))! : Self.manifestURL
        func fetch(_ channel: String) async throws -> [String: Any] {
            let address = channel == "preview" ? URL(string: url.absoluteString.replacingOccurrences(of: "/latest/download/", with: "/download/preview/"))! : url
            let data = try await download(address, limit: 8192)
            guard var release = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LooiError.message("升级清单无效") }
            release["channel"] = channel
            try validate(release); return release
        }
        if !includePreview { return try await fetch("stable") }
        let stable = try? await fetch("stable")
        let preview = try? await fetch("preview")
        if let preview, stable == nil || looiCompareVersions(preview["version"] as? String ?? "0", stable?["version"] as? String ?? "0") > 0 { return preview }
        if let stable { return stable }
        throw LooiError.message("在线版本暂不可用")
    }

    private func validate(_ release: [String: Any]) throws {
        guard let version = release["version"] as? String, version.range(of: #"^v?[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil, release["chip"] as? String == "ESP32-S3", ((release["partition"] as? String == "app3M_fat9M_16MB" && (release["board"] as? String ?? "n16r8") == "n16r8") || (release["partition"] as? String == "looi_8m" && release["board"] as? String == "n8r8")), let size = release["size"] as? Int, (32...3145728).contains(size), let sha = release["sha256"] as? String, sha.count == 64, sha.allSatisfy({ $0.isHexDigit }), let url = release["url"] as? String, url.hasPrefix("https://github.com/xlle-er/LOOI-DF26-Firmware/releases/") else { throw LooiError.message("固件版本或分区不兼容") }
    }
    func prepareRelease(_ release: [String: Any], progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws {
        try validate(release)
        let bytes = try await download(URL(string: release["url"] as! String)!, limit: 3145728, progress: progress)
        try firmwareCache.save(bytes, manifest: release); prepared = release
    }
    func installPrepared(closeHotspot: Bool = true, includePreview: Bool = false, progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws {
        guard let cached = try firmwareCache.read() else { throw LooiError.message("请先在联网时下载固件，再连接 ESP 热点") }
        guard LooiFirmwareCache.allowsUpdate(cached.manifest, includePreview: includePreview) else { throw LooiError.message("请先开启预览版更新") }
        try await upload(cached.bytes, name: "looi-s3.bin", expectedSHA: cached.manifest["sha256"] as? String, closeHotspot: closeHotspot, progress: progress)
    }
    private func download(_ url: URL, limit: Int, progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> Data {
        // URLSession validates HTTPS trust. Restrict every redirect to GitHub release hosts.
        let delegate = LooiReleaseRedirects(limit: limit, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await delegate.download(url, session: session)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= limit else { throw LooiError.message("在线版本暂不可用，或下载文件过大") }
        return data
    }
    func discover() { stopDiscovery(); devices = [:]; browser.delegate = self; browser.searchForServices(ofType: "_looi._tcp.", inDomain: "local.") }
    func stopDiscovery() { browser.stop(); services.forEach { $0.stop() }; services = [] }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) { services.append(service); service.delegate = self; service.resolve(withTimeout: 5) }
    func netServiceDidResolveAddress(_ sender: NetService) {
        for data in sender.addresses ?? [] {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let code = data.withUnsafeBytes { ptr in getnameinfo(ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) }
            if code == 0, let address = try? Self.localHost(String(cString: host)) { devices[sender.name] = address; return }
        }
    }
}

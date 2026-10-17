import Foundation
import Combine

@MainActor final class LooiDeviceSession: ObservableObject {
    unowned let robot: LooiBluetooth
    @Published var statusAvailable = false
    @Published var info: [String: Any] = [:]
    @Published var password = ""
    @Published var needsPassword = false
    @Published var needsName = false
    @Published var message = ""
    @Published var phase = "idle"
    @Published var busy = false
    @Published var progress: Double?
    @Published var progressLabel = ""
    private var progressID = UUID()
    private var deviceReleaseChecked = false
    var hasUpdate: Bool {
        guard let available = release?["version"] as? String else { return false }
        guard let current = info["firmware_version"] as? String else { return true }
        return looiCompareVersions(available, current) > 0
    }
    func setProgress(_ label: String, _ value: Double? = nil) {
        progressID = UUID(); progressLabel = label; progress = value.map { min(1, max(0, $0)) }
    }
    func transferProgress(_ label: String) -> @MainActor @Sendable (Double) -> Void {
        setProgress(label, 0); let id = progressID
        return { [weak self] value in
            guard let self, self.progressID == id else { return }
            if value >= 1 && label == "正在上传固件" { self.setProgress("设备正在写入与校验") }
            else { self.progress = min(1, max(self.progress ?? 0, value)) }
        }
    }
    func checkUpdates() async throws {
        setProgress("正在检查版本…")
        info = try await command("device_status"); statusAvailable = true
        release = nil; deviceReleaseChecked = false
        release = try await robot.wifi.release(includePreview: preview)
        message = hasUpdate ? "发现新版本" : "已是最新版本"
        setProgress("")
    }
    @Published var release: [String: Any]?
    @Published var manualAddress = ""
    @Published var localFirmware: Data?
    private var deviceID = ""
    private var pendingHost: String?
    private var inspecting = false
    private var inspectGeneration = 0
    private var reconnectID: UUID?
    init(robot: LooiBluetooth) { self.robot = robot }
    var needsWiringConfiguration: Bool { statusAvailable && info["hardware_configured"] as? Bool == false }
    var supportsIdentity: Bool { (info["capabilities"] as? [String] ?? []).contains("device_identity") }
    var preview: Bool { UserDefaults.standard.bool(forKey: "looi.ota.preview") }
    var closeHotspot: Bool { UserDefaults.standard.object(forKey: "looi.ota.close") as? Bool ?? true }
    func disconnected() {
        inspectGeneration += 1; inspecting = false; statusAvailable = false; info = [:]
    }
    func inspect() async {
        guard robot.isConnected, !inspecting else { return }
        statusAvailable = false; inspecting = true
        let generation = inspectGeneration
        defer { if generation == inspectGeneration { inspecting = false } }
        do {
            let value = try await robot.send(["type": "device_status"], preferBLE: true)
            guard generation == inspectGeneration, robot.isConnected, let id = value["device_id"] as? String else { return }
            info = value; statusAvailable = true
            if let board = (value["hardware_profile"] as? [String: Any])?["board"] as? String { UserDefaults.standard.set(board, forKey: "looi.hardware.board") }
            if id != deviceID { localFirmware = nil; deviceID = id; password = (try? LooiKeychain.read("device.\(id)")) ?? ""; phase = "idle"; release = nil }
            if password.isEmpty { needsPassword = true }
            else { try await authenticate() }
        } catch { if generation == inspectGeneration { message = error.localizedDescription } }
    }
    var diagnostics: String {
        let safe = info.filter { !["csrf_token", "control_token", "password", "admin_password"].contains($0.key) }
        guard let data = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    func restoreDefaultWiring() async throws {
        info = try await command("device_status")
        guard let profile = LooiDeviceReadiness.defaultWiringRepair(info) else { throw LooiError.message("设备已有接线配置，请保留现有配置") }
        _ = try await command("hardware_set", ["hardware_profile": profile])
        robot.disconnect(); message = "接线已保存，请重新连接"
    }
    func finishDebug() async throws {
        info = try await command("device_status"); statusAvailable = true
        if info["ota_mode"] as? Bool == true { try await exitUpgrade() }
    }
    func exitUpgrade() async throws {
        _ = try await command("ota_exit")
        info = try await command("device_status"); statusAvailable = true; phase = "idle"; release = nil; message = "已退出升级模式"
    }
    func requestNetwork(_ address: String) { pendingHost = address; needsPassword = true }
    func authenticate() async throws {
        if let host = pendingHost {
            try await robot.connectWifi(host, password: password)
            info = robot.wifi.info; let nextID = info["device_id"] as? String ?? ""; if nextID != deviceID { phase = "idle"; release = nil; localFirmware = nil }; deviceID = nextID; pendingHost = nil
        }
        guard !deviceID.isEmpty else { throw LooiError.message("请先连接自己的机器人") }
        if supportsIdentity { info = try await command("admin_auth") }
        else { _ = try await command("wifi_scan") } // Harmless authenticated legacy management operation.
        try LooiKeychain.save(password, key: "device.\(deviceID)")
        needsPassword = false
        if let expected = UserDefaults.standard.string(forKey: "looi.ota.expected.\(deviceID)"), info["firmware_version"] as? String == expected {
            phase = "complete"; message = "升级完成"; UserDefaults.standard.removeObject(forKey: "looi.ota.expected.\(deviceID)")
        }
        needsName = supportsIdentity && info["device_name_custom"] as? Bool == false && info["ap_name_custom"] as? Bool == false && !UserDefaults.standard.bool(forKey: "looi.named.\(deviceID)")
    }
    func skipName() { UserDefaults.standard.set(true, forKey: "looi.named.\(deviceID)"); needsName = false }
    func rename(_ name: String) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 24 else { throw LooiError.message("名字最多 24 个 UTF-8 字节") }
        _ = try await command("device_name_set", ["name": name]); skipName(); robot.disconnect(); message = "名称已保存，请重新连接"
    }
    func changePassword(_ value: String) async throws {
        guard (8...63).contains(value.utf8.count), value.utf8.allSatisfy({ (32...126).contains($0) }) else { throw LooiError.message("密码需为 8–63 位可打印 ASCII 字符") }
        _ = try await command("admin_password_set", ["new_password": value])
        try LooiKeychain.save(value, key: "device.\(deviceID)"); password = value; robot.disconnect(); message = "密码已保存，请重新连接"
    }
    func command(_ type: String, _ extra: [String: Any] = [:]) async throws -> [String: Any] {
        var payload = extra; payload["type"] = type
        do { return try await robot.manage(payload, password: password) }
        catch { if error.localizedDescription.localizedCaseInsensitiveContains("password") || error.localizedDescription.contains("管理密码") { needsPassword = true }; throw error }
    }
    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task { defer { busy = false; setProgress("") }; do { try await operation() } catch is CancellationError {} catch { if self.phase == "checking" { self.phase = "fallback" }; message = error.localizedDescription } }
    }
    func enter() async throws {
        guard !password.isEmpty else { needsPassword = true; return }
        info = try await command("device_status"); reconnectID = robot.connectedID
        info = try await command("ota_start", ["close_ap_after_update": closeHotspot])
        if info["connected"] as? Bool == true {
            if let ip = info["ip"] as? String { try? await connectHTTP(manualAddress.isEmpty ? ip : manualAddress) }
            if (info["capabilities"] as? [String] ?? []).contains("async_ota") {
                phase = "checking"; _ = try await command("firmware_check", ["channel": preview ? "preview" : "stable"])
                try await pollJob(checking: true); return
            }
        }
        if robot.wifi.connected { phase = "connected"; return }
        try await hotspot()
    }
    func pollJob(checking: Bool) async throws {
        setProgress(checking ? "正在检查版本…" : "设备正在下载并安装", checking ? nil : 0)
        for _ in 0..<600 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            do { info = try await command("ota_status") }
            catch { if !checking { try await verifyReboot(); return }; throw error }
            let state = info["ota_phase"] as? String ?? ""
            if state == "failed" { phase = "fallback"; message = info["error"] as? String ?? "设备下载失败"; return }
            if checking && state == "ready" { release = info["release"] as? [String: Any]; deviceReleaseChecked = true; phase = "online"; message = hasUpdate ? "发现新版本" : "已是最新版本"; return }
            if state == "rebooting" { try await verifyReboot(); return }
            if !checking { progress = min(1, max(0, Double(info["ota_progress"] as? Int ?? 0) / 100)) }
            message = state == "checking" ? "正在检查版本…" : "正在下载：\(info["ota_progress"] as? Int ?? 0)%"
        }
        phase = "fallback"; throw LooiError.message("升级超时，请重试")
    }
    func hotspot() async throws {
        info = try await command("ota_start", ["hotspot": true, "close_ap_after_update": closeHotspot])
        phase = "hotspot"; message = ""
    }
    func compatiblePackage(_ package: [String: Any]?) -> Bool {
        guard let package, LooiFirmwareCache.allowsUpdate(package, includePreview: preview) else { return false }
        if let release, package["version"] as? String != release["version"] as? String || package["sha256"] as? String != release["sha256"] as? String { return false }
        return (package["board"] as? String ?? "n16r8") == ((info["hardware_profile"] as? [String: Any])?["board"] as? String ?? "n16r8")
    }
    func stageLocal(_ bytes: Data) throws {
        guard (32...3145728).contains(bytes.count), bytes.first == 0xe9 else { throw LooiError.message("固件大小校验失败") }
        if info["hardware_protocol"] as? Int == 1 {
            let board = (info["hardware_profile"] as? [String: Any])?["board"] as? String ?? ""
            let marker = Data("LOOI_HW_V1|\(board)|1|\(info["partition"] as? String ?? "")|END".utf8)
            guard bytes.range(of: marker) != nil else { throw LooiError.message("固件与设备板型不兼容") }
        }
        localFirmware = bytes; release = nil; message = "本地固件已就绪"
    }
    func download() async throws {
        let value: [String: Any]
        if let release { value = release } else { value = try await robot.wifi.release(includePreview: preview) }
        try await robot.wifi.prepareRelease(value, progress: transferProgress("正在下载固件")); release = value; localFirmware = nil; message = "固件已下载"; if robot.wifi.connected { phase = "connected" }
    }
    func connectHTTP(_ address: String) async throws {
        let expected = deviceID
        try await robot.wifi.connect(address, password: password)
        guard robot.wifi.info["device_id"] as? String == expected else { robot.wifi.disconnect(); throw LooiError.message("设备身份不匹配") }
        message = "Wi-Fi 已连接"
    }
    func checkHotspotConnection() async throws {
        let ssid = info["ap_ssid"] as? String ?? "LOOI"
        message = "请在系统 Wi-Fi 中连接：\(ssid)"
        try await connectHTTP(manualAddress.isEmpty ? "192.168.4.1" : manualAddress)
        phase = "connected"
    }
    func install() async throws {
        setProgress("正在安装固件", 0)
        if let expected = release?["version"] as? String ?? robot.wifi.prepared?["version"] as? String { UserDefaults.standard.set(expected, forKey: "looi.ota.expected.\(deviceID)") }
        if phase == "online", let release {
            if !deviceReleaseChecked {
                _ = try await command("firmware_check", ["channel": preview ? "preview" : "stable"])
                try await pollJob(checking: true)
                guard phase == "online" else { return }
                guard self.release?["version"] as? String == release["version"] as? String, self.release?["channel"] as? String == release["channel"] as? String else { message = "版本已变化，请确认后再次安装"; return }
            }
            guard hasUpdate else { message = "已是最新版本"; return }
            _ = try await command("firmware_install", ["version": release["version"] ?? "", "channel": release["channel"] ?? (preview ? "preview" : "stable"), "close_ap_after_update": closeHotspot])
            phase = "installing"; try await pollJob(checking: false)
        } else if let localFirmware {
            try await robot.wifi.upload(localFirmware, name: "firmware.bin", closeHotspot: closeHotspot, progress: transferProgress("正在上传固件"))
            release = nil; try await verifyReboot(expectedVersion: "")
        } else {
            try await robot.wifi.installPrepared(closeHotspot: closeHotspot, includePreview: preview, progress: transferProgress("正在上传固件"))
            try await verifyReboot()
        }
    }
    func verifyReboot(expectedVersion: String? = nil) async throws {
        setProgress("正在重启…"); phase = "rebooting"; message = "正在重启…"
        let expected = expectedVersion ?? release?["version"] as? String ?? robot.wifi.prepared?["version"] as? String
        robot.wifi.disconnect()
        if let reconnectID { robot.disconnect(); try await Task.sleep(nanoseconds: 3_000_000_000); robot.connect(reconnectID) }
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard robot.isConnected else { continue }
            if let state = try? await command("device_status"), state["device_id"] as? String == deviceID {
                info = state
                if let expected, state["firmware_version"] as? String == expected { phase = "complete"; message = "升级完成"; UserDefaults.standard.removeObject(forKey: "looi.ota.expected.\(deviceID)"); return }
            }
        }
        message = "请重新连接并核对版本"
    }
}

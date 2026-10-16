import SwiftUI
import UniformTypeIdentifiers

struct LooiDeviceManagement: View {
    @ObservedObject var robot: LooiBluetooth
    @ObservedObject var wifi: LooiDeviceWifi
    @ObservedObject private var localization = LooiLocalization.shared
    @State private var address = "192.168.4.1"
    @State private var admin = "12345678"
    @State private var ssid = ""
    @State private var password = ""
    @State private var left = true
    @State private var right = false
    @State private var swap = false
    @State private var busy = false
    @State private var choosingFile = false
    @State private var info: [String: Any] = [:]
    @State private var release: [String: Any]?
    @State private var networks: [String] = []
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(L("Wi-Fi 连接")), footer: Text(L("连接 ESP 热点或同一局域网；也可通过 BLE 配网。"))) {
                    TextField(L("设备 IP"), text: $address).keyboardType(.numbersAndPunctuation).autocapitalization(.none).disableAutocorrection(true)
                    SecureField(L("设备管理密码"), text: $admin)
                    Button(L("Wi-Fi 连接")) { run { try await robot.connectWifi(address, password: admin); try await refresh() } }
                    Button(L("发现局域网设备")) { wifi.discover() }
                    ForEach(wifi.devices.keys.sorted(), id: \.self) { name in Button("\(name) · \(wifi.devices[name] ?? "")") { address = wifi.devices[name] ?? address } }
                    Button(L("读取设备状态")) { run { try await refresh() } }
                    Text(["device_id", "firmware_version", "network_state", "ip"].compactMap { info[$0] as? String }.joined(separator: " · ")).font(.caption)
                }.disabled(busy)
                Section(header: Text(L("设备配网"))) {
                    TextField(L("Wi-Fi 名称"), text: $ssid).autocapitalization(.none).disableAutocorrection(true)
                    SecureField(L("Wi-Fi 密码"), text: $password)
                    Button(L("扫描 Wi-Fi")) { run {
                        var result = try await command("wifi_scan")
                        while result["scanning"] as? Bool == true { try await Task.sleep(nanoseconds: 1_000_000_000); result = try await command("wifi_scan") }
                        networks = (result["networks"] as? [[String: Any]] ?? []).compactMap { $0["ssid"] as? String }
                    } }
                    ForEach(networks, id: \.self) { name in Button(name) { ssid = name } }
                    Button(L("保存并连接")) { run { _ = try await command("wifi_configure", ["ssid": ssid, "password": password]); password = ""; message = "正在连接，稍后读取状态查看 IP" } }
                    Button(L("忘记网络"), role: .destructive) { run { _ = try await command("wifi_forget"); try await refresh() } }
                }.disabled(busy)
                Section(header: Text(L("电机方向")), footer: Text(L("先架空车轮。保存会先停车，点动最多 300 毫秒。"))) {
                    Toggle(L("左轮反向"), isOn: $left); Toggle(L("右轮反向"), isOn: $right); Toggle(L("交换左右轮"), isOn: $swap)
                    Button(L("保存方向")) { run { _ = try await command("calibration_set", ["left_invert": left, "right_invert": right, "swap": swap]); try await refresh() } }
                    Button(L("前后反了")) { run { _ = try await command("calibration_set", ["shortcut": "reverse_forward"]); try await refresh() } }
                    Button(L("左右转向反了")) { run { _ = try await command("calibration_set", ["shortcut": "reverse_steering"]); try await refresh() } }
                    Button(L("恢复默认方向")) { run { _ = try await command("calibration_set", ["reset": true]); try await refresh() } }
                }.disabled(busy)
                Section(header: Text(L("点动测试"))) {
                    Button(L("接管控制")) { run { _ = try await command("control_acquire", ["takeover": true]) } }.disabled(busy)
                    ForEach(["forward", "backward", "left", "right", "left_forward", "left_backward", "right_forward", "right_backward"], id: \.self) { direction in
                        Button(LM(testTitle(direction))) { run { _ = try await command("control_acquire", ["takeover": true]); _ = try await command("calibration_test", ["direction": direction]) } }.disabled(busy)
                    }
                    Button(L("立即停止"), role: .destructive) { Task { _ = await robot.stopMotion() } }
                }
                Section(header: Text(L("固件升级")), footer: Text(L("上传需要 Wi-Fi 连接。保持供电，升级后重连核对版本。"))) {
                    Button(L("选择本地 .bin")) { choosingFile = true }
                    Button(L("检查在线版本")) { run { release = try await wifi.release(); message = "在线版本：\(release?["version"] as? String ?? "")" } }
                    if let release { Button(L("安装在线版本")) { run { try await wifi.installRelease(release); robot.disconnect(); message = "升级成功，请重连核对版本" } } }
                    Button(L("退出升级模式")) { run { _ = try await command("ota_exit") } }
                }.disabled(busy)
                if busy { ProgressView() }
                if !message.isEmpty { Text(LM(message)).font(.footnote).accessibilityIdentifier("device-management-status") }
            }
            .navigationTitle(L("设备管理"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() }.disabled(busy) } }
            .onDisappear { wifi.stopDiscovery() }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                run {
                    guard wifi.connected else { throw LooiError.message("请先通过 Wi-Fi 连接设备") }
                    guard let url = try result.get().first, url.pathExtension.lowercased() == "bin" else { throw LooiError.message("请选择应用 .bin 文件") }
                    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard (32...3145728).contains(size) else { throw LooiError.message("固件最大 3 MB") }
                    let data = try Data(contentsOf: url)
                    try await wifi.upload(data, name: url.lastPathComponent); robot.disconnect(); message = "升级成功，请重连核对版本"
                }
            }
        }.navigationViewStyle(.stack)
    }
    private func command(_ type: String, _ extra: [String: Any] = [:]) async throws -> [String: Any] {
        var payload = extra; payload["type"] = type
        return try await robot.manage(payload, password: admin)
    }
    private func refresh() async throws {
        info = try await command("device_status")
        if let calibration = info["calibration"] as? [String: Any] { left = calibration["left_invert"] as? Bool ?? true; right = calibration["right_invert"] as? Bool ?? false; swap = calibration["swap"] as? Bool ?? false }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task { defer { busy = false }; do { try await operation() } catch is CancellationError { } catch { message = error.localizedDescription } }
    }
    private func testTitle(_ direction: String) -> String { ["forward": "前进", "backward": "后退", "left": "左转", "right": "右转", "left_forward": "左轮正转", "left_backward": "左轮反转", "right_forward": "右轮正转", "right_backward": "右轮反转"][direction] ?? direction }
}

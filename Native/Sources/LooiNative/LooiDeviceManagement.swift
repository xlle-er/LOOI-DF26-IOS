import SwiftUI
import UniformTypeIdentifiers

struct LooiDeviceManagement: View {
    @ObservedObject var robot: LooiBluetooth
    @ObservedObject var wifi: LooiDeviceWifi
    @ObservedObject private var session: LooiDeviceSession
    @ObservedObject private var localization = LooiLocalization.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var ssid = ""
    @State private var routerPassword = ""
    @State private var name = ""
    @State private var newPassword = ""
    @State private var left = true
    @State private var right = false
    @State private var swap = false
    @State private var networks: [String] = []
    @State private var choosingFile = false
    @AppStorage("looi.ota.preview") private var preview = false
    @AppStorage("looi.ota.close") private var closeHotspot = true
    init(robot: LooiBluetooth, wifi: LooiDeviceWifi) { self.robot = robot; self.wifi = wifi; self.session = robot.management }
    var body: some View {
        NavigationView {
            Form {
                LooiDeviceAccess(session: session)
                Picker(L("调试机器人"), selection: $tab) {
                    Text(L("马达测试")).tag(0); Text(L("配网")).tag(1); Text("OTA").tag(2)
                }.pickerStyle(.segmented)
                if !robot.isConnected { Text(L("请先连接自己的机器人")) }
                Group {
                    if tab == 0 { motors }
                    if tab == 1 { network }
                    if tab == 2 { ota }
                }.disabled(session.busy || !robot.isConnected)
                if session.busy { ProgressView() }
                if !session.message.isEmpty { Text(LM(session.message)).font(.footnote).accessibilityIdentifier("device-management-status") }
                NavigationLink(L("管理设置")) { managementSettings }
            }
            .navigationTitle(L("调试机器人"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("立即停止"), role: .destructive) { Task { _ = await robot.stopMotion() } } }
                ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() } }
            }
            .task { await session.inspect(); loadCalibration() }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data]) { result in
                session.run {
                    let url = try result.get(); guard url.pathExtension.lowercased() == "bin" else { throw LooiError.message("请选择应用 .bin 文件") }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard (32...3145728).contains(size) else { throw LooiError.message("固件最大 3 MB") }
                    let bytes = try Data(contentsOf: url)
                    if session.phase == "hotspot" { try session.stageLocal(bytes) }
                    else { try await wifi.upload(bytes, name: url.lastPathComponent, closeHotspot: closeHotspot); session.release = nil; try await session.verifyReboot(expectedVersion: "") }
                }
            }
        }.navigationViewStyle(.stack)
    }
    private var motors: some View {
        Group {
            Section(header: Text(L("点动测试")), footer: Text(L("先架空车轮，点动最多 300 毫秒。"))) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                    ForEach([("forward", "前进"), ("backward", "后退"), ("left", "左转"), ("right", "右转"), ("left_forward", "左轮正转"), ("left_backward", "左轮反转"), ("right_forward", "右轮正转"), ("right_backward", "右轮反转")], id: \.0) { direction, title in
                        Button(L(title)) { session.run { _ = try await session.command("control_acquire", ["takeover": true]); _ = try await session.command("calibration_test", ["direction": direction]) } }.frame(minHeight: 44)
                    }
                }
            }
            Section(header: Text(L("电机方向"))) {
                Toggle(L("左轮反向"), isOn: $left); Toggle(L("右轮反向"), isOn: $right); Toggle(L("交换左右轮"), isOn: $swap)
                Button(L("保存方向")) { calibration(["left_invert": left, "right_invert": right, "swap": swap]) }
                Button(L("前后反了")) { calibration(["shortcut": "reverse_forward"]) }
                Button(L("左右转向反了")) { calibration(["shortcut": "reverse_steering"]) }
                Button(L("恢复默认方向")) { calibration(["reset": true]) }
            }
        }
    }
    private var network: some View {
        Section(header: Text(L("设备配网"))) {
            TextField(L("Wi-Fi 名称"), text: $ssid).autocapitalization(.none).disableAutocorrection(true)
            SecureField(L("Wi-Fi 密码"), text: $routerPassword)
            Button(L("扫描 Wi-Fi")) { session.run {
                var result = try await session.command("wifi_scan")
                for _ in 0..<30 {
                    if result["scanning"] as? Bool != true { break }
                    try await Task.sleep(nanoseconds: 1_000_000_000); result = try await session.command("wifi_scan")
                }
                networks = (result["networks"] as? [[String: Any]] ?? []).compactMap { $0["ssid"] as? String }
            } }
            ForEach(networks, id: \.self) { value in Button(value) { ssid = value } }
            Button(L("保存并连接")) { session.run { _ = try await session.command("wifi_configure", ["ssid": ssid, "password": routerPassword]); routerPassword = ""; session.message = "正在连接…" } }
            Button(L("忘记网络"), role: .destructive) { session.run { _ = try await session.command("wifi_forget") } }
        }
    }
    private var ota: some View {
        Section(header: Text(L("固件升级"))) {
            if !session.info.isEmpty && !(session.info["capabilities"] as? [String] ?? []).contains("async_ota") {
                DisclosureGroup(L("旧固件帮助")) { Text(L("若无法开启热点，长按 BOOT 3 秒后连接，并通过设备网页上传固件。")) }
            }
            Text((session.info["firmware_version"] as? String ?? "—") + (session.release.map { " → " + ($0["version"] as? String ?? "") } ?? ""))
            if session.phase == "idle" || session.phase == "complete" {
                Button(L("进入升级模式")) { session.run { try await session.enter() } }
            } else if session.phase == "fallback" {
                Button(L("改用热点升级")) { session.run { try await session.hotspot() } }
            } else if session.phase == "hotspot" {
                Text(session.info["ap_ssid"] as? String ?? "LOOI")
                if session.localFirmware != nil || session.compatiblePackage(wifi.prepared) {
                    Text(L("固件已下载") + " · " + (wifi.prepared?["version"] as? String ?? "bin"))
                    Text(L("请在系统 Wi-Fi 连接该热点，再返回继续。"))
                    Button(L("复制热点密码")) { UIPasteboard.general.string = session.password }
                    Button(L("已连接，继续")) { session.run { try await session.checkHotspotConnection() } }
                } else {
                    Button(L("下载固件")) { session.run { try await session.download() } }
                }
                Button(L("选择本地 .bin")) { choosingFile = true }
            } else if session.phase == "online" || session.phase == "connected" {
                if session.phase == "online" || session.localFirmware != nil || session.compatiblePackage(wifi.prepared) {
                    Button(L("安装 OTA 更新")) { session.run { try await session.install() } }
                } else { Button(L("下载固件")) { session.run { try await session.download() } } }
                if wifi.connected { Button(L("上传 bin 更新包")) { choosingFile = true } }
            } else if session.phase == "rebooting" {
                Button(L("核对升级版本")) { session.run { try await session.verifyReboot() } }
            }
            if session.phase != "idle" && session.phase != "complete" {
                Button(L("退出升级模式")) { session.run { _ = try await session.command("ota_exit"); session.phase = "idle" } }
            }
        }
    }
    private var managementSettings: some View {
        Form {
            Section(header: Text(L("设备信息"))) {
                Text(session.info["name"] as? String ?? "LOOI")
                Text(session.info["ip"] as? String ?? "192.168.4.1")
                TextField(L("手动指定 IP（可选）"), text: $session.manualAddress).keyboardType(.numbersAndPunctuation)
                Button(L("连接")) { session.run { if session.info.isEmpty { session.requestNetwork(session.manualAddress.isEmpty ? "192.168.4.1" : session.manualAddress) } else { try await session.connectHTTP(session.manualAddress.isEmpty ? (session.info["ip"] as? String ?? "192.168.4.1") : session.manualAddress) } } }
                if session.supportsIdentity {
                    TextField(L("机器人名字（支持中文）"), text: $name)
                    Button(L("修改机器人名字")) { session.run { try await session.rename(name) } }
                    SecureField(L("新管理密码"), text: $newPassword)
                    Button(L("修改管理密码")) { session.run { try await session.changePassword(newPassword); newPassword = "" } }
                } else { Text(L("升级固件后可修改名称和密码")) }
                Button(L("重新输入管理密码")) { session.needsPassword = true }
            }
            Section {
                Toggle(L("预览版更新"), isOn: $preview).onChange(of: preview) { _ in session.release = nil; if session.phase == "online" { session.phase = "idle" } }
                Toggle(L("升级后关闭 ESP 热点"), isOn: $closeHotspot)
            }
        }.navigationTitle(L("管理设置")).disabled(session.busy)
    }
    private func loadCalibration() {
        if let value = session.info["calibration"] as? [String: Any] { left = value["left_invert"] as? Bool ?? true; right = value["right_invert"] as? Bool ?? false; swap = value["swap"] as? Bool ?? false }
    }
    private func calibration(_ values: [String: Any]) { session.run { session.info = try await session.command("calibration_set", values); loadCalibration() } }
}

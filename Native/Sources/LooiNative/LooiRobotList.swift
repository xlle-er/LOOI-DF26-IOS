import SwiftUI

struct LooiRobotList: View {
    @ObservedObject private var localization = LooiLocalization.shared
    @ObservedObject var app: LooiAppModel
    @ObservedObject var bluetooth: LooiBluetooth
    @ObservedObject private var session: LooiDeviceSession
    @Environment(\.dismiss) private var dismiss
    @State private var rename: LooiRobotDevice?
    @State private var wiringSetup = false
    init(app: LooiAppModel, bluetooth: LooiBluetooth) {
        self.app = app; self.bluetooth = bluetooth; self.session = bluetooth.management
    }
    var body: some View {
        NavigationView {
            List {
                if bluetooth.isConnected && session.needsWiringConfiguration {
                    LooiWiringNotice(session: session, connected: true) { wiringSetup = true }
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    Label(LM(bluetooth.message), systemImage: bluetooth.scanning ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                    Button(bluetooth.scanning ? L("停止搜索") : L("搜索附近机器人")) { if bluetooth.scanning { bluetooth.stopScan() } else { bluetooth.scan() } }
                    if bluetooth.connectingID != nil { Button(L("取消连接"), role: .cancel) { bluetooth.disconnect() } }
                }
                Section(header: Text(L("附近的机器人")), footer: Text(L("编号是此 iPhone 识别设备的标识。信号强弱仅供参考；同名时请核对编号、添加本机备注，再连接并核对设备信息。不会自动连接信号最强的设备。"))) {
                    if bluetooth.devices.isEmpty { Text(bluetooth.scanning ? L("正在寻找小伙伴…") : L("尚未发现机器人，请确认身体已开机")).foregroundStyle(.secondary) }
                    ForEach(bluetooth.devices) { device in
                        LooiRobotRow(device: device, bluetooth: bluetooth, rename: { rename = device })
                    }
                }
                Section(header: Text(L("局域网机器人"))) {
                    Button(L("搜索局域网")) { bluetooth.wifi.discover() }
                    LooiLanRobots(bluetooth: bluetooth, wifi: bluetooth.wifi)
                }
                if bluetooth.isConnected {
                    Section(header: Text(L("确认我的机器人"))) {
                        Button(L("输入管理密码")) { bluetooth.management.needsPassword = true }
                        Button(L("断开当前机器人"), role: .destructive) { Task { await bluetooth.stopMotion(); bluetooth.disconnect() } }
                    }
                }
            }
            .background(LooiDeviceAccess(session: bluetooth.management))
            .navigationTitle(L("我的机器人"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() } } }
            .task { bluetooth.scan() }
            .onDisappear { bluetooth.stopScan(); bluetooth.wifi.stopDiscovery() }
            .task(id: bluetooth.connectedID) { if bluetooth.isConnected { await bluetooth.management.inspect() } }
            .sheet(isPresented: $wiringSetup) { LooiDeviceManagement(robot: bluetooth, wifi: bluetooth.wifi) }
            .sheet(item: $rename) { device in LooiRobotRename(device: device, bluetooth: bluetooth) }
        }.navigationViewStyle(.stack)
    }
}

private struct LooiMotionToggle: View {
    @ObservedObject private var localization = LooiLocalization.shared
    @ObservedObject var settings: LooiSettings
    let enabled: Bool
    var body: some View { Toggle(L("允许陪伴时的身体动作"), isOn: $settings.motionEnabled).disabled(!enabled) }
}

private struct LooiRobotRow: View {
    @ObservedObject private var localization = LooiLocalization.shared
    let device: LooiRobotDevice
    @ObservedObject var bluetooth: LooiBluetooth
    let rename: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(bluetooth.displayName(device.id)).font(.headline)
                if bluetooth.preferredID == device.id.uuidString { Text(L("我的机器人")).font(.caption2).padding(.horizontal, 7).padding(.vertical, 4).background(Color.cyan.opacity(0.15), in: Capsule()) }
                else if bluetooth.savedID == device.id.uuidString { Text(L("上次连接")).font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Menu {
                    Button(L("添加 / 修改本机备注"), action: rename)
                    Button(L("设为我的机器人")) { bluetooth.rememberMine(device.id) }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }.accessibilityLabel(L("设备备注"))
            }
            HStack {
                Text(L("编号 %@", device.shortID)).font(.system(.caption, design: .monospaced))
                Spacer()
                Label(L("%@ · %@ dBm", LM(device.signal), String(device.rssi)), systemImage: "wifi").font(.caption)
            }.foregroundStyle(.secondary)
            if bluetooth.connectedID == device.id { Label(L("已连接"), systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            else {
                Button(bluetooth.connectingID == device.id ? L("正在连接…") : L("连接此机器人")) { bluetooth.connect(device.id) }
                    .disabled(bluetooth.connectingID != nil || bluetooth.connectedID != nil)
                    .frame(minHeight: 44).accessibilityIdentifier("connect-\(device.shortID)")
            }
        }.padding(.vertical, 5)
    }
}

private struct LooiRobotRename: View {
    @ObservedObject private var localization = LooiLocalization.shared
    let device: LooiRobotDevice
    @ObservedObject var bluetooth: LooiBluetooth
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        NavigationView {
            Form {
                Text(L("设备编号 %@", device.shortID)).font(.caption)
                TextField(L("例如：小乐的 LOOI"), text: $name)
                Text(L("备注只保存在这台手机，不会修改机器人固件或其他伙伴手机中的名称。")).font(.caption).foregroundStyle(.secondary)
            }.navigationTitle(L("机器人备注"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("取消")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(L("保存")) { bluetooth.rename(device.id, name); dismiss() } }
                }
                .onAppear { name = bluetooth.aliases[device.id.uuidString] ?? "" }
        }.navigationViewStyle(.stack)
    }
}

private struct LooiLanRobots: View {
    @ObservedObject var bluetooth: LooiBluetooth
    @ObservedObject var wifi: LooiDeviceWifi
    var body: some View {
        ForEach(wifi.devices.keys.sorted(), id: \.self) { name in
            Button(name) { if let address = wifi.devices[name] { bluetooth.management.requestNetwork(address) } }
        }
    }
}

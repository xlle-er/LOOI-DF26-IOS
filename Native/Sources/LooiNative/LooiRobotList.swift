import SwiftUI

struct LooiRobotList: View {
    @ObservedObject var app: LooiAppModel
    @ObservedObject var bluetooth: LooiBluetooth
    @Environment(\.dismiss) private var dismiss
    @State private var rename: LooiRobotDevice?
    var body: some View {
        NavigationView {
            List {
                Section {
                    Label(bluetooth.message, systemImage: bluetooth.scanning ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                    Button(bluetooth.scanning ? "停止搜索" : "搜索附近机器人") { if bluetooth.scanning { bluetooth.stopScan() } else { bluetooth.scan() } }
                    if bluetooth.connectingID != nil { Button("取消连接", role: .cancel) { bluetooth.disconnect() } }
                }
                Section(header: Text("附近的机器人"), footer: Text("编号是此 iPhone 识别设备的标识。信号强弱仅供参考；同名时请核对编号、添加本机备注，再连接并用点头确认。不会自动连接信号最强的设备。")) {
                    if bluetooth.devices.isEmpty { Text(bluetooth.scanning ? "正在寻找小伙伴…" : "尚未发现机器人，请确认身体已开机").foregroundStyle(.secondary) }
                    ForEach(bluetooth.devices) { device in
                        LooiRobotRow(device: device, bluetooth: bluetooth, rename: { rename = device })
                    }
                }
                if bluetooth.isConnected {
                    Section(header: Text("确认我的机器人")) {
                        Button("让已连接的机器人点头", action: app.identifyRobot).disabled(app.phase != .idle)
                        Text("点头使用头部舵机，不驱动车轮。确认无误后，可在设备菜单中添加本机备注。").font(.caption).foregroundStyle(.secondary)
                        Button("动作测试", action: app.testMotion).disabled(app.phase != .idle)
                        LooiMotionToggle(settings: app.settings, enabled: app.isActive)
                        Button("断开当前机器人", role: .destructive) { Task { await bluetooth.stopMotion(); bluetooth.disconnect() } }
                    }
                }
            }
            .navigationTitle("我的机器人")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { bluetooth.scan() }
            .onDisappear { bluetooth.stopScan() }
            .sheet(item: $rename) { device in LooiRobotRename(device: device, bluetooth: bluetooth) }
        }.navigationViewStyle(.stack)
    }
}

private struct LooiMotionToggle: View {
    @ObservedObject var settings: LooiSettings
    let enabled: Bool
    var body: some View { Toggle("允许陪伴时的身体动作", isOn: $settings.motionEnabled).disabled(!enabled) }
}

private struct LooiRobotRow: View {
    let device: LooiRobotDevice
    @ObservedObject var bluetooth: LooiBluetooth
    let rename: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(bluetooth.displayName(device.id)).font(.headline)
                if bluetooth.preferredID == device.id.uuidString { Text("我的机器人").font(.caption2).padding(.horizontal, 7).padding(.vertical, 4).background(Color.cyan.opacity(0.15), in: Capsule()) }
                else if bluetooth.savedID == device.id.uuidString { Text("上次连接").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Menu {
                    Button("添加 / 修改本机备注", action: rename)
                    Button("设为我的机器人") { bluetooth.rememberMine(device.id) }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }.accessibilityLabel("设备备注")
            }
            HStack {
                Text("编号 \(device.shortID)").font(.system(.caption, design: .monospaced))
                Spacer()
                Label("\(device.signal) · \(device.rssi) dBm", systemImage: "wifi").font(.caption)
            }.foregroundStyle(.secondary)
            if bluetooth.connectedID == device.id { Label("已连接", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            else {
                Button(bluetooth.connectingID == device.id ? "正在连接…" : "连接此机器人") { bluetooth.connect(device.id) }
                    .disabled(bluetooth.connectingID != nil || bluetooth.connectedID != nil)
                    .frame(minHeight: 44).accessibilityIdentifier("connect-\(device.shortID)")
            }
        }.padding(.vertical, 5)
    }
}

private struct LooiRobotRename: View {
    let device: LooiRobotDevice
    @ObservedObject var bluetooth: LooiBluetooth
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        NavigationView {
            Form {
                Text("设备编号 \(device.shortID)").font(.caption)
                TextField("例如：小乐的 LOOI", text: $name)
                Text("备注只保存在这台手机，不会修改机器人固件或其他伙伴手机中的名称。").font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("机器人备注")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { bluetooth.rename(device.id, name); dismiss() } }
                }
                .onAppear { name = bluetooth.aliases[device.id.uuidString] ?? "" }
        }.navigationViewStyle(.stack)
    }
}

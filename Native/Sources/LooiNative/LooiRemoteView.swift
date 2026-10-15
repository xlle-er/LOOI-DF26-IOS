import SwiftUI

struct LooiRemoteView: View {
    @ObservedObject private var localization = LooiLocalization.shared
    @ObservedObject var remote: LooiRemoteControl
    @ObservedObject var bluetooth: LooiBluetooth
    let compact: Bool
    let close: () -> Void
    var body: some View {
        VStack(spacing: compact ? 8 : 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("遥控器")).font(.headline)
                    Text(bluetooth.isConnected ? bluetooth.connectedName : L("未连接身体")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) { Label(L("关闭遥控"), systemImage: "xmark").frame(minHeight: 44) }
            }
            HStack(spacing: 16) {
                Picker(L("操作方式"), selection: $remote.mode) {
                    Text(L("摇杆")).tag(LooiRemoteControl.Mode.joystick)
                    Text(L("方向键")).tag(LooiRemoteControl.Mode.buttons)
                }.pickerStyle(.segmented).disabled(remote.state != .ready)
                Button { remote.emergencyStop() } label: {
                    Label(L("停止"), systemImage: "stop.fill").font(.headline)
                        .padding(.horizontal, 18).frame(minHeight: 48).background(Color.red, in: Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("remoteStop")
            }
            if compact {
                HStack(spacing: 24) { pad; information }
            } else {
                information
                pad.frame(maxWidth: .infinity)
            }
        }
        .padding(compact ? 12 : 20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityIdentifier("remoteController")
    }
    @ViewBuilder private var pad: some View {
        if remote.mode == .joystick { LooiRemoteJoystick(remote: remote, size: compact ? 142 : 220) }
        else {
            let side: CGFloat = compact ? 44 : 62
            VStack(spacing: 4) {
                direction("前进", icon: "arrow.up", x: 0, y: -1, size: side)
                HStack(spacing: 4) {
                    direction("左转", icon: "arrow.turn.up.left", x: -1, y: 0, size: side)
                    Image(systemName: "car.side.fill").frame(width: side, height: side).foregroundStyle(.secondary)
                    direction("右转", icon: "arrow.turn.up.right", x: 1, y: 0, size: side)
                }
                direction("后退", icon: "arrow.down", x: 0, y: 1, size: side)
            }
        }
    }
    private var information: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LM(remote.message)).font(.footnote).foregroundStyle(remote.state == .failed ? .orange : .secondary)
            Text(L("手动控制期间暂停 AI 身体动作")).font(.caption).foregroundStyle(.secondary)
            HStack { Text(L("速度")); Spacer(); Text(String(format: "%.2f", remote.speed)).monospacedDigit() }.font(.caption)
            Slider(value: $remote.speed, in: 0.05...0.30).accessibilityLabel(L("速度")).disabled(!remote.ready)
            if remote.state == .failed { Button(L("重试")) { remote.retry() }.frame(minHeight: 44).disabled(!bluetooth.isConnected) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func direction(_ title: String, icon: String, x: Double, y: Double, size: CGFloat) -> some View {
        LooiRemoteDirection(remote: remote, title: L(title), icon: icon, x: x, y: y, size: size)
    }
}

private struct LooiRemoteJoystick: View {
    @ObservedObject private var localization = LooiLocalization.shared
    @ObservedObject var remote: LooiRemoteControl
    let size: CGFloat
    @GestureState private var touching = false
    @State private var gesture: UUID?
    @State private var attempted = false
    @State private var offset = CGSize.zero
    var body: some View {
        Circle().fill(Color.white.opacity(0.08))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
            .overlay(Image(systemName: "plus").font(.title).foregroundStyle(.secondary))
            .overlay(Circle().fill(Color.cyan.opacity(remote.ready ? 0.8 : 0.2)).frame(width: size * 0.34, height: size * 0.34).offset(offset))
            .frame(width: size, height: size).contentShape(Circle())
            .highPriorityGesture(DragGesture(minimumDistance: 0).updating($touching) { _, state, _ in state = true }
                .onChanged { value in
                    if !attempted { attempted = true; gesture = remote.begin() }
                    guard let gesture else { return }
                    let radius = size * 0.33
                    let dx = value.location.x - size / 2, dy = value.location.y - size / 2
                    let factor = min(1, radius / max(hypot(dx, dy), 0.001))
                    offset = CGSize(width: dx * factor, height: dy * factor)
                    remote.update(gesture, x: Double(dx / radius), y: Double(dy / radius))
                }.onEnded { _ in release() })
            .onChange(of: touching) { if !$0 { release() } }
            .onChange(of: remote.ready) { if !$0 { offset = .zero } }
            .onDisappear { release() }
            .accessibilityElement().accessibilityLabel(L("摇杆，拖动控制方向，松手停止"))
            .accessibilityAction(named: Text(L("前进"))) { remote.pulse(x: 0, y: -1) }
            .accessibilityAction(named: Text(L("后退"))) { remote.pulse(x: 0, y: 1) }
            .accessibilityAction(named: Text(L("左转"))) { remote.pulse(x: -1, y: 0) }
            .accessibilityAction(named: Text(L("右转"))) { remote.pulse(x: 1, y: 0) }
    }
    private func release() { if let gesture { remote.release(gesture) }; gesture = nil; attempted = false; offset = .zero }
}

private struct LooiRemoteDirection: View {
    @ObservedObject var remote: LooiRemoteControl
    let title: String
    let icon: String
    let x: Double, y: Double
    let size: CGFloat
    @GestureState private var touching = false
    @State private var gesture: UUID?
    @State private var attempted = false
    var body: some View {
        Image(systemName: icon).font(.title3)
            .frame(width: size, height: size)
            .background(Color.cyan.opacity(touching && remote.ready ? 0.5 : 0.12), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0).updating($touching) { _, state, _ in state = true }
                .onChanged { value in
                    if !attempted { attempted = true; gesture = remote.begin() }
                    guard let gesture else { return }
                    if (0...size).contains(value.location.x), (0...size).contains(value.location.y) { remote.update(gesture, x: x, y: y) }
                    else { remote.release(gesture) }
                }.onEnded { _ in release() })
            .onChange(of: touching) { if !$0 { release() } }.onDisappear { release() }
            .accessibilityElement().accessibilityLabel(title).accessibilityAddTraits(.isButton)
            .accessibilityAction { remote.pulse(x: x, y: y) }
    }
    private func release() { if let gesture { remote.release(gesture) }; gesture = nil; attempted = false }
}

struct LooiRemoteScreen: View {
    @ObservedObject var remote: LooiRemoteControl
    @ObservedObject var bluetooth: LooiBluetooth
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            LooiRemoteView(remote: remote, bluetooth: bluetooth, compact: false) { remote.close(); dismiss() }.padding()
        }.background(Color.black.ignoresSafeArea())
            .onAppear { remote.open() }.onDisappear { remote.close() }
            .onChange(of: remote.presented) { if !$0 { dismiss() } }
    }
}

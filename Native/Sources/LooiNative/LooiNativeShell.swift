import SwiftUI
import Combine

@MainActor public func makeLooiRootController() -> UIViewController {
    LooiHostingController(app: LooiAppModel())
}

// UIKit owns scene rotation; SwiftUI owns presentation and the companion lifecycle.
@MainActor private final class LooiHostingController: UIHostingController<LooiRootView> {
    private let app: LooiAppModel
    private var subscription: AnyCancellable?
    private var companion = false
    init(app: LooiAppModel) {
        self.app = app
        super.init(rootView: LooiRootView(app: app))
        subscription = app.$phase.map { $0 == .starting || $0 == .active }
            .removeDuplicates().sink { [weak self] companion in
                // @Published emits before the property changes; defer UIKit work.
                DispatchQueue.main.async { self?.setCompanion(companion) }
            }
    }
    @objc required dynamic init?(coder aDecoder: NSCoder) { fatalError("Use init(app:)") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { companion ? .landscape : .portrait }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { companion ? .landscapeRight : .portrait }
    override var shouldAutorotate: Bool { true }
    override var prefersStatusBarHidden: Bool { companion }
    override var prefersHomeIndicatorAutoHidden: Bool { companion }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); rotateScene() }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.app.camera.updateOrientation() }
    }
    private func setCompanion(_ value: Bool) {
        companion = value
        setNeedsStatusBarAppearanceUpdate(); setNeedsUpdateOfHomeIndicatorAutoHidden()
        rotateScene()
    }
    private func rotateScene() {
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            guard let scene = viewIfLoaded?.window?.windowScene else { return }
            let requested = companion
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: supportedInterfaceOrientations)) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.companion == requested else { return }
                    self.app.notice = requested ? "请将手机横放以显示眼睛；轻点屏幕可退出陪伴。" : "请将手机竖放以查看设置。"
                }
            }
        } else { UIViewController.attemptRotationToDeviceOrientation() }
    }
}

private enum LooiDestination: String, Identifiable {
    case robots, settings, remote, debug
    var id: String { rawValue }
}

struct LooiRootView: View {
    @ObservedObject private var localization = LooiLocalization.shared
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var app: LooiAppModel
    @State private var destination: LooiDestination?
    @State private var controlsVisible = false
    private var companion: Bool { app.phase == .starting || app.phase == .active }
    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color(red: 0.02, green: 0.024, blue: 0.03).ignoresSafeArea()
                // Preserve the original eye/motion host across layout changes. It is
                // never visible in portrait, including during rotation transitions.
                LooiEyesView(face: app.face).ignoresSafeArea()
                    .opacity(companion && landscape ? 1 : 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
                if companion {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { withAnimation { if !app.remote.presented { controlsVisible.toggle() } } }
                        .accessibilityElement().accessibilityLabel(L("陪伴画面，轻点显示退出按钮"))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { controlsVisible = true }
                        .accessibilityAction(named: Text(L("退出陪伴"))) { exitCompanion() }
                    if landscape {
                        LooiCompanionCameraWindow(camera: app.camera, width: min(144, geometry.size.width * 0.16))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.leading, 24).padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                    if controlsVisible {
                        companionOverlay
                            .transition(.opacity)
                    }
                } else {
                    LooiSetupView(app: app, settings: app.settings, bluetooth: app.body,
                                  showRobots: { destination = .robots }, showDebug: { destination = .debug }, showSettings: { destination = .settings }, showRemote: { destination = .remote })
                }
            }
            .task(id: controlsVisible && companion && !app.remote.presented) {
                guard controlsVisible && companion, !app.remote.presented, app.settings.configuration.isLive, !UIAccessibility.isVoiceOverRunning else { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled { withAnimation { controlsVisible = false } }
            }
            .onChange(of: app.remote.presented) { visible in if visible { controlsVisible = true } }
            .onChange(of: app.phase) { _ in controlsVisible = companion }
            .onAppear { app.camera.updateOrientation() }
            .onChange(of: geometry.size) { _ in
                app.camera.updateOrientation()
                if app.remote.presented { app.remote.emergencyStop() }
            }
        }
        .environment(\.locale, localization.locale)
        .preferredColorScheme(.dark)
        .sheet(item: $destination) { destination in
            switch destination {
            case .robots: LooiRobotList(app: app, bluetooth: app.body)
            case .settings: LooiSettingsView(app: app, settings: app.settings)
            case .debug: LooiDeviceManagement(robot: app.body, wifi: app.body.wifi)
            case .remote: LooiRemoteScreen(remote: app.remote, bluetooth: app.body)
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { app.remote.emergencyStop() }
            if phase == .background { Task { await app.stop() } }
            if phase == .active { localization.refreshSystemLanguage() }
        }
    }
    private var companionOverlay: some View {
        VStack {
            HStack {
                LooiCallStatus(live: app.live, camera: app.camera)
                    .padding(.leading, 160)
                Spacer()
                Button(action: exitCompanion) {
                    Label(L("退出陪伴"), systemImage: "xmark")
                        .font(.headline).padding(.horizontal, 18).frame(minHeight: 48)
                        .background(.ultraThinMaterial, in: Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("exitCompanion")
            }
            Spacer(minLength: 0)
            if app.remote.presented {
                LooiRemoteView(remote: app.remote, bluetooth: app.body, compact: true) { app.remote.close() }
            } else {
                VStack(spacing: 6) {
                    Button { app.remote.open() } label: { Label(L("遥控器"), systemImage: "gamecontroller").frame(minHeight: 44) }
                        .disabled(!app.body.isConnected || app.isBusy)
                    LooiCompanionControls(app: app, live: app.live, camera: app.camera, settings: app.settings, bodyService: app.body, landscape: true)
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }
    private func exitCompanion() { controlsVisible = false; Task { await app.stop() } }
}

private struct LooiCompanionCameraWindow: View {
    @ObservedObject private var localization = LooiLocalization.shared
    @ObservedObject var camera: LooiCamera
    let width: CGFloat
    var body: some View {
        if camera.running {
            LooiCameraPreview(camera: camera)
                .frame(width: width, height: width * 0.75)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                .accessibilityLabel(L("摄像头实时预览"))
                .accessibilityIdentifier("companionCameraPreview")
        }
    }
}

private struct LooiSetupView: View {
    @ObservedObject private var localization = LooiLocalization.shared
    @ObservedObject var app: LooiAppModel
    @ObservedObject var settings: LooiSettings
    @ObservedObject var bluetooth: LooiBluetooth
    let showRobots: () -> Void
    let showDebug: () -> Void
    let showSettings: () -> Void
    let showRemote: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LOOI").font(.system(size: 17, weight: .semibold, design: .rounded)).tracking(4).foregroundStyle(.secondary)
                    Text(L("陪伴设置")).font(.largeTitle.bold())
                    Text(L("准备好后开始陪伴，手机将横屏展示眼睛。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.top, 22)
                VStack(spacing: 0) {
                    setupRow(L("连接机器人"), detail: bluetooth.isConnected ? bluetooth.connectedName : L("未连接身体"), icon: "antenna.radiowaves.left.and.right", action: showRobots)
                    setupRow(L("调试机器人"), detail: L("马达测试 · 配网 · OTA"), icon: "wrench.and.screwdriver", action: showDebug)
                    Divider().padding(.leading, 58)
                    setupRow(L("AI 服务"), detail: L(settings.configuration.preset.title) + " · " + (settings.configuration.isLive ? L("实时语音与视觉") : L("文字与视觉")), icon: "waveform", action: showSettings)
                }.background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22))
                Button(action: showRemote) {
                    Label(L("遥控器"), systemImage: "gamecontroller.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.cyan.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
                }.disabled(!bluetooth.isConnected || app.isBusy).accessibilityIdentifier("openRemote")
                LooiCompanionControls(app: app, live: app.live, camera: app.camera, settings: settings, bodyService: bluetooth, landscape: false)
            }.padding(.horizontal, 22).padding(.bottom, 24)
        }.accessibilityIdentifier("companionSetup")
    }
    private func setupRow(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct LooiCallStatus: View {
    @ObservedObject private var localization = LooiLocalization.shared
    @ObservedObject var live: LooiLiveService
    @ObservedObject var camera: LooiCamera
    var body: some View {
        Text(live.speaking ? L("正在回应") : live.microphone ? (camera.running ? L("我在听，也在看") : L("我在听")) : live.connecting ? L("正在连接 AI…") : L("就在这里，陪着你"))
            .font(.caption).foregroundStyle(.secondary)
    }
}

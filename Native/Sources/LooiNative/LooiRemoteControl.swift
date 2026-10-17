import Foundation
import Combine

struct LooiDriveVector: Equatable {
    let linear: Double
    let angular: Double
    static let zero = Self(linear: 0, angular: 0)
    static func joystick(x: Double, y: Double, speed: Double) -> Self {
        guard x.isFinite, y.isFinite, speed.isFinite else { return .zero }
        let radius = hypot(x, y)
        guard radius > 0.12 else { return .zero }
        let magnitude = min(1, (radius - 0.12) / 0.88)
        let scale = magnitude * min(0.30, max(0.05, speed)) / max(abs(x) + abs(y), 0.001)
        return Self(linear: -y * scale, angular: x * scale)
    }
}

// Closures keep the control loop testable without Core Bluetooth or hardware.
@MainActor final class LooiRemoteControl: ObservableObject {
    enum Mode: String, CaseIterable { case joystick, buttons }
    enum State { case inactive, preparing, ready, stopping, failed }
    @Published private(set) var presented = false
    @Published private(set) var state: State = .inactive
    @Published private(set) var message = "按住操作，松手停止"
    @Published private(set) var moving = false
    @Published var mode: Mode = .joystick { didSet { if mode != oldValue { emergencyStop() } } }
    @Published var speed = 0.15
    var prepare: (@MainActor () async throws -> Void)?
    var takeControl: (() -> Void)?
    var presentationChanged: ((Bool) -> Void)?
    var stopFailed: (() -> Void)?
    private let connected: @MainActor () -> Bool
    private let send: @MainActor ([String: Any]) async throws -> Void
    private let stop: @MainActor () async -> Bool
    private let tick: UInt64
    private var loop: Task<Void, Never>?
    private var epoch = 0
    private var gesture: UUID?
    private var x = 0.0, y = 0.0
    var ready: Bool { presented && state == .ready && connected() }
    init(connected: @escaping @MainActor () -> Bool, send: @escaping @MainActor ([String: Any]) async throws -> Void,
         stop: @escaping @MainActor () async -> Bool, tickNanoseconds: UInt64 = 100_000_000) {
        self.connected = connected; self.send = send; self.stop = stop; tick = tickNanoseconds
    }
    func open() {
        guard !presented, state != .stopping else { return }
        presented = true; presentationChanged?(true); takeControl?(); halt(closing: false)
    }
    func close() { guard presented else { return }; presented = false; presentationChanged?(false); halt(closing: true) }
    func emergencyStop() { guard presented else { return }; halt(closing: false) }
    func connectionLost(reason: String? = nil) {
        guard presented, state != .failed else { return }
        invalidate(); state = .failed; message = reason ?? "遥控连接已中断，请重新连接机器人后重试"
        // A rejected command can fault while the link is still alive. Attempt a
        // bounded stop once; repeated faults must not recursively enqueue stops.
        let token = epoch
        if connected() { Task { guard token == epoch else { return }; _ = await stop() } }
    }
    func retry() { guard presented, state == .failed else { return }; halt(closing: false) }
    private func invalidate() {
        epoch += 1; loop?.cancel(); loop = nil; gesture = nil; x = 0; y = 0; moving = false
    }
    private func halt(closing: Bool) {
        invalidate(); let token = epoch
        state = closing ? .stopping : .preparing; message = "正在确认机器人停止…"
        Task {
            guard token == epoch else { return }
            let confirmed = await stop()
            guard token == epoch else { return }
            if !confirmed { stopFailed?() }
            if closing { state = .inactive; return }
            if confirmed && connected() {
                do { try await prepare?() }
                catch {
                    guard token == epoch else { return }
                    state = .failed; message = error.localizedDescription; return
                }
            }
            guard token == epoch else { return }
            state = confirmed && connected() ? .ready : .failed
            message = state == .ready ? "按住操作，松手停止" : "停止未获确认，请检查连接后重试"
        }
    }
    func begin() -> UUID? {
        guard ready, gesture == nil else { return nil }
        let id = UUID(); gesture = id; return id
    }
    func update(_ id: UUID, x: Double, y: Double) {
        guard ready, gesture == id else { return }
        self.x = x; self.y = y
        guard loop == nil else { return }
        let token = epoch
        loop = Task {
            defer { if token == epoch { loop = nil } }
            while !Task.isCancelled, token == epoch, gesture == id, ready {
                let vector = LooiDriveVector.joystick(x: self.x, y: self.y, speed: speed)
                do {
                    if vector == .zero {
                        if moving {
                            guard await stop() else { throw LooiError.message("停止未获确认，请检查连接后重试") }
                            guard token == epoch else { return }; moving = false
                        }
                    } else {
                        // Await each application ACK; retain only the latest input.
                        let command = try LooiBodyProtocol.validated(["type": "motion", "linear": vector.linear,
                            "angular": vector.angular, "duration_ms": 400, "ramp_ms": 60, "label": "manual_remote"], motionAllowed: true)
                        try await send(command)
                        guard token == epoch else { return }; if !moving { moving = true }
                    }
                } catch {
                    guard token == epoch else { return }
                    invalidate(); state = .failed; message = error.localizedDescription
                    _ = await stop(); return
                }
                try? await Task.sleep(nanoseconds: tick)
            }
        }
    }
    func release(_ id: UUID) { guard gesture == id else { return }; emergencyStop() }
    func pulse(x: Double, y: Double) {
        guard let id = begin() else { return }; update(id, x: x, y: y)
        Task { try? await Task.sleep(nanoseconds: 200_000_000); release(id) }
    }
}

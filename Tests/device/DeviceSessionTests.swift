import Foundation

enum LooiError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

@MainActor enum LooiKeychain {
    static var values: [String: String] = [:]
    static func read(_ key: String) throws -> String? { values[key] }
    static func save(_ value: String, key: String) throws { values[key] = value }
}
@MainActor final class FakeWifi {
    var info: [String: Any] = [:], prepared: [String: Any]?
    var connected = false
    func disconnect() { connected = false }
    func connect(_ address: String, password: String) async throws { connected = true }
    func release(includePreview: Bool) async throws -> [String: Any] { ["version": "2.3.0"] }
    func prepareRelease(_ value: [String: Any], progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws {}
    func upload(_ bytes: Data, name: String, closeHotspot: Bool, progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws {}
    func installPrepared(closeHotspot: Bool, includePreview: Bool, progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws {}
}
@MainActor final class LooiBluetooth {
    let wifi = FakeWifi()
    var connectedID: UUID? = UUID(), isConnected = true
    var commands: [[String: Any]] = []
    var status: [String: Any] = ["device_id": "test-robot", "capabilities": ["device_identity"], "device_name_custom": true, "ap_name_custom": true, "ota_mode": true, "hardware_configured": true, "hardware_ready": true, "hardware_profile": ["board": "n16r8"], "csrf_token": "secret-session-token"]
    var busy = false, statusFails = false
    func send(_ payload: [String: Any], preferBLE: Bool) async throws -> [String: Any] {
        if statusFails { throw LooiError.message("offline") }; return status
    }
    func manage(_ payload: [String: Any], password: String) async throws -> [String: Any] {
        commands.append(payload)
        let type = payload["type"] as? String
        if type == "device_status" { if statusFails { throw LooiError.message("offline") }; return status }
        guard password == "12345678" else { throw LooiError.message("请先输入设备管理密码") }
        if type == "ota_exit" {
            if busy { throw LooiError.message("Update in progress") }
            status["ota_mode"] = false
        }
        return status
    }
    func disconnect() { isConnected = false; wifi.disconnect() }
    func connect(_ id: UUID) { isConnected = true; connectedID = id }
    func connectWifi(_ address: String, password: String) async throws { try await wifi.connect(address, password: password) }
}
@main struct DeviceSessionTests {
    @MainActor static func main() async throws {
        let robot = LooiBluetooth(), session: LooiDeviceSession
        session = LooiDeviceSession(robot: robot)
        await session.inspect()
        assert(session.statusAvailable && session.needsPassword)
        assert(!session.needsWiringConfiguration)
        session.password = "12345678"; try await session.authenticate()
        assert(!session.needsPassword)
        robot.status["firmware_version"] = "2.2.2"
        let beforeCheck = robot.commands.count
        try await session.checkUpdates(); assert(session.hasUpdate)
        assert(!robot.commands.dropFirst(beforeCheck).contains { ["ota_start", "firmware_check", "firmware_install"].contains($0["type"] as? String ?? "") })
        let update = session.transferProgress("正在下载固件"); update(0.5); assert(session.progress == 0.5)
        session.setProgress("正在重启…"); update(0.9); assert(session.progress == nil) // late download callback cannot overwrite reboot

        assert(!session.diagnostics.contains("secret-session-token"))
        // Device is in OTA even though a reconnected app thinks its phase is idle.
        assert(session.phase == "idle" && session.info["ota_mode"] as? Bool == true)
        try await session.finishDebug()
        assert(session.info["ota_mode"] as? Bool == false)
        assert(robot.commands.contains { $0["type"] as? String == "ota_exit" })
        assert(!robot.commands.contains { $0["type"] as? String == "hardware_set" })
        robot.status["ota_mode"] = true; robot.busy = true
        do { try await session.finishDebug(); assertionFailure("Active OTA cannot be exited") }
        catch { assert(error.localizedDescription == "Update in progress") }
        assert(session.info["ota_mode"] as? Bool == true)
        session.disconnected(); assert(!session.statusAvailable && session.info.isEmpty)
        robot.statusFails = true; await session.inspect()
        assert(!session.statusAvailable) // stale previous status cannot hide the retry UI
        robot.statusFails = false; robot.busy = false
        session.password = "wrong"
        do { try await session.authenticate(); assertionFailure("Bad password accepted") } catch {}
        assert(session.needsPassword)
        session.password = "12345678"; try await session.authenticate()
        do { try await session.restoreDefaultWiring(); assertionFailure("Existing wiring replaced") } catch {}
        assert(!robot.commands.contains { $0["type"] as? String == "hardware_set" })
        robot.status["hardware_configured"] = false
        await session.inspect(); assert(session.needsWiringConfiguration)
        try await session.restoreDefaultWiring()
        let repair = robot.commands.last { $0["type"] as? String == "hardware_set" }
        let profile = repair?["hardware_profile"] as? [String: Any]
        assert((profile?["pins"] as? [String: Int]) == ["ena": 17, "in1": 16, "in2": 15, "in3": 7, "in4": 6, "enb": 5])
        assert(!robot.isConnected)
        print("Device session checks passed: stale OTA exit, active-job refusal, state retry, credentials, redaction and guarded wiring repair")
    }
}

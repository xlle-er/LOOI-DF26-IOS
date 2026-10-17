import Foundation

@MainActor private final class FakeRobot {
    var connected = true
    var stopResult = true
    var holdMotion = false
    var holdStop = false
    var commands: [[String: Any]] = []
    var stops = 0
    var motionReplies: [CheckedContinuation<Void, Error>] = []
    var stopReplies: [CheckedContinuation<Bool, Never>] = []
    func send(_ command: [String: Any]) async throws {
        commands.append(command)
        if holdMotion { try await withCheckedThrowingContinuation { motionReplies.append($0) } }
    }
    func stop() async -> Bool {
        stops += 1
        if holdStop { return await withCheckedContinuation { stopReplies.append($0) } }
        return stopResult
    }
    func make() -> LooiRemoteControl {
        LooiRemoteControl(connected: { self.connected }, send: { try await self.send($0) }, stop: { await self.stop() }, tickNanoseconds: 5_000_000)
    }
}

@main struct RemoteTests {
    @MainActor static var passed = 0
    @MainActor static func check(_ condition: Bool, _ name: String) {
        precondition(condition, name); passed += 1
    }
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("Timed out waiting for remote state")
    }
    @MainActor static func main() async {
        check(LooiDriveVector.joystick(x: 0.05, y: 0.05, speed: 0.15) == .zero, "center dead zone")
        check(LooiDriveVector.joystick(x: .nan, y: 1, speed: 0.15) == .zero, "nonfinite input cannot move")
        let forward = LooiDriveVector.joystick(x: 0, y: -1, speed: 0.15)
        check(forward.linear == 0.15 && forward.angular == 0, "forward uses face-frame positive linear")
        check(LooiDriveVector.joystick(x: -1, y: 0, speed: 0.15).angular < 0, "left turn uses original scenario sign")
        let diagonal = LooiDriveVector.joystick(x: 3, y: -3, speed: 10)
        check(abs(diagonal.linear) + abs(diagonal.angular) <= 0.30001, "combined wheel outputs stay inside speed limit")

        let robot = FakeRobot(), remote = FakeRobot() // second instance used below for disconnected admission
        let control = robot.make()
        var takeovers = 0
        control.takeControl = { takeovers += 1 }
        control.open(); control.open()
        check(control.presented && !control.ready && takeovers == 1, "opening is idempotent and cannot drive before stop ACK")
        await wait { control.ready }
        let id = control.begin()!
        check(control.begin() == nil, "second simultaneous touch cannot take over")
        control.update(id, x: 0, y: -1)
        await wait { !robot.commands.isEmpty }
        check(robot.commands[0]["duration_ms"] as? Int == 400 && robot.commands[0]["ramp_ms"] as? Int == 60, "every command has a short firmware lease")
        control.release(id)
        await wait { control.ready }
        let count = robot.commands.count
        control.update(id, x: 1, y: 0)
        try? await Task.sleep(nanoseconds: 20_000_000)
        check(robot.commands.count == count && robot.stops >= 2, "release stops renewals and stale touches cannot resume")
        let next = control.begin()!
        control.update(next, x: -1, y: 0)
        control.emergencyStop(); await wait { control.ready }
        let stoppedCount = robot.commands.count
        control.update(next, x: 1, y: 0)
        try? await Task.sleep(nanoseconds: 15_000_000)
        check(robot.commands.count == stoppedCount, "emergency stop invalidates a still-held gesture")
        control.mode = .buttons; await wait { control.ready }
        check(robot.stops >= 4, "changing control mode requests a stop")
        control.close(); await wait { control.state == .inactive }
        check(!control.presented && control.begin() == nil, "closed remote cannot drive")
        remote.connected = false
        let disconnected = remote.make(); disconnected.open()
        await wait { disconnected.state == .failed }
        check(disconnected.begin() == nil, "disconnected robot cannot be armed")
        disconnected.close()

        let delayed = FakeRobot(); delayed.holdMotion = true
        let latest = delayed.make(); latest.open(); await wait { latest.ready }
        let finger = latest.begin()!; latest.update(finger, x: 0, y: -1)
        await wait { delayed.motionReplies.count == 1 }
        latest.update(finger, x: 1, y: 0); latest.update(finger, x: 0, y: 1)
        check(delayed.commands.count == 1, "at most one command waits for ACK")
        delayed.motionReplies.removeFirst().resume()
        await wait { delayed.commands.count == 2 }
        check((delayed.commands[1]["linear"] as? Double ?? 0) < 0 && delayed.commands[1]["angular"] as? Double == 0, "only latest target survives slow ACK")
        latest.release(finger); await wait { latest.ready }
        delayed.motionReplies.removeFirst().resume()
        let releasedCount = delayed.commands.count
        try? await Task.sleep(nanoseconds: 15_000_000)
        check(delayed.commands.count == releasedCount && !latest.moving, "late ACK after release cannot restart old motion")
        let faultFinger = latest.begin()!; latest.update(faultFinger, x: 1, y: 0)
        await wait { delayed.motionReplies.count == 1 }
        delayed.motionReplies.removeFirst().resume(throwing: LooiError.message("test timeout"))
        await wait { latest.state == .failed }
        check(latest.begin() == nil && !latest.moving, "command failure inhibits control and requests stop")
        latest.retry(); await wait { latest.ready }
        check(latest.begin() != nil, "retry requires a fresh gesture")
        latest.connectionLost()
        check(!latest.ready && !latest.moving && latest.state == .failed, "disconnect invalidates control immediately")
        latest.close()

        let late = FakeRobot(); late.holdStop = true
        let closing = late.make(); closing.open()
        await wait { late.stopReplies.count == 1 }
        closing.close(); await wait { late.stopReplies.count == 2 }
        late.stopReplies.removeLast().resume(returning: true)
        await wait { closing.state == .inactive }
        late.stopReplies.removeFirst().resume(returning: true)
        try? await Task.sleep(nanoseconds: 5_000_000)
        check(!closing.presented && closing.state == .inactive, "late prepare completion cannot resurrect a closed panel")

        let refused = FakeRobot(); refused.stopResult = false
        let refusedRemote = refused.make(); refusedRemote.open()
        await wait { refusedRemote.state == .failed }
        check(refusedRemote.begin() == nil, "unconfirmed initial stop prevents movement")
        var stopWarning = false
        refusedRemote.stopFailed = { stopWarning = true }
        refusedRemote.close(); await wait { refusedRemote.state == .inactive }
        check(stopWarning, "failed stop remains observable after panel closes")
        let immediate = FakeRobot(); let cancelledOpen = immediate.make()
        cancelledOpen.open(); cancelledOpen.close()
        await wait { cancelledOpen.state == .inactive }
        check(immediate.stops == 1 && !cancelledOpen.presented, "cancelled prepare task cannot issue a late stop")
        let fault = FakeRobot(); let retrying = fault.make()
        retrying.open(); await wait { retrying.ready }
        let priorStops = fault.stops
        retrying.connectionLost(); retrying.retry(); await wait { retrying.ready }
        check(fault.stops == priorStops + 1, "old fault recovery cannot interfere with a new retry")
        retrying.close()
        let locked = FakeRobot(); let checked = locked.make()
        var blocked = true
        checked.prepare = { if blocked { throw LooiError.message("升级模式中，运动已锁定") } }
        checked.open(); await wait { checked.state == .failed }
        check(checked.message == "升级模式中，运动已锁定", "preflight reports the actual motion lock")
        check(checked.begin() == nil && locked.commands.isEmpty, "locked controller never sends motion")
        blocked = false; checked.retry(); await wait { checked.ready }
        check(checked.ready, "explicit exit followed by retry restores control")
        checked.connectionLost(reason: "电机未就绪")
        check(checked.message == "电机未就绪", "application rejection preserves reason instead of blaming connection")
        checked.close(); await wait { checked.state == .inactive }
        print("Remote control checks passed: \(passed)")
    }
}

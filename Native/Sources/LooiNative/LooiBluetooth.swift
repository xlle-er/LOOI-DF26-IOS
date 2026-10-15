import Foundation
import CoreBluetooth
import Combine

struct LooiRobotDevice: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
    var lastSeen: Date
    var shortID: String { String(id.uuidString.suffix(8)) }
    var signal: String { rssi >= -55 ? "信号很强" : rssi >= -70 ? "信号良好" : "信号较弱" }
}

@MainActor final class LooiBluetooth: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let service = CBUUID(string: "7f2c2b6a-2d8f-4f6b-9a59-8a7f9d7c0001")
    private static let commandID = CBUUID(string: "7f2c2b6a-2d8f-4f6b-9a59-8a7f9d7c0002")
    private static let eventsID = CBUUID(string: "7f2c2b6a-2d8f-4f6b-9a59-8a7f9d7c0003")
    @Published private(set) var devices: [LooiRobotDevice] = []
    @Published private(set) var scanning = false
    @Published private(set) var connectedID: UUID?
    @Published private(set) var connectingID: UUID?
    @Published private(set) var message = "选择自己的机器人后连接"
    @Published private(set) var aliases: [String: String] = UserDefaults.standard.dictionary(forKey: "looi.robot.aliases") as? [String: String] ?? [:]
    @Published private(set) var savedID = UserDefaults.standard.string(forKey: "looi.robot.savedID")
    @Published private(set) var preferredID = UserDefaults.standard.string(forKey: "looi.robot.preferredID")
    var onFault: ((String) -> Void)?
    var onConnection: ((Bool) -> Void)?
    var isConnected: Bool { connectedID != nil && command != nil }
    var connectedName: String { connectedID.map { displayName($0) } ?? "未连接身体" }
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var active: CBPeripheral?
    private var command: CBCharacteristic?
    private var scanRequested = false
    private var scanTimeout: Task<Void, Never>?
    private var connectionTimeout: Task<Void, Never>?
    private var decoder = LooiNotificationDecoder()
    private var queue: [Command] = []
    private var current: Command?
    private var writeOutstanding = false
    private var stopTask: Task<Bool, Never>?

    private final class Command {
        let id: String
        let bytes: Data
        let continuation: CheckedContinuation<[String: Any], Error>
        var offset = 0
        var written = false
        var ack: [String: Any]?
        var timeout: Task<Void, Never>?
        init(id: String, bytes: Data, continuation: CheckedContinuation<[String: Any], Error>) {
            self.id = id; self.bytes = bytes; self.continuation = continuation
        }
    }

    func displayName(_ id: UUID) -> String { aliases[id.uuidString] ?? devices.first { $0.id == id }?.name ?? "LOOI Body" }
    func rename(_ id: UUID, _ name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        if clean.isEmpty { aliases.removeValue(forKey: id.uuidString) } else { aliases[id.uuidString] = clean }
        UserDefaults.standard.set(aliases, forKey: "looi.robot.aliases")
    }
    func rememberMine(_ id: UUID) { preferredID = id.uuidString; UserDefaults.standard.set(preferredID, forKey: "looi.robot.preferredID") }
    func scan() {
        scanRequested = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main); return }
        guard central?.state == .poweredOn else { updatePowerMessage(); return }
        devices.removeAll { Date().timeIntervalSince($0.lastSeen) > 20 && $0.id != connectedID }
        scanning = true; message = "正在搜索附近的 LOOI…"
        central?.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }; self?.stopScan()
        }
    }
    func stopScan() { scanRequested = false; central?.stopScan(); scanning = false; scanTimeout?.cancel() }
    func connect(_ id: UUID) {
        guard connectingID == nil, connectedID == nil, let peripheral = peripherals[id], central?.state == .poweredOn else { return }
        stopScan(); active = peripheral; connectingID = id; message = "正在连接 \(displayName(id))…"
        peripheral.delegate = self; central?.connect(peripheral)
        connectionTimeout?.cancel()
        connectionTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, let self, self.connectingID == id else { return }
            self.message = "连接超时，请检查机器人电源或是否已被其他手机连接"; self.disconnect()
        }
    }
    func disconnect() {
        stopScan(); connectionTimeout?.cancel()
        if let active { central?.cancelPeripheralConnection(active) }
        clearConnection("身体已断开")
    }
    func send(_ payload: [String: Any]) async throws -> [String: Any] {
        guard isConnected else { throw LooiError.message("请先连接自己的机器人") }
        guard queue.count < 24 else { throw LooiError.message("动作队列繁忙，请稍后重试") }
        let id = UUID().uuidString
        let bytes = try LooiBodyProtocol.packet(payload, id: id)
        return try await withCheckedThrowingContinuation { continuation in
            queue.append(Command(id: id, bytes: bytes, continuation: continuation)); pump()
        }
    }
    @discardableResult func stopMotion() async -> Bool {
        if let stopTask { return await stopTask.value }
        failPending("动作已取消")
        guard isConnected else { return true }
        let task = Task { [weak self] in
            guard let self else { return false }
            do { _ = try await self.send(["type": "stop", "reason": "native_stop"]); return true }
            catch { return false }
        }
        stopTask = task
        let confirmed = await task.value; stopTask = nil
        return confirmed
    }
    private func pump() {
        guard let active, let command, isConnected, !writeOutstanding else { return }
        if current == nil, !queue.isEmpty {
            let item = queue.removeFirst(); current = item
            item.timeout = Task { [weak self, weak item] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self, let item, self.current === item else { return }
                if self.writeOutstanding { self.message = "蓝牙写入超时，请重新连接身体"; self.disconnect(); self.onFault?(self.message); return }
                self.finish(.failure(LooiError.message("身体指令未确认，已暂停动作")))
            }
        }
        guard let item = current else { return }
        if item.written { if let ack = item.ack { finish(.success(ack)) }; return }
        let type: CBCharacteristicWriteType = command.properties.contains(.write) ? .withResponse : .withoutResponse
        let size = min(180, active.maximumWriteValueLength(for: type))
        guard size > 0 else { finish(.failure(LooiError.message("机器人写入长度无效"))); return }
        while item.offset < item.bytes.count {
            if type == .withoutResponse && !active.canSendWriteWithoutResponse { return }
            let end = min(item.offset + size, item.bytes.count)
            let chunk = item.bytes.subdata(in: item.offset..<end); item.offset = end
            if type == .withResponse { writeOutstanding = true; active.writeValue(chunk, for: command, type: type); return }
            active.writeValue(chunk, for: command, type: type)
        }
        item.written = true; if let ack = item.ack { finish(.success(ack)) }
    }
    private func finish(_ result: Result<[String: Any], Error>) {
        guard let item = current else { return }; current = nil; item.timeout?.cancel(); item.continuation.resume(with: result)
        if case let .failure(error) = result {
            message = error.localizedDescription
            let dropped = queue; queue.removeAll(); dropped.forEach { $0.continuation.resume(throwing: error) }
            onFault?(message)
        }
        pump()
    }
    private func failPending(_ message: String) {
        let pending = queue + (current.map { [$0] } ?? []); queue.removeAll(); current = nil
        pending.forEach { $0.timeout?.cancel(); $0.continuation.resume(throwing: LooiError.message(message)) }
    }
    private func clearConnection(_ reason: String) {
        failPending(reason); active = nil; command = nil; writeOutstanding = false; decoder.reset()
        connectedID = nil; connectingID = nil; onConnection?(false)
    }
    private func updatePowerMessage() {
        switch central?.state {
        case .unauthorized: message = "请在系统设置中允许 LOOI 使用蓝牙"
        case .poweredOff: message = "蓝牙未开启，请在系统设置中打开"
        case .unsupported: message = "此设备不支持蓝牙低功耗连接"
        default: message = "蓝牙正在准备，请稍候"
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { if scanRequested { scan() } }
        else { scanning = false; clearConnection("蓝牙不可用"); updatePowerMessage() }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard RSSI.intValue != 127 else { return }
        peripherals[peripheral.identifier] = peripheral
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "LOOI Body"
        if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            guard Date().timeIntervalSince(devices[index].lastSeen) >= 0.8 else { return }
            devices[index].rssi = Int(Double(devices[index].rssi) * 0.65 + RSSI.doubleValue * 0.35)
            devices[index].lastSeen = Date(); devices[index].name = name
        } else {
            devices.append(.init(id: peripheral.identifier, name: name, rssi: RSSI.intValue, lastSeen: Date()))
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard active === peripheral else { return }; peripheral.discoverServices([Self.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard active === peripheral else { return }; connectionTimeout?.cancel(); clearConnection("连接失败"); message = error?.localizedDescription ?? "连接失败，请确认机器人未被其他手机占用"
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard active === peripheral else { return }; connectionTimeout?.cancel(); clearConnection("身体连接已断开"); message = "身体连接已断开，语音陪伴可继续"; onFault?(message)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard active === peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { message = "机器人服务不可用"; disconnect(); return }
        peripheral.discoverCharacteristics([Self.commandID, Self.eventsID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard active === peripheral else { return }
        guard error == nil, let write = service.characteristics?.first(where: { $0.uuid == Self.commandID }),
              write.properties.contains(.write) || write.properties.contains(.writeWithoutResponse),
              let events = service.characteristics?.first(where: { $0.uuid == Self.eventsID }) else { message = "机器人指令服务不完整"; disconnect(); return }
        command = write; peripheral.setNotifyValue(true, for: events)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard active === peripheral, characteristic.uuid == Self.eventsID else { return }
        guard connectingID != nil else { return }
        guard error == nil, characteristic.isNotifying else { message = "无法接收机器人确认消息"; disconnect(); return }
        connectionTimeout?.cancel(); connectingID = nil; connectedID = peripheral.identifier
        savedID = peripheral.identifier.uuidString; UserDefaults.standard.set(savedID, forKey: "looi.robot.savedID")
        message = "已连接 \(connectedName)"; onConnection?(true)
        Task { [weak self] in
            do { _ = try await self?.send(["type": "ping"]); _ = try await self?.send(["type": "config_get"]) }
            catch { self?.message = error.localizedDescription }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active === peripheral, characteristic.uuid == Self.commandID else { return }
        writeOutstanding = false
        if let error { finish(.failure(error)) } else { pump() }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { if active === peripheral { pump() } }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active === peripheral, characteristic.uuid == Self.eventsID, error == nil, let data = characteristic.value else { return }
        let values: [[String: Any]]
        do { values = try decoder.append(data) } catch { message = error.localizedDescription; return }
        for value in values {
            guard let id = value["id"] as? String, let item = current, id == item.id,
                  let type = value["type"] as? String else { continue }
            if type == "error" || value["accepted"] as? Bool == false { finish(.failure(LooiError.message(value["message"] as? String ?? "机器人拒绝指令"))) }
            else if ["ack", "pong", "config"].contains(type) { item.ack = value; if item.written { finish(.success(value)) } }
        }
    }
}

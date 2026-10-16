import Foundation

enum LooiBodyProtocol {
    static let supportedCommands: Set<String> = ["motion", "stop", "ping", "config_get", "config_update", "device_status", "wifi_scan", "wifi_configure", "wifi_forget", "calibration_get", "calibration_set", "calibration_test", "control_acquire", "control_renew", "control_release", "ota_start", "ota_exit", "ota_status", "firmware_check", "firmware_install", "hardware_get", "hardware_set"]
    static func validated(_ payload: [String: Any], motionAllowed: Bool) throws -> [String: Any] {
        var result = payload; result.removeValue(forKey: "id")
        switch result["type"] as? String {
        case "motion":
            guard motionAllowed else { throw LooiError.message("身体动作未开启") }
            for field in ["linear", "angular"] {
                guard let value = result[field] as? Double, value.isFinite else { throw LooiError.message("动作参数无效") }
                result[field] = min(0.4, max(-0.4, value))
            }
            result["duration_ms"] = bounded(result["duration_ms"], min: 50, max: 1000, fallback: 300)
            let duration = result["duration_ms"] as! Int
            result["ramp_ms"] = bounded(result["ramp_ms"], min: 0, max: min(500, duration / 2), fallback: 120)
        case "stop", "ping", "config_get": break
        default: throw LooiError.message("不支持的身体指令")
        }
        return result
    }
    private static func bounded(_ value: Any?, min low: Int, max high: Int, fallback: Int) -> Int {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return min(high, max(low, fallback)) }
        return Int(min(Double(high), max(Double(low), number.doubleValue)))
    }
    static func packet(_ payload: [String: Any], id: String) throws -> Data {
        var object = payload; object["id"] = id
        return (object["type"] as? String == "stop" ? Data([10]) : Data()) + (try JSONSerialization.data(withJSONObject: object)) + Data([10])
    }
}

struct LooiNotificationDecoder {
    private var buffer = Data()
    mutating func reset() { buffer.removeAll() }
    mutating func append(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        guard buffer.count <= 65_536 else { buffer.removeAll(); throw LooiError.message("机器人消息过长") }
        var values: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer.prefix(upTo: newline)); buffer.removeSubrange(...newline)
            if let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { values.append(value) }
        }
        return values
    }
}

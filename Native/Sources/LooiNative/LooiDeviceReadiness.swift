import Foundation

enum LooiDeviceReadiness {
    static func defaultWiringRepair(_ status: [String: Any]) -> [String: Any]? {
        guard status["hardware_configured"] as? Bool == false,
              let profile = status["hardware_profile"] as? [String: Any],
              let board = profile["board"] as? String, ["n16r8", "n8r8"].contains(board) else { return nil }
        return ["version": 1, "board": board, "pins": ["ena": 17, "in1": 16, "in2": 15, "in3": 7, "in4": 6, "enb": 5]]
    }
    static func blockReason(_ status: [String: Any]) -> String? {
        if status["ota_mode"] as? Bool == true { return localizedReason("Exit upgrade mode before moving") }
        if status["hardware_ready"] as? Bool == false { return localizedReason(status["hardware_error"] as? String ?? "Hardware configuration required") }
        return nil
    }
    static func localizedReason(_ message: String) -> String {
        switch message {
        case "Device administrator password required": return "请先输入设备管理密码"
        case "Controls locked during update", "Controls locked during OTA", "Exit upgrade mode before moving": return "升级模式中，运动已锁定，请先退出升级模式"
        case "Hardware configuration required": return "电机接线尚未配置"
        case "Control busy, expired, or locked; acquire control first": return "运动未获许可，请在调试页检查升级锁定与电机状态"
        case "Another controller is active; explicitly take control": return "机器人正由其他客户端控制"
        case "PWM initialization failed; motors disabled": return "电机 PWM 初始化失败"
        case "Physical Flash/PSRAM mismatch; motors disabled": return "固件板型与设备 Flash/PSRAM 不匹配"
        case "Invalid hardware configuration; motors disabled": return "电机接线配置无效"
        default: return message
        }
    }
}

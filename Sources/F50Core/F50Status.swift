import Foundation
import SwiftUI

public enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Codable {
    case iconOnly = "仅图标"
    case dailyUsage = "图标 + 当日用量"
    case speeds = "图标 + 速率"
    case traffic = "图标 + 套餐用量"
    case cpuMem = "图标 + CPU/内存"
    case temperature = "图标 + 温度"
    case devices = "图标 + Wi-Fi 设备数"

    public var id: String { rawValue }
}

public enum F50RoamingState: Equatable {
    case unknown
    case home
    case domestic
    case international
}

public struct F50Status: Equatable, Codable {
    public var isOnline: Bool = false
    public var errorMessage: String? = nil

    public var networkType: String = "5G SA" // e.g. "5G SA", "5G NSA", "4G LTE"
    public var signalBar: Int = 0           // 0 to 5
    public var rsrp: String = "N/A"         // e.g. "-85 dBm"
    public var rsrq: String = "N/A"         // e.g. "-7 dB"
    public var snr: String = "N/A"          // e.g. "8 dB"
    public var carrier: String = "未知"     // e.g. "中国移动"
    public var currentBands: String = ""   // e.g. "B3 + n78"
    // 路由器原始 ppp_status（如 ipv4_ipv6_connected / ppp_disconnected / ppp_connecting）
    public var rawPppStatus: String = ""

    private var normalizedPppStatus: String {
        rawPppStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // 路由器原始 network_simcard_roam：Home / Internal（国内漫游）/ International（国际漫游）
    public var rawRoamStatus: String = ""
    // 数据漫游开关 roam_setting_option 是否为 on；nil 表示路由器未返回
    public var isDataRoamingEnabled: Bool? = nil

    public var roamingState: F50RoamingState {
        switch rawRoamStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "home": return .home
        case "internal": return .domestic
        case "international": return .international
        default: return .unknown
        }
    }

    public var isMobileDataTransitioning: Bool {
        // ppp_connecting / ppp_disconnecting
        normalizedPppStatus.hasSuffix("connecting")
    }

    public var isMobileDataOn: Bool {
        let value = normalizedPppStatus
        if value == "connect" || value == "1" { return true }
        return value.hasSuffix("connected") && !value.hasSuffix("disconnected")
    }

    public var dlSpeed: Double = 0.0        // Bytes per sec
    public var ulSpeed: Double = 0.0        // Bytes per sec
    public var dlHistory: [Double] = []
    public var ulHistory: [Double] = []

    public var connectedDevices: Int = 0
    public var smsUnreadCount: Int = 0
    public var cpuUsage: Double = 0.0       // 0 - 100%
    public var memUsage: Double = 0.0       // 0 - 100%
    public var temperature: Double = 0.0    // ℃

    public var batteryValue: Int = -1       // -1 means no battery or N/A
    public var isCharging: Bool = false

    public var monthlyRx: UInt64 = 0
    public var monthlyTx: UInt64 = 0
    public var realtimeRx: UInt64 = 0
    public var realtimeTx: UInt64 = 0
    public var dailyRx: UInt64 = 0
    public var dailyTx: UInt64 = 0
    public var trackedDaily: UInt64 = 0
    public var trafficLimit: UInt64 = 0
    // 0 表示未知/尚未检测到；此时不显示重置天数
    public var trafficResetDay: Int = 0

    public var daysUntilReset: Int? {
        guard (1...31).contains(trafficResetDay) else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let currentDay = calendar.component(.day, from: today)
        let resetDayToUse = trafficResetDay
        
        let targetDate: Date
        if currentDay < resetDayToUse {
            var components = calendar.dateComponents([.year, .month], from: today)
            let range = calendar.range(of: .day, in: .month, for: today) ?? 1..<31
            components.day = min(resetDayToUse, range.count)
            targetDate = calendar.date(from: components) ?? today
        } else {
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: today) else { return 0 }
            var components = calendar.dateComponents([.year, .month], from: nextMonth)
            let range = calendar.range(of: .day, in: .month, for: nextMonth) ?? 1..<31
            components.day = min(resetDayToUse, range.count)
            targetDate = calendar.date(from: components) ?? today
        }
        
        let diff = calendar.dateComponents([.day], from: today, to: targetDate)
        return max(0, diff.day ?? 0)
    }

    /// 路由器累计用量（自上次清零起；monthly_rx_bytes + monthly_tx_bytes）
    public var monthlyTotal: UInt64 { monthlyRx &+ monthlyTx }

    public var sessionTotal: UInt64 { realtimeRx &+ realtimeTx }

    /// 当日用量：路由器原生当日计数优先，否则用本地基线跟踪值
    public var dailyTotal: UInt64 {
        let nativeDaily = dailyRx &+ dailyTx
        return nativeDaily > 0 ? nativeDaily : max(trackedDaily, sessionTotal)
    }

    public var trafficUsageRatio: Double {
        guard trafficLimit > 0 else { return 0 }
        return min(1.0, max(0.0, Double(monthlyTotal) / Double(trafficLimit)))
    }

    public var trafficUsageColor: Color {
        guard trafficLimit > 0 else { return F50Theme.cyan }
        let ratio = trafficUsageRatio
        if ratio >= 0.9 {
            return F50Theme.red
        } else if ratio >= 0.75 {
            return F50Theme.orange
        } else {
            return F50Theme.cyan
        }
    }

    public var lastUpdated: Date = Date()

    public init() {}

    mutating func mergeHardwareMetrics(from payload: [String: Any]) {
        if let value = payload["cpu_utility"] ?? payload["cpu_usage"] ?? payload["cpu_percent"] ?? payload["cpu_rate"] ?? payload["cpu"] ?? payload["cpu_load"] {
            let parsed = F50ResponseParser.parseDouble(value)
            if parsed > 0 { cpuUsage = min(100.0, max(0.0, parsed)) }
        }
        if let value = payload["mem_utility"] ?? payload["mem_usage"] ?? payload["mem_percent"] ?? payload["memory_rate"] ?? payload["memory"] ?? payload["mem_used_percent"] {
            let parsed = F50ResponseParser.parseDouble(value)
            if parsed > 0 { memUsage = min(100.0, max(0.0, parsed)) }
        }
        // 取第一个「有效」值：部分固件（F50 Pro B22）对不支持的键返回空串，不能让它挡住后面的键
        let temperatureKeys = ["cpu_temp", "temperature", "temp", "ic_temp", "soc_temp", "modem_temp", "internal_temperature", "chip_temp", "device_temp", "cpu_temperature"]
        for key in temperatureKeys {
            guard let value = payload[key] else { continue }
            var parsed = F50ResponseParser.parseDouble(value)
            if parsed > 1_000 { parsed /= 1_000.0 }
            if parsed > 0 && parsed < 130 {
                temperature = parsed
                break
            }
        }
    }

    mutating func clearHardwareMetrics() {
        cpuUsage = 0
        memUsage = 0
        temperature = 0
    }

    // Helper to extract double value from string
    private func parseVal(_ str: String) -> Double? {
        let clean = str.replacingOccurrences(of: "dBm", with: "")
                       .replacingOccurrences(of: "dB", with: "")
                       .trimmingCharacters(in: .whitespaces)
        return Double(clean)
    }

    // RSRP Quality (Excellent >= -85, Good >= -95, Fair >= -105, Poor < -105)
    public var rsrpQuality: (label: String, color: Color, ratio: Double) {
        guard let val = parseVal(rsrp) else { return ("-", .secondary, 0.0) }
        if val >= -85 {
            return ("极佳", F50Theme.green, 1.0)
        } else if val >= -95 {
            return ("良好", F50Theme.blue, 0.75)
        } else if val >= -105 {
            return ("一般", F50Theme.orange, 0.50)
        } else {
            return ("较差", F50Theme.red, 0.25)
        }
    }

    // SINR Quality (Excellent >= 20, Good >= 13, Fair >= 3, Poor < 3)
    public var snrQuality: (label: String, color: Color, ratio: Double) {
        guard let val = parseVal(snr) else { return ("-", .secondary, 0.0) }
        if val >= 20 {
            return ("极佳", F50Theme.green, 1.0)
        } else if val >= 13 {
            return ("良好", F50Theme.blue, 0.75)
        } else if val >= 3 {
            return ("一般", F50Theme.orange, 0.50)
        } else {
            return ("较差", F50Theme.red, 0.25)
        }
    }

    // RSRQ Quality (Excellent >= -10, Good >= -15, Fair >= -20, Poor < -20)
    public var rsrqQuality: (label: String, color: Color, ratio: Double) {
        guard let val = parseVal(rsrq) else { return ("-", .secondary, 0.0) }
        if val >= -10 {
            return ("极佳", F50Theme.green, 1.0)
        } else if val >= -15 {
            return ("良好", F50Theme.blue, 0.75)
        } else if val >= -20 {
            return ("一般", F50Theme.orange, 0.50)
        } else {
            return ("较差", F50Theme.red, 0.25)
        }
    }

    public static func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 {
            return String(format: "%.0f B/s", bytesPerSec)
        } else if bytesPerSec < 1024 * 1024 {
            return String(format: "%.1f KB/s", bytesPerSec / 1024.0)
        } else if bytesPerSec < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSec / (1024.0 * 1024.0))
        } else {
            return String(format: "%.2f GB/s", bytesPerSec / (1024.0 * 1024.0 * 1024.0))
        }
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        let dBytes = Double(bytes)
        if dBytes < 1024 {
            return "\(bytes) B"
        } else if dBytes < 1024 * 1024 {
            return String(format: "%.1f KB", dBytes / 1024.0)
        } else if dBytes < 1024 * 1024 * 1024 {
            return String(format: "%.2f MB", dBytes / (1024.0 * 1024.0))
        } else if dBytes < 1024 * 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", dBytes / (1024.0 * 1024.0 * 1024.0))
        } else {
            return String(format: "%.2f TB", dBytes / (1024.0 * 1024.0 * 1024.0 * 1024.0))
        }
    }

    public var tempColor: Color {
        if temperature <= 0 {
            return .secondary
        } else if temperature < 45 {
            return F50Theme.green
        } else if temperature < 60 {
            return F50Theme.orange
        } else {
            return F50Theme.red
        }
    }

    public var cpuColor: Color {
        if cpuUsage <= 0 {
            return .secondary
        } else if cpuUsage < 50 {
            return F50Theme.green
        } else if cpuUsage < 80 {
            return F50Theme.orange
        } else {
            return F50Theme.red
        }
    }

    public var memColor: Color {
        if memUsage <= 0 {
            return .secondary
        } else if memUsage < 60 {
            return F50Theme.green
        } else if memUsage < 85 {
            return F50Theme.orange
        } else {
            return F50Theme.red
        }
    }

    public mutating func recordSpeed(dl: Double, ul: Double) {
        dlHistory.append(dl)
        if dlHistory.count > 16 {
            dlHistory.removeFirst(dlHistory.count - 16)
        }
        ulHistory.append(ul)
        if ulHistory.count > 16 {
            ulHistory.removeFirst(ulHistory.count - 16)
        }
    }

    // MARK: - 审核与演示模式模拟数据 (Demo Mode Mock Data)
    public static var mock: F50Status {
        mockStatus(tick: 0)
    }

    public static func mockStatus(tick: Int = 0) -> F50Status {
        var s = F50Status()
        s.isOnline = true
        s.errorMessage = nil

        s.networkType = "5G SA"
        s.signalBar = 4
        s.rsrp = "-82 dBm"
        s.rsrq = "-7 dB"
        s.snr = "19 dB"
        s.carrier = "中国移动"
        s.currentBands = "B3 + n78"
        s.rawPppStatus = "ipv4_ipv6_connected"
        s.rawRoamStatus = "Home"
        s.isDataRoamingEnabled = false

        // 模拟自然呼吸波动的上下行速率
        let baseDl = 48.5 * 1024.0 * 1024.0
        let baseUl = 6.2 * 1024.0 * 1024.0
        let wave = sin(Double(tick) * 0.5) * 6.0 * 1024.0 * 1024.0
        s.dlSpeed = max(12.0 * 1024.0 * 1024.0, baseDl + wave)
        s.ulSpeed = max(1.5 * 1024.0 * 1024.0, baseUl + (wave * 0.18))

        s.dlHistory = [
            18.2 * 1024 * 1024,
            24.5 * 1024 * 1024,
            31.0 * 1024 * 1024,
            42.8 * 1024 * 1024,
            55.3 * 1024 * 1024,
            49.1 * 1024 * 1024,
            46.7 * 1024 * 1024,
            s.dlSpeed
        ]
        s.ulHistory = [
            2.1 * 1024 * 1024,
            3.4 * 1024 * 1024,
            4.2 * 1024 * 1024,
            5.8 * 1024 * 1024,
            6.5 * 1024 * 1024,
            5.9 * 1024 * 1024,
            6.1 * 1024 * 1024,
            s.ulSpeed
        ]

        s.connectedDevices = 3
        s.smsUnreadCount = 1
        s.cpuUsage = max(15.0, min(85.0, 26.5 + (sin(Double(tick) * 0.35) * 4.0)))
        s.memUsage = 41.8
        s.temperature = max(30.0, min(65.0, 39.2 + (sin(Double(tick) * 0.2) * 0.8)))

        s.monthlyRx = 38_654_705_664 // ~36.0 GB
        s.monthlyTx = 4_294_967_296  // ~4.0 GB
        s.trafficLimit = 107_374_182_400 // 100 GB
        s.trafficResetDay = 1
        s.batteryValue = -1

        return s
    }
}

/// 高级低饱和度调色盘与全局主题规范
public enum F50Theme {
    public static let green = Color(red: 0.18, green: 0.68, blue: 0.45)    // 翡翠绿
    public static let blue = Color(red: 0.22, green: 0.50, blue: 0.92)     // 霁蓝
    public static let orange = Color(red: 0.94, green: 0.58, blue: 0.20)   // 琥珀金
    public static let red = Color(red: 0.88, green: 0.32, blue: 0.32)      // 绯红
    public static let purple = Color(red: 0.54, green: 0.46, blue: 0.84)   // 鸢尾紫
    public static let cyan = Color(red: 0.20, green: 0.66, blue: 0.70)     // 烟青蓝
    public static let gray = Color(red: 0.55, green: 0.58, blue: 0.62)     // 岩灰

    public static func cardBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.115, green: 0.145, blue: 0.185)
            : Color.white
    }

    public static func panelBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.10, blue: 0.135)
            : Color(red: 0.945, green: 0.955, blue: 0.97)
    }

    public static func cardBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }

    public static func controlBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.04)
    }

    public static func controlHover(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.08)
    }
}

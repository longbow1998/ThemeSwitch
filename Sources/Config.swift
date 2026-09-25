import Foundation

extension Notification.Name {
    /// 设置窗口保存后必须 post 这个通知，菜单栏 AppDelegate 监听它并立即重新应用
    static let themeConfigChanged = Notification.Name("ThemeSwitch.configChanged")
}

struct ThemeConfig: Codable, Equatable {
    var enabled: Bool
    var timeZoneID: String
    var darkHour: Int
    var darkMinute: Int
    var lightHour: Int
    var lightMinute: Int
    /// 换算提示与菜单「下次切换」使用的参考时区："system" 表示跟随系统时区，
    /// 否则为 IANA 标识（如 "Asia/Shanghai"）。只影响换算展示，不影响调度逻辑。
    var referenceTimeZoneID: String
    /// 是否在菜单栏图标后显示时钟。只影响状态栏展示，不影响切换调度。
    var showClock: Bool
    /// 菜单栏时钟显示的时区："system" 跟随系统，否则为 IANA 标识。只影响展示。
    var clockTimeZoneID: String

    init(
        enabled: Bool,
        timeZoneID: String,
        darkHour: Int,
        darkMinute: Int,
        lightHour: Int,
        lightMinute: Int,
        referenceTimeZoneID: String = "system",
        showClock: Bool = false,
        clockTimeZoneID: String = "system"
    ) {
        self.enabled = enabled
        self.timeZoneID = timeZoneID
        self.darkHour = darkHour
        self.darkMinute = darkMinute
        self.lightHour = lightHour
        self.lightMinute = lightMinute
        self.referenceTimeZoneID = referenceTimeZoneID
        self.showClock = showClock
        self.clockTimeZoneID = clockTimeZoneID
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case timeZoneID
        case darkHour
        case darkMinute
        case lightHour
        case lightMinute
        case referenceTimeZoneID
        case showClock
        case clockTimeZoneID
    }

    /// 为兼容旧版本持久化的配置：JSON 里没有 referenceTimeZoneID / showClock /
    /// clockTimeZoneID 键时分别取 "system" / false / "system"，其余字段照常解码，
    /// 避免 load() 因缺字段解码失败而回退 .default、丢掉用户已有设置。
    /// 定义了自定义 init(from:) 后成员初始化器被抑制，上面的显式 init 保持调用点不变。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        timeZoneID = try container.decode(String.self, forKey: .timeZoneID)
        darkHour = try container.decode(Int.self, forKey: .darkHour)
        darkMinute = try container.decode(Int.self, forKey: .darkMinute)
        lightHour = try container.decode(Int.self, forKey: .lightHour)
        lightMinute = try container.decode(Int.self, forKey: .lightMinute)
        referenceTimeZoneID = try container.decodeIfPresent(String.self, forKey: .referenceTimeZoneID) ?? "system"
        showClock = try container.decodeIfPresent(Bool.self, forKey: .showClock) ?? false
        clockTimeZoneID = try container.decodeIfPresent(String.self, forKey: .clockTimeZoneID) ?? "system"
    }

    static let `default`: ThemeConfig = ThemeConfig(
        enabled: true,
        timeZoneID: "Asia/Shanghai",
        darkHour: 19,
        darkMinute: 0,
        lightHour: 7,
        lightMinute: 0
    )

    /// 持久化在 UserDefaults.standard 中的键：整个结构体以 JSON 存储。
    static let storageKey = "ThemeSwitch.config.v1"

    static func load() -> ThemeConfig {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(ThemeConfig.self, from: data),
              decoded.isValid
        else {
            return .default
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// timeZoneID == "system" 时返回 TimeZone.current，否则返回 TimeZone(identifier:)，取不到时回退 TimeZone.current
    var resolvedTimeZone: TimeZone {
        if timeZoneID == "system" {
            return TimeZone.current
        }
        return TimeZone(identifier: timeZoneID) ?? TimeZone.current
    }

    /// 参考时区的实际时区对象：语义同 resolvedTimeZone
    var resolvedReferenceTimeZone: TimeZone {
        if referenceTimeZoneID == "system" {
            return TimeZone.current
        }
        return TimeZone(identifier: referenceTimeZoneID) ?? TimeZone.current
    }

    /// 时区的展示名，例如 "Asia/Shanghai (UTC+8)"
    var timeZoneDisplayName: String {
        Self.displayName(for: resolvedTimeZone)
    }

    /// 参考时区的展示名，例如 "Asia/Shanghai (UTC+8)"
    var referenceTimeZoneDisplayName: String {
        Self.displayName(for: resolvedReferenceTimeZone)
    }

    /// 菜单栏时钟时区的实际时区对象：语义同 resolvedTimeZone
    var resolvedClockTimeZone: TimeZone {
        if clockTimeZoneID == "system" {
            return TimeZone.current
        }
        return TimeZone(identifier: clockTimeZoneID) ?? TimeZone.current
    }

    private static func displayName(for timeZone: TimeZone) -> String {
        let offsetSeconds = timeZone.secondsFromGMT(for: Date())
        let sign = offsetSeconds < 0 ? "-" : "+"
        let totalMinutes = abs(offsetSeconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let offsetText: String
        if minutes == 0 {
            offsetText = "\(hours)"
        } else {
            offsetText = "\(hours):\(String(format: "%02d", minutes))"
        }
        return "\(timeZone.identifier) (UTC\(sign)\(offsetText))"
    }

    /// 菜单栏时钟文本：中文「9月25日 周五 21:45」、英文「Sep 25 Fri 21:45」。
    /// 格式模式串存在 Localizable.strings 里（key: clock.date_format），两种语言各取各的；
    /// locale 用 Locale.current —— 在 App bundle 里它会跟随当前生效的界面语言，
    /// 星期名与月份名随之本地化。模式串固定用 HH，显式模式串不受 locale 的 12 小时偏好影响，
    /// 因此两种语言都是 24 小时制、不会出现 AM/PM。
    /// 设置窗口预览与菜单栏共用，保证两处显示一致。
    static func clockString(for date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = timeZone
        formatter.dateFormat = NSLocalizedString(
            "clock.date_format",
            comment: "Menu bar clock date format; keep the 24-hour \"HH\" pattern"
        )
        return formatter.string(from: date)
    }

    /// 取值范围是否合法，防止损坏或被手工篡改的偏好值进入调度逻辑。
    private var isValid: Bool {
        (0...23).contains(darkHour)
            && (0...59).contains(darkMinute)
            && (0...23).contains(lightHour)
            && (0...59).contains(lightMinute)
            && !timeZoneID.isEmpty
            && !referenceTimeZoneID.isEmpty
            && !clockTimeZoneID.isEmpty
    }
}

// MARK: - 界面语言

/// App 当前生效的界面语言：由 bundle 里的本地化资源（en.lproj / zh-Hans.lproj）决定，
/// 跟随系统「语言与地区」以及按 App 指定的语言。只有中文走 zh-Hans，其余一律英文。
enum AppLanguage {
    /// 只有中文界面才用中文专用的显示逻辑（时区中文城市名表）；英文界面走中性写法。
    static var isChinese: Bool {
        (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh")
    }
}

import Cocoa
import SwiftUI

// MARK: - 时区短名

/// 常见时区的中文城市名；只在中文界面使用（英文界面直接用 IANA 标识符最后一段，
/// 见 timeZoneShortName），表里没有的时区也走那里的兜底逻辑。
private let commonTimeZoneNames: [String: String] = [
    "UTC": "UTC",
    "Africa/Cairo": "开罗",
    "Africa/Johannesburg": "约翰内斯堡",
    "America/Argentina/Buenos_Aires": "布宜诺斯艾利斯",
    "America/Chicago": "芝加哥",
    "America/Denver": "丹佛",
    "America/Los_Angeles": "洛杉矶",
    "America/Mexico_City": "墨西哥城",
    "America/New_York": "纽约",
    "America/Phoenix": "凤凰城",
    "America/Sao_Paulo": "圣保罗",
    "America/Toronto": "多伦多",
    "America/Vancouver": "温哥华",
    "Asia/Bangkok": "曼谷",
    "Asia/Dubai": "迪拜",
    "Asia/Hong_Kong": "香港",
    "Asia/Jakarta": "雅加达",
    "Asia/Karachi": "卡拉奇",
    "Asia/Kolkata": "印度",
    "Asia/Macau": "澳门",
    "Asia/Seoul": "首尔",
    "Asia/Shanghai": "北京时间",
    "Asia/Singapore": "新加坡",
    "Asia/Taipei": "台北",
    "Asia/Tokyo": "东京",
    "Australia/Perth": "珀斯",
    "Australia/Sydney": "悉尼",
    "Europe/Amsterdam": "阿姆斯特丹",
    "Europe/Berlin": "柏林",
    "Europe/London": "伦敦",
    "Europe/Madrid": "马德里",
    "Europe/Moscow": "莫斯科",
    "Europe/Paris": "巴黎",
    "Europe/Rome": "罗马",
    "Pacific/Auckland": "奥克兰"
]

/// 时区短名。中文界面沿用上面的中文城市名表，表里没有时再取系统给出的中文名；
/// 英文界面不直译那张表 —— 直接用 IANA 标识符最后一段并把下划线换成空格
/// （America/Los_Angeles → Los Angeles），比意译更准确，也不会出现半中半英。
/// 两种语言都保留原有兜底：认不出的标识符原样返回，不崩。
private func timeZoneShortName(_ identifier: String) -> String {
    let resolved = identifier == "system" ? TimeZone.current.identifier : identifier
    if AppLanguage.isChinese {
        if let name = commonTimeZoneNames[identifier] ?? commonTimeZoneNames[resolved] {
            return name
        }
        if let timeZone = TimeZone(identifier: resolved) {
            let locale = Locale(identifier: "zh_CN")
            for style in [TimeZone.NameStyle.shortGeneric, .generic] {
                if let name = timeZone.localizedName(for: style, locale: locale), !name.isEmpty {
                    return name.hasSuffix("时间") ? String(name.dropLast(2)) : name
                }
            }
        }
    }
    guard TimeZone(identifier: resolved) != nil else {
        return resolved
    }
    return (resolved as NSString).lastPathComponent.replacingOccurrences(of: "_", with: " ")
}

// MARK: - 时间与换算

/// 设置窗口的尺寸约束。纯计算、无状态，便于单独编译测试。
enum Layout {
    /// 窗口内容宽度按语言取值：英文标签更长，520 下输入框和开关文字会被挤得偏窄，560 更舒服。
    static var contentWidth: CGFloat { AppLanguage.isChinese ? 520 : 560 }

    /// 内容高度上限相对屏幕可用高度的边距。visibleFrame 已经排除菜单栏与 Dock，
    /// 这里再留一点空隙，免得窗口紧贴菜单栏或 Dock。
    static let verticalMargin: CGFloat = 40

    /// 内容高度下限：极小屏幕或 visibleFrame 异常时也不把内容压到不可用
    /// （底部按钮行始终完整可见）。
    static let minimumContentHeight: CGFloat = 360

    /// 拿不到屏幕尺寸时的兜底可用高度（例如窗口还没上屏）。
    static let fallbackVisibleHeight: CGFloat = 900

    /// 内容高度上限 = 屏幕可用高度 - 上下边距 - 窗口装饰（标题栏）高度，再以下限兜底。
    /// 内容比上限高时多出来的部分交给设置视图里的 ScrollView 滚动，窗口本身不会长到屏幕外
    /// ——曾经就是没这个上限：窗口 1084pt 高、屏幕放不下，底部的「保存」按钮既点不到也没有滚动条。
    /// visibleHeight 非有限值或非正数（拿不到屏幕）时退回 fallbackVisibleHeight。
    static func maxContentHeight(forVisibleHeight visibleHeight: CGFloat, chromeHeight: CGFloat = 0) -> CGFloat {
        let usable = visibleHeight.isFinite && visibleHeight > 0 ? visibleHeight : fallbackVisibleHeight
        let chrome = chromeHeight.isFinite ? max(0, chromeHeight) : 0
        return max(minimumContentHeight, usable - verticalMargin - chrome)
    }

    /// 当前屏幕的可用高度；拿不到屏幕（窗口还没上屏）时退回兜底值。
    /// AppKit 侧还会按窗口真正所在屏幕再算一次，这里只负责让 SwiftUI 侧有个合理上限。
    static func currentVisibleHeight() -> CGFloat {
        NSScreen.main?.visibleFrame.height ?? fallbackVisibleHeight
    }
}

/// 换算提示里的「钟点」：纯数字，固定 24 小时制。
/// 固定用 en_US_POSIX 是为了不受界面语言影响 —— 两种语言下输出完全一致，也不会变成 12 小时制。
private func wallClockString(_ date: Date, in timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

/// date 在 timeZone 当地日历中的「第几天」（换算为 UTC 纪元天序号），
/// 用于判断时区换算后是否跨天。不用 Calendar.ordinality：在该 SDK 上它会忽略时区。
private func absoluteDay(_ date: Date, in timeZone: TimeZone) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    return Int(utc.date(from: components)!.timeIntervalSince1970 / 86_400)
}

private func calendar(for timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
}

private enum ZoneHint {
    struct Conversion {
        let action: String
        let zoneTime: String
        let referenceTime: String
        let dayOffset: Int
    }

    case empty
    case invalidTimeZone
    case invalidReferenceTimeZone
    case sameAsReference(zoneName: String)
    case converted(zoneName: String, referenceName: String, dark: Conversion, light: Conversion, localNow: String)
}

/// 把所设时区的切换时刻（date 的时分）换算成参考时区的当地时间，
/// 并标注是否相对所设时区跨天（>0 次日，<0 前一天）。
private func conversion(
    for date: Date,
    in timeZone: TimeZone,
    referenceTimeZone: TimeZone,
    action: String
) -> ZoneHint.Conversion {
    let zoneCalendar = calendar(for: timeZone)
    var components = zoneCalendar.dateComponents([.year, .month, .day], from: Date())
    let picked = Calendar.current.dateComponents([.hour, .minute], from: date)
    components.hour = picked.hour
    components.minute = picked.minute
    components.second = 0
    let instant = zoneCalendar.date(from: components) ?? date
    return ZoneHint.Conversion(
        action: action,
        zoneTime: wallClockString(instant, in: timeZone),
        referenceTime: wallClockString(instant, in: referenceTimeZone),
        dayOffset: absoluteDay(instant, in: referenceTimeZone) - absoluteDay(instant, in: timeZone)
    )
}

/// 换算提示始终拿「参考时区」做对比：参考时区与所设时区相同时不换算，
/// 否则列出两个切换时刻各自在参考时区的当地时间（跨天时加注）。
private func makeZoneHint(timeZoneID: String, referenceTimeZoneID: String, darkTime: Date, lightTime: Date) -> ZoneHint {
    let identifier = timeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)
    if identifier.isEmpty {
        return .empty
    }
    if identifier != "system", TimeZone(identifier: identifier) == nil {
        return .invalidTimeZone
    }
    // 参考时区留空视同跟随系统；非 "system" 时必须是有效 IANA 标识
    let referenceIdentifier = referenceTimeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedReference = referenceIdentifier.isEmpty ? "system" : referenceIdentifier
    if normalizedReference != "system", TimeZone(identifier: normalizedReference) == nil {
        return .invalidReferenceTimeZone
    }
    let timeZone = identifier == "system" ? TimeZone.current : TimeZone(identifier: identifier)!
    let referenceZone = normalizedReference == "system"
        ? TimeZone.current
        : TimeZone(identifier: normalizedReference)!
    if timeZone.identifier == referenceZone.identifier {
        return .sameAsReference(zoneName: timeZoneShortName(timeZone.identifier))
    }
    return .converted(
        zoneName: timeZoneShortName(timeZone.identifier),
        referenceName: timeZoneShortName(referenceZone.identifier),
        dark: conversion(
            for: darkTime,
            in: timeZone,
            referenceTimeZone: referenceZone,
            action: NSLocalizedString("action.darken", comment: "")
        ),
        light: conversion(
            for: lightTime,
            in: timeZone,
            referenceTimeZone: referenceZone,
            action: NSLocalizedString("action.lighten", comment: "")
        ),
        localNow: wallClockString(Date(), in: timeZone)
    )
}

// MARK: - 编辑模型

final class SettingsModel: ObservableObject {
    @Published var enabled: Bool
    /// 登录自启。真实来源是系统登录项（LoginItem），不进 ThemeConfig：
    /// 它只在点「保存」时写回系统，点「取消」时靠 load(from:) 重新读系统状态回滚。
    @Published var launchAtLogin: Bool
    /// 界面语言选择（编辑中的值）："system" / "en" / "zh-Hans"。与窗口里其它控件一致，
    /// 点「保存」才写进配置，点「取消」由 load(from:) 回滚。
    @Published var language: String
    /// 当前实际生效的界面语言标识（来自已保存的配置）：设置窗口自己用它渲染。
    /// 与 language 分开，是因为窗口里的 SwiftUI 文案要和菜单、弹窗同一语言 ——
    /// 那些地方（NSLocalizedString / 时区短名表）走的是已保存的选择，
    /// 若这里跟着编辑中的值走，会出现「窗口已经是新语言、菜单还是旧语言」的错位。
    @Published var activeLanguage: String
    @Published var timeZoneID: String
    @Published var referenceTimeZoneID: String
    @Published var showClock: Bool
    @Published var clockTimeZoneID: String
    @Published var darkTime: Date
    @Published var lightTime: Date

    init() {
        let config = ThemeConfig.default
        enabled = config.enabled
        launchAtLogin = LoginItem.isEnabled
        language = config.language
        activeLanguage = LanguageOverride.effectiveIdentifier
        timeZoneID = config.timeZoneID
        referenceTimeZoneID = config.referenceTimeZoneID
        showClock = config.showClock
        clockTimeZoneID = config.clockTimeZoneID
        darkTime = Self.timeOfDay(hour: config.darkHour, minute: config.darkMinute)
        lightTime = Self.timeOfDay(hour: config.lightHour, minute: config.lightMinute)
    }

    func load(from config: ThemeConfig) {
        enabled = config.enabled
        // 每次重新读系统真实状态，而不是沿用界面上的值
        launchAtLogin = LoginItem.isEnabled
        language = LanguageOverride.normalized(config.language)
        // 已保存的配置此刻已经生效（AppDelegate 每次刷新都会 apply），直接取当前生效值
        activeLanguage = LanguageOverride.effectiveIdentifier
        timeZoneID = config.timeZoneID.isEmpty ? "system" : config.timeZoneID
        referenceTimeZoneID = config.referenceTimeZoneID.isEmpty ? "system" : config.referenceTimeZoneID
        showClock = config.showClock
        clockTimeZoneID = config.clockTimeZoneID.isEmpty ? "system" : config.clockTimeZoneID
        darkTime = Self.timeOfDay(hour: config.darkHour, minute: config.darkMinute)
        lightTime = Self.timeOfDay(hour: config.lightHour, minute: config.lightMinute)
    }

    func makeConfig(
        timeZoneID: String,
        referenceTimeZoneID: String,
        clockTimeZoneID: String
    ) -> ThemeConfig {
        ThemeConfig(
            enabled: enabled,
            timeZoneID: timeZoneID,
            darkHour: Self.hour(of: darkTime),
            darkMinute: Self.minute(of: darkTime),
            lightHour: Self.hour(of: lightTime),
            lightMinute: Self.minute(of: lightTime),
            referenceTimeZoneID: referenceTimeZoneID,
            showClock: showClock,
            clockTimeZoneID: clockTimeZoneID,
            language: LanguageOverride.normalized(language)
        )
    }

    private static func timeOfDay(hour: Int, minute: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = min(max(hour, 0), 23)
        components.minute = min(max(minute, 0), 59)
        components.second = 0
        return Calendar.current.date(from: components) ?? Date()
    }

    private static func hour(of date: Date) -> Int {
        Calendar.current.component(.hour, from: date)
    }

    private static func minute(of date: Date) -> Int {
        Calendar.current.component(.minute, from: date)
    }
}

// MARK: - 时区换算提示行

private struct ConversionLine: View {
    let zoneName: String
    let conversion: ZoneHint.Conversion
    let referenceName: String

    var body: some View {
        HStack(spacing: 6) {
            Text(zoneName)
                .foregroundStyle(.secondary)
            Text(conversion.zoneTime)
                .fontWeight(.medium)
                .monospacedDigit()
            Text(conversion.action)
                .foregroundStyle(.secondary)
            // 「=」是语言中立的符号，不走本地化查表
            Text(verbatim: "=")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            Text(referenceName)
                .foregroundStyle(.secondary)
            Text(conversion.referenceTime)
                .fontWeight(.medium)
                .monospacedDigit()
            if conversion.dayOffset > 0 {
                Text("settings.hint.next_day")
                    .foregroundStyle(.secondary)
            } else if conversion.dayOffset < 0 {
                Text("settings.hint.previous_day")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        // 英文换算行更长：窄行下宁可略微缩字，也不要截断成「…」
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
}

// MARK: - 设置视图（SwiftUI）

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var onReset: () -> Void
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 只有表单参与滚动：底部的「恢复默认 / 取消 / 保存」固定在窗口底部不滚动，
            // 任何屏幕尺寸下都点得到（以前窗口会一直长到屏幕外，这几个按钮就再也点不到了）。
            // 内容不超高时 ScrollView 不多占高度、也不会出现滚动条
            // （macOS 默认是滚动时才显示的浮层滚动条），窗口仍按内容自适应高度。
            ScrollView {
                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("settings.general.enable", isOn: $model.enabled)
                            Toggle("settings.general.launch_at_login", isOn: $model.launchAtLogin)
                            HStack(spacing: 12) {
                                Text("settings.general.language")
                                    .fixedSize()
                                Picker("settings.general.language", selection: $model.language) {
                                    // 语言名一律用各自的母语写法（English / 简体中文），两套 .strings 里取值相同、
                                    // 不随界面语言翻译 —— 这样不管界面当前是什么语言，用户都认得出自己的语言；
                                    // 只有「跟随系统」跟当前语言走。
                                    Text("language.follow_system").tag(LanguageOverride.systemValue)
                                    Text("language.en").tag(LanguageOverride.englishIdentifier)
                                    Text("language.zh_hans").tag(LanguageOverride.simplifiedChineseIdentifier)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text("settings.general.language_hint")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    } header: {
                        Text("settings.section.general")
                    } footer: {
                        Text("settings.general.footer")
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Text("settings.time_zone.label")
                                    .fixedSize()
                                TimeZoneComboBox(selection: $model.timeZoneID)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            HStack(spacing: 12) {
                                Text("settings.time_zone.reference_label")
                                    .fixedSize()
                                TimeZoneComboBox(selection: $model.referenceTimeZoneID)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            hintView
                        }
                        .padding(.vertical, 2)
                    } header: {
                        Text("settings.section.time_zone")
                    } footer: {
                        Text("settings.time_zone.footer")
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Section {
                        Grid(alignment: .leading, verticalSpacing: 14) {
                            GridRow {
                                Text("settings.switch_times.to_dark")
                                    .fixedSize()
                                timePicker(
                                    label: NSLocalizedString("settings.switch_times.to_dark", comment: ""),
                                    time: $model.darkTime
                                )
                            }
                            GridRow {
                                Text("settings.switch_times.to_light")
                                    .fixedSize()
                                timePicker(
                                    label: NSLocalizedString("settings.switch_times.to_light", comment: ""),
                                    time: $model.lightTime
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("settings.section.switch_times")
                    } footer: {
                        Text("settings.switch_times.footer")
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("settings.clock.show", isOn: $model.showClock)
                            HStack(spacing: 12) {
                                Text("settings.clock.time_zone_label")
                                    .fixedSize()
                                TimeZoneComboBox(selection: $model.clockTimeZoneID)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ClockPreviewLine(showClock: $model.showClock, timeZoneID: $model.clockTimeZoneID)
                        }
                        .padding(.vertical, 2)
                    } header: {
                        Text("settings.section.clock")
                    } footer: {
                        Text("settings.clock.footer")
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Section {
                        Text("settings.about.body")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text("settings.section.about")
                    }
                }
                .formStyle(.grouped)
            }

            Divider()

            HStack(spacing: 12) {
                Button("settings.button.reset", action: onReset)
                Spacer()
                Button("settings.button.cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("settings.button.save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        // SwiftUI 侧的本地化语言：`Text("key")`（LocalizedStringKey）按它查表。
        // 与 AppKit 侧 LanguageOverride 交换 bundle 查表取的是同一个语言，两边不会打架。
        // 取的是已保存并生效的语言（activeLanguage），所以窗口里的文案与菜单、弹窗始终一致。
        .environment(\.locale, AppLanguage.locale(for: model.activeLanguage))
        .frame(width: Layout.contentWidth)
        // 高度上限按当前屏幕可用高度算：超出的部分交给上面的 ScrollView 滚动。
        // AppKit 侧（FittingHostingController）还会按窗口真正所在的屏幕再兜一次底。
        .frame(maxHeight: Layout.maxContentHeight(forVisibleHeight: Layout.currentVisibleHeight()))
    }

    private func timePicker(label: String, time: Binding<Date>) -> some View {
        DatePicker(label, selection: time, displayedComponents: [.hourAndMinute])
            .labelsHidden()
            .environment(\.locale, Self.timePickerLocale)
    }

    /// 时间选择器用的 locale：语言跟随 App 当前语言，小时制固定 24 小时
    /// （与菜单栏时钟口径一致，英文下也不会出现 AM/PM）。
    /// 按当前语言现算而不是用 static let：语言能在 App 内切换，常量会一直停在启动时的语言。
    private static var timePickerLocale: Locale {
        var components = Locale.Components(identifier: AppLanguage.locale.identifier)
        components.hourCycle = .zeroToTwentyThree
        return Locale(components: components)
    }

    @ViewBuilder
    private var hintView: some View {
        switch makeZoneHint(
            timeZoneID: model.timeZoneID,
            referenceTimeZoneID: model.referenceTimeZoneID,
            darkTime: model.darkTime,
            lightTime: model.lightTime
        ) {
        case .empty:
            Text("settings.hint.empty")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .invalidTimeZone:
            Label("settings.hint.invalid_zone", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .invalidReferenceTimeZone:
            Label("settings.hint.invalid_reference_zone", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .sameAsReference(let zoneName):
            Text(String(
                format: NSLocalizedString("settings.hint.same_zone", comment: ""),
                zoneName
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        case .converted(let zoneName, let referenceName, let dark, let light, let localNow):
            VStack(alignment: .leading, spacing: 6) {
                ConversionLine(zoneName: zoneName, conversion: dark, referenceName: referenceName)
                ConversionLine(zoneName: zoneName, conversion: light, referenceName: referenceName)
                Text(String(
                    format: NSLocalizedString("settings.hint.local_now", comment: ""),
                    zoneName,
                    localNow
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 菜单栏时钟预览行

/// 时钟预览的计算结果（纯数据，便于用固定时间戳单独测试）
struct ClockPreview: Equatable {
    /// 预览用的时区
    let timeZone: TimeZone
    /// 该时区下的日期时间文本（与菜单栏时钟共用同一个格式化函数，两处显示始终一致）
    let text: String
    /// 时钟已关闭：仍然算出时间，只是弱化显示并附「已关闭」标记
    let isOff: Bool
}

/// 预览用的时区：空值 / "system" / 非法标识都回退系统时区。
/// 非法标识在保存时会被拦截、不会写进配置，这里回退只是让预览始终有东西可显示。
func previewTimeZone(for timeZoneID: String) -> TimeZone {
    let identifier = timeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)
    if identifier.isEmpty || identifier == "system" {
        return TimeZone.current
    }
    return TimeZone(identifier: identifier) ?? TimeZone.current
}

/// 时钟预览的纯函数：时间点由调用方给出，方便用固定时间戳测试。
/// 关闭状态下也照常算出该时区的时间 —— 只显示「已关闭」的话，改时区时预览不会有任何变化，
/// 很容易被当成「时区没生效」。
func makeClockPreview(showClock: Bool, timeZoneID: String, at date: Date) -> ClockPreview {
    let timeZone = previewTimeZone(for: timeZoneID)
    return ClockPreview(
        timeZone: timeZone,
        text: ThemeConfig.clockString(for: date, in: timeZone),
        isOff: !showClock
    )
}

/// 实时预览菜单栏时钟：随开关、时区、当前时间更新；时钟关闭时弱化显示并标注「已关闭」。
/// 刷新用 Timer + @State 自己驱动，而不是 TimelineView：TimelineView 的 content 闭包会捕获
/// 创建时的视图值，父视图重渲染时闭包未必被替换，于是「改了时区预览不跟着变」。
/// 这里每次 tick 都让 body 按当前绑定值重算，结构上就读不到旧值。
private struct ClockPreviewLine: View {
    @Binding var showClock: Bool
    @Binding var timeZoneID: String

    /// 每秒一跳的「现在」，与 AppDelegate 里菜单栏时钟的定时器同频
    @State private var now = Date()
    private static let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let preview = makeClockPreview(showClock: showClock, timeZoneID: timeZoneID, at: now)
        return HStack(spacing: 6) {
            Text("settings.clock.preview")
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(preview.text)
                .monospacedDigit()
                .fixedSize()
                .foregroundStyle(preview.isOff ? Color.secondary : Color.primary)
            if preview.isOff {
                Text("settings.clock.preview_off")
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .font(.callout)
        .onReceive(Self.ticker) { now = $0 }
    }
}

// MARK: - 时区选择框（可搜索 ComboBox）

/// 时区选择框的写入决策：三条回调路径共用一份纯逻辑，便于单独编译测试。
/// 只判断「该不该写、写什么」，不碰控件，也不碰绑定。
enum TimeZoneComboWriter {
    /// 触发写入的回调来源
    enum Source: Equatable {
        /// 从下拉列表选中一项，或按下回车：控件里的文本就是用户的选择
        case action
        /// 输入过程中：只提交已经合法的标识，让预览与换算提示即时跟随
        case typing
        /// 结束编辑：只有用户确实改过文本（typedSinceLastCommit）才提交
        case endEditing(typedSinceLastCommit: Bool)
    }

    /// 返回要写进配置的值；nil 表示这次回调不写。
    /// text 必须是已规范化的值（见 TimeZoneComboBox.normalized）。
    static func value(normalized text: String, current: String, source: Source) -> String? {
        // 值没变就不写：省掉一次无谓的模型更新与整窗重渲染
        guard text != current else { return nil }
        switch source {
        case .action:
            return text
        case .typing:
            // 半截文本留在控件里，不进配置；但已经合法的标识要即时提交，
            // 否则用户还在输入框里时预览、换算提示都不会动。
            return isValid(text) ? text : nil
        case .endEditing(let typedSinceLastCommit):
            // 一次下拉选择可能先触发 comboBoxAction、随后才来 controlTextDidEndEditing；
            // 后者若带的是选中前的旧文本，就会把刚写进去的新值覆盖回旧值（顺序由 AppKit 决定，
            // 不可依赖）。只有「用户确实改过文本」的结束编辑才提交，这条路径就写不出旧值。
            return typedSinceLastCommit ? text : nil
        }
    }

    /// 能写进配置的标识：哨兵值 "system"，或任意合法的 IANA 时区标识
    static func isValid(_ identifier: String) -> Bool {
        identifier == "system" || TimeZone(identifier: identifier) != nil
    }
}

private struct TimeZoneComboBox: NSViewRepresentable {
    @Binding var selection: String

    /// 下拉框第一项「跟随系统」的本地化显示文案。它只是显示值，配置里存的仍是哨兵值 "system"；
    /// 显示、规范化、以及非法标识弹窗里的提示共用这一个来源，
    /// 否则切到英文后选 "Follow System" 会被当成非法时区标识。
    fileprivate static var followSystemItem: String {
        NSLocalizedString("zone.follow_system", comment: "")
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.isEditable = true
        comboBox.completes = true
        comboBox.addItems(withObjectValues: [Self.followSystemItem] + TimeZone.knownTimeZoneIdentifiers)
        comboBox.stringValue = Self.displayText(for: selection)
        comboBox.target = context.coordinator
        comboBox.action = #selector(Coordinator.comboBoxAction(_:))
        comboBox.delegate = context.coordinator
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        // 每次都刷新 coordinator 持有的最新绑定，否则它会一直写回旧的值。
        context.coordinator.parent = self
        // 只在用户没有正在编辑时才同步显示值：
        // 编辑中强行改写 stringValue 会把用户刚选中的内容弹回旧值（这正是之前保存不上的原因）。
        guard comboBox.currentEditor() == nil else { return }
        let displayText = Self.displayText(for: selection)
        if comboBox.stringValue != displayText {
            comboBox.stringValue = displayText
        }
    }

    private static func displayText(for identifier: String) -> String {
        identifier == "system" ? followSystemItem : identifier
    }

    /// 把控件里的文本规范成配置里存的标识：本地化后的「跟随系统」（英文 "Follow System"）→ "system"，
    /// 其余去掉首尾空白。比较的是本地化后的显示文案本身，不再写死中文。
    fileprivate static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == followSystemItem ? "system" : trimmed
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: TimeZoneComboBox
        /// 上一次提交之后用户是否又改过文本。controlTextDidChange 置位、提交成功后清零，
        /// 用来判断「结束编辑」这条路径该不该写（见 TimeZoneComboWriter.Source.endEditing）。
        private var typedSinceLastCommit = false

        init(_ parent: TimeZoneComboBox) {
            self.parent = parent
        }

        /// 从下拉列表选中一项，或按下回车
        @objc func comboBoxAction(_ sender: NSComboBox) {
            commit(from: sender, source: .action)
        }

        /// 输入过程中：只提交已经合法的标识 —— 半截文本（例如刚敲到 "Asia/Shan"）不进配置，
        /// 免得每敲一个字符就写一次半成品；但输入到合法标识的那一刻就提交，
        /// 这样时钟预览、换算提示不用等用户离开输入框才更新。
        @objc func controlTextDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            typedSinceLastCommit = true
            commit(from: comboBox, source: .typing)
        }

        /// 手输自定义标识后离开输入框（或关窗、点其它控件）时提交。
        /// 不用 controlTextDidChange 直接写：见上面那条。
        @objc func controlTextDidEndEditing(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            commit(from: comboBox, source: .endEditing(typedSinceLastCommit: typedSinceLastCommit))
        }

        /// 三条回调路径唯一的写入口：先规范化，再由 TimeZoneComboWriter 决定写不写。
        private func commit(from comboBox: NSComboBox, source: TimeZoneComboWriter.Source) {
            let text = TimeZoneComboBox.normalized(comboBox.stringValue)
            guard let value = TimeZoneComboWriter.value(
                normalized: text,
                current: parent.selection,
                source: source
            ) else { return }
            typedSinceLastCommit = false
            parent.selection = value
        }
    }
}

// MARK: - AppKit 窗口壳

final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hostingController: FittingHostingController<SettingsView>?
    private let model = SettingsModel()

    func show() {
        if window == nil {
            buildWindow()
        }
        model.load(from: ThemeConfig.load())
        // 窗口标题、内容宽度都是 AppKit 侧的，不跟 SwiftUI 环境 locale 走：
        // 界面语言可以在 App 内切换，所以每次打开都按当前语言重设一次，
        // 否则切完语言再打开设置窗口，标题还停在旧语言、宽度也还是旧语言的。
        window?.title = NSLocalizedString("settings.window.title", comment: "")
        hostingController?.minContentWidth = Layout.contentWidth
        // 语言可能在两次打开之间被切过（宽度、文案行数都变了），重新套用一次尺寸，
        // 顺带保证窗口留在屏幕可见区域内；尺寸没变时这两步都是空操作。
        hostingController?.applyFittingSize()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let rootView = SettingsView(
            model: model,
            onReset: { [weak self] in self?.resetToDefaults() },
            onCancel: { [weak self] in self?.cancelChanges() },
            onSave: { [weak self] in self?.saveChanges() }
        )
        let hostingController = FittingHostingController(rootView: rootView)
        hostingController.minContentWidth = Layout.contentWidth
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable]
        window.title = NSLocalizedString("settings.window.title", comment: "")
        window.delegate = self
        self.window = window
        self.hostingController = hostingController
        window.center()
        hostingController.applyFittingSize()
    }

    private func resetToDefaults() {
        model.load(from: ThemeConfig.default)
    }

    private func cancelChanges() {
        model.load(from: ThemeConfig.load())
        window?.orderOut(nil)
    }

    /// 非法时区标识的统一提示文案：参数是用户输入（或下拉框里）的原始文本，
    /// 「跟随系统」按当前界面语言显示，不再是写死的中文。
    private func invalidTimeZoneMessage(_ identifier: String) -> String {
        String(
            format: NSLocalizedString("alert.timezone.invalid.message", comment: ""),
            identifier,
            TimeZoneComboBox.followSystemItem
        )
    }

    private func saveChanges() {
        let identifier = model.timeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        if identifier != "system", TimeZone(identifier: identifier) == nil {
            presentAlert(
                title: NSLocalizedString("alert.timezone.invalid.title", comment: ""),
                message: invalidTimeZoneMessage(identifier)
            )
            return
        }
        let referenceIdentifier = model.referenceTimeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReference = referenceIdentifier.isEmpty ? "system" : referenceIdentifier
        if normalizedReference != "system", TimeZone(identifier: normalizedReference) == nil {
            presentAlert(
                title: NSLocalizedString("alert.reference_timezone.invalid.title", comment: ""),
                message: invalidTimeZoneMessage(referenceIdentifier)
            )
            return
        }
        let clockIdentifier = model.clockTimeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedClock = clockIdentifier.isEmpty ? "system" : clockIdentifier
        if normalizedClock != "system", TimeZone(identifier: normalizedClock) == nil {
            presentAlert(
                title: NSLocalizedString("alert.clock_timezone.invalid.title", comment: ""),
                message: invalidTimeZoneMessage(clockIdentifier)
            )
            return
        }
        let config = model.makeConfig(
            timeZoneID: identifier,
            referenceTimeZoneID: normalizedReference,
            clockTimeZoneID: normalizedClock
        )
        if !(0...23).contains(config.darkHour) || !(0...59).contains(config.darkMinute)
            || !(0...23).contains(config.lightHour) || !(0...59).contains(config.lightMinute)
        {
            presentAlert(
                title: NSLocalizedString("alert.time.invalid.title", comment: ""),
                message: NSLocalizedString("alert.time.invalid.message", comment: "")
            )
            return
        }
        // 登录自启只在点「保存」时才写回系统；只在开关与系统实际状态不一致时才动手，
        // 避免「没碰过这个开关的保存」也去重写登录项。
        if model.launchAtLogin != LoginItem.isEnabled {
            do {
                try LoginItem.setEnabled(model.launchAtLogin)
            } catch {
                // 失败就不保存、不关窗：把开关还原成系统实际状态，由用户看到后再决定，
                // 不让界面显示的状态和系统真正的状态对不上。
                model.launchAtLogin = LoginItem.isEnabled
                presentAlert(
                    title: NSLocalizedString("alert.login_item.failed.title", comment: ""),
                    message: error.localizedDescription
                )
                return
            }
        }
        config.save()
        // 语言立即生效：先 apply 一次，不依赖通知的时序；下面的通知会让 AppDelegate 重新刷新
        // 菜单与菜单栏时钟（它每次刷新也会 apply）。设置窗口自身在下次打开时按新语言渲染。
        LanguageOverride.apply(config.language)
        NotificationCenter.default.post(name: .themeConfigChanged, object: nil)
        window?.orderOut(nil)
    }

    private func presentAlert(title: String, message: String) {
        guard let window else {
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("alert.ok", comment: ""))
        alert.beginSheetModal(for: window) { _ in }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.load(from: ThemeConfig.load())
        return true
    }
}

/// 让 SwiftUI 内容的高度驱动窗口大小：布局后用 hosting view 的 fittingSize 同步窗口尺寸，
/// 内容变化（换算提示行数增减、界面语言切换等）时窗口随之伸缩。
/// 高度同时被屏幕可用高度约束（见 Layout.maxContentHeight）：超出的部分交给内容里的
/// ScrollView 滚动，窗口不会长到屏幕外面去；换尺寸后还会把窗口收回屏幕可见区域内。
private final class FittingHostingController<Content: View>: NSHostingController<Content> {
    var minContentWidth: CGFloat = 0
    private var appliedContentSize: NSSize = .zero

    override func viewDidLayout() {
        super.viewDidLayout()
        fitContent()
    }

    /// 窗口创建后、以及每次重新打开时套用一次（此时 fittingSize 已可用）：
    /// 重新打开时也调用，是因为语言可能在两次打开之间被切过，内容宽高都会变。
    func applyFittingSize() {
        view.layoutSubtreeIfNeeded()
        fitContent()
        keepOnScreen()
    }

    private func fitContent() {
        guard let window = view.window else { return }
        let fitting = view.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        let target = NSSize(
            width: max(minContentWidth, ceil(fitting.width)),
            height: min(
                max(ceil(fitting.height), Layout.minimumContentHeight),
                contentHeightLimit(of: window)
            )
        )
        if abs(target.width - appliedContentSize.width) < 0.5,
           abs(target.height - appliedContentSize.height) < 0.5
        {
            return
        }
        appliedContentSize = target
        // 以原中心为基准换尺寸（语义同 setContentSize，但不会把窗口顶出屏幕），随后再收回可见区域
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: target)).size
        var frame = window.frame
        frame.origin = NSPoint(
            x: frame.midX - frameSize.width / 2,
            y: frame.midY - frameSize.height / 2
        )
        frame.size = frameSize
        window.setFrame(frame, display: true)
        keepOnScreen()
    }

    /// 窗口内容高度的上限：按窗口所在屏幕的可用高度算，并扣掉标题栏等窗口装饰。
    /// 拿不到屏幕时用兜底值，宁可给个保守上限也不要让窗口长出屏幕。
    private func contentHeightLimit(of window: NSWindow) -> CGFloat {
        let visibleHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? Layout.fallbackVisibleHeight
        let chromeHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        return Layout.maxContentHeight(forVisibleHeight: visibleHeight, chromeHeight: chromeHeight)
    }

    /// 把窗口收回屏幕可见区域内。尺寸没变时也要做：换屏幕、改分辨率之后窗口可能落在屏幕外。
    /// 窗口比可见区域还高时让顶部对齐可见区域顶部 —— 至少标题栏与红绿灯按钮点得到。
    func keepOnScreen() {
        guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        if frame.height > visible.height {
            frame.origin.y = visible.maxY - frame.height
        } else {
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        if frame.width > visible.width {
            frame.origin.x = visible.minX
        } else {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        }
        if frame != window.frame {
            window.setFrame(frame, display: true)
        }
    }
}

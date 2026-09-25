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

private enum Layout {
    /// 窗口内容宽度按语言取值：英文标签更长，520 下输入框和开关文字会被挤得偏窄，560 更舒服。
    /// 高度仍由 SwiftUI 内容（NSHostingController.fittingSize）决定，不放滚动条、不裁切。
    static var contentWidth: CGFloat { AppLanguage.isChinese ? 520 : 560 }
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
            clockTimeZoneID: clockTimeZoneID
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
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("settings.general.enable", isOn: $model.enabled)
                        Toggle("settings.general.launch_at_login", isOn: $model.launchAtLogin)
                        Text("settings.general.launch_at_login_hint")
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
                                    .disabled(!model.showClock)
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
        .frame(width: Layout.contentWidth)
    }

    private func timePicker(label: String, time: Binding<Date>) -> some View {
        DatePicker(label, selection: time, displayedComponents: [.hourAndMinute])
            .labelsHidden()
            .environment(\.locale, Self.timePickerLocale)
    }

    /// 时间选择器用的 locale：语言跟随 App 当前语言，小时制固定 24 小时
    /// （与菜单栏时钟口径一致，英文下也不会出现 AM/PM）。
    private static let timePickerLocale: Locale = {
        var components = Locale.Components(identifier: Locale.current.identifier)
        components.hourCycle = .zeroToTwentyThree
        return Locale(components: components)
    }()

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

/// 实时预览菜单栏时钟：随开关、时区、当前时间更新；关闭时置灰显示「已关闭」。
private struct ClockPreviewLine: View {
    @Binding var showClock: Bool
    @Binding var timeZoneID: String

    var body: some View {
        HStack(spacing: 6) {
            Text("settings.clock.preview")
                .foregroundStyle(.secondary)
                .fixedSize()
            if showClock {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ThemeConfig.clockString(for: context.date, in: previewTimeZone))
                        .monospacedDigit()
                        .fixedSize()
                }
            } else {
                Text("settings.clock.preview_off")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
    }

    /// 预览用的时区：非法标识暂时回退系统时区（保存时会被拦截，不会写入配置）
    private var previewTimeZone: TimeZone {
        let identifier = timeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        if identifier.isEmpty || identifier == "system" {
            return TimeZone.current
        }
        return TimeZone(identifier: identifier) ?? TimeZone.current
    }
}

// MARK: - 时区选择框（可搜索 ComboBox）

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

        init(_ parent: TimeZoneComboBox) {
            self.parent = parent
        }

        /// 从下拉列表选中一项，或按下回车
        @objc func comboBoxAction(_ sender: NSComboBox) {
            parent.selection = TimeZoneComboBox.normalized(sender.stringValue)
        }

        /// 手输自定义标识后离开输入框时提交。
        /// 这里刻意不用 controlTextDidChange —— 那会在每敲一个字符时就把半截文本写进配置。
        @objc func controlTextDidEndEditing(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            parent.selection = TimeZoneComboBox.normalized(comboBox.stringValue)
        }
    }
}

// MARK: - AppKit 窗口壳

final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = SettingsModel()

    func show() {
        if window == nil {
            buildWindow()
        }
        model.load(from: ThemeConfig.load())
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

/// 让 SwiftUI 内容的高度驱动窗口大小：布局后用 hosting view 的 fittingSize 同步
/// window.contentSize。内容变化（换算提示行数增减等）时窗口随之伸缩，
/// 不再用固定高度把内容裁进滚动条。本机实测 fittingSize 在窗口创建后即可用。
private final class FittingHostingController<Content: View>: NSHostingController<Content> {
    var minContentWidth: CGFloat = 0
    private var appliedContentSize: NSSize = .zero

    override func viewDidLayout() {
        super.viewDidLayout()
        fitContent()
    }

    /// 窗口创建后立即套用一次，减少首次显示时的尺寸跳动（本机实测此时 fittingSize 已可用）。
    func applyFittingSize() {
        view.layoutSubtreeIfNeeded()
        fitContent()
    }

    private func fitContent() {
        guard let window = view.window else { return }
        let fitting = view.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        let target = NSSize(
            width: max(minContentWidth, ceil(fitting.width)),
            height: ceil(fitting.height)
        )
        if abs(target.width - appliedContentSize.width) < 0.5,
           abs(target.height - appliedContentSize.height) < 0.5
        {
            return
        }
        appliedContentSize = target
        window.setContentSize(target)
    }
}

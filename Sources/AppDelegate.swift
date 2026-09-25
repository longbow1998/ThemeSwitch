import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    /// 菜单栏时钟的 1 秒定时器，与上面 8 秒的调度轮询 Timer 并存，互不干扰
    private var clockTimer: Timer?
    private var settingsWindow: SettingsWindow?
    private var statusMenuItem: NSMenuItem?
    private var nextSwitchMenuItem: NSMenuItem?
    private var quickToggleMenuItem: NSMenuItem?
    private var observerTokens: [NSObjectProtocol] = []
    /// 最近一次生效的配置：供 1 秒时钟定时器使用，避免每秒读盘；随 refreshUI 更新
    private var currentConfig: ThemeConfig = .default

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        observerTokens.append(
            NotificationCenter.default.addObserver(
                forName: .themeConfigChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyScheduledAppearance()
            }
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        startPollingTimer()
        startClockTimer()
        applyScheduledAppearance()

        // 调试入口：设了 THEMESWITCH_OPEN_SETTINGS=1 时启动即打开设置窗口。
        // 菜单栏图标（LSUIElement 的状态项）无法通过 AX 触发，自动化测试只能靠这个开关。
        if ProcessInfo.processInfo.environment["THEMESWITCH_OPEN_SETTINGS"] == "1" {
            openSettings(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - 状态栏

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self

        // 信息区：两条只读状态（置灰），与下面的操作区用分隔线分组
        let status = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        status.isEnabled = false

        let nextSwitch = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        nextSwitch.isEnabled = false

        let quick = menu.addItem(
            withTitle: "",
            action: #selector(quickToggleAppearance(_:)),
            keyEquivalent: ""
        )

        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ThemeSwitch", action: #selector(quit(_:)), keyEquivalent: "q")

        item.menu = menu

        statusItem = item
        statusMenuItem = status
        nextSwitchMenuItem = nextSwitch
        quickToggleMenuItem = quick
    }

    /// 状态栏图标：优先 SF Symbol（模板图像，自动跟随菜单栏深浅色）；
    /// 取不到时退化成文字，保证状态栏始终有可读的状态指示且不会崩。
    /// 开启时钟时在图标后附加时钟文字（等宽数字字体，避免数字宽度抖动）。
    private func setStatusIcon(dark: Bool, clockText: String?) {
        guard let button = statusItem?.button else { return }
        if let clockText, !clockText.isEmpty {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else {
            button.font = nil
        }
        if let image = NSImage(
            systemSymbolName: dark ? "moon.fill" : "sun.max",
            accessibilityDescription: dark ? "深色模式" : "浅色模式"
        ) {
            image.isTemplate = true
            button.image = image
            button.title = clockText ?? ""
            button.imagePosition = clockText == nil ? .imageOnly : .imageLeft
        } else {
            button.image = nil
            let fallback = dark ? "深" : "浅"
            button.title = clockText.map { "\(fallback) \($0)" } ?? fallback
        }
    }

    // MARK: - 定时切换

    private func startPollingTimer() {
        let pollTimer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            self?.applyScheduledAppearance()
        }
        RunLoop.main.add(pollTimer, forMode: .common)
        timer = pollTimer
    }

    /// 菜单栏时钟：1 秒一跳，但只在格式化文本变化时才写 button.title，避免无谓重绘。
    /// 与 8 秒的调度轮询 Timer 并存，各自只做自己的事；两者都在 applicationWillTerminate 清理。
    private func startClockTimer() {
        let clockTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateClockDisplay()
        }
        RunLoop.main.add(clockTimer, forMode: .common)
        self.clockTimer = clockTimer
    }

    @objc private func updateClockDisplay() {
        guard let button = statusItem?.button, currentConfig.showClock else { return }
        let text = ThemeConfig.clockString(for: Date(), in: currentConfig.resolvedClockTimeZone)
        if button.title != text {
            button.title = text
        }
    }

    @objc private func applyScheduledAppearance() {
        let config = ThemeConfig.load()

        if config.enabled {
            let shouldBeDark = Schedule.shouldBeDark(config)
            if shouldBeDark != AppearanceController.isDark {
                AppearanceController.setDark(shouldBeDark)
            }
        }

        refreshUI(config: config)
    }

    private func refreshUI(config: ThemeConfig) {
        currentConfig = config
        let isDark = AppearanceController.isDark
        // 时钟只受 showClock 控制，与 enabled（自动切换）无关
        let clockText: String? = config.showClock
            ? ThemeConfig.clockString(for: Date(), in: config.resolvedClockTimeZone)
            : nil
        setStatusIcon(dark: isDark, clockText: clockText)

        statusMenuItem?.title =
            "当前：\(isDark ? "深色模式" : "浅色模式") · 自动切换已\(config.enabled ? "启用" : "停用")"
        nextSwitchMenuItem?.title = Self.nextSwitchDescription(for: config)

        quickToggleMenuItem?.title = isDark ? "立即切换为浅色" : "立即切换为深色"
        quickToggleMenuItem?.isEnabled = true
    }

    // MARK: - 菜单文案

    /// 「下次切换」的自然语言描述：把配置时区的切换时刻换算成参考时区的当地时间，
    /// 用户看到的就是自己关心的那座城市的钟，例如「下次：明天 北京 19:00 转为深色」。
    /// 参考时区默认跟随系统（referenceTimeZoneID == "system"），用户可指定其他时区。
    private static func nextSwitchDescription(for config: ThemeConfig) -> String {
        guard config.enabled else {
            return "自动切换已停用，不会定时切换"
        }
        guard let next = Schedule.nextSwitch(config) else {
            return "深浅色时间相同，不会自动切换"
        }
        let referenceZone = config.resolvedReferenceTimeZone
        let day = dayDescription(for: next.date, in: referenceZone)
        let dayPrefix = day.isEmpty ? "" : "\(day) "
        return "下次：\(dayPrefix)\(shortTimeZoneName(referenceZone)) "
            + "\(string(from: next.date, in: referenceZone)) 转为\(next.toDark ? "深色" : "浅色")"
    }

    private static func string(from date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 切换时刻距 date 一定在 24 小时之内，参考时区下只会落在今天或明天；
    /// 万一因 DST 出现更长间隔，退回具体日期。
    private static func dayDescription(
        for date: Date,
        in timeZone: TimeZone,
        relativeTo now: Date = Date()
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            return ""
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow)
        {
            return "明天"
        }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    /// 常见时区的中文城市名；表里没有时退回 IANA 标识符最后一段
    /// （如 Asia/Kathmandu → Kathmandu）。
    private static let timeZoneCityNames: [String: String] = [
        "UTC": "UTC", "Etc/UTC": "UTC", "GMT": "GMT", "Etc/GMT": "GMT",
        "Asia/Shanghai": "北京",
        "Asia/Hong_Kong": "香港",
        "Asia/Macau": "澳门",
        "Asia/Taipei": "台北",
        "Asia/Tokyo": "东京",
        "Asia/Seoul": "首尔",
        "Asia/Singapore": "新加坡",
        "Asia/Kuala_Lumpur": "吉隆坡",
        "Asia/Bangkok": "曼谷",
        "Asia/Jakarta": "雅加达",
        "Asia/Manila": "马尼拉",
        "Asia/Ho_Chi_Minh": "胡志明市",
        "Asia/Kolkata": "印度", "Asia/Calcutta": "印度",
        "Asia/Kathmandu": "加德满都",
        "Asia/Dhaka": "达卡",
        "Asia/Karachi": "卡拉奇",
        "Asia/Dubai": "迪拜",
        "Asia/Tehran": "德黑兰",
        "Asia/Jerusalem": "耶路撒冷",
        "Asia/Riyadh": "利雅得",
        "Australia/Perth": "珀斯",
        "Australia/Brisbane": "布里斯班",
        "Australia/Sydney": "悉尼",
        "Australia/Melbourne": "墨尔本",
        "Pacific/Auckland": "奥克兰",
        "Pacific/Honolulu": "檀香山",
        "America/Anchorage": "安克雷奇",
        "America/Vancouver": "温哥华",
        "America/Los_Angeles": "洛杉矶",
        "America/Denver": "丹佛",
        "America/Phoenix": "凤凰城",
        "America/Chicago": "芝加哥",
        "America/Mexico_City": "墨西哥城",
        "America/New_York": "纽约",
        "America/Toronto": "多伦多",
        "America/Bogota": "波哥大",
        "America/Lima": "利马",
        "America/Santiago": "圣地亚哥",
        "America/Sao_Paulo": "圣保罗",
        "America/Buenos_Aires": "布宜诺斯艾利斯",
        "Europe/London": "伦敦",
        "Europe/Dublin": "都柏林",
        "Europe/Lisbon": "里斯本",
        "Europe/Madrid": "马德里",
        "Europe/Paris": "巴黎",
        "Europe/Brussels": "布鲁塞尔",
        "Europe/Amsterdam": "阿姆斯特丹",
        "Europe/Berlin": "柏林",
        "Europe/Zurich": "苏黎世",
        "Europe/Vienna": "维也纳",
        "Europe/Rome": "罗马",
        "Europe/Stockholm": "斯德哥尔摩",
        "Europe/Oslo": "奥斯陆",
        "Europe/Copenhagen": "哥本哈根",
        "Europe/Helsinki": "赫尔辛基",
        "Europe/Warsaw": "华沙",
        "Europe/Prague": "布拉格",
        "Europe/Budapest": "布达佩斯",
        "Europe/Athens": "雅典",
        "Europe/Bucharest": "布加勒斯特",
        "Europe/Istanbul": "伊斯坦布尔",
        "Europe/Kyiv": "基辅", "Europe/Kiev": "基辅",
        "Europe/Moscow": "莫斯科",
        "Africa/Casablanca": "卡萨布兰卡",
        "Africa/Lagos": "拉各斯",
        "Africa/Cairo": "开罗",
        "Africa/Johannesburg": "约翰内斯堡",
        "Africa/Nairobi": "内罗毕"
    ]

    private static func shortTimeZoneName(_ timeZone: TimeZone) -> String {
        if let known = timeZoneCityNames[timeZone.identifier] {
            return known
        }
        let last = timeZone.identifier.split(separator: "/").last.map(String.init)
            ?? timeZone.identifier
        return last.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - 菜单动作

    @objc private func quickToggleAppearance(_ sender: Any?) {
        AppearanceController.setDark(!AppearanceController.isDark)
        refreshUI(config: ThemeConfig.load())
    }

    @objc private func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow()
        }
        settingsWindow?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func handleSystemWake(_ notification: Notification) {
        applyScheduledAppearance()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        applyScheduledAppearance()
    }
}

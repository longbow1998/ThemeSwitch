import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    /// 菜单栏时钟的 1 秒定时器，与上面 8 秒的调度轮询 Timer 并存，互不干扰
    private var clockTimer: Timer?
    private var settingsWindow: SettingsWindow?
    private var statusMenuItem: NSMenuItem?
    private var overrideNoticeMenuItem: NSMenuItem?
    private var nextSwitchMenuItem: NSMenuItem?
    private var quickToggleMenuItem: NSMenuItem?
    private var resumeAutomationMenuItem: NSMenuItem?
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

        // 信息区：只读状态（置灰），与下面的操作区用分隔线分组。
        // 「暂停说明行」只在手动覆盖生效时出现，平时隐藏，菜单保持原来的样子。
        let status = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        status.isEnabled = false

        let overrideNotice = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        overrideNotice.isEnabled = false
        overrideNotice.isHidden = true

        let nextSwitch = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        nextSwitch.isEnabled = false

        let quick = menu.addItem(
            withTitle: "",
            action: #selector(quickToggleAppearance(_:)),
            keyEquivalent: ""
        )

        // 与「立即切换」同组，也只在覆盖生效时出现
        let resume = menu.addItem(
            withTitle: "恢复自动切换",
            action: #selector(resumeAutomation(_:)),
            keyEquivalent: ""
        )
        resume.isHidden = true

        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ThemeSwitch", action: #selector(quit(_:)), keyEquivalent: "q")

        item.menu = menu

        statusItem = item
        statusMenuItem = status
        overrideNoticeMenuItem = overrideNotice
        nextSwitchMenuItem = nextSwitch
        quickToggleMenuItem = quick
        resumeAutomationMenuItem = resume
    }

    /// 状态栏图标：优先 SF Symbol（模板图像，自动跟随菜单栏深浅色）；
    /// 取不到时退化成文字，保证状态栏始终有可读的状态指示且不会崩。
    /// 开启时钟时在图标后附加时钟文字（等宽数字字体，避免数字宽度抖动）。
    private func setStatusIcon(dark: Bool, clockText: String?, paused: Bool) {
        guard let button = statusItem?.button else { return }
        if let clockText, !clockText.isEmpty {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else {
            button.font = nil
        }
        if let image = Self.statusBarIcon(dark: dark, paused: paused) {
            button.image = image
            button.title = clockText ?? ""
            button.imagePosition = clockText == nil ? .imageOnly : .imageLeft
        } else {
            button.image = nil
            let fallback = dark ? "深" : "浅"
            button.title = clockText.map { "\(fallback) \($0)" } ?? fallback
        }
    }

    /// 太阳 / 月亮的模板图标；`paused` 为真时在右下角叠一个暂停角标，
    /// 让用户不点开菜单也能看出自动切换正被手动覆盖暂停。
    /// 取不到 SF Symbol 时返回 nil，由 setStatusIcon 退化成原来的纯文字。
    static func statusBarIcon(dark: Bool, paused: Bool) -> NSImage? {
        let symbolName = dark ? "moon.fill" : "sun.max"
        let description = dark ? "深色模式" : "浅色模式"
        // 不给底图加 symbol configuration：尺寸与改动前完全一致（sun.max 16pt、moon.fill 15pt）
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) else {
            return nil
        }
        base.isTemplate = true

        guard paused,
              let badge = NSImage(
                  systemSymbolName: "pause.circle.fill",
                  accessibilityDescription: "自动切换已暂停"
              )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        else {
            return base
        }
        badge.isTemplate = true

        let canvas = NSSize(width: 16, height: 16)
        let badgeRect = NSRect(x: canvas.width - 8, y: 0, width: 8, height: 8)
        func draw(_ image: NSImage, in rect: NSRect) {
            let size = image.size
            guard size.width > 0, size.height > 0 else { return }
            // 等比缩放、居中，且只缩不放：底图保持原本大小，角标缩小后贴角
            let scale = min(1, min(rect.width / size.width, rect.height / size.height))
            let target = NSSize(width: size.width * scale, height: size.height * scale)
            image.draw(
                in: NSRect(
                    x: rect.midX - target.width / 2,
                    y: rect.midY - target.height / 2,
                    width: target.width,
                    height: target.height
                )
            )
        }

        let image = NSImage(size: canvas, flipped: false) { _ in
            draw(base, in: NSRect(origin: .zero, size: canvas))
            // 模板图只按 alpha 上色，底图和角标的实心圆叠在一起会糊成一团。
            // 先把角标区域挖空（连同一条细缝），pause.circle.fill 里那两道竖杠保持透明，
            // 暂停的形状才读得出来。
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -0.75, dy: -0.75)).fill()
            NSGraphicsContext.restoreGraphicsState()
            draw(badge, in: badgeRect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(description)（自动切换已暂停）"
        return image
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

        // 手动覆盖窗口内 scheduledTarget 返回 nil，这里就什么都不做（用户的临时选择优先）；
        // 窗口到点自动失效，下面这行重新按计划收敛 —— 这就是休眠 / 重启 / 改系统时钟的自愈来源。
        if let target = ManualOverride.scheduledTarget(config),
           target != AppearanceController.isDark {
            AppearanceController.setDark(target)
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
        // 自动切换停用时无所谓「暂停」，覆盖状态只在启用时对外呈现
        let overrideDeadline = config.enabled ? ManualOverride.deadline : nil
        setStatusIcon(dark: isDark, clockText: clockText, paused: overrideDeadline != nil)

        statusMenuItem?.title = Self.statusTitle(
            isDark: isDark,
            config: config,
            overrideDeadline: overrideDeadline
        )
        if let overrideDeadline {
            overrideNoticeMenuItem?.title = Self.overrideNoticeTitle(deadline: overrideDeadline, config: config)
        }
        overrideNoticeMenuItem?.isHidden = overrideDeadline == nil
        nextSwitchMenuItem?.title = Self.nextSwitchDescription(for: config)

        quickToggleMenuItem?.title = isDark ? "立即切换为浅色" : "立即切换为深色"
        quickToggleMenuItem?.isEnabled = true
        resumeAutomationMenuItem?.isHidden = overrideDeadline == nil
    }

    // MARK: - 菜单文案

    /// 首行状态：覆盖期间必须写明「暂停中」以及恢复时刻（参考时区的当地时间），
    /// 其余情况保持原来的措辞。
    static func statusTitle(isDark: Bool, config: ThemeConfig, overrideDeadline: Date?) -> String {
        let appearance = isDark ? "深色模式" : "浅色模式"
        guard let overrideDeadline else {
            return "当前：\(appearance) · 自动切换已\(config.enabled ? "启用" : "停用")"
        }
        return "当前：\(appearance) · 自动切换已暂停（至 \(momentDescription(overrideDeadline, in: config)) 恢复）"
    }

    /// 说明行：让用户明白暂停是自己刚才手动切换造成的，以及到点会自动恢复、无需操作。
    static func overrideNoticeTitle(deadline: Date, config: ThemeConfig) -> String {
        "手动切换后临时暂停，到 \(momentDescription(deadline, in: config)) 会自动恢复按计划切换，无需手动操作"
    }

    /// 覆盖窗口的恢复时刻：与「下次切换」同一套参考时区口径，例如「明天 05:00」。
    static func momentDescription(_ date: Date, in config: ThemeConfig) -> String {
        let referenceZone = config.resolvedReferenceTimeZone
        let day = dayDescription(for: date, in: referenceZone)
        let dayPrefix = day.isEmpty ? "" : "\(day) "
        return "\(dayPrefix)\(string(from: date, in: referenceZone))"
    }

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

    /// 「立即切换为深色 / 浅色」：照旧切换外观，同时把自动切换暂停到下一个计划切换时刻。
    /// 这样手动选择立刻生效且不会被 8 秒后的收敛逻辑拉回去，而到点后调度照常接管。
    @objc private func quickToggleAppearance(_ sender: Any?) {
        let config = ThemeConfig.load()
        AppearanceController.setDark(!AppearanceController.isDark)
        ManualOverride.activateForManualToggle(config)
        refreshUI(config: config)
    }

    /// 「恢复自动切换」：清掉覆盖并立刻收敛回计划状态（不必等下一个切换时刻）。
    @objc private func resumeAutomation(_ sender: Any?) {
        ManualOverride.clear()
        applyScheduledAppearance()
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

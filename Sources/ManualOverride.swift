import Foundation

/// 手动切换的「覆盖窗口」。
///
/// 用户在菜单里手动切换深浅色后，从那一刻起到「下一次计划切换时刻」为止，
/// 收敛逻辑（`AppDelegate.applyScheduledAppearance`）完全不动外观；到点后覆盖自动失效，
/// 重新按 `Schedule` 的计划收敛。
///
/// 覆盖只是「一个到期时间戳 + 窗口内跳过收敛」，不是把切换改成一次性触发：
/// 窗口到期后调度仍然是收敛式的，所以休眠、重启、改系统时钟跨过切换时刻之后依然能自愈。
enum ManualOverride {
    /// 到期时刻在 UserDefaults.standard 里的键（写入 ~/Library/Preferences/com.themeswitch.app.plist）。
    static let deadlineKey = "ThemeSwitch.manualOverrideDeadline.v1"

    /// 覆盖状态的存储域。生产固定用 UserDefaults.standard；
    /// 验证程序可以换成独立 suite，避免污染真实配置。
    static var store: UserDefaults = .standard

    /// 当前的覆盖截止时间；nil 表示没有覆盖或已过期
    static var deadline: Date? { deadline(at: Date()) }

    /// 是否有生效中的覆盖
    static var isActive: Bool { isActive(at: Date()) }

    /// 设置覆盖，截止到指定时刻
    static func activate(until deadline: Date) {
        store.set(deadline, forKey: deadlineKey)
    }

    /// 立即清除覆盖
    static func clear() {
        store.removeObject(forKey: deadlineKey)
    }

    /// 到期即视为没有覆盖，顺手清掉存的值，避免过期时间戳一直留在偏好文件里
    static func deadline(at now: Date) -> Date? {
        guard let stored = store.object(forKey: deadlineKey) as? Date else { return nil }
        guard stored > now else {
            clear()
            return nil
        }
        return stored
    }

    static func isActive(at now: Date) -> Bool {
        deadline(at: now) != nil
    }

    /// 手动切换后的固定动作：把覆盖窗口开到「下一次计划切换时刻」，返回该时刻。
    ///
    /// - 自动切换停用：本来就没有收敛要暂停，不开窗口
    /// - 两个时间点相同（`Schedule.nextSwitch` 返回 nil）：没有「下一次」可言，直接切就行，也不开窗口
    @discardableResult
    static func activateForManualToggle(_ config: ThemeConfig, from now: Date = Date()) -> Date? {
        guard config.enabled, let next = Schedule.nextSwitch(config, from: now)?.date else {
            return nil
        }
        activate(until: next)
        return next
    }

    /// 这次收敛应该把系统外观设成什么？true = 暗色，nil = 这次什么都别做。
    ///
    /// 覆盖窗口生效中或自动切换停用时返回 nil；其余情况完全交给 `Schedule` 的计划值。
    /// applyScheduledAppearance 的唯一判断入口就是这里，收敛语义因此保持不变。
    static func scheduledTarget(_ config: ThemeConfig, at now: Date = Date()) -> Bool? {
        guard config.enabled, !isActive(at: now) else { return nil }
        return Schedule.shouldBeDark(config, at: now)
    }
}

import Foundation

enum Schedule {
    /// 在 config 指定的时区里，date 这一刻应该显示暗色吗？
    ///
    /// - 先把 date 换算到 config.resolvedTimeZone 的当地「时分」再比较；
    /// - dark < light：当天 [dark, light) 区间为暗色；
    /// - dark > light（跨午夜，如 19:00 转暗、07:00 转亮）：时分 >= dark 或 < light 为暗色；
    /// - dark == light：暗色区间 [dark, light) 为空，视为 24 小时恒为亮色，不发生切换。
    static func shouldBeDark(_ config: ThemeConfig, at date: Date = Date()) -> Bool {
        let dark = minuteOfDay(hour: config.darkHour, minute: config.darkMinute)
        let light = minuteOfDay(hour: config.lightHour, minute: config.lightMinute)
        guard dark != light else {
            return false
        }
        let now = minuteOfDay(in: config.resolvedTimeZone, at: date)
        if dark < light {
            return now >= dark && now < light
        }
        return now >= dark || now < light
    }

    /// 从 date 起的下一次切换：返回 (切换时刻, 是否切到暗色)；永不切换时返回 nil
    static func nextSwitch(_ config: ThemeConfig, from date: Date = Date()) -> (date: Date, toDark: Bool)? {
        let dark = minuteOfDay(hour: config.darkHour, minute: config.darkMinute)
        let light = minuteOfDay(hour: config.lightHour, minute: config.lightMinute)
        guard dark != light else {
            return nil
        }
        let calendar = calendar(for: config.resolvedTimeZone)
        // 每天只有两个切换时刻：dark 时刻切到暗色，light 时刻切到亮色。
        // 取两者中在 date 之后的先到者即可。
        let nextDark = nextOccurrence(hour: config.darkHour, minute: config.darkMinute, after: date, in: calendar)
        let nextLight = nextOccurrence(hour: config.lightHour, minute: config.lightMinute, after: date, in: calendar)
        return nextDark <= nextLight ? (nextDark, true) : (nextLight, false)
    }

    private static func calendar(for timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func minuteOfDay(hour: Int, minute: Int) -> Int {
        hour * 60 + minute
    }

    /// date 在指定时区里的当地「时分」折合的当日分钟数。
    private static func minuteOfDay(in timeZone: TimeZone, at date: Date) -> Int {
        let components = calendar(for: timeZone).dateComponents([.hour, .minute], from: date)
        return minuteOfDay(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }

    /// date 之后（不含恰好等于 date 的那一刻）在指定时区里的下一个 hour:minute 时刻。
    /// 今天的该时刻还没过就取今天，否则顺延到明天同一时刻（跨 DST 时保持挂钟时间）。
    private static func nextOccurrence(hour: Int, minute: Int, after date: Date, in calendar: Calendar) -> Date {
        let today = calendar.dateComponents([.year, .month, .day], from: date)
        if let todayAtTime = dateAt(on: today, hour: hour, minute: minute, in: calendar), todayAtTime > date {
            return todayAtTime
        }
        if let todayAtTime = dateAt(on: today, hour: hour, minute: minute, in: calendar),
           let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayAtTime)
        {
            return tomorrow
        }
        return calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
    }

    private static func dateAt(on day: DateComponents, hour: Int, minute: Int, in calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.year = day.year
        components.month = day.month
        components.day = day.day
        components.hour = hour
        components.minute = minute
        components.second = 0
        components.nanosecond = 0
        return calendar.date(from: components)
    }
}

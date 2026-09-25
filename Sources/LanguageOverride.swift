import Foundation

/// App 内界面语言覆盖：让用户在设置里选界面语言，而不是只能跟随系统。
///
/// 这不是 Xcode 工程（纯 `swiftc` + 手工组装 bundle），没有 Xcode 的「App 语言」基础设施，
/// 所以要在运行时无视系统语言切换界面语言，需要两条路一起走：
///
/// 1. **AppKit 侧（本文件）**：交换 `Bundle.main` 的 `localizedString(forKey:value:table:)`。
///    用户选了具体语言时改从对应的 `<lang>.lproj` 子 bundle 取值，选「跟随系统」时走原实现，
///    于是 `NSLocalizedString`（菜单、窗口标题、弹窗、登录项错误……）全都跟着切换。
/// 2. **SwiftUI 侧（见 SettingsWindow）**：给设置窗口根视图挂 `.environment(\.locale, …)`，
///    让 `LocalizedStringKey`（`Text("key")`）按同一语言查表。
///
/// 两边取的都是 `AppLanguage`，因此不会出现一半中文一半英文。
///
/// 交换的是类实现（Swift 里 `Bundle` 就是 `NSBundle`），进程里所有 bundle 都会经过交换后的实现，
/// 所以用 `self === Bundle.main` 的守卫把实际影响限制在主 bundle 内 ——
/// 否则 SwiftUI / AppKit 查自己 framework bundle 里的文案也会被劫持。
enum LanguageOverride {

    // MARK: - 取值

    /// 配置里表示「跟随系统语言」的哨兵值
    static let systemValue = "system"
    static let englishIdentifier = "en"
    static let simplifiedChineseIdentifier = "zh-Hans"

    /// 可显式选择的语言（不含「跟随系统」），顺序与设置窗口里的选项一致
    static let selectableIdentifiers = [englishIdentifier, simplifiedChineseIdentifier]

    /// 把配置里的原始值规范化成合法选择：空值、非法值、认不出的标识一律当「跟随系统」。
    /// 配置是用户可手改的 JSON，这里不信任它。
    static func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return selectableIdentifiers.contains(trimmed) ? trimmed : systemValue
    }

    // MARK: - 状态

    /// 用户的选择（已规范化）
    private static var selection = systemValue
    /// 覆盖生效时的语言标识；「跟随系统」或资源缺失时为 nil
    private static var overriddenIdentifier: String?
    /// 覆盖生效时用来查表的 `<lang>.lproj` 子 bundle
    private static var overrideBundle: Bundle?
    private static var installed = false

    // MARK: - 应用选择

    /// 应用配置里的语言选择：启动时、以及每次配置变更后调用。
    /// 可重复调用，值没变时直接返回（不会反复建 bundle）。
    /// 只在主线程调用（安装方法交换、改静态状态都不加锁）。
    static func apply(_ raw: String) {
        installSwizzleIfNeeded()
        let next = normalized(raw)
        guard next != selection else { return }
        selection = next
        guard next != systemValue,
              let path = Bundle.main.path(forResource: next, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            // 「跟随系统」，或 <lang>.lproj 取不到：整体退回系统语言。
            // 只换文案不换格式化语言会得到半中半英的界面，所以这里把覆盖彻底关掉，
            // AppLanguage 也会跟着回到系统判定 —— 宁可不生效，也不混语言。
            overriddenIdentifier = nil
            overrideBundle = nil
            return
        }
        overriddenIdentifier = next
        overrideBundle = bundle
    }

    // MARK: - 当前生效的语言

    /// 当前生效的界面语言标识（"en" / "zh-Hans"）：优先用户显式选择，没选时看系统
    static var effectiveIdentifier: String {
        overriddenIdentifier ?? systemIdentifier
    }

    /// 系统语言的判定：bundle 支持的本地化里排第一的那个，且必须真的有对应的 .lproj。
    /// 本 App 只声明了 en 与 zh-Hans，因此繁体中文等其它系统语言都会落到 en。
    ///
    /// 为什么要确认资源存在：安装损坏（Info.plist 声明了 zh-Hans 但 .lproj 被删）时
    /// preferredLocalizations 仍会报出 zh-Hans，而文案查表已经回退到英文 ——
    /// 于是会出现「英文模式串 + 中文 locale」这种半中半英。这里确认过再采用，否则退回英文。
    /// 结果只取决于 bundle 与系统设置，进程内不会变，所以算一次缓存起来（时钟每秒都要读它）。
    static var systemIdentifier: String { cachedSystemIdentifier }

    private static let cachedSystemIdentifier: String = {
        let preferred = Bundle.main.preferredLocalizations.first ?? englishIdentifier
        return Bundle.main.path(forResource: preferred, ofType: "lproj") != nil
            ? preferred
            : englishIdentifier
    }()

    // MARK: - 交换 Bundle 的本地化查找

    /// 覆盖语言下的查表结果；没有覆盖、或该 key 在覆盖语言里缺失时返回 nil，由调用方退回原实现。
    fileprivate static func overriddenString(forKey key: String, table tableName: String?) -> String? {
        guard let overrideBundle else { return nil }
        let localized = overrideBundle.localizedString(forKey: key, value: nil, table: tableName)
        // value 传 nil 时查不到会原样返回 key，据此判断「覆盖语言里没有这个 key」。
        // 两套 .strings 的 key 强制对齐（见 README），真缺了也宁可回退到系统语言，
        // 好过把 key 本身显示给用户。
        return localized == key ? nil : localized
    }

    private static func installSwizzleIfNeeded() {
        guard !installed else { return }
        installed = true
        let original = #selector(Bundle.localizedString(forKey:value:table:))
        let replacement = #selector(Bundle.ts_localizedString(forKey:value:table:))
        guard let originalMethod = class_getInstanceMethod(Bundle.self, original),
              let replacementMethod = class_getInstanceMethod(Bundle.self, replacement)
        else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }
}

extension Bundle {
    /// 交换后的实现：`self` 是主 bundle 且用户选了具体语言时改从 `<lang>.lproj` 取值，
    /// 其余情况（其它 bundle、跟随系统、覆盖语言里缺这个 key）一律走原实现。
    ///
    /// 下面这行看着像递归，其实是交换后的「原实现」：`method_exchangeImplementations` 之后，
    /// `ts_localizedString…` 这个名字已经指向原来的方法，这是方法交换的固定写法。
    @objc fileprivate func ts_localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if self === Bundle.main, let overridden = LanguageOverride.overriddenString(forKey: key, table: tableName) {
            return overridden
        }
        return ts_localizedString(forKey: key, value: value, table: tableName)
    }
}

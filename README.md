# ThemeSwitch

一个 macOS 菜单栏小工具：**按你指定的时区、在你指定的两个时间点自动切换系统深浅色**，并可选地在菜单栏显示指定时区的日期 / 星期 / 时间。

## 为什么需要它

macOS 自带的「外观 → 自动」是**按系统时区的日出日落**切换的。这在正常情况下够用，但有两种场景会出问题：

- **系统时区与真实所在地不一致**（例如为了网络环境把系统时区设成海外，但人在国内）——自带的自动切换会在"错误的"日出日落时变暗
- **需要固定的作息时间**——比如希望每天 19:00 转暗、05:00 转亮，而不是跟着季节变化的日出日落

ThemeSwitch 完全独立于系统时区工作：它用你自己选定的时区来判断，因此不受系统时区设置影响。

## 功能

- 自选时区 + 两个时间点，自动切换深浅色
- 可选**菜单栏时钟**：在图标后显示指定时区的「日期 + 星期 + 24 小时制时间」
- 设置窗口带**时区换算提示**：把当前设定换算成参考时区的当地时间，一眼看懂对应关系
- 菜单栏菜单显示当前状态与下次切换时间（同样按参考时区换算）
- **手动切换会暂停自动切换**：点「立即切换为深色 / 浅色」后，直到下一个计划切换时刻都不再自动干预，
  菜单里能看到暂停状态、也能一键恢复自动切换
- 可配置**登录自启**（优先用系统的 `SMAppService`，未签名场景自动回退到 LaunchAgent）
- **单实例保护**：重复启动不会在菜单栏出现多个图标
- **界面中英双语**：系统语言是中文时显示简体中文，其余一律英文（默认语言 `en`）；
  菜单、设置窗口、弹窗与错误提示都查同一套 `Localizable.strings`，
  菜单栏时钟的日期格式、星期名与时区显示名也跟着界面语言走
- 纯菜单栏（无 Dock 图标），无第三方依赖

## 系统要求

- macOS 13.0 或更高
- 构建需要 Xcode Command Line Tools（`xcode-select --install`）

## 安装

### 从源码构建

```bash
git clone https://github.com/longbow1998/ThemeSwitch.git
cd ThemeSwitch
./install.sh          # 构建并安装到 /Applications
./install.sh --launch-at-login   # 额外设置登录自启
```

卸载：

```bash
./uninstall.sh            # 保留配置
./uninstall.sh --purge    # 同时清除配置
```

### 从 Release 下载

到 [Releases](https://github.com/longbow1998/ThemeSwitch/releases) 下载 `ThemeSwitch.zip`，解压后把 `ThemeSwitch.app` 拖进 `/Applications`。

> **首次打开会被 Gatekeeper 拦下**——本项目使用 ad-hoc 签名（没有 Apple 开发者证书），
> 下载后系统会提示"无法验证开发者"。解决办法是**右键点 App → 打开**，或执行：
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/ThemeSwitch.app
> ```

**注意**：Release 里的二进制目前是 **Apple Silicon（arm64）** 构建，Intel Mac 请从源码构建。

### 仅构建

```bash
./build.sh
# 产物：build/ThemeSwitch.app
```

## 使用

1. 启动后菜单栏出现一个图标（☀️ / 🌙 随当前深浅色变化）
2. 点图标 → **设置…**
3. 在设置里配置：
   - **时区**：判断时段所用的时区
   - **参考时区**：换算提示与菜单「下次切换」所参照的时区（建议设成你自己的真实时区）
   - **切换时间**：转暗 / 转亮两个时间点
   - **菜单栏时钟**（可选）：开启后菜单栏显示日期 / 星期 / 时间

### 举个例子

人在国内（UTC+8），但系统时区设成了 `America/Los_Angeles`（UTC-7），希望北京时间 19:00 转暗、05:00 转亮：

| 设置项 | 值 |
| --- | --- |
| 时区 | `America/Los_Angeles` |
| 转暗 | `04:00` |
| 转亮 | `14:00` |
| 参考时区 | `Asia/Shanghai` |
| 菜单栏时钟 | 开启，时区 `Asia/Shanghai` |

设置窗口会实时显示换算结果，确认 `04:00 = 北京 19:00`、`14:00 = 北京 05:00`。

## 文件结构

```
Sources/
  main.swift                 程序入口
  Config.swift               配置模型与持久化（UserDefaults）、时钟文案格式化、当前界面语言
  Schedule.swift             时区感知的时段计算
  AppearanceController.swift 读写系统外观
  ManualOverride.swift       手动切换的覆盖窗口（暂停自动切换的状态）
  AppDelegate.swift          菜单栏图标、菜单、定时器
  SettingsWindow.swift       设置窗口（SwiftUI）
Resources/
  en.lproj/Localizable.strings      英文文案（默认语言）
  zh-Hans.lproj/Localizable.strings 简体中文文案（key 与 en 完全一致）
Info.plist                   App bundle 信息（CFBundleDevelopmentRegion=en、CFBundleLocalizations）
build.sh                     构建脚本（编译 + 拷贝 .lproj + ad-hoc 签名）
install.sh / uninstall.sh    安装与卸载
```

## 工作原理

- **时段判断**：把当前时刻换算到配置时区，与两个时间点比较（支持跨午夜区间）
- **切换外观**：调用
  ```
  osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to <true|false>'
  ```
  首次使用可能需要在「系统设置 → 隐私与安全性 → 自动化」里允许本 App 控制 System Events
- **配置存储**：`~/Library/Preferences/com.themeswitch.app.plist`（UserDefaults）
- **无网络访问**，所有逻辑本地完成

### 手动切换与自动切换的关系

自动切换是**收敛式**的：App 每 8 秒（以及每次系统唤醒时）算一遍「按计划现在该是什么颜色」，
发现和当前状态不一致就拉回去。好处是休眠、重启、改系统时钟之后都能自愈，
代价是**手动切换会被立刻拉回**。所以引入了一个「手动覆盖窗口」：

- 在菜单里点「立即切换为深色 / 浅色」时，除了切换外观，还会记下一个**到期时间戳**：
  下一次计划切换时刻（用 `Schedule.nextSwitch` 算，记在 UserDefaults 里，与配置分开存）
- 在这个时刻之前，App 完全不动外观 —— 手动选择被尊重
  - 例：计划 19:00 转暗 / 05:00 转亮，你 22:00 手动切成亮色 → 22:00 到次日 05:00 一直保持亮色
  - 次日 05:00 计划目标本来就是亮色，无事发生；19:00 计划目标变暗 → 自动切暗，回归
- 到点后覆盖自动失效，重新按计划收敛，**不需要任何操作**
- 覆盖期间菜单首行写明「自动切换已暂停（至 05:00 恢复）」、菜单栏图标叠一个暂停角标，
  菜单里还有一项「恢复自动切换」可以立刻结束暂停

关键点是覆盖只是「一个到期时间戳 + 窗口内跳过收敛」，**不是把手动切换变成一次性触发**：
调度的收敛语义没变，所以休眠或关机跨过切换时刻之后依然能自愈
（比如合盖跨过 05:00，唤醒后 8 秒内就按计划对齐）。
两个时间点相同时没有「下一次计划切换」，此时不进入暂停，直接切就行。

## 已知限制

- 切换依赖 `osascript`，因此需要「自动化」权限；未授权时切换会静默失败（菜单里的「立即切换」同样受影响）
- 时段精度为轮询间隔（约 8 秒），切换时刻可能有数秒误差
- 时区显示名分语言：中文界面用内置的常用时区中文名映射表（少见时区取系统给出的中文名），
  英文界面直接用 IANA 标识符最后一段（`America/Los_Angeles` → `Los Angeles`）；
  两者都保留兜底，认不出的标识符原样显示、不崩
- 手动切换只在自动切换**启用**时进入暂停状态；停用时本来就不会自动干预，不存在暂停一说

## 开源许可

[MIT](LICENSE)

---

# English

A tiny macOS menu bar utility that **switches the system light/dark appearance at two times you choose, evaluated in a timezone you choose**, and can optionally show a clock (date, weekday, 24-hour time) of any timezone next to its menu bar icon.

Unlike the built-in "Auto" appearance — which follows sunrise/sunset of your **system** timezone — ThemeSwitch is fully independent of it. Useful when your system timezone differs from where you actually live, or when you want a fixed schedule.

Features: configurable timezone and switch times, optional menu bar clock, timezone conversion hints in the settings window, no third-party dependencies.

The interface is bilingual (English / Simplified Chinese). English is the default language (`CFBundleDevelopmentRegion`), so every system language other than Chinese gets the English UI; the clock format, weekday names and time zone names follow the app language as well. Product strings live in `Resources/en.lproj/Localizable.strings` and `Resources/zh-Hans.lproj/Localizable.strings` and are loaded through the standard bundle lookup.

Manually toggling the appearance from the menu pauses the automatic schedule until the next planned switch time (the menu shows the pause state and offers a one-click resume). The schedule itself stays convergent, so sleeping, rebooting, or changing the system clock still self-heals.

Requires macOS 13+. Build with `./build.sh`, install with `./install.sh`.

Licensed under the [MIT License](LICENSE).

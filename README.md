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
- 可配置**登录自启**（优先用系统的 `SMAppService`，未签名场景自动回退到 LaunchAgent）
- **单实例保护**：重复启动不会在菜单栏出现多个图标
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
  Config.swift               配置模型与持久化（UserDefaults）
  Schedule.swift             时区感知的时段计算
  AppearanceController.swift 读写系统外观
  AppDelegate.swift          菜单栏图标、菜单、定时器
  SettingsWindow.swift       设置窗口（SwiftUI）
Info.plist                   App bundle 信息
build.sh                     构建脚本
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

## 已知限制

- 切换依赖 `osascript`，因此需要「自动化」权限；未授权时切换会静默失败（菜单里的「立即切换」同样受影响）
- 时段精度为轮询间隔（约 8 秒），切换时刻可能有数秒误差
- 参考时区与时钟时区使用内置的常用时区中文名映射表，少见的 IANA 时区会回退显示标识符本身

## 开源许可

[MIT](LICENSE)

---

# English

A tiny macOS menu bar utility that **switches the system light/dark appearance at two times you choose, evaluated in a timezone you choose**, and can optionally show a clock (date, weekday, 24-hour time) of any timezone next to its menu bar icon.

Unlike the built-in "Auto" appearance — which follows sunrise/sunset of your **system** timezone — ThemeSwitch is fully independent of it. Useful when your system timezone differs from where you actually live, or when you want a fixed schedule.

Features: configurable timezone and switch times, optional menu bar clock, timezone conversion hints in the settings window, no third-party dependencies.

Requires macOS 13+. Build with `./build.sh`, install with `./install.sh`.

Licensed under the [MIT License](LICENSE).

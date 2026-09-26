# ThemeSwitch

**English** | [简体中文](README.zh-CN.md)

A tiny macOS menu bar utility that **switches the system light/dark appearance at two times you choose, evaluated in a timezone you choose**, and can optionally show a clock (date, weekday, 24-hour time) of any timezone next to its menu bar icon.

## Why this exists

macOS's built-in "Auto" appearance switches at **sunrise/sunset of your system timezone**. That is usually fine, but it breaks in two situations:

- **Your system timezone does not match where you actually live** — for example you set the system timezone to an overseas one for network reasons while you are physically elsewhere. The built-in auto switch then flips at the "wrong" sunrise and sunset.
- **You want a fixed schedule** — e.g. dark at 19:00 and light at 05:00 every day, instead of tracking a sunrise that drifts through the year.

ThemeSwitch works completely independently of the system timezone: it evaluates everything in a timezone *you* pick, so your system timezone setting has no effect on it.

## Features

- Pick a timezone and two times; the appearance switches automatically
- Optional **menu bar clock**: date + weekday + 24-hour time of a timezone you choose, shown after the icon
- **Timezone conversion hints** in the settings window: your chosen times are shown alongside the same moments in a reference timezone you care about
- The menu shows the current state and the next switch time (also converted to the reference timezone)
- **Manual toggling pauses the schedule**: after you pick "Switch to Dark/Light Mode" from the menu, the app leaves the appearance alone until the next planned switch. The menu shows the paused state and offers a one-click resume.
- Configurable **launch at login** (uses the system `SMAppService` API, with an automatic LaunchAgent fallback for unsigned builds)
- **Single-instance guard**: launching it again will not create a second menu bar icon
- **Bilingual UI (English / Simplified Chinese), switchable in-app**: follows the system language by default (Simplified Chinese for Chinese systems, English for everything else — `en` is the development region), and can also be pinned to `English` or `简体中文` in the settings. Once pinned it overrides the system language for the menu, settings window, alerts and the menu bar clock, including date format, weekday names and timezone display names (24-hour in both languages).
- Menu bar only (no Dock icon), no third-party dependencies

## Requirements

- macOS 13.0 or later
- Building requires the Xcode Command Line Tools (`xcode-select --install`)

## Installation

### Build from source

```bash
git clone https://github.com/longbow1998/ThemeSwitch.git
cd ThemeSwitch
./install.sh                     # build and install into /Applications
./install.sh --launch-at-login   # additionally register it as a login item
```

Uninstall:

```bash
./uninstall.sh            # keeps your configuration
./uninstall.sh --purge    # also removes the configuration
```

### Download a release

Each [release](https://github.com/longbow1998/ThemeSwitch/releases) ships three files:

| File | What it is |
| --- | --- |
| `ThemeSwitch.dmg` | **Recommended.** Open it and drag `ThemeSwitch.app` onto the `Applications` shortcut. |
| `ThemeSwitch.zip` | The plain app bundle, for scripted installs. |
| `checksums.txt` | SHA-256 of both files above. |

> **Gatekeeper will block the first launch.** This project is ad-hoc signed (there is no Apple Developer certificate), so macOS reports that the developer cannot be verified. Either **right-click the app → Open**, or run:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/ThemeSwitch.app
> ```

**Note**: the release binary is currently **Apple Silicon (arm64)** only. On an Intel Mac, build from source.

### Build only

```bash
./build.sh
# output: build/ThemeSwitch.app
```

## Usage

1. After launching, an icon appears in the menu bar (☀️ / 🌙 depending on the current appearance)
2. Click it → **Settings…**
3. Configure:
   - **Time zone** — the timezone used to evaluate the two switch times
   - **Reference time zone** — the timezone used for the conversion hints and the menu's "next switch" line (set this to the timezone you actually care about)
   - **Switch times** — when to turn dark and when to turn light
   - **Menu Bar Clock** (optional) — shows date / weekday / time after the icon. The settings window previews the selected timezone live; the preview keeps showing the time even when the clock is turned off (dimmed and labelled "clock is off"), so changing the timezone always gives visible feedback.
   - **Interface language** (optional) — Follow System / English / 简体中文. Takes effect immediately after Save (menu, menu bar clock, alerts, settings window).

### A worked example

You live in UTC+8, but your system timezone is set to `America/Los_Angeles` (UTC−7). You want the appearance to turn dark at 19:00 Beijing time and light at 05:00 Beijing time:

| Setting | Value |
| --- | --- |
| Time zone | `America/Los_Angeles` |
| Switch to dark | `04:00` |
| Switch to light | `14:00` |
| Reference time zone | `Asia/Shanghai` |
| Menu bar clock | on, timezone `Asia/Shanghai` |

The settings window shows the conversion live, so you can confirm `04:00 = 19:00 Beijing` and `14:00 = 05:00 Beijing`.

## Project layout

```
Sources/
  main.swift                 Entry point
  Config.swift               Config model + persistence (UserDefaults), clock formatting, current UI language
  LanguageOverride.swift     Runtime override of the UI language (bundle lookup exchange + language resolution)
  Schedule.swift             Timezone-aware schedule computation
  AppearanceController.swift Reads/writes the system appearance
  ManualOverride.swift       Manual-toggle override window (the paused state)
  AppDelegate.swift          Menu bar icon, menu, timers
  SettingsWindow.swift       Settings window (SwiftUI)
Resources/
  en.lproj/Localizable.strings      English strings (default language)
  zh-Hans.lproj/Localizable.strings Simplified Chinese strings (keys identical to en)
Info.plist                   App bundle metadata (CFBundleDevelopmentRegion=en, CFBundleLocalizations)
build.sh                     Build script (compile + copy .lproj + ad-hoc sign)
install.sh / uninstall.sh    Install and uninstall
```

## How it works

- **Schedule evaluation** — the current moment is converted into the configured timezone and compared against the two times (midnight-crossing ranges supported)
- **Switching the appearance** — calls
  ```
  osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to <true|false>'
  ```
  On first use you may need to allow this app to control System Events under System Settings → Privacy & Security → Automation
- **Configuration storage** — `~/Library/Preferences/com.themeswitch.app.plist` (UserDefaults)
- **UI language** — follows the system by default (`CFBundleLocalizations` only declares `en` / `zh-Hans`, so other system languages such as Traditional Chinese fall back to English). When a specific language is pinned in the settings, the app exchanges `Bundle.main`'s `localizedString(forKey:value:table:)` at runtime so AppKit lookups (`NSLocalizedString`, covering the menu, alerts and window titles) read from the matching `<lang>.lproj` sub-bundle, and sets the corresponding environment `locale` on the SwiftUI settings view (`Text("key")` lookups). Language resolution is centralised in `AppLanguage`, which also drives the clock date format, weekday names and timezone display names. Choosing "Follow System", or a missing `.lproj`, falls back to the system's normal lookup path.
- **No network access** — everything happens locally

### Manual vs. automatic switching

The automatic schedule is **convergent**: every 8 seconds (and on every system wake) the app computes what the appearance *should* be according to the schedule and pulls it back if it differs. That self-heals after sleep, reboot or system clock changes — but it also means a manual toggle would be reverted almost immediately. Hence the **manual override window**:

- Picking "Switch to Dark/Light Mode" from the menu both switches the appearance and records an **expiry timestamp**: the next planned switch time (computed with `Schedule.nextSwitch`, stored in UserDefaults separately from the configuration)
- Until that moment the app leaves the appearance completely alone, so your manual choice is respected
  - Example: schedule is dark at 19:00 / light at 05:00, and you manually switch to light at 22:00 → it stays light from 22:00 until 05:00 the next day
  - At 05:00 the scheduled target is already light, so nothing happens; at 19:00 the target becomes dark and the app switches back, returning to the schedule
- When the window expires the override simply lapses and the schedule resumes — **no action needed**
- While paused, the first menu line reads "Auto switching paused (resumes at 05:00)", the menu bar icon carries a small pause badge, and a "Resume Auto Switching" item ends the pause immediately

The key point is that the override is just *an expiry timestamp plus skipping convergence inside that window* — it does **not** turn the schedule into a one-shot trigger. The convergent semantics are unchanged, so sleeping or shutting down across a switch time still self-heals (e.g. closing the lid over 05:00, and the appearance is aligned within 8 seconds of waking). If both times are equal there is no "next planned switch", so no pause is entered — the toggle just switches.

## Known limitations

- Switching relies on `osascript`, so the Automation permission is required; without it the switch fails silently (the menu's manual switch is affected too)
- Schedule precision is the polling interval (about 8 seconds), so a switch may be a few seconds late
- After changing the UI language, the menu, clock, alerts and settings window all use the new language immediately; AppKit objects that are **already on screen** (such as an open alert) do not change language mid-flight — reopen or restart the app
- Timezone display names are language-specific: the Chinese UI uses a built-in table of common Chinese city names (falling back to the system's Chinese name), while the English UI uses the last segment of the IANA identifier (`America/Los_Angeles` → `Los Angeles`). Both keep a fallback so an unrecognised identifier is shown verbatim rather than crashing.
- Manual toggling only enters the paused state while automatic switching is **enabled**; when it is disabled there is nothing to pause
- The settings window's height is capped at "visible screen height − margins − title bar". When the content does not fit, the window stops growing and the form area scrolls instead; the Reset / Cancel / Save row is pinned to the bottom of the window and never scrolls, so it stays clickable at any screen size.

## License

[MIT](LICENSE)

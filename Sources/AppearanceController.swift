import Foundation

enum AppearanceController {
    /// 当前是否为暗色。等价于读取 `defaults read -g AppleInterfaceStyle`：
    /// 该键只在暗色模式下存在且值为 "Dark"；读取失败（浅色模式）或键不存在均按浅色处理。
    static var isDark: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "-g", "AppleInterfaceStyle"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                return false
            }
            return output.lowercased() == "dark"
        } catch {
            return false
        }
    }

    /// 切换深浅色。成功返回 true。
    /// 实现方式：调用 osascript
    ///   tell application "System Events" to tell appearance preferences to set dark mode to <true|false>
    /// 已实测此命令在本机可用，无需额外权限。
    @discardableResult
    static func setDark(_ dark: Bool) -> Bool {
        let darkMode = dark ? "true" : "false"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "tell application \"System Events\" to tell appearance preferences to set dark mode to \(darkMode)"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

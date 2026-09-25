import Foundation
import ServiceManagement

// MARK: - 错误

/// 登录自启的失败原因。errorDescription 就是给用户看的文案
/// （设置窗口保存失败时用 NSAlert 原样展示）。
enum LoginItemError: LocalizedError {
    /// 系统里已登记，但被用户在「系统设置 › 登录项」中关掉，需要用户自己去允许
    case requiresApproval
    /// 拿不到 App 的可执行文件路径，写不了 LaunchAgent
    case executableNotFound
    /// 写 LaunchAgent plist 失败
    case launchAgentWriteFailed(path: String, reason: String)
    /// plist 写好了，但 launchctl 没能把它注册进 launchd
    case launchAgentLoadFailed(path: String, attempts: [String])
    /// 两层策略都没成功
    case registrationFailed(serviceError: String?, launchAgentError: String)
    /// 注销失败
    case unregistrationFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            return "ThemeSwitch 的登录项已在「系统设置 › 通用 › 登录项与扩展」中被关闭。请在那里重新允许它。"
        case .executableNotFound:
            return "找不到 ThemeSwitch 的可执行文件，无法设置登录自启。"
        case .launchAgentWriteFailed(let path, let reason):
            return "无法写入登录项文件 \(path)：\(reason)"
        case .launchAgentLoadFailed(let path, let attempts):
            return "已写入登录项文件 \(path)，但注册到 launchd 失败：\n" + attempts.joined(separator: "\n")
        case .registrationFailed(let serviceError, let launchAgentError):
            var lines = ["注册登录项失败。"]
            if let serviceError {
                lines.append("系统登录项接口：\(serviceError)")
            }
            lines.append("LaunchAgent：\(launchAgentError)")
            lines.append("可稍后重试，或在「系统设置 › 通用 › 登录项与扩展」里手动添加 ThemeSwitch。")
            return lines.joined(separator: "\n")
        case .unregistrationFailed(let reason):
            return "取消登录自启失败：\(reason)"
        }
    }
}

// MARK: - 依赖抽象（测试可注入假实现，避免触碰真实 launchd / 登录项）

/// 执行外部命令的结果；stderr 也合并进 output，失败信息随结果一起返回而不是打到终端
struct CommandResult {
    let status: Int32
    let output: String

    var succeeded: Bool { status == 0 }
}

protocol CommandRunner: AnyObject {
    func run(_ command: String, arguments: [String]) -> CommandResult
}

/// 真实实现：Process + 合并管道。先读到 EOF 再 waitUntilExit，两路输出共用一个管道，不会互相堵死。
final class ProcessCommandRunner: CommandRunner {
    func run(_ command: String, arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

/// 第一层用到的 ServiceManagement 接口；SMAppService 的成员同名同签名，直接满足它
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

// MARK: - 登录自启（两层策略）

/// 登录自启的实现：
///   1. 系统 API `SMAppService.mainApp`（macOS 13+）—— 首选，由系统统一管理；
///   2. 手写 LaunchAgent plist（`~/Library/LaunchAgents/<bundle id>.plist`）—— 兜底。
/// 本 App 是 ad-hoc 签名、没有 Developer ID，`register()` 常常直接失败，所以第二层是必需的。
///
/// 依赖（LaunchAgents 目录、可执行文件、服务接口、命令执行器）全部由参数注入：
/// 生产环境走默认值，测试可换成临时目录 + 假实现，不碰真实登录项。
final class LoginItemManager {
    /// 与 install.sh / uninstall.sh 共用同一个 label，三边注册、清理的是同一个登录项
    static let defaultLabel = "com.themeswitch.app"
    private static let launchctl = "/bin/launchctl"

    private let label: String
    private let launchAgentsDirectory: URL
    private let executableURL: URL?
    private let service: LoginItemService
    private let runner: CommandRunner

    init(
        label: String? = nil,
        launchAgentsDirectory: URL? = nil,
        executableURL: URL? = nil,
        service: LoginItemService? = nil,
        runner: CommandRunner? = nil
    ) {
        self.label = label ?? Bundle.main.bundleIdentifier ?? Self.defaultLabel
        self.launchAgentsDirectory = launchAgentsDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.executableURL = executableURL ?? Bundle.main.executableURL
        self.service = service ?? SMAppService.mainApp
        self.runner = runner ?? ProcessCommandRunner()
    }

    // MARK: - 对外接口

    /// 系统真实状态：SMAppService 报 .enabled，或 LaunchAgent plist 存在且已加载
    var isEnabled: Bool {
        if service.status == .enabled {
            return true
        }
        return hasLaunchAgent && isLaunchAgentLoaded
    }

    /// 设置登录自启。已处于目标状态时直接返回（幂等）；失败抛错，错误信息可展示给用户。
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard !isEnabled else { return }
            try enable()
        } else {
            guard isEnabled || hasLaunchAgent || isServiceRegistered else { return }
            try disable()
        }
    }

    // MARK: - 状态细节

    /// plist 路径与 uninstall.sh 的清理目标一致
    private var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist", isDirectory: false)
    }

    private var hasLaunchAgent: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 当前登录用户在 launchd 里的域
    private var domain: String {
        "gui/\(getuid())"
    }

    /// 系统里登记过（含等待用户允许的状态），未登记时 unregister 会报 kSMErrorJobNotFound
    private var isServiceRegistered: Bool {
        service.status != .notRegistered && service.status != .notFound
    }

    private var isLaunchAgentLoaded: Bool {
        runner.run(Self.launchctl, arguments: ["print", "\(domain)/\(label)"]).succeeded
    }

    /// launchd 里这个 label 当前的执行进程号（launchctl print 的 "pid = N" 行）；没在跑或读不到时为 nil
    private var launchedProcessIdentifier: pid_t? {
        let result = runner.run(Self.launchctl, arguments: ["print", "\(domain)/\(label)"])
        guard result.succeeded else { return nil }
        for line in result.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid = ") else { continue }
            return pid_t(trimmed.dropFirst("pid = ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// 当前进程就是 launchd 为这个 label 拉起来的那个进程：此时 bootout 会把 App 自己杀掉，
    /// 后续的配置保存与通知都执行不到，所以这种情况要跳过 bootout（删掉 plist 已足够：
    /// launchd 只在加载时读 plist，进程随 App 退出自然结束，下次登录不会再启动）。
    private var isOwnProcessTheLoginItem: Bool {
        launchedProcessIdentifier == getpid()
    }

    // MARK: - 注册 / 注销

    private func enable() throws {
        // 用户在「系统设置 › 登录项」里明确关掉过：只提示，不用 LaunchAgent 绕过用户的选择
        if service.status == .requiresApproval {
            throw LoginItemError.requiresApproval
        }

        var serviceFailure: String?
        do {
            try service.register()
            guard service.status != .enabled else { return }
            // 注册没报错但状态没到 .enabled，同样是在等用户在系统设置里允许
            throw LoginItemError.requiresApproval
        } catch let error as LoginItemError {
            throw error
        } catch {
            serviceFailure = error.localizedDescription
        }

        // 第一层不行（ad-hoc 签名下是常态），退回 LaunchAgent；两层都失败才报错
        do {
            try installLaunchAgent()
        } catch {
            throw LoginItemError.registrationFailed(
                serviceError: serviceFailure,
                launchAgentError: error.localizedDescription
            )
        }
    }

    private func disable() throws {
        var failures: [String] = []

        if isServiceRegistered {
            do {
                try service.unregister()
            } catch {
                failures.append("系统登录项注销失败：\(error.localizedDescription)")
            }
        }

        // 没加载时 bootout 本身就会报错，属预期情况，不单独记失败；以最终状态为准。
        // 当前进程就是登录项拉起来的那个进程时要跳过：bootout 会把 App 自己杀掉。
        if !isOwnProcessTheLoginItem {
            _ = runner.run(Self.launchctl, arguments: ["bootout", "\(domain)/\(label)"])
        }
        if hasLaunchAgent {
            do {
                try FileManager.default.removeItem(at: plistURL)
            } catch {
                failures.append("无法删除 \(plistURL.path)：\(error.localizedDescription)")
            }
        }

        // 复查真实状态：还有残留才算失败
        if isEnabled || hasLaunchAgent {
            failures.append("登录项仍然有效：\(plistURL.path)")
        }
        guard failures.isEmpty else {
            throw LoginItemError.unregistrationFailed(reason: failures.joined(separator: "\n"))
        }
    }

    /// 第二层兜底：写 LaunchAgent plist 并交给 launchd 加载
    private func installLaunchAgent() throws {
        guard let executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path)
        else {
            throw LoginItemError.executableNotFound
        }

        // 与 install.sh --launch-at-login 的 plist 保持同样的键：登录即运行、可执行文件取当前 App 的真实路径
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path],
            "RunAtLoad": true,
            "ProcessType": "Interactive"
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(
                at: launchAgentsDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: plistURL, options: .atomic)
            // launchd 拒绝加载组/其他人可写的 plist，固定成 0644
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: plistURL.path
            )
        } catch {
            throw LoginItemError.launchAgentWriteFailed(path: plistURL.path, reason: error.localizedDescription)
        }

        // 当前进程就是 launchd 拉起的那份登录项时，job 已经在 launchd 里跑着：
        // 既不该 bootout（会杀掉自己），重新 bootstrap 也会因已加载而失败；写好 plist 即完成。
        guard !isOwnProcessTheLoginItem else { return }

        // 先清掉可能存在的旧注册（例如 App 换过位置），否则 bootstrap 会因为已加载而失败
        _ = runner.run(Self.launchctl, arguments: ["bootout", "\(domain)/\(label)"])

        let bootstrap = runner.run(Self.launchctl, arguments: ["bootstrap", domain, plistURL.path])
        if bootstrap.succeeded {
            return
        }
        let load = runner.run(Self.launchctl, arguments: ["load", "-w", plistURL.path])
        if load.succeeded {
            return
        }

        // 两层都没成：删掉刚写的 plist，不留「文件在、没生效」的半成品，状态与返回值保持一致
        try? FileManager.default.removeItem(at: plistURL)
        throw LoginItemError.launchAgentLoadFailed(
            path: plistURL.path,
            attempts: [
                "launchctl bootstrap \(domain) → \(bootstrap.output)",
                "launchctl load -w → \(load.output)"
            ]
        )
    }
}

// MARK: - 对外 API

enum LoginItem {
    /// 当前是否已注册为登录项（读系统真实状态，不是读配置）
    static var isEnabled: Bool {
        manager.isEnabled
    }

    /// 设置登录自启。失败时抛错，错误信息要能直接展示给用户
    static func setEnabled(_ enabled: Bool) throws {
        try manager.setEnabled(enabled)
    }

    private static let manager = LoginItemManager()
}

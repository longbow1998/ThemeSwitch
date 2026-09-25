import Cocoa

autoreleasepool {
    // 单实例保护。
    //
    // 场景：开启「登录时自动启动」时，launchd 会立刻 bootstrap 这个 LaunchAgent，
    // 而它带 RunAtLoad，于是 App 已经在前台运行时又被拉起一个进程 ——
    // 结果就是菜单栏出现两个一模一样的图标。
    //
    // 这里让后启动的实例直接退出，保留已经在跑的那个。
    let selfPID = ProcessInfo.processInfo.processIdentifier
    if let bundleID = Bundle.main.bundleIdentifier {
        let alreadyRunning = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != selfPID }
        if alreadyRunning {
            exit(0)
        }
    }

    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    _ = application.setActivationPolicy(.accessory)
    application.run()
}

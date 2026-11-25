import AppKit

/**
 * @Author lt_xiaoyi
 * @Description 启动 BarNest 应用
 * @Version 1.0
 */

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

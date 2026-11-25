import AppKit
import ServiceManagement

/**
 * @Author lt_xiaoyi
 * @Description 应用启动与退出生命周期
 * @Version 1.0
 */

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusBarController()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        NSLog("BarNest 启动：macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前释放断言，避免把别人的图标留在 « 菜单里。
        controller?.cleanup()
    }
}

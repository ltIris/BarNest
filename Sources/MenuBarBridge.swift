import Foundation
import os
import AppKit
import CoreGraphics

/**
 * @Author lt_xiaoyi
 * @Description 定义 MenuBarClientCore 收纳断言的调用接口。
 * @Version 1.0
 */
@objc private protocol AssessmentModeAssertion {
    @objc(activateWithConfiguration:completionHandler:)
    func activate(with configuration: AnyObject, completionHandler: @escaping (Error?) -> Void)
    func invalidate()
}

/**
 * @Author lt_xiaoyi
 * @Description 表示菜单栏收纳接口的不可用、配置或激活错误。
 * @Version 1.0
 */
enum MenuBarBridgeError: LocalizedError {
    case unavailable
    case configurationFailed
    case activation(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "MenuBarClientCore 框架不可用或接口已变更"
        case .configurationFailed: return "无法构造白名单配置"
        case .activation(let s): return "MenuBarAgent 拒绝：\(s)"
        }
    }
}

/**
 * @Author lt_xiaoyi
 * @Description 桥接系统菜单栏收纳接口，并管理白名单断言。
 * @Version 1.0
 */
final class MenuBarBridge {
    static let shared = MenuBarBridge()

    private let frameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    private let configInit = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
    private let classes: (assertion: NSObject.Type, configuration: NSObject.Type)?
    private var active: (assertion: AssessmentModeAssertion, allowList: [String])?
    private var pending: AssessmentModeAssertion?

    // 这些宿主不能被隐藏，否则控制中心/时钟/输入法会一起消失。
    // 关键：必须包含 App 自己的 bundleID，否则收纳后自己的菜单栏按钮也消失，
    // 用户就再也点不到按钮、无法恢复。
    //
    // macOS 27 的「正在播放 / 隔空播放 / 声音」等并不是独立 App，而是
    // ControlCenter 内部的模块级菜单项（NowPlayingMenuExtraView），标识形如
    // com.apple.controlcenter.nowplaying。它们只在需要时动态出现，靠「实时扫描
    // PID → 进程 bundleID」永远补不进来，必须在这里显式放行，否则一收纳就消失。
    static let alwaysAllowed: Set<String> = {
        var base: Set<String> = [
            "com.apple.MenuBarAgent",
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.TextInputMenuAgent",
            "com.apple.notificationcenterui",
            "com.apple.wifi.WiFiAgent",
            // 系统自带的菜单栏图标：隔空播放/屏幕镜像、蓝牙、电池、声音、VPN、时间机器等。
            // 这些绝不能被收纳，否则用户会以为「系统图标坏了」。
            "com.apple.AirPlayUIAgent",
            "com.apple.airplay",
            "com.apple.bluetooth",
            "com.apple.BluetoothFileExchange",
            "com.apple.bluetoothuiserver",
            "com.apple.powerd",
            "com.apple.battery",
            "com.apple.systemuiserver",
            "com.apple.Sound",
            "com.apple.coreaudiod",
            "com.apple.vpnmenu",
            "com.apple.timemachine",
            "com.apple.Spotlight",
            "com.apple.campo",
            // 控制中心模块级菜单项（动态出现，PID 扫描抓不到）。
            "com.apple.controlcenter.nowplaying",
            "com.apple.controlcenter.screenmirroring",
            "com.apple.controlcenter.screenmirroring.displaypreview",
            "com.apple.controlcenter.musicrecognition",
            "com.apple.controlcenter.sound",
            "com.apple.controlcenter.stagemanager",
            "com.apple.controlcenter.keyboardbrightness",
            "com.apple.controlcenter.liveactivity",
            "com.apple.controlcenter.bentoboxes",
            "com.apple.controlcenter.bentobox.biome",
            "com.apple.controlcenter.displayablemenuextras",
            "com.apple.controlcenter.hearingaccessibility",
            "com.apple.controlcenter.motoraccessibility",
            "com.apple.controlcenter.visionaccessibility",
            "com.apple.controlcenter.ringlight",
            "com.apple.controlcenter.helper",
            // 「正在播放 / 实时活动」的宿主进程：白名单漏掉它们，
            // 收纳时这些系统模块会被一并藏进溢出区（表现为「播放图标消失」）。
            "com.apple.MediaRemoteUI",
            "com.apple.mediaremote",
            "com.apple.MediaPlayer",
            "com.apple.NowPlaying",
            "com.apple.chronod",
            "com.apple.WidgetKit",
            "com.apple.MusicRecognition",
            "com.apple.mediaremoted",
            "com.apple.controlcenter.utilities",
            "com.apple.controlcenter.ccutil",
            // 媒体与小组件宿主。
            "com.apple.MediaRemote",
            "com.apple.mediaremote",
            "com.apple.Music",
            "com.apple.chronod",
            "com.apple.widgetkit",
            "com.apple.WidgetKit",
            "com.apple.notificationcenterui.widgets",
            "com.apple.Siri",
            "com.apple.siri",
        ]
        if let selfID = Bundle.main.bundleIdentifier { base.insert(selfID) }
        return base
    }()

    // 只要是 Apple 官方 bundle id，一律不参与收纳（系统图标永远保留）。
    static func isSystemOwned(_ bundleID: String) -> Bool {
        bundleID.hasPrefix("com.apple.") || bundleID.hasPrefix("com.apple")
    }

    private init() {
        guard dlopen(frameworkPath, RTLD_NOW) != nil,
              let assertion = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
              let configuration = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
              assertion.instancesRespond(to: #selector(AssessmentModeAssertion.activate(with:completionHandler:))),
              assertion.instancesRespond(to: #selector(AssessmentModeAssertion.invalidate)),
              configuration.instancesRespond(to: configInit)
        else {
            classes = nil
            return
        }
        classes = (assertion, configuration)
    }

    var isAvailable: Bool { classes != nil }
    var currentAllowList: [String]? { active?.allowList }

    // 只允许 allowList 里的 app 图标显示，其余由系统收进 « 菜单。
    func restrict(allowedBundleIDs: [String], completion: @escaping (Error?) -> Void) {
        pending?.invalidate()
        pending = nil
        guard let classes else {
            completion(MenuBarBridgeError.unavailable)
            return
        }
        var allowed = Set(allowedBundleIDs)
        allowed.formUnion(Self.alwaysAllowed)
        let allowList = allowed.sorted()

        // 系统项枚举只有 0..8 这 9 个（实测：传 0..<1024 会被框架规范化成 0..8；
        // 传空数组 = 允许 0 个系统项，会导致菜单栏系统图标全部消失）。
        // 注意：不能用 NSArray() 代替——那是「一个都不允许」，不是「不设限」。
        let allSystemItems = (0..<9).map { NSNumber(value: $0) } as NSArray
        guard let allocated = (classes.configuration as AnyObject)
                .perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let config = allocated.perform(configInit, with: allSystemItems, with: allowList as NSArray)?
                .takeRetainedValue() else {
            completion(MenuBarBridgeError.configurationFailed)
            return
        }

        let assertion = unsafeBitCast(classes.assertion.init(), to: AssessmentModeAssertion.self)
        pending = assertion
        assertion.activate(with: config) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.pending === assertion else { return }
                self.pending = nil
                if let error {
                    assertion.invalidate()
                    completion(MenuBarBridgeError.activation(error.localizedDescription))
                } else {
                    self.active?.assertion.invalidate()
                    self.active = (assertion, allowList)
                    completion(nil)
                }
            }
        }
    }

    // 释放断言，菜单栏立即恢复原状。
    func release() {
        pending?.invalidate()
        pending = nil
        active?.assertion.invalidate()
        active = nil
    }
}

// MARK: - 统一断言协调器

/**
 * @Author lt_xiaoyi
 * @Description 统一协调收纳断言的临时释放与恢复，保证系统组件和原菜单可交互。
 * @Version 1.0
 */
@MainActor
final class MenuBarAssertionCoordinator {
    static let shared = MenuBarAssertionCoordinator()

    private var isRestricted = false
    private var allowList: [String] = []
    // 需要完全释放断言的场景（系统区点击等）。
    private var lifts: Set<String> = []
    // 只临时让某个已收纳 App 回到菜单栏（从工作台弹它的原菜单），其他图标仍收纳。
    private var tempAllowed: Set<String> = []
    private var appliedSignature: String?

    var restricted: Bool { isRestricted }
    var isLifted: Bool { !lifts.isEmpty }

    func restrict(allowList: [String], completion: ((Error?) -> Void)? = nil) {
        isRestricted = true
        self.allowList = allowList
        apply(completion: completion)
    }

    func restore() {
        isRestricted = false
        allowList = []
        lifts.removeAll()
        tempAllowed.removeAll()
        apply()
    }

    // 白名单内容变化（App 启停 / 偏好设置开关变更）时调用。
    func updateAllowList(_ list: [String]) {
        guard isRestricted else { return }
        allowList = list
        apply()
    }

    /**
     * 强制重建断言（即使白名单内容没变）。
     *
     * 为什么需要：assessment mode 的白名单是「激活那一刻的快照」，
     * 之后才动态出现的菜单栏项（典型就是「正在播放」这个 attached AV module）
     * 永远进不了旧快照，会一直停在溢出区。而 apply() 带签名去重，
     * 内容不变时不重建 → 动态模块就永久不回来。
     * 内容相同时重建是视觉无缝的（新旧断言项目集合一致），不会闪。
     */
    func forceReapply() {
        guard isRestricted, lifts.isEmpty else { return }
        appliedSignature = nil
        apply()
    }

    func beginLift(_ reason: String) {
        lifts.insert(reason)
        apply()
    }

    func endLift(_ reason: String) {
        lifts.remove(reason)
        apply()
    }

    /**
     * 临时把某个已收纳的 App 放回菜单栏：重新激活断言时把它加进白名单，
     * 只有它一个图标回来，不会像「完全释放」那样让所有图标一起展开。
     */
    func beginTemporaryAllow(_ bundleID: String) {
        tempAllowed.insert(bundleID)
        apply()
    }

    func endTemporaryAllow(_ bundleID: String) {
        tempAllowed.remove(bundleID)
        apply()
    }

    // 校对「收纳是否真的收住了」。
    //
    // 这是之前一个隐蔽的真 bug：点时间 / 控制中心时必须短暂放开断言（不改放开系统根本不响应），
    // 那一刻 18 个图标全回到菜单栏；等面板关闭我们归还断言时，**系统正在显示面板会拒绝收缩**，
    // 而 apply() 只发一次请求，失败没有任何重试 —— 菜单栏就永久停在「全部展开 + « 溢出箭头」，
    // 直到下次 App 启停或改设置才碰巧恢复。用户看到的就是「点了时间之后所有图标回来了、还冒出 «」。
    //
    // 这里按「本该被藏起来的图标是不是还在菜单栏上」来判断收敛，没收敛就强制重放断言。
    // 返回 true 表示已经收干净。
    @discardableResult
    func verify(hidden: Set<String>) -> Bool {
        guard isRestricted, lifts.isEmpty, !hidden.isEmpty else { return true }
        let leaked = MenuBarScanner.liveMenuBarBundleIDs().intersection(hidden)
        guard !leaked.isEmpty else { return true }
        NSLog("BarNest 收纳未收敛，重放断言（泄漏 %d 个：%@）",
              leaked.count, leaked.sorted().joined(separator: ","))
        appliedSignature = nil
        apply()
        return false
    }

    private func apply(completion: ((Error?) -> Void)? = nil) {
        let shouldHold = isRestricted && lifts.isEmpty
        let effective = shouldHold ? Array(Set(allowList).union(tempAllowed)).sorted() : []
        let signature = shouldHold ? "hold:" + effective.joined(separator: ",") : "release"
        guard signature != appliedSignature else {
            completion?(nil)
            return
        }
        appliedSignature = signature
        if shouldHold {
            MenuBarBridge.shared.restrict(allowedBundleIDs: effective) { error in
                if let error { NSLog("BarNest 收纳断言失败：\(error.localizedDescription)") }
                completion?(error)
            }
        } else {
            MenuBarBridge.shared.release()
            completion?(nil)
        }
    }
}

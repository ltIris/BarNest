import AppKit

/**
 * @Author lt_xiaoyi
 * @Description 工作台中的「正在播放」入口。
 * 收纳断言会影响系统播放项，因此在工作台保留独立入口；
 * 点击时暂时释放断言，再触发系统原有的播放面板。
 * @Version 1.0
 */
@MainActor
enum NowPlayingEntry {
    // 固定 bundleID，用来把这一格和真实 App 区分开。
    static let bundleID = "__now_playing__"

    static func isPinned(_ id: String) -> Bool { id == bundleID }

    // 系统「正在播放 / 隔空播放」菜单项的 AXIdentifier。
    private static let systemItemID = "com.apple.menuextra.now-playing"

    /**
     * 正在出声的那个 App（没有就是 nil）。
     *
     * 两条信号合起来判：
     *  · CoreAudio 的 `IsRunningOutput` 给出「候选集合」（挂着的流也算，包括暂停的）；
     *  · MediaRemote 的 Now Playing 会话给出「到底在不在播」，用它把暂停中的
     *    App 从候选里剔除 —— 否则暂停的 Apple Music 会一直霸占横条，用户正在听
     *    的播放器反而显示不出来。
     * 全都不在播时返回 nil，由调用方回落到「上次那个播放器」。
     */
    private static var playingApp: NSRunningApplication? {
        let clients = AudioActivity.activeOutputClients()
        guard !clients.isEmpty else { return nil }

        let state = MediaRemoteQuery.state()
        var candidates = clients
        var decided: AudioActivity.Client?

        if let state {
            if state.isPlaying, state.pid != 0,
               let hit = candidates.first(where: { $0.pid == state.pid }) {
                // 优先使用系统确认正在播放的进程，避免暂停后仍保留输出流的应用占位。
                decided = hit
            } else {
                // 仅在存在其他候选时剔除暂停进程；未向 MediaRemote 注册的播放器仍以 CoreAudio 为准。
                if !state.isPlaying, state.pid != 0, candidates.count > 1 {
                    candidates.removeAll { $0.pid == state.pid }
                }
                decided = candidates.first
            }
        } else {
            decided = candidates.first
        }

        logDecision(clients: clients, state: state, decided: decided)
        guard let decided else { return nil }
        return app(for: decided)
    }

    // 判定结果变化时记一行，方便排查「明明在放歌却显示已暂停」这类问题。
    private static var lastDecisionLog = ""
    private static func logDecision(clients: [AudioActivity.Client],
                                    state: MediaRemoteQuery.State?,
                                    decided: AudioActivity.Client?) {
        let who = decided?.bundleID ?? "nil"
        let names = clients.map { $0.bundleID ?? String($0.pid) }.joined(separator: ",")
        let line = "clients=[\(names)] mr(pid=\(state?.pid ?? -1), playing=\(state?.isPlaying ?? false), info=\(state?.hasInfo ?? false)) -> \(who)"
        guard line != lastDecisionLog else { return }
        lastDecisionLog = line
        log(line)
    }

    private static func app(for client: AudioActivity.Client) -> NSRunningApplication? {
        if let bid = client.bundleID,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            return running
        }
        return NSRunningApplication(processIdentifier: client.pid)
    }

    // 上一次判定「确实在播」（不是挂着输出流的僵尸流）。横条用它决定右侧文案。
    private(set) static var isPlayingNow = false

    // 仅调试用：让横条固定显示「在播」样式，方便自查外观（不接触真实播放状态）。
    static var forcePlayingDemo = false

    /**
     * 工作台里那一格：常驻，永远排在最前面。
     *
     * 长得和其它格子完全一样：**播放器自己的真实图标 + 名字**。
     * 不画播放符号、不加小字 —— 一格就是 App 一格的样子，用户不用分辨哪个是「特制」的。
     */
    static func item() -> TrackedItem {
        isPlayingNow = forcePlayingDemo
        if let app = playingApp {
            isPlayingNow = true
            if let bid = app.bundleIdentifier { remember(bid) }
            let snap = snapshot(of: app)
            return TrackedItem(bundleID: bundleID, name: snap.name, icon: snap.icon)
        }
        // 没在出声：兜底也必须是一个**此刻真的在运行**的播放器。
        //
        // 这里曾经无条件信任持久化的 bundleID，哪怕那个 App 早就退出了也照显示，
        // 于是出现「用户在放网易云、工作台却写着酷狗音乐」——酷狗哪天开过一次，
        // 键里就永久留着它的 bundleID。现在只有「还开着」的才配被显示。
        if let app = fallbackPlayerApp() {
            let snap = snapshot(of: app)
            return TrackedItem(bundleID: bundleID, name: snap.name, icon: snap.icon)
        }
        return TrackedItem(bundleID: bundleID, name: "正在播放", icon: blankIcon())
    }

    // App →（名字, 真实图标）。名字和图标一律用宿主 App 自己的，绝不自己画。
    private static func snapshot(of app: NSRunningApplication) -> (name: String, icon: NSImage?) {
        let host = AppIdentity.host(for: app)
        let name = host?.name ?? app.localizedName ?? "正在播放"
        let icon = host.map { NSWorkspace.shared.icon(forFile: $0.url.path) } ?? app.icon
        return (name, icon)
    }

    // 没在出声时的兜底播放器：只认「此刻真的在运行」的音乐类 App。
    private static func fallbackPlayerApp() -> NSRunningApplication? {
        // 1) 上次真在放歌的那个还开着 → 用它（暂停 / 切歌时不换脸）。
        if let bid = lastBundleID {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
               app.activationPolicy == .regular {
                return app
            }
            // 它已经退出了：把这条记忆作废，别再显示一个不在运行的播放器。
            lastBundleID = nil
        }
        // 2) 本会话里最近放过歌、现在还开着的（多个播放器并存时按「最近」排）。
        for bid in recentPlayerIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
               app.activationPolicy == .regular {
                return app
            }
        }
        // 3) 最近被用户点开的那个音乐 App，如果还开着就优先它。
        //    同时开着网易云和音乐、两边都暂停时，用户刚点开谁就是谁。
        if let bid = lastActivatedMusicID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
           app.activationPolicy == .regular {
            return app
        }
        // 4) 最后兜底：此刻在运行、且声明为「音乐」类别的 App。
        //    用 Info.plist 的 LSApplicationCategoryType 判断，不硬编码任何 bundleID，
        //    用户装什么播放器都认。
        if let front = NSWorkspace.shared.frontmostApplication, isMusicApp(front) {
            return front
        }
        let musicApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && isMusicApp($0)
        }
        // 同分时优先用户自己装的播放器：系统自带的「音乐」经常只是被误开、
        // 一直挂在后台，不该抢走正在用的那个。
        return musicApps.first { $0.bundleIdentifier?.hasPrefix("com.apple.") == false }
            ?? musicApps.first
    }

    /**
     * 最近一次被用户点开的音乐 App。
     *
     * 为什么需要它：网易云 / 音乐 / 酷狗这类 App 暂停时都会继续挂着音频对象，
     * 而 `NSWorkspace.runningApplications` 的顺序不做任何承诺 —— 只按「谁是音乐
     * 类别」去挑，同时开着两个播放器时就可能挑到用户没在用的那个。
     */
    private static var lastActivatedMusicID: String? {
        get { UserDefaults.standard.string(forKey: "notchtool.lastActivatedMusic") }
        set { UserDefaults.standard.set(newValue, forKey: "notchtool.lastActivatedMusic") }
    }

    private static var activationObserver: NSObjectProtocol?

    // 启动时挂一次 App 激活监听，记录最后被点开的音乐 App。
    static func startTracking() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard isMusicApp(app) else { return }
                lastActivatedMusicID = bid
            }
        }
    }

    // 这个 App 是不是「音乐播放器」：看它自己声明的类别，不靠名字猜。
    private static func isMusicApp(_ app: NSRunningApplication) -> Bool {
        guard let bid = app.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
              let dict = Bundle(url: url)?.infoDictionary else { return false }
        return (dict["LSApplicationCategoryType"] as? String) == "public.app-category.music"
    }

    /**
     * 上次在放歌的播放器，跨启动记住，避免「没在放歌时这一格变脸」。
     * 只在那个 App **仍作为音乐 App 安装着** 时有意义，运行状态由兜底逻辑校验。
     */
    private static var lastBundleID: String? {
        get { UserDefaults.standard.string(forKey: "notchtool.lastPlayedBundleID") }
        set { UserDefaults.standard.set(newValue, forKey: "notchtool.lastPlayedBundleID") }
    }

    /**
     * 本会话里「确实放过歌」的播放器，最近的排前面；跨启动保留，
     * 用来在多个音乐 App 同时开着时挑对那一个。
     */
    private static var recentPlayerIDs: [String] {
        UserDefaults.standard.stringArray(forKey: "notchtool.recentPlayers") ?? []
    }

    private static func remember(_ bid: String) {
        lastBundleID = bid
        // 真放过歌的那个，就是用户心里的「我的播放器」。同时写进「最近激活」，
        // 这样它暂停、甚至下次启动时，都不会被其它只是开着的音乐 App 顶掉。
        lastActivatedMusicID = bid
        var ids = recentPlayerIDs.filter { $0 != bid }
        ids.insert(bid, at: 0)
        if ids.count > 8 { ids = Array(ids.prefix(8)) }
        UserDefaults.standard.set(ids, forKey: "notchtool.recentPlayers")
    }

    // 从没探到过任何播放器时的占位：一个空的系统符号，不做任何自绘。
    private static func blankIcon() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        guard let base = NSImage(systemSymbolName: "play.circle", accessibilityDescription: "正在播放")?
            .withSymbolConfiguration(config) else {
            return NSImage(size: NSSize(width: 40, height: 40))
        }
        let canvas = NSSize(width: 40, height: 40)
        let image = NSImage(size: canvas)
        let rect = NSRect(x: (canvas.width - base.size.width) / 2,
                          y: (canvas.height - base.size.height) / 2,
                          width: base.size.width, height: base.size.height)
        image.lockFocus()
        base.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }

    /**
     * 点这一格 = 弹出系统原生的「正在播放」面板。
     *
     * 收纳生效时那颗系统项根本不在 AX 树里（系统把它整个移除了），所以先把收纳
     * 短暂放开，等 MenuBarAgent 重新布局（约 260ms）后再 AXPress。
     * 若这个播放器没在系统里注册 Now Playing（网易云这类就是），系统项按不动——
     * 那就退回「切到正在出声的那个 App」。
     */
    static func activate() {
        let coordinator = MenuBarAssertionCoordinator.shared
        guard coordinator.restricted else {
            if !MenuBarAction.pressSystemMenuExtra(identifier: systemItemID) { openPlayingApp() }
            return
        }
        coordinator.beginLift("workbench-nowplaying")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            log("lifted, restricted=\(coordinator.restricted) lifted=\(coordinator.isLifted)")
            let pressed = MenuBarAction.pressSystemMenuExtra(identifier: systemItemID)
            log("press now-playing -> \(pressed ? "ok" : "fail")")
            if !pressed { openPlayingApp() }
            try? await Task.sleep(nanoseconds: pressed ? 420_000_000 : 120_000_000)
            coordinator.endLift("workbench-nowplaying")
        }
    }

    private static func openPlayingApp() {
        openCurrentPlayer()
    }

    /**
     * 打开播放器本身（右键菜单 / 系统项按不动时的兜底）。
     * 正在出声就用它；暂停时用兜底解析出的那个，保证点的永远是眼前显示的那个 App。
     */
    static func openCurrentPlayer() {
        (playingApp ?? fallbackPlayerApp())?.activate()
    }

    // 调试日志：写 /tmp/notchtool-np.txt，生产环境无副作用（只追加一行）。
    private static func log(_ line: String) {
        NSLog("BarNest NP %@", line)
        let text = line + "\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/notchtool-np.txt") {
            h.seekToEndOfFile()
            h.write(text.data(using: .utf8)!)
            h.closeFile()
        } else {
            try? text.write(toFile: "/tmp/notchtool-np.txt", atomically: true, encoding: .utf8)
        }
    }
}

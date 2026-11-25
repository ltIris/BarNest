import AppKit

/**
 * @Author lt_xiaoyi
 * @Description 持久化用户的图标选择：哪些 App 合并进菜单栏按钮、按什么顺序展示。
 * @Version 1.0
 */
final class IconConfig {
    static let shared = IconConfig()

    private let defaults = UserDefaults.standard
    private let orderKey = "notchtool.iconOrder"
    private let excludedKey = "notchtool.iconExcluded"
    private let initializedKey = "notchtool.iconInitialized"
    private let collapseKey = "notchtool.collapseOnLaunch"
    // 用户主动收纳（合并）进工作台的图标。默认空：没设置过就不该显示"已合并"。
    private let collapsedKey = "notchtool.collapsedIDs"

    private init() {}

    // 正在被收纳合并的图标 bundleID。开关开启 = 在这个集合里。
    var collapsedIDs: [String] {
        get { defaults.stringArray(forKey: collapsedKey) ?? [] }
        set { defaults.set(newValue, forKey: collapsedKey) }
    }

    func isCollapsed(_ bundleID: String) -> Bool { collapsedIDs.contains(bundleID) }

    func setCollapsed(_ bundleID: String, on: Bool) {
        var ids = collapsedIDs
        if on {
            if !ids.contains(bundleID) { ids.append(bundleID) }
        } else {
            ids.removeAll { $0 == bundleID }
        }
        collapsedIDs = ids
    }

    // 用户手动排除的 bundleID（默认自动收纳所有真实图标，只有排除的才不收）。
    var excludedBundleIDs: [String] {
        get { defaults.stringArray(forKey: excludedKey) ?? [] }
        set { defaults.set(newValue, forKey: excludedKey) }
    }

    /**
     * 兼容旧接口：selectedBundleIDs 现在表示「自动收纳时正在展示的」，由调用方用 computeSelected 算出。
     * 这里返回已保存的顺序（偏好设置拖动排序用）。
     */
    var selectedBundleIDs: [String] {
        get { defaults.stringArray(forKey: orderKey) ?? [] }
        set { defaults.set(newValue, forKey: orderKey) }
    }

    /**
     * 严格以「当前真实扫描到的图标」为唯一数据来源——菜单栏现在有什么就只显示什么。
     * 保存的顺序只用来排序，绝不用于新增图标（否则会把历史遗留/已不存在的 App 带出来）。
     */
    func computeSelected(fromCatalog catalog: [TrackedItem]) -> [TrackedItem] {
        let excluded = Set(excludedBundleIDs)
        // Apple 系统自带的菜单栏图标（AirPlay/蓝牙/WiFi 等）永不参与收纳与展示。
        let available = catalog.filter {
            !excluded.contains($0.bundleID) && !MenuBarBridge.isSystemOwned($0.bundleID)
        }
        let order = selectedBundleIDs
        let orderIndex = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return available.sorted { a, b in
            let ia = orderIndex[a.bundleID] ?? Int.max
            let ib = orderIndex[b.bundleID] ?? Int.max
            if ia != ib { return ia < ib }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /**
     * 清掉历史版本塞进收纳集合里的系统常驻项 id。
     *
     * 早期版本尝试把「实时活动」当成可收纳的联动条目种进 collapsedIDs（用户并没有要求过），
     * 结果偏好设置和工作台里多出一行「实时活动（常驻菜单栏 · 只联动）」。
     * 这里做一次性清理：系统项本来就不该出现在这份用户名单里。
     */
    func purgeSystemEntries() {
        let key = "notchtool.systemEntriesPurged"
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(true, forKey: key)
        let cleaned = collapsedIDs.filter { !MenuBarBridge.isSystemOwned($0) }
        if cleaned.count != collapsedIDs.count { collapsedIDs = cleaned }
    }

    /**
     * 清掉历史遗留的「菜单栏替身播放图标」开关。
     *
     * 那颗图标已经彻底删掉：菜单栏上的播放项被系统连根拔掉，仿一颗永远是仿的。
     * 现在改成工作台里一格常驻入口（不可关），所以这个旧键只是脏数据。
     */
    func purgeLegacyStandIn() {
        defaults.removeObject(forKey: "notchtool.nowPlayingStandIn")
    }

    // 是否收纳到 « 菜单（作为一个整体开关，默认关，避免误操作）。
    var collapseOnLaunch: Bool {
        get { defaults.object(forKey: collapseKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: collapseKey) }
    }

    // 首次运行时，默认勾选所有 AX 扫描到的真实菜单栏图标（无需用户一个个点）。
    func ensureInitialized(allCandidates: [TrackedItem]) {
        if defaults.object(forKey: initializedKey) == nil {
            defaults.set(true, forKey: initializedKey)
        }
        // 若还没有任何选择，自动把当前所有真实图标全部纳入。
        if (defaults.stringArray(forKey: orderKey) ?? []).isEmpty, !allCandidates.isEmpty {
            defaults.set(allCandidates.map(\.bundleID), forKey: orderKey)
        }
    }

    // 按用户顺序返回要展示的图标；对已不在运行的 App 也尽量用已安装信息构造。
    func selectedItems(fromCatalog catalog: [TrackedItem]) -> [TrackedItem] {
        let byID = Dictionary(catalog.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        return selectedBundleIDs.compactMap { byID[$0] }
    }

    // 工作台只展示用户已收纳且仍在运行的应用；图标被隐藏后可用应用信息补全。
    func workbenchItems() -> [TrackedItem] {
        workbenchItems(fromCatalog: [])
    }

    // 复用偏好设置已扫描的图标，避免每次切换开关都重新扫描菜单栏。
    func workbenchItems(fromCatalog catalog: [TrackedItem], includeInactive: Bool = false) -> [TrackedItem] {
        let byID = Dictionary(catalog.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        let excluded = Set(excludedBundleIDs)
        var items: [TrackedItem] = []
        var seen = Set<String>()
        for bid in collapsedIDs {
            guard !seen.contains(bid), !excluded.contains(bid) else { continue }
            // 系统图标（Wi-Fi / 蓝牙 / 时钟 / 正在播放 / 实时活动…）永不参与收纳与展示。
            // 它们是菜单栏的固定组成部分，不进这份「用户主动收纳」的名单。
            guard !MenuBarBridge.isSystemOwned(bid) else { continue }
            // 已退出的 App 默认不展示（工作台上必须消失）；
            // 但偏好设置的「已合并」列表需要把所有操作过的项都列出来，传 includeInactive。
            if !includeInactive,
               NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty { continue }
            guard let item = byID[bid] ?? IconStore.item(forBundleID: bid) else { continue }
            items.append(item)
            seen.insert(bid)
        }
        // 手动顺序优先；未排序的保持扫描顺序（菜单栏上的真实位置）。
        let order = selectedBundleIDs
        let index = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated().sorted { a, b in
            let ia = index[a.element.bundleID] ?? Int.max
            let ib = index[b.element.bundleID] ?? Int.max
            if ia != ib { return ia < ib }
            return a.offset < b.offset
        }.map(\.element)
    }

    func contains(_ bundleID: String) -> Bool { !excludedBundleIDs.contains(bundleID) }

    // 从排除列表移除 = 重新纳入自动收纳。
    func add(_ bundleID: String) {
        excludedBundleIDs = excludedBundleIDs.filter { $0 != bundleID }
    }

    // 加入排除列表 = 不再收纳/展示这个图标。
    func remove(_ bundleID: String) {
        var ids = excludedBundleIDs
        if !ids.contains(bundleID) { ids.append(bundleID) }
        excludedBundleIDs = ids
    }

    func move(from fromIndex: Int, to toIndex: Int) {
        var ids = selectedBundleIDs
        guard ids.indices.contains(fromIndex), ids.indices.contains(toIndex) else { return }
        let item = ids.remove(at: fromIndex)
        ids.insert(item, at: toIndex)
        selectedBundleIDs = ids
    }
}

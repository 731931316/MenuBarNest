import AppKit
import ApplicationServices
import Combine
import NestCore
import SwiftUI

/// 负责布局持久化、状态项分区、原生下拉面板与权限生命周期。
@MainActor
final class NestCoordinator: NSObject, ObservableObject {
    /// 最近一次扫描到的真实状态项。
    @Published var entries: [MenuBarEntry] = []
    /// 用户编辑的布局规则，保存成功不等于已应用到系统。
    @Published var layout = LayoutState()
    /// 辅助功能权限状态。
    @Published var accessibilityGranted = false
    /// 获取状态项图像所需的屏幕录制权限状态。
    @Published var screenRecordingGranted = false
    /// 防止异步系统移动重入。
    @Published var isBusy = false
    /// 可供用户了解操作结果的状态文本。
    @Published var statusMessage = "请授权后刷新菜单栏图标。"
    /// 保存或系统操作失败的明确说明。
    @Published var errorMessage: String?
    /// 表示真实菜单栏已按规则完成分区。
    @Published var managementActive = false
    /// 当前实际应用的布局；尚未应用的编辑不改变下拉面板。
    @Published private(set) var appliedLayout: LayoutState?
    /// 管理窗口搜索文本。
    @Published var query = ""
    /// 管理窗口当前选择的分区。
    @Published var selectedSection: VisibilitySection?

    /// 系统交互适配器，便于替换为测试实现。
    private let system: any MenuBarSystemManaging
    /// 本地配置仓库。
    private let repository: LayoutRepository
    /// 配置读取损坏时阻止后续静默覆盖。
    private var configurationReadable = true
    /// 顶部“更多”控制项。
    private var moreItem: NSStatusItem?
    /// 常显区与收起区之间的收纳分隔项。
    private var collapsedBoundary: NSStatusItem?
    /// 收起区与始终隐藏区之间的收纳分隔项。
    private var hiddenBoundary: NSStatusItem?
    /// 原生下拉面板。
    private let popover = NSPopover()
    /// 设置窗口。
    private var managementWindow: NSWindow?
    /// 用于权限刷新及退出应用项目检测的计时器。
    private var pollTimer: Timer?
    /// 点击原始菜单后检查是否可以安全重新收纳。
    private var rehideTimer: Timer?
    /// 临时展开的原图标，避免在用户菜单仍打开时重新隐藏。
    private var temporarilyRevealed = false
    /// 首次应用前的项目顺序，用于本次会话恢复。
    private var originalOrder: [String] = []
    /// 屏幕参数变化通知。
    private var screenObserver: NSObjectProtocol?
    /// 用于系统菜单活动监测的观察器令牌。
    private var menuObserver: NSObjectProtocol?
    /// 原始应用菜单仍处于跟踪状态时暂停收纳。
    private var menuTracking = false
    /// 对退出执行一次异步恢复。
    private var terminating = false
    /// 串行操作任务；退出、权限撤销、屏幕变化时取消并等待它释放系统事件。
    private var operationTask: Task<Void, Never>?
    /// 仅本次启动尝试恢复上次已成功应用的规则。
    private var pendingLaunchRestore = true

    /// 创建本地配置仓库，预览使用独立临时文件且不启动系统控制。
    init(system: (any MenuBarSystemManaging)? = nil, preview: Bool = false) {
        self.system = system ?? MenuBarSystem()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let configURL = preview
            ? FileManager.default.temporaryDirectory.appendingPathComponent("MenuBarNest-Preview/config.json")
            : support.appendingPathComponent("MenuBarNest/layout.json")
        repository = LayoutRepository(fileURL: configURL)
        super.init()
        if !preview {
            do { layout = try repository.load() }
            catch {
                configurationReadable = false
                errorMessage = "配置读取失败，为保护原配置已暂停保存：\(error.localizedDescription)"
                NestLog.app.error("配置读取失败，已阻止自动覆盖。")
            }
        }
        updatePermissions()
    }

    /// 安装自己的控制项；首次启动不自动移动用户图标。
    func start() {
        installControls()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenConfigurationChanged() }
        }
        // 跨进程菜单跟踪通知并非所有应用都会发送，配合鼠标与轮询做保守恢复。
        menuObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.HIToolbox.beginMenuTrackingNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.menuTracking = true } }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(menuTrackingEnded),
            name: NSNotification.Name("com.apple.HIToolbox.endMenuTrackingNotification"), object: nil
        )
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        NestLog.app.info("菜单栏管理器启动，等待用户应用布局。")
        refresh()
        showManagementWindow()
    }

    /// 以保存的分区顺序返回项目，并应用窗口搜索条件。
    func items(in section: VisibilitySection) -> [MenuBarEntry] {
        let ids = layout.orderedIDs(in: section, among: entries.map(\.id))
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    /// 下拉面板使用已应用布局，不受搜索或待应用编辑影响。
    func overflowItems() -> [MenuBarEntry] {
        guard let appliedLayout else { return [] }
        let ids = appliedLayout.orderedIDs(in: .collapsed, among: entries.map(\.id))
        return ids.compactMap { id in entries.first { $0.id == id } }
    }

    /// 刷新权限及真实状态项，保留离线应用的既有规则。
    func refresh() {
        guard !isBusy, !terminating else { return }
        updatePermissions()
        guard accessibilityGranted else {
            statusMessage = "需要辅助功能权限，才能识别和整理其他软件的图标。"
            return
        }
        isBusy = true
        operationTask = Task {
            await scanAndCapture()
            guard !Task.isCancelled, !terminating else { isBusy = false; return }
            statusMessage = entries.isEmpty
                ? "暂未识别到可管理图标。请确认菜单栏可见，并检查权限后刷新。"
                : "已识别 \(entries.count) 个图标。编辑后点击“应用布局”生效。"
            isBusy = false
            if pendingLaunchRestore {
                pendingLaunchRestore = false
                if layout.managementEnabled && screenRecordingGranted && !entries.isEmpty { applyLayout() }
            }
        }
    }

    /// 请求辅助功能信任，由系统设置完成授权。
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        updatePermissions()
        if !accessibilityGranted { openPrivacySettings(accessibility: true) }
    }

    /// 请求录屏权限，只用于局部状态项图像。
    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        updatePermissions()
        if !screenRecordingGranted {
            statusMessage = "请在系统设置中开启屏幕录制权限；若已开启但仍提示未授权，请退出后重新打开本应用。"
            openPrivacySettings(accessibility: false)
        }
        else { refresh() }
    }

    /// 打开对应的系统权限页面。
    func openPrivacySettings(accessibility: Bool) {
        let pane = accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 编辑规则并原子保存；用户明确点击应用后才移动系统图标。
    func moveItem(id: String, to section: VisibilitySection, before: String? = nil) {
        guard !isBusy, !terminating, entries.first(where: { $0.id == id })?.canMove == true else { return }
        layout.move(id: id, to: section, before: before)
        // 未应用的编辑属于草稿，重启不得把草稿擅自应用到真实菜单栏。
        layout.managementEnabled = false
        statusMessage = saveLayout()
            ? "规则已保存，点击“应用布局”更新菜单栏。"
            : "规则已在窗口中更新，但保存失败。"
    }

    /// 将规则应用到真实菜单栏，只有全部可管理项目移动成功后才收纳。
    func applyLayout() {
        guard !isBusy, !terminating else { return }
        updatePermissions()
        guard accessibilityGranted else {
            errorMessage = MenuBarOperationError.accessibilityRequired.localizedDescription
            return
        }
        guard screenRecordingGranted else {
            errorMessage = "下拉面板需要屏幕录制权限来显示原图标。请授权后再应用布局。"
            return
        }
        isBusy = true
        errorMessage = nil
        dismissOverflow()
        operationTask = Task {
            setBoundaries(collapsed: false, hidden: false)
            await pause(180)
            await scanAndCapture()
            guard !Task.isCancelled, !terminating else { isBusy = false; return }
            if originalOrder.isEmpty { originalOrder = entries.sorted { $0.frame.minX < $1.frame.minX }.map(\.id) }
            do {
                try await arrangeSections()
                try Task.checkCancellation()
                updatePermissions()
                guard accessibilityGranted && screenRecordingGranted else {
                    throw MenuBarOperationError.unsupported("管理权限已撤销，所有图标保持展开。")
                }
                // 只有已确认正确顺序后，才扩大分隔项宽度隐藏指定分区。
                setBoundaries(collapsed: true, hidden: true)
                try await verifyAppliedVisibility()
                try Task.checkCancellation()
                managementActive = true
                layout.managementEnabled = true
                appliedLayout = layout
                temporarilyRevealed = false
                statusMessage = saveLayout()
                    ? "布局已应用。点击顶部“更多”查看收起的图标。"
                    : "布局已应用，但设置保存失败；重新启动后可能无法恢复。"
                NestLog.app.info("菜单栏布局应用成功。")
            } catch {
                setBoundaries(collapsed: false, hidden: false)
                managementActive = false
                appliedLayout = nil
                if !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                    statusMessage = "布局未完整应用，已展开所有分区。"
                }
                NestLog.app.error("菜单栏布局应用失败，已取消收纳。")
            }
            isBusy = false
        }
    }

    /// 面板中的图像不替代原控件；临时恢复后调用真实软件菜单。
    func activateItem(_ entry: MenuBarEntry, rightButton: Bool = false) {
        guard !isBusy, !terminating, accessibilityGranted else { return }
        dismissOverflow()
        isBusy = true
        operationTask = Task {
            setBoundaries(collapsed: false, hidden: true)
            temporarilyRevealed = true
            await pause(180)
            let live = system.scan(excludingPID: getpid()).first {
                $0.processIdentifier == entry.processIdentifier && $0.id == entry.id
            }
            do {
                try Task.checkCancellation()
                guard let live else { throw MenuBarOperationError.itemUnavailable }
                try await system.click(live, rightButton: rightButton)
                statusMessage = "已调用原软件图标。使用完后可点击“更多”重新收纳。"
                scheduleRehide()
            } catch {
                if !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                    statusMessage = "图标未能打开，已保留原位显示以便手动操作。"
                }
                NestLog.system.warning("原始状态项点击失败，保留可见状态。")
            }
            isBusy = false
        }
    }

    /// 恢复显示并尽量还原本次会话开始管理前的顺序。
    func restoreAll() {
        guard !isBusy, !terminating else { return }
        isBusy = true
        operationTask = Task {
            let orderRestored = await restoreOriginalOrder()
            guard !Task.isCancelled, !terminating else { isBusy = false; return }
            layout.reset()
            let saved = saveLayout()
            statusMessage = orderRestored && saved
                ? "全部图标已恢复显示，收纳规则已清空。"
                : "全部图标已展开；排序恢复或设置保存未完成，请查看提示。"
            isBusy = false
        }
    }

    /// 创建或重新展示本地管理窗口。
    func showManagementWindow() {
        if managementWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "菜单栏收纳"
            window.minSize = NSSize(width: 940, height: 640)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MainView(model: self))
            window.center()
            managementWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        managementWindow?.makeKeyAndOrderFront(nil)
    }

    /// 关闭下拉面板。
    func dismissOverflow() { popover.close() }

    /// 修改自动重新收纳开关。
    func setAutoCollapse(_ enabled: Bool) {
        layout.autoCollapse = enabled
        saveLayout()
        if !enabled { rehideTimer?.invalidate() }
    }

    /// 限制自动收纳延迟到安全范围，避免立即打断菜单操作。
    func setCollapseDelay(_ delay: Double) {
        layout.collapseDelay = max(3, min(60, delay))
        saveLayout()
    }

    /// 在退出前撤销收纳并尽量恢复原顺序，随后让 AppKit 完成退出。
    func prepareToTerminate() async {
        guard !terminating else { return }
        terminating = true
        pollTimer?.invalidate()
        rehideTimer?.invalidate()
        operationTask?.cancel()
        await operationTask?.value
        _ = await restoreOriginalOrder()
        for item in [moreItem, collapsedBoundary, hiddenBoundary].compactMap({ $0 }) {
            NSStatusBar.system.removeStatusItem(item)
        }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let menuObserver { DistributedNotificationCenter.default().removeObserver(menuObserver) }
        DistributedNotificationCenter.default().removeObserver(self)
        NestLog.app.info("收纳已撤销，应用退出。")
    }

    /// 只负责显示的预览数据，用于离屏渲染，不访问或移动真实状态项。
    func configurePreview() {
        accessibilityGranted = true
        screenRecordingGranted = true
        let names = ["微信", "音乐", "云同步", "剪贴板", "日历", "网络", "系统时钟"]
        let symbols = ["bubble.left.and.bubble.right.fill", "music.note", "icloud.fill", "doc.on.clipboard.fill", "calendar", "network", "clock.fill"]
        entries = zip(names.indices, names).map { index, name in
            MenuBarEntry(id: "preview-\(index)", name: name, bundleIdentifier: "preview",
                         processIdentifier: 0, windowID: UInt32(index), frame: .zero,
                         image: NSImage(systemSymbolName: symbols[index], accessibilityDescription: name),
                         canMove: index != 6, limitation: index == 6 ? "系统固定项目" : nil)
        }
        layout.reconcile(discoveredIDs: entries.map(\.id))
        layout.move(id: "preview-2", to: .collapsed, before: nil)
        layout.move(id: "preview-3", to: .collapsed, before: nil)
        layout.move(id: "preview-4", to: .hidden, before: nil)
        statusMessage = "界面预览 · 示例图标"
        appliedLayout = layout
    }

    /// 安装三个自有状态项，分隔项宽度决定左侧分区是否可见。
    private func installControls() {
        hiddenBoundary = makeBoundary(name: "HiddenBoundary", symbol: "eye.slash")
        collapsedBoundary = makeBoundary(name: "CollapsedBoundary", symbol: "chevron.left")
        moreItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        moreItem?.autosaveName = "MenuBarNest.More"
        if let button = moreItem?.button {
            button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "更多菜单栏图标")
            button.image?.isTemplate = true
            button.toolTip = "菜单栏收纳：点击展开，右键管理"
            button.target = self
            button.action = #selector(moreClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 430, height: 180)
        popover.contentViewController = NSHostingController(rootView: OverflowView(model: self))
    }

    /// 创建分隔项；未启用管理时仍保持细窄以便安全拖动。
    private func makeBoundary(name: String, symbol: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: 18)
        item.autosaveName = "MenuBarNest.\(name)"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "收纳分区边界")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "分区边界，由菜单栏收纳自动管理"
        return item
    }

    /// 使用大于所有屏幕宽度的分隔项把左侧图标挤出可见区域。
    private func setBoundaries(collapsed: Bool, hidden: Bool) {
        let screenWidth = NSScreen.screens.reduce(CGFloat(0)) { $0 + $1.frame.width }
        let expanded = max(10000, screenWidth * 2)
        collapsedBoundary?.length = collapsed ? expanded : 18
        hiddenBoundary?.length = hidden ? expanded : 18
        collapsedBoundary?.button?.image = collapsed ? nil : NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "收起区边界")
        hiddenBoundary?.button?.image = hidden ? nil : NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "隐藏区边界")
    }

    /// 按“隐藏、隐藏边界、收起、收起边界、常显、更多”的物理顺序排列。
    private func arrangeSections() async throws {
        guard let moreItem, let collapsedBoundary, let hiddenBoundary else { throw MenuBarOperationError.itemUnavailable }
        var anchor = try ownEntry(for: moreItem)
        for section in [VisibilitySection.visible, .collapsed, .hidden] {
            let ids = layout.orderedIDs(in: section, among: entries.filter(\.canMove).map(\.id))
            for id in ids.reversed() {
                try Task.checkCancellation()
                guard let source = entries.first(where: { $0.id == id }) else { continue }
                let current = system.scan(excludingPID: getpid()).first {
                    $0.processIdentifier == source.processIdentifier && $0.id == source.id
                }
                guard let current else { throw MenuBarOperationError.itemUnavailable }
                try await system.move(current, to: CGPoint(x: anchor.frame.minX + 2, y: anchor.frame.midY))
                guard let moved = system.scan(excludingPID: getpid()).first(where: {
                    $0.processIdentifier == source.processIdentifier && $0.id == source.id
                }) else {
                    throw MenuBarOperationError.itemUnavailable
                }
                anchor = moved
            }
            if section == .visible || section == .collapsed {
                let boundary = section == .visible ? collapsedBoundary : hiddenBoundary
                try await system.move(try ownEntry(for: boundary), to: CGPoint(x: anchor.frame.minX + 2, y: anchor.frame.midY))
                anchor = try ownEntry(for: boundary)
            }
        }
        await scanAndCapture()
        // 校验分隔项与各分区的左右关系，禁止仅凭事件发送认定成功。
        let leftBoundary = try ownEntry(for: hiddenBoundary).frame.midX
        let rightBoundary = try ownEntry(for: collapsedBoundary).frame.midX
        let moreX = try ownEntry(for: moreItem).frame.midX
        guard leftBoundary < rightBoundary && rightBoundary < moreX else { throw MenuBarOperationError.movementFailed }
        // 系统保护项若被分隔项挤到左侧，拒绝收纳，防止间接隐藏不可管理项。
        guard entries.filter({ !$0.canMove }).allSatisfy({ $0.frame.midX > rightBoundary }) else {
            throw MenuBarOperationError.unsupported("有系统固定图标位于收纳边界左侧，已保持全部展开。请调整顶部“更多”入口位置后重试。")
        }
        for entry in entries where entry.canMove {
            let x = entry.frame.midX
            switch layout.section(for: entry.id) {
            case .visible: guard x > rightBoundary && x < moreX else { throw MenuBarOperationError.movementFailed }
            case .collapsed: guard x > leftBoundary && x < rightBoundary else { throw MenuBarOperationError.movementFailed }
            case .hidden: guard x < leftBoundary else { throw MenuBarOperationError.movementFailed }
            }
        }
        // 分区正确仍不等于顺序正确，按真实屏幕顺序逐区核对保存的规则。
        for section in VisibilitySection.allCases {
            let movable = entries.filter { $0.canMove && layout.section(for: $0.id) == section }
            let expected = layout.orderedIDs(in: section, among: movable.map(\.id))
            guard movable.sorted(by: { $0.frame.minX < $1.frame.minX }).map(\.id) == expected else {
                throw MenuBarOperationError.movementFailed
            }
        }
    }

    /// 把自有状态项转换成系统交互层使用的 Quartz 坐标。
    private func ownEntry(for item: NSStatusItem) throws -> MenuBarEntry {
        guard let button = item.button, let window = button.window else { throw MenuBarOperationError.itemUnavailable }
        // 自有项同样使用实时 Quartz 窗口位置，避免多屏切换时混用 AppKit 坐标。
        guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]],
              let record = windows.first(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == CGWindowID(window.windowNumber) &&
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid()
              }),
              let bounds = record[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else {
            throw MenuBarOperationError.itemUnavailable
        }
        return MenuBarEntry(id: "own-\(item.autosaveName ?? "control")", name: "管理器控制项",
                            bundleIdentifier: Bundle.main.bundleIdentifier ?? "local.MenuBarNest",
                            processIdentifier: getpid(), windowID: CGWindowID(window.windowNumber),
                            frame: frame, image: nil, canMove: true, limitation: nil)
    }

    /// 连续确认真实窗口可见性；系统未完成收纳时展开所有分区并报告失败。
    private func verifyAppliedVisibility() async throws {
        let expectedEntries = entries
        var stableMatches = 0
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            try Task.checkCancellation()
            guard AXIsProcessTrusted() && CGPreflightScreenCaptureAccess() else {
                throw MenuBarOperationError.unsupported("管理权限已撤销，所有图标保持展开。")
            }
            // 由系统适配层观察当前逻辑项，不把旧 CG 编号或副本重新解释为真实图标。
            let currentEntries = system.scan(excludingPID: getpid())
            let displays = NSScreen.screens.compactMap { screen -> CGRect? in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                let bounds = CGDisplayBounds(number.uint32Value)
                guard !bounds.isEmpty, !bounds.isNull else { return nil }
                return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: NSStatusBar.system.thickness)
            }
            // 逻辑身份与所属进程必须一致；仅缓存身份而无实时窗口证据不能算验证成功。
            let matches = expectedEntries.allSatisfy { entry in
                guard let current = currentEntries.first(where: {
                    $0.id == entry.id && $0.processIdentifier == entry.processIdentifier
                }), current.windowID != kCGNullWindowID, let onScreen = current.isOnScreen else { return false }
                let frame = current.frame
                let intersectsBar = displays.contains {
                    let intersection = $0.intersection(frame)
                    return !intersection.isNull && intersection.width > 1 && intersection.height > 1
                }
                if entry.canMove && layout.section(for: entry.id) != .visible {
                    return !onScreen || !intersectsBar
                }
                // 常显项必须完整处于菜单栏宽度内，防止把被挤出屏幕当成正常显示。
                return onScreen && displays.contains {
                    $0.minX - 1 <= frame.minX && frame.maxX <= $0.maxX + 1 &&
                    abs($0.midY - frame.midY) <= 6
                }
            }
            stableMatches = matches ? stableMatches + 1 : 0
            if stableMatches >= 3 {
                NestLog.system.debug("常显及收纳分区的实际可见性已确认。")
                return
            }
        }
        NestLog.system.warning("分区实际可见性未达到预期，取消收纳。")
        throw MenuBarOperationError.unsupported("系统未确认各分区的显示状态，已保持展开。请减少常显图标或调整入口位置后重试。")
    }

    /// 扫描时复用已采集图像；未授予录屏权限不调用截图 API。
    private func scanAndCapture() async {
        let previous = Dictionary(entries.map { ($0.id, $0.image) }, uniquingKeysWith: { first, _ in first })
        var fresh = system.scan(excludingPID: getpid())
        if screenRecordingGranted {
            for index in fresh.indices {
                guard !Task.isCancelled else { return }
                fresh[index].image = await system.captureIcon(for: fresh[index]) ?? previous[fresh[index].id] ?? nil
            }
        }
        guard !Task.isCancelled else { return }
        entries = fresh
        layout.reconcile(discoveredIDs: fresh.map(\.id))
        NestLog.system.debug("状态项扫描完成，数量 \(fresh.count, privacy: .public)。")
    }

    /// 保存失败时明确提示，禁止把内存编辑状态宣称为持久化成功。
    @discardableResult private func saveLayout() -> Bool {
        guard configurationReadable else {
            errorMessage = "原配置无法读取，已阻止覆盖。请先在本机备份并修复配置后重新启动。"
            return false
        }
        do { try repository.save(layout); return true }
        catch {
            errorMessage = "设置保存失败：\(error.localizedDescription)"
            NestLog.app.error("布局保存失败。")
            return false
        }
    }

    /// 定时检查授权撤销；发现撤销立即取消收纳，避免图标不可访问。
    private func poll() {
        updatePermissions()
        if !(accessibilityGranted && screenRecordingGranted) && (managementActive || isBusy) {
            operationTask?.cancel()
            setBoundaries(collapsed: false, hidden: false)
            managementActive = false
            appliedLayout = nil
            statusMessage = "权限已撤销，已暂停收纳并恢复图标显示。"
            NestLog.system.warning("管理权限撤销，已暂停收纳。")
        }
        guard accessibilityGranted, !isBusy, !terminating else { return }
        let live = system.scan(excludingPID: getpid())
        // 新项目可能落在宽分隔项左侧，项目增减时先展开，防止入口不可访问。
        let currentIDs = Set(entries.map(\.id))
        if Set(live.map(\.id)) != currentIDs {
            setBoundaries(collapsed: false, hidden: false)
            managementActive = false
            appliedLayout = nil
            temporarilyRevealed = false
            rehideTimer?.invalidate()
            layout.reconcile(discoveredIDs: live.map(\.id))
            statusMessage = "菜单栏项目已变化，分区已展开；请刷新并重新应用布局。"
            NestLog.system.info("状态项清单变化，已展开分区等待重新应用。")
        }
        // 窗口映射变化不代表新增图标；每次观察都更新位置，并沿用同一逻辑项的图像。
        let images = Dictionary(entries.map { ($0.id, $0.image) }, uniquingKeysWith: { first, _ in first })
        entries = live.map { entry in var entry = entry; entry.image = images[entry.id] ?? nil; return entry }
    }

    /// 屏幕变化后展开分区，并要求按新布局重新确认应用。
    private func screenConfigurationChanged() {
        operationTask?.cancel()
        setBoundaries(collapsed: false, hidden: false)
        managementActive = false
        appliedLayout = nil
        statusMessage = "屏幕布局已变化，图标已展开；请重新应用布局。"
        NestLog.system.info("屏幕参数变化，已暂停收纳。")
    }

    /// 刷新系统权限，不自动发起新的授权请求。
    private func updatePermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    /// 根据点击类型打开面板或管理菜单。
    @objc private func moreClicked() {
        guard let button = moreItem?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "管理菜单栏图标…", action: #selector(openManagement), keyEquivalent: "")
            menu.addItem(withTitle: "重新收起图标", action: #selector(collapseNow), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "恢复全部图标", action: #selector(restoreClicked), keyEquivalent: "")
            menu.addItem(withTitle: "退出菜单栏收纳", action: #selector(quitClicked), keyEquivalent: "")
            menu.items.forEach { $0.target = self }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            return
        }
        if temporarilyRevealed { collapseNow() }
        if popover.isShown { dismissOverflow() }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    /// 菜单动作：显示管理窗口。
    @objc private func openManagement() { showManagementWindow() }
    /// 菜单动作：恢复全部。
    @objc private func restoreClicked() { restoreAll() }
    /// 菜单动作：触发受控退出。
    @objc private func quitClicked() { NSApp.terminate(nil) }
    /// 明确用户点击后立即重新收纳。
    @objc private func collapseNow() {
        guard managementActive else { return }
        setBoundaries(collapsed: true, hidden: true)
        temporarilyRevealed = false
        rehideTimer?.invalidate()
        statusMessage = "收起区已重新收纳。"
    }
    /// 收到原软件菜单跟踪结束通知，允许重新收纳。
    @objc private func menuTrackingEnded() { menuTracking = false }

    /// 自动收纳时避开仍打开的弹出菜单及正在按下的鼠标按钮。
    private func scheduleRehide() {
        rehideTimer?.invalidate()
        guard layout.autoCollapse else { return }
        rehideTimer = Timer.scheduledTimer(withTimeInterval: layout.collapseDelay, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.managementActive, self.temporarilyRevealed else { return }
                guard !self.menuTracking, NSEvent.pressedMouseButtons == 0, !self.hasVisibleMenuWindow() else { return }
                self.collapseNow()
            }
        }
    }

    /// 使用窗口层级保守判断是否仍有系统弹出菜单，避免打断选择。
    private func hasVisibleMenuWindow() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return true }
        return windows.contains { window in
            let level = window[kCGWindowLayer as String] as? Int ?? 0
            let owner = window[kCGWindowOwnerPID as String] as? Int32 ?? 0
            return owner != getpid() && level == Int(CGWindowLevelForKey(.popUpMenuWindow))
        }
    }

    /// 撤掉收纳边界后，以初始顺序恢复可移动项目；失败时仍保持全部可见。
    private func restoreOriginalOrder() async -> Bool {
        setBoundaries(collapsed: false, hidden: false)
        managementActive = false
        appliedLayout = nil
        temporarilyRevealed = false
        rehideTimer?.invalidate()
        await pause(120)
        guard !Task.isCancelled else { return false }
        guard accessibilityGranted, !originalOrder.isEmpty, let moreItem else { return originalOrder.isEmpty }
        do {
            var anchor = try ownEntry(for: moreItem)
            for id in originalOrder.reversed() {
                try Task.checkCancellation()
                guard let entry = system.scan(excludingPID: getpid()).first(where: { $0.id == id }) else { continue }
                // 固定项作为相对位置锚点但绝不拖动，恢复其与应用图标原有穿插关系。
                if !entry.canMove { anchor = entry; continue }
                try await system.move(entry, to: CGPoint(x: anchor.frame.minX + 2, y: anchor.frame.midY))
                if let moved = system.scan(excludingPID: getpid()).first(where: {
                    $0.id == entry.id && $0.processIdentifier == entry.processIdentifier
                }) { anchor = moved }
            }
            originalOrder.removeAll()
            return true
        } catch {
            errorMessage = "图标已展开，原始排序未能完整恢复：\(error.localizedDescription)"
            NestLog.system.warning("原始顺序恢复未完成，所有分区保持可见。")
            return false
        }
    }

    /// 给 Window Server 留出短暂布局时间，不阻塞主线程。
    private func pause(_ milliseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}

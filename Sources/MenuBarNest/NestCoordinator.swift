import AppKit
import ApplicationServices
import Combine
import NestCore
import SwiftUI

/// 负责布局持久化、原生菜单栏同一行开合、状态项分区与权限生命周期。
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
    @Published var isBusy = false { didSet { updateControlAppearance() } }
    /// 可供用户了解操作结果的状态文本。
    @Published var statusMessage = "请授权后刷新菜单栏图标。"
    /// 保存或系统操作失败的明确说明。
    @Published var errorMessage: String?
    /// 表示真实菜单栏已按规则完成分区。
    @Published var managementActive = false { didSet { updateControlAppearance() } }
    /// 经实时窗口证据确认的同一行展开状态，忙碌期间保留最后成功状态。
    @Published private(set) var inlineExpanded = false { didSet { updateControlAppearance() } }
    /// 当前实际应用的布局；尚未应用的编辑不改变真实菜单栏分区。
    @Published private(set) var appliedLayout: LayoutState?
    /// 管理窗口搜索文本。
    @Published var query = ""
    /// 管理窗口当前选择的分区。
    @Published var selectedSection: VisibilitySection?

    /// 系统交互适配器，便于替换为测试实现。
    private let system: any MenuBarSystemManaging
    /// 同一行开合的匿名测试观察点，生产运行使用真实权限及自有状态项。
    private let inlineEnvironment: InlineMenuBarEnvironment?
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
    /// 设置窗口。
    private var managementWindow: NSWindow?
    /// 用于权限刷新及退出应用项目检测的计时器。
    private var pollTimer: Timer?
    /// 同一行展开后检查是否可以安全自动收起。
    private var rehideTimer: Timer?
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
    init(system: (any MenuBarSystemManaging)? = nil, preview: Bool = false,
         inlineEnvironment: InlineMenuBarEnvironment? = nil) {
        self.system = system ?? MenuBarSystem()
        self.inlineEnvironment = inlineEnvironment
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
                if layout.managementEnabled && !entries.isEmpty { applyLayout() }
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

    /// 请求可选录屏权限，只用于管理窗口内的局部原图预览。
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
        isBusy = true
        errorMessage = nil
        rehideTimer?.invalidate()
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
                guard accessibilityGranted else {
                    throw MenuBarOperationError.unsupported("管理权限已撤销，所有图标保持展开。")
                }
                // 只有已确认正确顺序后，才扩大分隔项宽度隐藏指定分区。
                setBoundaries(collapsed: true, hidden: true)
                entries = try await verifyInlineVisibility(expanded: false, expected: entries, applied: layout)
                try Task.checkCancellation()
                managementActive = true
                layout.managementEnabled = true
                appliedLayout = layout
                inlineExpanded = false
                statusMessage = saveLayout()
                    ? "布局已应用。点击顶部箭头，在菜单栏同一行展开或收起图标。"
                    : "布局已应用，但设置保存失败；重新启动后可能无法恢复。"
                NestLog.app.info("菜单栏布局应用成功。")
            } catch {
                setBoundaries(collapsed: false, hidden: false)
                managementActive = false
                appliedLayout = nil
                inlineExpanded = false
                if !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                    statusMessage = "布局未完整应用，已展开所有分区。"
                }
                NestLog.app.error("菜单栏布局应用失败，已取消收纳。")
            }
            isBusy = false
        }
    }

    /// 显式定位请求先恢复真实图标，再按逻辑身份调用原软件菜单。
    func activateItem(_ entry: MenuBarEntry, rightButton: Bool = false) {
        guard !isBusy, !terminating, accessibilityGranted else { return }
        isBusy = true
        operationTask = Task {
            setBoundaries(collapsed: false, hidden: true)
            await pause(180)
            let live = system.scan(excludingPID: getpid()).first {
                $0.processIdentifier == entry.processIdentifier && $0.id == entry.id
            }
            do {
                try Task.checkCancellation()
                guard let live else { throw MenuBarOperationError.itemUnavailable }
                if managementActive, let appliedLayout {
                    entries = try await verifyInlineVisibility(expanded: true, expected: entries, applied: appliedLayout)
                    inlineExpanded = true
                }
                try await system.click(live, rightButton: rightButton)
                statusMessage = "已调用原软件图标。使用完后可点击顶部箭头收起。"
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

    /// 只改变原生分隔项长度；实时确认成功后才切换开合状态，连续点击不重入。
    func toggleInlineExpansion() {
        guard !isBusy, !terminating else { return }
        guard managementActive, let appliedLayout else {
            statusMessage = "请先在管理窗口应用布局，再使用顶部箭头展开图标。"
            return
        }
        updatePermissions()
        guard accessibilityGranted else {
            suspendManagement(message: "辅助功能权限已撤销，已暂停管理并展开所有分区。")
            return
        }
        let previousExpanded = inlineExpanded
        let requestedExpanded = !previousExpanded
        let expected = entries
        isBusy = true
        errorMessage = nil
        rehideTimer?.invalidate()
        operationTask = Task {
            // 普通开合只切换收起区，始终隐藏边界在两种状态下均保持收纳。
            setBoundaries(collapsed: !requestedExpanded, hidden: true)
            do {
                entries = try await verifyInlineVisibility(expanded: requestedExpanded, expected: expected, applied: appliedLayout)
                try Task.checkCancellation()
                inlineExpanded = requestedExpanded
                statusMessage = requestedExpanded
                    ? "收起区已在菜单栏同一行展开，再次点击顶部箭头收起。"
                    : "收起区已收起，常显区继续显示。"
                if requestedExpanded { scheduleRehide() }
                NestLog.app.info("原生菜单栏开合已确认，展开状态 \(requestedExpanded, privacy: .public)。")
            } catch {
                // 生命周期取消由退出或权限处理恢复；不得让旧任务重新扩大分隔项。
                guard !(error is CancellationError), !Task.isCancelled, !terminating else {
                    isBusy = false
                    return
                }
                updatePermissions()
                guard accessibilityGranted, managementActive else {
                    suspendManagement(message: "管理状态已变化，已展开所有分区。")
                    isBusy = false
                    return
                }
                let failureMessage = error.localizedDescription
                setBoundaries(collapsed: !previousExpanded, hidden: true)
                do {
                    entries = try await verifyInlineVisibility(expanded: previousExpanded, expected: expected, applied: appliedLayout)
                    inlineExpanded = previousExpanded
                    errorMessage = failureMessage
                    statusMessage = previousExpanded ? "开合未完成，已保留展开状态。" : "开合未完成，已恢复收起状态。"
                    if previousExpanded { scheduleRehide() }
                    NestLog.system.warning("菜单栏开合未确认，已恢复上一次成功状态。")
                } catch {
                    guard !(error is CancellationError), !Task.isCancelled, !terminating else {
                        isBusy = false
                        return
                    }
                    suspendManagement(message: "系统未确认恢复状态，已暂停管理并展开所有分区。")
                    errorMessage = failureMessage
                    NestLog.system.error("开合与状态恢复均未确认，已取消收纳。")
                }
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

    /// 修改自动重新收纳开关。
    func setAutoCollapse(_ enabled: Bool) {
        layout.autoCollapse = enabled
        saveLayout()
        if !enabled { rehideTimer?.invalidate() }
        else if inlineExpanded { scheduleRehide() }
    }

    /// 限制自动收纳延迟到安全范围，避免立即打断菜单操作。
    func setCollapseDelay(_ delay: Double) {
        layout.collapseDelay = max(3, min(60, delay))
        saveLayout()
        if inlineExpanded { scheduleRehide() }
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
        hiddenBoundary = makeBoundary(name: "HiddenBoundary")
        collapsedBoundary = makeBoundary(name: "CollapsedBoundary")
        moreItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        moreItem?.autosaveName = "MenuBarNest.More"
        if let button = moreItem?.button {
            button.target = self
            button.action = #selector(moreClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateControlAppearance()
    }

    /// 按已确认状态更新唯一可见控制按钮，系统操作期间禁止再次触发。
    private func updateControlAppearance() {
        guard let button = moreItem?.button else { return }
        let symbol = managementActive ? (inlineExpanded ? "chevron.right" : "chevron.left") : "slider.horizontal.3"
        let action = managementActive ? (inlineExpanded ? "收起图标" : "展开图标") : "管理菜单栏图标"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: action)
        button.image?.isTemplate = true
        button.toolTip = "\(action) · 右键打开管理菜单"
        button.isEnabled = !isBusy && !terminating
    }

    /// 创建透明细分隔项，只由唯一入口控制，不额外显示边界按钮。
    private func makeBoundary(name: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: 1)
        item.autosaveName = "MenuBarNest.\(name)"
        item.button?.toolTip = "分区边界，由菜单栏收纳自动管理"
        return item
    }

    /// 使用大于所有屏幕宽度的分隔项把左侧图标挤出可见区域。
    private func setBoundaries(collapsed: Bool, hidden: Bool) {
        if let inlineEnvironment {
            inlineEnvironment.updateBoundaries(collapsed, hidden)
            return
        }
        let screenWidth = NSScreen.screens.reduce(CGFloat(0)) { $0 + $1.frame.width }
        let expanded = max(10000, screenWidth * 2)
        collapsedBoundary?.length = collapsed ? expanded : 1
        hiddenBoundary?.length = hidden ? expanded : 1
        collapsedBoundary?.button?.image = nil
        hiddenBoundary?.button?.image = nil
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
            throw MenuBarOperationError.unsupported("有系统固定图标位于收纳边界左侧，已保持全部展开。请调整顶部入口位置后重试。")
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
                            frame: frame, image: nil, canMove: true, limitation: nil,
                            isOnScreen: record[kCGWindowIsOnscreen as String] as? Bool)
    }

    /// 连续确认入口所在菜单栏行的真实状态，不把副屏副本或未知窗口当作成功。
    private func verifyInlineVisibility(expanded: Bool, expected: [MenuBarEntry], applied: LayoutState) async throws -> [MenuBarEntry] {
        var stableMatches = 0
        var lastResult = InlineVisibilityPolicy.VerificationResult.unresolved
        let previousImages = Dictionary(entries.map { ($0.id, $0.image) }, uniquingKeysWith: { first, _ in first })
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            try Task.checkCancellation()
            updatePermissions()
            guard accessibilityGranted else {
                throw MenuBarOperationError.unsupported("管理权限已撤销，所有图标保持展开。")
            }
            // 每次按逻辑身份和进程匹配，新旧窗口编号变化不等同于图标增减。
            var currentEntries = system.scan(excludingPID: getpid())
            lastResult = inlineVisibilityResult(current: currentEntries, expected: expected, applied: applied, expanded: expanded)
            stableMatches = lastResult == .confirmed ? stableMatches + 1 : 0
            if stableMatches >= 3 {
                for index in currentEntries.indices {
                    currentEntries[index].image = screenRecordingGranted ? previousImages[currentEntries[index].id] ?? nil : nil
                }
                NestLog.system.debug("入口及各分区的同一行可见状态已连续确认。")
                return currentEntries
            }
        }
        NestLog.system.warning("系统未确认所请求的同一行可见状态。")
        throw MenuBarOperationError.unsupported(lastResult == .insufficientSpace
            ? "菜单栏空间不足，无法完整显示所需图标和入口。请减少展开图标或切换菜单较短的应用后重试。"
            : "系统未确认各分区的显示状态，请确认菜单栏可见后刷新并重新应用布局。")
    }

    /// 把同一逻辑项的实时窗口证据交给纯规则校验，不使用历史可见性补齐缺失值。
    private func inlineVisibilityResult(current: [MenuBarEntry], expected: [MenuBarEntry], applied: LayoutState,
                                        expanded: Bool) -> InlineVisibilityPolicy.VerificationResult {
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(current.map(\.id))
        let mappingConfirmed = currentIDs.count == current.count && currentIDs == Set(expected.map(\.id)) && expected.allSatisfy { old in
            guard let entry = currentByID[old.id] else { return false }
            return entry.processIdentifier == old.processIdentifier && entry.windowID != kCGNullWindowID && entry.isOnScreen != nil
        }
        guard mappingConfirmed, let control = currentControllerEntry(), control.windowID != kCGNullWindowID,
              let controlOnScreen = control.isOnScreen else { return .unresolved }
        guard controlOnScreen else { return .insufficientSpace }
        let observed = current.map {
            InlineVisibilityPolicy.ObservedItem(id: $0.id, onScreen: $0.isOnScreen, frame: $0.frame,
                section: applied.section(for: $0.id), canMove: $0.canMove)
        }
        return InlineVisibilityPolicy.verify(items: observed, menuBarStrips: currentMenuBarStrips(),
            controllerFrame: control.frame, isExpanded: expanded)
    }

    /// 读取控制入口的真实原始窗口，测试时仅返回合成观察。
    private func currentControllerEntry() -> MenuBarEntry? {
        if let inlineEnvironment { return inlineEnvironment.controller() }
        guard let moreItem else { return nil }
        return try? ownEntry(for: moreItem)
    }

    /// 获取各显示器当前的菜单栏几何，不缓存旧分辨率或旧显示器排列。
    private func currentMenuBarStrips() -> [CGRect] {
        if let inlineEnvironment { return inlineEnvironment.menuBarStrips() }
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let bounds = CGDisplayBounds(number.uint32Value)
            guard !bounds.isEmpty, !bounds.isNull else { return nil }
            return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: NSStatusBar.system.thickness)
        }
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
        updatePermissions()
        if !screenRecordingGranted {
            // 可选录屏中途撤销时不沿用缓存原图，界面改用应用图标。
            for index in fresh.indices { fresh[index].image = nil }
        }
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
        let previouslyRecorded = screenRecordingGranted
        updatePermissions()
        if previouslyRecorded && !screenRecordingGranted {
            // 录屏仅影响原图预览，撤销后清除图像而不停止原生同一行开合。
            for index in entries.indices { entries[index].image = nil }
            NestLog.app.info("可选原图预览权限已撤销，同一行管理继续运行。")
        }
        if !accessibilityGranted && (managementActive || isBusy) {
            suspendManagement(message: "辅助功能权限已撤销，已暂停收纳并恢复图标显示。")
            NestLog.system.warning("辅助功能权限撤销，已暂停收纳。")
        }
        guard accessibilityGranted, !isBusy, !terminating else { return }
        let live = system.scan(excludingPID: getpid())
        // 新项目可能落在宽分隔项左侧，项目增减时先展开，防止入口不可访问。
        let currentIDs = Set(entries.map(\.id))
        let oldProcesses = Dictionary(entries.map { ($0.id, $0.processIdentifier) }, uniquingKeysWith: { first, _ in first })
        if Set(live.map(\.id)) != currentIDs || live.contains(where: { oldProcesses[$0.id] != $0.processIdentifier }) {
            suspendManagement(message: "菜单栏项目已变化，分区已展开；请刷新并重新应用布局。")
            layout.reconcile(discoveredIDs: live.map(\.id))
            NestLog.system.info("状态项清单变化，已展开分区等待重新应用。")
        }
        // 窗口映射变化不代表新增图标；每次观察都更新位置，并沿用同一逻辑项的图像。
        let images = Dictionary(entries.map { ($0.id, $0.image) }, uniquingKeysWith: { first, _ in first })
        if managementActive, let appliedLayout,
           inlineVisibilityResult(current: live, expected: entries, applied: appliedLayout, expanded: inlineExpanded) == .insufficientSpace {
            // 长应用菜单挤出展开组时，等原菜单关闭再退回较窄的收起态。
            if inlineExpanded, !menuInteractionActive() {
                toggleInlineExpansion()
            } else {
                errorMessage = "当前菜单栏空间不足，请减少常显图标或切换菜单较短的应用。"
            }
        }
        entries = live.map { entry in var entry = entry; entry.image = images[entry.id] ?? nil; return entry }
    }

    /// 屏幕变化后展开分区，并要求按新布局重新确认应用。
    private func screenConfigurationChanged() {
        suspendManagement(message: "屏幕布局已变化，图标已展开；请重新应用布局。")
        NestLog.system.info("屏幕参数变化，已暂停收纳。")
    }

    /// 权限撤销、显示器变化或恢复失败时取消任务并安全撤销分隔项。
    private func suspendManagement(message: String) {
        operationTask?.cancel()
        rehideTimer?.invalidate()
        setBoundaries(collapsed: false, hidden: false)
        managementActive = false
        appliedLayout = nil
        inlineExpanded = false
        statusMessage = message
        NestLog.app.warning("菜单栏管理已暂停，自有分隔项已撤销。")
    }

    /// 刷新系统权限，不自动发起新的授权请求。
    private func updatePermissions() {
        if let inlineEnvironment {
            let permissions = inlineEnvironment.permissions()
            accessibilityGranted = permissions.accessibility
            screenRecordingGranted = permissions.screenRecording
            return
        }
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    /// 左键切换原生同一行开合，右键打开管理菜单。
    @objc private func moreClicked() {
        guard let button = moreItem?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(withTitle: "管理菜单栏图标…", action: #selector(openManagement), keyEquivalent: "")
            let toggleItem = menu.addItem(withTitle: inlineExpanded ? "收起图标" : "展开图标", action: #selector(toggleClicked), keyEquivalent: "")
            toggleItem.isEnabled = managementActive && !isBusy
            menu.addItem(.separator())
            menu.addItem(withTitle: "恢复全部图标", action: #selector(restoreClicked), keyEquivalent: "")
            menu.addItem(withTitle: "退出菜单栏收纳", action: #selector(quitClicked), keyEquivalent: "")
            menu.items.forEach { $0.target = self }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            return
        }
        if managementActive { toggleInlineExpansion() }
        else { showManagementWindow() }
    }

    /// 菜单动作：显示管理窗口。
    @objc private func openManagement() { showManagementWindow() }
    /// 菜单动作：恢复全部。
    @objc private func restoreClicked() { restoreAll() }
    /// 菜单动作：触发受控退出。
    @objc private func quitClicked() { NSApp.terminate(nil) }
    /// 管理菜单调用与左键一致的验证开合流程。
    @objc private func toggleClicked() { toggleInlineExpansion() }
    /// 自动收纳只请求关闭已展开状态，不在菜单操作期间切换。
    @objc private func collapseNow() {
        guard managementActive, inlineExpanded, !isBusy, !menuInteractionActive() else { return }
        toggleInlineExpansion()
    }
    /// 收到原软件菜单跟踪结束通知，允许重新收纳。
    @objc private func menuTrackingEnded() { menuTracking = false }

    /// 自动收纳时避开仍打开的弹出菜单及正在按下的鼠标按钮。
    private func scheduleRehide() {
        rehideTimer?.invalidate()
        guard layout.autoCollapse else { return }
        rehideTimer = Timer.scheduledTimer(withTimeInterval: layout.collapseDelay, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.managementActive, self.inlineExpanded, !self.isBusy else { return }
                guard !self.menuInteractionActive() else { return }
                self.collapseNow()
            }
        }
    }

    /// 菜单跟踪和鼠标按下期间推迟自动收起，未知窗口清单也保守等待。
    private func menuInteractionActive() -> Bool {
        if let inlineEnvironment { return inlineEnvironment.menuInteractionActive() }
        return menuTracking || NSEvent.pressedMouseButtons != 0 || hasVisibleMenuWindow()
    }

    /// 使用窗口层级保守判断是否仍有系统弹出菜单，避免打断选择。
    private func hasVisibleMenuWindow() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return true }
        return windows.contains { window in
            let level = window[kCGWindowLayer as String] as? Int ?? 0
            return level == Int(CGWindowLevelForKey(.popUpMenuWindow))
        }
    }

    /// 撤掉收纳边界后，以初始顺序恢复可移动项目；失败时仍保持全部可见。
    private func restoreOriginalOrder() async -> Bool {
        setBoundaries(collapsed: false, hidden: false)
        managementActive = false
        appliedLayout = nil
        inlineExpanded = false
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

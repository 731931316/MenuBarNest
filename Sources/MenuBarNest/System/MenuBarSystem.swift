import AppKit
import ApplicationServices
import ScreenCaptureKit

/// 通过公开窗口、辅助功能和事件接口管理原始菜单栏状态项。
@MainActor
final class MenuBarSystem: MenuBarSystemManaging {
    /// 从窗口清单中提取的状态项元数据；不采集普通应用窗口的内容。
    struct WindowRecord {
        /// Window Server 为本次运行分配的窗口编号。
        let id: CGWindowID
        /// 当前窗口所属进程。
        let pid: pid_t
        /// 窗口当前的 Quartz 坐标。
        let frame: CGRect
        /// 系统提供的窗口名称，权限不足时可能为空。
        let title: String
        /// 窗口所在层级，用于排除应用主窗口。
        let layer: Int
        /// 系统是否报告窗口位于屏幕上，避免点击自动隐藏中的菜单栏。
        let isOnScreen: Bool
    }

    /// 辅助功能返回的一个状态项身份及位置。
    struct AccessibleItem {
        /// 真实辅助功能元素，用于区分同名状态项并保持本会话身份。
        let element: AXUIElement
        /// 软件提供的辅助功能标识，可能为空。
        let identifier: String
        /// 辅助功能标题或描述，用于名称与回退身份。
        let name: String
        /// 状态项在 Quartz 坐标中的位置。
        let frame: CGRect
    }

    /// 进程身份元数据；测试可注入匿名信息而不访问真实应用清单。
    struct ApplicationInfo {
        /// 软件标识，用于兼容已保存的布局键。
        let bundleIdentifier: String
        /// 对用户展示的软件名称，不写入日志。
        let name: String
        /// 本次进程启动时间，用于识别同 PID、同软件的进程重启。
        let launchDate: Date?

        /// 创建真实或匿名进程身份，未提供启动时间时只保证 PID 与软件标识一致。
        init(bundleIdentifier: String, name: String, launchDate: Date? = nil) {
            self.bundleIdentifier = bundleIdentifier
            self.name = name
            self.launchDate = launchDate
        }
    }

    /// 当前会话中逻辑状态项的身份，与当前操作窗口编号相互独立。
    private struct CachedIdentity {
        /// 身份当前所属进程，避免窗口编号复用时错配。
        let pid: pid_t
        /// 防止同 PID 被另一软件复用后沿用旧身份。
        let bundleIdentifier: String
        /// 防止同 PID、同软件重启后复用旧窗口绑定。
        let launchDate: Date?
        /// 已分配的身份键。
        let id: String
        /// 缺少稳定身份时给用户的提示。
        let warning: String?
    }

    /// 已识别的一个真实状态项及其最后验证的操作窗口。
    private struct CachedLogicalItem {
        /// 不随窗口切换或图标移动改变的逻辑身份。
        let identity: CachedIdentity
        /// 无 AX 回退项为空；有 AX 项按元素等价关系优先复用。
        let element: AXUIElement?
        /// 仅在同进程中唯一时才用作元素重建后的匹配依据。
        let identifier: String
        /// 当前已绑定的操作窗口；未确认窗口时为空。
        let windowID: CGWindowID?
        /// 是否由 AX 或自有 AppKit 窗口证明为真实状态项。
        let verified: Bool
        /// AX 在收起后暂不返回元素时仍可保留的名称。
        let name: String
    }

    /// 匿名窗口数据注入点；生产环境为空并使用公开 CG API。
    private let windowRecordsProvider: ((CGWindowListOption, CGWindowID) -> [WindowRecord])?
    /// 匿名 AX 元素注入点；注入后不读取人工元素属性。
    private let accessibleItemsProvider: ((pid_t) -> [AccessibleItem])?
    /// 匿名显示器条带注入点，避免测试依赖本机屏幕布局。
    private let menuBarStripsProvider: (() -> [CGRect])?
    /// 匿名进程身份注入点，避免测试访问个人应用名称。
    private let applicationInfoProvider: ((pid_t) -> ApplicationInfo)?
    /// 已验证窗口对应的旧身份键，用于布局兼容和窗口切换。
    private var identities = [CGWindowID: CachedIdentity]()
    /// 真实状态项缓存；不把多屏副本或内部代理缓存为新的逻辑项。
    private var logicalItems = [CachedLogicalItem]()
    /// 最近获取的共享窗口对象，逐图标截图时复用。
    private var shareableContent: SCShareableContent?
    /// 共享窗口元数据的缓存时间。
    private var shareableContentDate = Date.distantPast
    /// 合并同时到来的共享窗口查询。
    private var shareableContentTask: Task<SCShareableContent, Error>?
    /// 防止并发拖动、点击互相干扰。
    private var operationInFlight = false
    /// 节流截图失败日志，避免逐图标重复打印。
    private var lastCaptureWarningDate = Date.distantPast
    /// 仅在未确认窗口数量变化时输出警告，避免周期扫描重复告警。
    private var lastUnresolvedWindowCount = 0

    /// 配置公开系统适配或匿名数据源；不在初始化时读取窗口、发送事件或请求权限。
    init(windowRecordsProvider: ((CGWindowListOption, CGWindowID) -> [WindowRecord])? = nil,
         accessibleItemsProvider: ((pid_t) -> [AccessibleItem])? = nil,
         menuBarStripsProvider: (() -> [CGRect])? = nil,
         applicationInfoProvider: ((pid_t) -> ApplicationInfo)? = nil) {
        self.windowRecordsProvider = windowRecordsProvider
        self.accessibleItemsProvider = accessibleItemsProvider
        self.menuBarStripsProvider = menuBarStripsProvider
        self.applicationInfoProvider = applicationInfoProvider
    }

    /// 按真实 AX 状态项逐项建模，CG 窗口仅用于映射截图及交互目标。
    func scan(excludingPID: pid_t) -> [MenuBarEntry] {
        let allRecords = windowRecords(options: [.optionAll, .excludeDesktopElements])
        let statusRecords = allRecords.filter { $0.pid != excludingPID && hasStatusWindowShape($0) }
        let records = statusRecords.filter(isStatusWindow)
        let previousItems = logicalItems
        let pids = Set(statusRecords.map(\.pid)).union(previousItems.map { $0.identity.pid }).subtracting([excludingPID])
        let applications = Dictionary(uniqueKeysWithValues: pids.map { ($0, applicationInfo(for: $0)) })
        let liveRecords = Dictionary(allRecords.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 窗口编号复用、进程重启或软件身份变化时，必须先撤销旧操作绑定。
        identities = identities.filter { id, cached in
            guard let record = liveRecords[id], let application = applications[cached.pid] else { return false }
            return record.pid == cached.pid && sameProcess(cached, pid: record.pid, application: application)
        }
        let fallbackStrip = fallbackMenuBarStrip(excludingPID: excludingPID, allRecords: allRecords)
        var nextItems = [CachedLogicalItem]()
        var entries = [MenuBarEntry]()
        var claimedWindows = Set<CGWindowID>()
        var claimedIdentities = Set<String>()

        for pid in pids.sorted() {
            guard let application = applications[pid] else { continue }
            let processRecords = records.filter { $0.pid == pid }
            let oldItems = previousItems.filter { sameProcess($0.identity, pid: pid, application: application) }
            let accessible = accessibleItems(for: pid)
            var usedOldIDs = Set<String>()
            for (index, item) in accessible.enumerated() {
                let old = cachedItem(for: item, among: oldItems, currentItems: accessible,
                    records: processRecords, excluding: usedOldIDs)
                if let old { usedOldIDs.insert(old.identity.id) }
                let selected = operationWindow(for: item, cached: old, among: processRecords, excluding: claimedWindows)
                let identity = logicalIdentity(pid: pid, application: application, accessible: item, record: selected,
                    preferred: old?.identity, group: processRecords, excluding: claimedIdentities)
                claimedIdentities.insert(identity.id)
                if let selected {
                    claimedWindows.insert(selected.id)
                    identities[selected.id] = identity
                }
                let name = displayName(accessible: item, record: selected, application: application,
                    ordinal: index + 1, itemCount: accessible.count)
                let mappingLimitation = selected == nil ? "尚未确认这个状态项的真实操作窗口，请展开菜单栏后刷新。" : nil
                let protectedReason = managementLimitation(bundle: application.bundleIdentifier,
                    title: selected?.title ?? "", accessible: item)
                entries.append(makeEntry(identity: identity, application: application, accessible: item, record: selected,
                    name: name, restriction: mappingLimitation ?? protectedReason))
                nextItems.append(CachedLogicalItem(identity: identity, element: item.element, identifier: item.identifier,
                    windowID: selected?.id ?? old?.windowID, verified: selected != nil || old?.verified == true, name: name))
            }

            // AX 收起期间可能暂时不枚举元素；只保留曾验证且同一真实窗口已移出屏幕的项。
            for old in oldItems where !usedOldIDs.contains(old.identity.id) && old.verified {
                guard let id = old.windowID, !claimedWindows.contains(id),
                      let record = processRecords.first(where: { $0.id == id }), retainedHiddenWindow(record) else { continue }
                let protectedReason = managementLimitation(bundle: application.bundleIdentifier, title: record.title, accessible: nil)
                entries.append(makeEntry(identity: old.identity, application: application, accessible: nil, record: record,
                    name: old.name, restriction: protectedReason))
                nextItems.append(old)
                claimedWindows.insert(id)
                claimedIdentities.insert(old.identity.id)
                identities[id] = old.identity
            }

            // 不提供 AX 的软件仅回退到管理入口所在单屏的真实可见窗；不可见代理和残留不生成项目。
            if accessible.isEmpty, let fallbackStrip {
                let visible = processRecords.filter { $0.isOnScreen && visibleIntersection($0.frame, with: fallbackStrip) }
                    .sorted { $0.frame.minX < $1.frame.minX }
                for (index, record) in visible.enumerated() where !claimedWindows.contains(record.id) {
                    let overlaps = visible.contains { $0.id != record.id && $0.frame.intersection(record.frame).width > 1 }
                    guard !overlaps else { continue }
                    let old = oldItems.first { $0.windowID == record.id && !claimedIdentities.contains($0.identity.id) }
                    let ownVerified = isOwnAppKitWindow(record)
                    let verified = old?.verified == true || ownVerified
                    let identity = logicalIdentity(pid: pid, application: application, accessible: nil, record: record,
                        preferred: old?.identity, group: processRecords, excluding: claimedIdentities)
                    let name = displayName(accessible: nil, record: record, application: application,
                        ordinal: index + 1, itemCount: visible.count)
                    let restriction = verified ? managementLimitation(bundle: application.bundleIdentifier, title: record.title, accessible: nil) :
                        "这个软件未提供可验证的辅助功能状态项，暂不允许排序或收纳。"
                    entries.append(makeEntry(identity: identity, application: application, accessible: nil, record: record,
                        name: name, restriction: restriction))
                    nextItems.append(CachedLogicalItem(identity: identity, element: old?.element,
                        identifier: old?.identifier ?? "", windowID: record.id, verified: verified, name: name))
                    claimedWindows.insert(record.id)
                    claimedIdentities.insert(identity.id)
                    if verified { identities[record.id] = identity }
                }
            }
        }
        logicalItems = nextItems
        let mappedWindows = Set(nextItems.filter(\.verified).compactMap(\.windowID))
        identities = identities.filter { mappedWindows.contains($0.key) }
        entries.sort {
            if abs($0.frame.minY - $1.frame.minY) > 1 { return $0.frame.minY < $1.frame.minY }
            return $0.frame.minX < $1.frame.minX
        }
        let unresolvedCount = entries.filter { $0.windowID == kCGNullWindowID }.count
        if unresolvedCount != lastUnresolvedWindowCount {
            if unresolvedCount > 0 {
                NestLog.system.warning("部分逻辑状态项未确认真实操作窗口，已限制管理，数量：\(unresolvedCount)")
            } else {
                NestLog.system.info("逻辑状态项的操作窗口均已重新确认。")
            }
            lastUnresolvedWindowCount = unresolvedCount
        }
        NestLog.system.debug("逻辑状态项扫描完成，项目数量：\(entries.count)，未确认窗口数量：\(unresolvedCount)")
        return entries
    }

    /// 使用 macOS 14 起的单窗口截图接口；未授权时直接返回，不触发权限提示。
    func captureIcon(for entry: MenuBarEntry) async -> NSImage? {
        guard entry.windowID != kCGNullWindowID else { return nil }
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard entry.frame.width > 0, entry.frame.height > 0 else { return nil }
        do {
            var content = try await currentShareableContent()
            if !content.windows.contains(where: { $0.windowID == entry.windowID && $0.owningApplication?.processID == entry.processIdentifier }) {
                content = try await currentShareableContent(forceRefresh: true)
            }
            guard let window = content.windows.first(where: {
                $0.windowID == entry.windowID && $0.owningApplication?.processID == entry.processIdentifier
            }), currentWindow(entry) != nil else {
                logCaptureWarning()
                return nil
            }
            // 独立窗口过滤器只读取这个图标；禁止使用整屏截图后再裁剪。
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = max(CGFloat(filter.pointPixelScale), 1)
            configuration.width = max(1, Int(ceil(entry.frame.width * scale)))
            configuration.height = max(1, Int(ceil(entry.frame.height * scale)))
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.captureResolution = .best
            guard CGPreflightScreenCaptureAccess() else { return nil }
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return NSImage(cgImage: image, size: entry.frame.size)
        } catch {
            logCaptureWarning()
            return nil
        }
    }

    /// 模拟 Command 拖动，并重新读取窗口位置确认系统接受了目标位置。
    func move(_ entry: MenuBarEntry, to destination: CGPoint) async throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw MenuBarOperationError.accessibilityRequired }
        guard entry.canMove else {
            throw MenuBarOperationError.unsupported(entry.limitation ?? "系统不允许移动这个状态项。")
        }
        guard destination.x.isFinite, destination.y.isFinite else {
            throw MenuBarOperationError.unsupported("图标的目标位置无效。")
        }
        try beginOperation()
        defer { operationInFlight = false }
        guard let initial = currentWindow(entry), initial.isOnScreen, let start = interactivePoint(in: initial.frame) else {
            throw MenuBarOperationError.itemUnavailable
        }
        // Command 拖到桌面可能删除状态项；只允许在同一显示器的菜单栏矩形内拖动。
        guard menuBarStrips().contains(where: { $0.contains(start) && $0.contains(destination) }) else {
            throw MenuBarOperationError.unsupported("只能在同一显示器的菜单栏内移动图标，请先展开收起区。")
        }
        let tolerance = max(10, initial.frame.width / 2 + 4)
        if position(initial.frame, matches: destination, tolerance: tolerance) {
            guard try await confirmSettledPosition(entry, destination: destination, tolerance: tolerance) else {
                throw MenuBarOperationError.movementFailed
            }
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw MenuBarOperationError.movementFailed
        }
        source.localEventsSuppressionInterval = 0
        let token = Int64.random(in: 1...Int64.max)
        let pointerBefore = CGEvent(source: nil)?.location
        var mouseIsDown = false
        defer {
            // 任何超时或取消都补发抬起事件，防止留下系统拖动状态。
            if mouseIsDown {
                event(type: .leftMouseUp, at: destination, button: .left, entry: entry, source: source, token: token, command: true)?
                    .post(tap: .cghidEventTap)
            }
            if let pointerBefore { CGWarpMouseCursorPosition(pointerBefore) }
        }
        NestLog.system.debug("开始菜单栏图标拖动")
        guard let down = event(type: .leftMouseDown, at: start, button: .left, entry: entry, source: source, token: token, command: true) else {
            throw MenuBarOperationError.movementFailed
        }
        down.post(tap: .cghidEventTap)
        mouseIsDown = true
        try await Task.sleep(for: .milliseconds(60))
        for step in 1...5 {
            try Task.checkCancellation()
            let fraction = CGFloat(step) / 5
            let point = CGPoint(x: start.x + (destination.x - start.x) * fraction, y: start.y + (destination.y - start.y) * fraction)
            guard let drag = event(type: .leftMouseDragged, at: point, button: .left, entry: entry, source: source, token: token, command: true) else {
                throw MenuBarOperationError.movementFailed
            }
            drag.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(35))
        }
        guard let up = event(type: .leftMouseUp, at: destination, button: .left, entry: entry, source: source, token: token, command: true) else {
            throw MenuBarOperationError.movementFailed
        }
        up.post(tap: .cghidEventTap)
        mouseIsDown = false

        // 使用窗口编号直接校验，只有目标匹配且布局连续稳定才允许下一次拖动。
        if try await confirmSettledPosition(entry, destination: destination, tolerance: tolerance) {
            NestLog.system.info("菜单栏图标移动位置及布局稳定性已确认")
            shareableContentDate = .distantPast
            return
        }
        NestLog.system.error("系统未确认菜单栏图标的目标位置")
        throw MenuBarOperationError.movementFailed
    }

    /// 点击已恢复到菜单栏可见位置的原始状态项，不关闭其所属应用。
    func click(_ entry: MenuBarEntry, rightButton: Bool) async throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw MenuBarOperationError.accessibilityRequired }
        try beginOperation()
        defer { operationInFlight = false }
        guard let current = currentWindow(entry), current.isOnScreen, let point = interactivePoint(in: current.frame) else {
            throw MenuBarOperationError.unsupported("请先展开并恢复这个图标，再打开它的菜单。")
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw MenuBarOperationError.itemUnavailable
        }
        source.localEventsSuppressionInterval = 0
        let token = Int64.random(in: 1...Int64.max)
        let button: CGMouseButton = rightButton ? .right : .left
        let downType: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp
        guard
            let down = event(type: downType, at: point, button: button, entry: entry, source: source, token: token, command: false),
            let up = event(type: upType, at: point, button: button, entry: entry, source: source, token: token, command: false)
        else { throw MenuBarOperationError.itemUnavailable }
        // 取消时仍然发送配对抬起；点击后保留指针，避免关闭应用的原生弹出菜单。
        var mouseIsDown = false
        defer { if mouseIsDown { up.post(tap: .cghidEventTap) } }
        down.post(tap: .cghidEventTap)
        mouseIsDown = true
        try await Task.sleep(for: .milliseconds(35))
        up.post(tap: .cghidEventTap)
        mouseIsDown = false
        NestLog.system.info("已向原始菜单栏图标发送点击事件")
    }

    /// 解析公开窗口清单；单窗口校验也沿用同一元数据读取路径。
    private func windowRecords(options: CGWindowListOption, windowID: CGWindowID = kCGNullWindowID) -> [WindowRecord] {
        if let windowRecordsProvider { return windowRecordsProvider(options, windowID) }
        guard let dictionaries = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]] else { return [] }
        return dictionaries.compactMap { dictionary in
            guard
                let id = dictionary[kCGWindowNumber as String] as? NSNumber,
                let pid = dictionary[kCGWindowOwnerPID as String] as? NSNumber,
                let bounds = dictionary[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds),
                let layer = dictionary[kCGWindowLayer as String] as? NSNumber
            else { return nil }
            return WindowRecord(id: id.uint32Value, pid: pid.int32Value, frame: frame,
                title: dictionary[kCGWindowName as String] as? String ?? "", layer: layer.intValue,
                isOnScreen: dictionary[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    /// 状态窗口形状仅用于收集候选进程，不能据此把 CG 窗口视作真实状态项。
    private func hasStatusWindowShape(_ record: WindowRecord) -> Bool {
        record.layer == Int(CGWindowLevelForKey(.statusWindow)) &&
            record.frame.minX.isFinite && record.frame.minY.isFinite &&
            record.frame.width > 0 && record.frame.width < 600 &&
            record.frame.height > 0 && record.frame.height <= max(40, NSStatusBar.system.thickness + 8)
    }

    /// 只保留真实菜单栏 Y 条带内的候选，包含本软件收起后水平移出屏幕的窗口。
    private func isStatusWindow(_ record: WindowRecord) -> Bool {
        guard hasStatusWindowShape(record) else { return false }
        return menuBarStrips().contains { abs($0.midY - record.frame.midY) <= 6 }
    }

    /// 直接读取各显示器的 Quartz 几何，避免显示器切换时混用缓存的 AppKit 坐标。
    private func menuBarStrips() -> [CGRect] {
        if let menuBarStripsProvider { return menuBarStripsProvider() }
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let bounds = CGDisplayBounds(number.uint32Value)
            guard !bounds.isEmpty, !bounds.isNull else { return nil }
            return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: NSStatusBar.system.thickness)
        }
    }

    /// 读取真实 AX 状态项；只去除同一元素的重复引用，保留同进程、同名的独立元素。
    private func accessibleItems(for pid: pid_t) -> [AccessibleItem] {
        if let accessibleItemsProvider { return uniqueAccessibleItems(accessibleItemsProvider(pid)) }
        guard AXIsProcessTrusted() else { return [] }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.08)
        guard let extras = elementAttribute(application, name: kAXExtrasMenuBarAttribute) else { return [] }
        let children = attribute(extras, name: kAXChildrenAttribute) as? [AXUIElement] ?? []
        let items = children.compactMap { child -> AccessibleItem? in
            guard let frame = accessibilityFrame(child), frame.width > 0, frame.height > 0 else { return nil }
            let identifier = attribute(child, name: kAXIdentifierAttribute) as? String ?? ""
            let title = attribute(child, name: kAXTitleAttribute) as? String ?? ""
            let description = attribute(child, name: kAXDescriptionAttribute) as? String ?? ""
            return AccessibleItem(element: child, identifier: identifier, name: title.isEmpty ? description : title, frame: frame)
        }
        return uniqueAccessibleItems(items)
    }

    /// 同一个 AX 元素只建模一次；名称和 identifier 相同不能证明是同一个图标。
    private func uniqueAccessibleItems(_ items: [AccessibleItem]) -> [AccessibleItem] {
        var result = [AccessibleItem]()
        for item in items where item.frame.minX.isFinite && item.frame.minY.isFinite &&
            item.frame.width.isFinite && item.frame.height.isFinite && item.frame.width > 0 && item.frame.height > 0 {
            if !result.contains(where: { CFEqual($0.element, item.element) }) { result.append(item) }
        }
        return result
    }

    /// 查询进程身份；注入匿名元数据时不读取 NSRunningApplication。
    private func applicationInfo(for pid: pid_t) -> ApplicationInfo {
        if let applicationInfoProvider { return applicationInfoProvider(pid) }
        let application = NSRunningApplication(processIdentifier: pid)
        return ApplicationInfo(bundleIdentifier: application?.bundleIdentifier ?? "process-\(pid)",
            name: application?.localizedName ?? "未识别的状态项", launchDate: application?.launchDate)
    }

    /// 同时核对 PID、软件标识和启动时间，避免进程复用后串用缓存。
    private func sameProcess(_ identity: CachedIdentity, pid: pid_t, application: ApplicationInfo) -> Bool {
        identity.pid == pid && identity.bundleIdentifier == application.bundleIdentifier && identity.launchDate == application.launchDate
    }

    /// 优先匹配 AX 元素本身，只有当前与缓存双方 identifier 唯一时才允许标识回退。
    private func cachedItem(for item: AccessibleItem, among oldItems: [CachedLogicalItem],
                            currentItems: [AccessibleItem], records: [WindowRecord], excluding usedIDs: Set<String>) -> CachedLogicalItem? {
        let available = oldItems.filter { !usedIDs.contains($0.identity.id) }
        if let exact = available.first(where: { $0.element.map { CFEqual($0, item.element) } ?? false }) { return exact }
        if !item.identifier.isEmpty, currentItems.filter({ $0.identifier == item.identifier }).count == 1 {
            let matches = available.filter { $0.identifier == item.identifier }
            if matches.count == 1 { return matches[0] }
        }
        // 元素重建且没有稳定标识时，只允许唯一吻合的已验证原窗口延续旧身份。
        let windowMatches = available.filter { cached in
            guard cached.verified, let id = cached.windowID,
                  let record = records.first(where: { $0.id == id }) else { return false }
            return matchesAccessibleFrame(item.frame, window: record.frame)
        }
        return windowMatches.count == 1 ? windowMatches[0] : nil
    }

    /// AX 常仅表示窗口内的图标区域；按中心及合理包含关系匹配，不要求整个窗口等宽。
    private func matchesAccessibleFrame(_ frame: CGRect, window: CGRect) -> Bool {
        abs(frame.midX - window.midX) < 6 && abs(frame.midY - window.midY) < 8 &&
            frame.minX >= window.minX - 6 && frame.maxX <= window.maxX + 6 &&
            frame.minY >= window.minY - 8 && frame.maxY <= window.maxY + 8
    }

    /// 只绑定真实可见且唯一匹配的窗口；已验证项收起后继续使用原窗口，不改绑副屏副本。
    private func operationWindow(for item: AccessibleItem, cached: CachedLogicalItem?, among records: [WindowRecord],
                                 excluding claimedIDs: Set<CGWindowID>) -> WindowRecord? {
        let available = records.filter { !claimedIDs.contains($0.id) }
        if let cached, cached.verified, let id = cached.windowID,
           let hidden = available.first(where: { $0.id == id }), retainedHiddenWindow(hidden) { return hidden }
        let candidates = available.filter { record in
            record.isOnScreen && menuBarStrips().contains(where: { visibleIntersection(record.frame, with: $0) }) &&
                matchesAccessibleFrame(item.frame, window: record.frame)
        }.sorted {
            let left = abs($0.frame.midX - item.frame.midX) + abs($0.frame.midY - item.frame.midY)
            let right = abs($1.frame.midX - item.frame.midX) + abs($1.frame.midY - item.frame.midY)
            return left < right
        }
        if let cached, cached.verified, let original = candidates.first(where: { $0.id == cached.windowID }) { return original }
        guard let best = candidates.first else { return nil }
        if candidates.count > 1 {
            let firstDistance = abs(best.frame.midX - item.frame.midX) + abs(best.frame.midY - item.frame.midY)
            let second = candidates[1]
            let secondDistance = abs(second.frame.midX - item.frame.midX) + abs(second.frame.midY - item.frame.midY)
            // 多个窗口同样吻合时不能猜测事件目标，交给界面明确提示无法确认。
            guard secondDistance - firstDistance > 0.5 else { return nil }
        }
        return best
    }

    /// 判断窗口是否实际与某个菜单栏的可见范围相交，排除仅 Y 相同的屏幕外窗口。
    private func visibleIntersection(_ frame: CGRect, with strip: CGRect) -> Bool {
        let intersection = frame.intersection(strip)
        return !intersection.isNull && intersection.width > 1 && intersection.height > 1
    }

    /// 仅保留已验证后水平移出所有屏幕的真实窗口；(0,0) 不可见残留不能进入隐藏缓存。
    private func retainedHiddenWindow(_ record: WindowRecord) -> Bool {
        isStatusWindow(record) &&
            !menuBarStrips().contains { visibleIntersection(record.frame, with: $0) }
    }

    /// 无 AX 时只扫描管理器原始控制窗口所在屏幕；找不到入口则采用主显示器。
    private func fallbackMenuBarStrip(excludingPID: pid_t, allRecords: [WindowRecord]) -> CGRect? {
        let strips = menuBarStrips()
        if windowRecordsProvider != nil { return strips.first }
        let ownWindowIDs = Set(NSApp.windows.compactMap { window -> CGWindowID? in
            guard window.windowNumber > 0 else { return nil }
            return CGWindowID(window.windowNumber)
        })
        if let entry = allRecords.first(where: {
            $0.pid == excludingPID && $0.isOnScreen && ownWindowIDs.contains($0.id) && isStatusWindow($0)
        }), let strip = strips.first(where: { visibleIntersection(entry.frame, with: $0) }) { return strip }
        let primary = CGDisplayBounds(CGMainDisplayID())
        return strips.first(where: { abs($0.minX - primary.minX) < 1 && abs($0.minY - primary.minY) < 1 }) ?? strips.first
    }

    /// 自建测试项可用 AppKit 原始窗口编号验证；注入窗口数据时不读取本机 AppKit 清单。
    private func isOwnAppKitWindow(_ record: WindowRecord) -> Bool {
        guard windowRecordsProvider == nil, record.pid == ProcessInfo.processInfo.processIdentifier else { return false }
        return NSApp.windows.contains { $0.windowNumber > 0 && CGWindowID($0.windowNumber) == record.id }
    }

    /// 通用 CG 窗口名仅用于旧布局身份兼容，不直接显示为用户的软件名称。
    private func isGenericWindowTitle(_ title: String) -> Bool {
        let suffix = title.dropFirst(5)
        return title.hasPrefix("Item-") && !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// 优先采用真实 AX 名称，再采用有效窗口名；无语义名称的多项以展示序号区分。
    private func displayName(accessible: AccessibleItem?, record: WindowRecord?, application: ApplicationInfo,
                             ordinal: Int, itemCount: Int) -> String {
        if let name = accessible?.name, !name.isEmpty, !isGenericWindowTitle(name) { return name }
        if let title = record?.title, !title.isEmpty, !isGenericWindowTitle(title) { return title }
        return itemCount > 1 ? application.name + " · 图标\(ordinal)" : application.name
    }

    /// 未确认映射使用空窗口编号并禁止移动；实时可见状态仅来自本次可信窗口元数据。
    private func makeEntry(identity: CachedIdentity, application: ApplicationInfo, accessible: AccessibleItem?,
                           record: WindowRecord?, name: String, restriction: String?) -> MenuBarEntry {
        MenuBarEntry(id: identity.id, name: name, bundleIdentifier: application.bundleIdentifier,
            processIdentifier: identity.pid, windowID: record?.id ?? kCGNullWindowID,
            frame: record?.frame ?? accessible?.frame ?? .zero, image: nil, canMove: restriction == nil,
            limitation: restriction ?? identity.warning, isOnScreen: record?.isOnScreen)
    }

    /// 读取一个辅助功能属性，失败时保留为 nil。
    private func attribute(_ element: AXUIElement, name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// 将经过类型检查的辅助功能对象属性转换为 AXUIElement。
    private func elementAttribute(_ element: AXUIElement, name: String) -> AXUIElement? {
        guard let value = attribute(element, name: name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// 读取辅助功能对象的位置及尺寸；AX 坐标与 Quartz 相同。
    private func accessibilityFrame(_ element: AXUIElement) -> CGRect? {
        guard
            let position = attribute(element, name: kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
            let size = attribute(element, name: kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    /// 优先复用已验证身份；首次绑定保留旧版 base 规则，缺少稳定 AX 标识时明确会话局限。
    private func logicalIdentity(pid: pid_t, application: ApplicationInfo, accessible: AccessibleItem?, record: WindowRecord?,
                                 preferred: CachedIdentity?, group: [WindowRecord], excluding claimedIDs: Set<String>) -> CachedIdentity {
        if let preferred, sameProcess(preferred, pid: pid, application: application), !claimedIDs.contains(preferred.id) { return preferred }
        if let record, let cached = identities[record.id], sameProcess(cached, pid: pid, application: application),
           !claimedIDs.contains(cached.id) { return cached }
        let bundle = application.bundleIdentifier
        let identityPart = accessible.flatMap { $0.identifier.isEmpty ? nil : $0.identifier } ?? record?.title ?? ""
        let sameProcessCount = group.filter { $0.pid == pid }.count
        let base: String
        let warning: String?
        if !identityPart.isEmpty {
            base = bundle + ":" + identityPart
            warning = nil
        } else if sameProcessCount == 1 {
            base = bundle + ":status-item"
            warning = nil
        } else {
            base = bundle + ":session-item"
            warning = "这个软件未提供稳定图标标识；软件重启后可能需要重新分区。"
        }
        // 旧通用窗口名仍可作为 base 兼容既有规则，但不把副本数量当作逻辑图标数量。
        let usedIDs = Set(identities.values.map(\.id)).union(claimedIDs)
        var slot = 0
        while usedIDs.contains(slot == 0 ? base : base + ":slot-\(slot)") { slot += 1 }
        let missingBundleWarning = bundle.hasPrefix("process-") ? "无法识别软件标识；软件重启后需要重新分区。" : nil
        let duplicateWarning = slot > 0 ? "同名状态项仅保证本次运行身份稳定；软件重启后可能需要重新分区。" : nil
        let unstableAXWarning = accessible?.identifier.isEmpty != false ? "这个软件未提供稳定图标标识；软件重启后可能需要重新分区。" : nil
        let cached = CachedIdentity(pid: pid, bundleIdentifier: bundle, launchDate: application.launchDate,
            id: slot == 0 ? base : base + ":slot-\(slot)", warning: warning ?? missingBundleWarning ?? duplicateWarning ?? unstableAXWarning)
        return cached
    }

    /// 保留系统固定控制项与隐私指示项；名单不能替代实际拖动结果验证。
    private func managementLimitation(bundle: String, title: String, accessible: AccessibleItem?) -> String? {
        guard bundle == "com.apple.controlcenter" || bundle == "com.apple.systemuiserver" else { return nil }
        let identity = [title, accessible?.identifier ?? "", accessible?.name ?? ""].joined(separator: " ").lowercased()
        if ["clock", "bentobox", "siri", "control center", "控制中心", "时钟"].contains(where: { identity.contains($0) }) {
            return "这个系统固定图标不支持拖动或分区管理。"
        }
        if ["audiovideomodule", "facetime", "musicrecognition"].contains(where: { identity.contains($0) }) {
            return "这个系统状态或隐私指示图标不支持收起。"
        }
        if identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "无法确认这个系统图标的身份，暂不允许移动。"
        }
        return nil
    }

    /// 校验逻辑身份、当前绑定及进程生命周期，防止旧窗口编号被其他状态项复用后误操作。
    private func currentWindow(_ entry: MenuBarEntry) -> WindowRecord? {
        guard entry.windowID != kCGNullWindowID,
              let record = windowRecords(options: .optionAll).first(where: {
                  $0.id == entry.windowID && $0.pid == entry.processIdentifier
              }), record.layer == Int(CGWindowLevelForKey(.statusWindow)) else { return nil }
        if let logical = logicalItems.first(where: { $0.identity.id == entry.id && $0.identity.pid == entry.processIdentifier }) {
            guard logical.verified, logical.windowID == entry.windowID, isStatusWindow(record),
                  sameProcess(logical.identity, pid: record.pid, application: applicationInfo(for: record.pid)) else { return nil }
            if let element = logical.element {
                let frame: CGRect?
                if let accessibleItemsProvider {
                    // 匿名测试只比较注入元素，不对人工 AX 引用调用系统属性接口。
                    frame = accessibleItemsProvider(record.pid).first(where: { CFEqual($0.element, element) })?.frame
                } else {
                    frame = accessibilityFrame(element)
                }
                guard let frame, matchesAccessibleFrame(frame, window: record.frame) else { return nil }
            } else {
                guard isOwnAppKitWindow(record) else { return nil }
            }
            return record
        }
        // 收纳边界由协调器直接创建，不参与跨应用扫描；只允许本进程原始 AppKit 状态窗口。
        guard entry.id.hasPrefix("own-"), isOwnAppKitWindow(record) else { return nil }
        return record
    }

    /// 找到图标与菜单栏的可见交集；屏幕外隐藏项必须先由控制器展开。
    private func interactivePoint(in frame: CGRect) -> CGPoint? {
        let visible = menuBarStrips().map { $0.intersection(frame) }.filter { !$0.isNull && $0.width > 1 && $0.height > 1 }
        guard let best = visible.max(by: { $0.width < $1.width }) else { return nil }
        return CGPoint(x: best.midX, y: best.midY)
    }

    /// 检查系统给出的最终位置，允许状态项宽度导致的插入位置偏移。
    private func position(_ frame: CGRect, matches point: CGPoint, tolerance: CGFloat) -> Bool {
        abs(frame.midX - point.x) <= tolerance && abs(frame.midY - point.y) <= max(6, frame.height / 2)
    }

    /// 连续三次采样达到目标并稳定，防止把布局动画的过渡帧当成成功结果。
    private func confirmSettledPosition(_ entry: MenuBarEntry, destination: CGPoint, tolerance: CGFloat) async throws -> Bool {
        var previous: CGRect?
        var stableMatches = 0
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(50))
            guard let current = currentWindow(entry) else { throw MenuBarOperationError.itemUnavailable }
            guard position(current.frame, matches: destination, tolerance: tolerance) else {
                previous = nil
                stableMatches = 0
                continue
            }
            if let previous,
               abs(previous.minX - current.frame.minX) < 0.5,
               abs(previous.minY - current.frame.minY) < 0.5,
               abs(previous.width - current.frame.width) < 0.5,
               abs(previous.height - current.frame.height) < 0.5 {
                stableMatches += 1
            } else {
                stableMatches = 1
            }
            previous = current.frame
            if stableMatches >= 3 { return true }
        }
        return false
    }

    /// 保证操作串行，并在用户正按住鼠标时拒绝接管指针。
    private func beginOperation() throws {
        guard !operationInFlight else { throw MenuBarOperationError.unsupported("正在调整其他图标，请稍后重试。") }
        guard !CGEventSource.buttonState(.combinedSessionState, button: .left),
              !CGEventSource.buttonState(.combinedSessionState, button: .right)
        else { throw MenuBarOperationError.unsupported("请松开鼠标按钮后再调整图标。") }
        operationInFlight = true
    }

    /// 创建带公开窗口指向字段及操作标记的鼠标事件。
    private func event(type: CGEventType, at point: CGPoint, button: CGMouseButton, entry: MenuBarEntry,
                       source: CGEventSource, token: Int64, command: Bool) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return nil }
        event.flags = command ? .maskCommand : []
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(entry.windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(entry.windowID))
        event.setIntegerValueField(.eventSourceUserData, value: token)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        return event
    }

    /// 两秒内复用窗口元数据，并合并异步查询，避免每个图标重复请求系统。
    private func currentShareableContent(forceRefresh: Bool = false) async throws -> SCShareableContent {
        if !forceRefresh, let shareableContent, Date().timeIntervalSince(shareableContentDate) < 2 { return shareableContent }
        if let shareableContentTask { return try await shareableContentTask.value }
        let task = Task { try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        shareableContentTask = task
        defer { shareableContentTask = nil }
        let result = try await task.value
        shareableContent = result
        shareableContentDate = Date()
        return result
    }

    /// 截图不可用时只记录通用警告，不输出窗口名、应用名或屏幕内容。
    private func logCaptureWarning() {
        guard Date().timeIntervalSince(lastCaptureWarningDate) > 5 else { return }
        lastCaptureWarningDate = Date()
        NestLog.system.warning("单个菜单栏图标截图暂不可用，保留名称入口")
    }
}

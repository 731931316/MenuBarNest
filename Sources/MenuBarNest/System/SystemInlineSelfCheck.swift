import AppKit
import ApplicationServices

/// 同一行展开的实机检查，仅改变自建状态项长度，不发送鼠标事件、不截图、不读写用户布局。
extension SystemSelfCheck {
    /// 本次检查创建的细窄状态项；原始 AppKit 窗口是状态验证的唯一基准。
    @MainActor
    private struct InlineFixture {
        /// 只标识自建项的中性标签。
        let label: String
        /// 始终强引用的本进程状态项。
        let item: NSStatusItem
        /// 清理时恢复的细窄长度。
        let originalLength: CGFloat
        /// 状态项当前原始窗口编号；允许 Window Server 重建窗口。
        var windowID: CGWindowID? {
            guard let number = item.button?.window?.windowNumber, number > 0,
                  UInt64(number) <= UInt64(CGWindowID.max) else { return nil }
            return CGWindowID(number)
        }
    }

    /// 根据实际原始窗口顺序分配测试角色，避免为准备测试拖动任何状态项。
    private struct InlineRoles {
        /// 始终隐藏区的自建内容项。
        let hidden: InlineFixture
        /// 始终隐藏区右侧的自建分隔项。
        let hiddenDivider: InlineFixture
        /// 收起区的自建内容项。
        let collapsed: InlineFixture
        /// 收起区右侧的自建分隔项。
        let collapsedDivider: InlineFixture
        /// 始终可见区的自建内容项。
        let visible: InlineFixture
        /// 每个阶段必须保留真实身份和映射的三项内容。
        var contents: [InlineFixture] { [hidden, collapsed, visible] }
    }

    /// 安全比较窗口时同时核对 PID，不能把编号复用当作同一外部窗口。
    private struct InlineWindowKey: Hashable {
        /// 当前窗口编号，不输出外部窗口编号。
        let id: CGWindowID
        /// 当前窗口所属进程，不输出外部进程编号。
        let pid: pid_t
    }

    /// 只保存安全验证所需的窗口元数据，外部名称和图像不进入该类型。
    private struct InlineWindowState {
        /// 窗口及所属进程的组合键。
        let key: InlineWindowKey
        /// 当前 Quartz 几何。
        let frame: CGRect
        /// 系统实时可见标志，缺失时明确为未知。
        let onScreen: Bool?
        /// 仅本进程可保留原始窗口名，用于扫描身份兼容；不写入报告。
        let ownTitle: String
    }

    /// 一次公开 CG 元数据观察，不包含屏幕内容。
    private struct InlineScene {
        /// 菜单栏状态层的几何记录。
        let windows: [InlineWindowState]
        /// 无法解析的状态层记录数量；存在时不能承诺检查安全。
        let incompleteCount: Int
    }

    /// 将同一次匿名自身元数据快照提供给生产扫描器，不扫描其他应用的 AX 树。
    @MainActor
    private final class InlineObservationSource {
        /// 本轮只读观察到的状态层窗口。
        var scene: InlineScene

        /// 保存基线观察，后续在每次扫描前更新。
        init(scene: InlineScene) { self.scene = scene }
    }

    /// 不具备安全环境与已执行验证失败必须分开报告。
    private enum InlineCheckError: Error {
        /// 未改变分隔项或已安全恢复，当前环境不满足完整验证前提。
        case skipped(String)
        /// 已执行的状态变化或安全校验未达到预期。
        case failed(String)
    }

    /// 验证始终隐藏、收起、同一行展开、再次收起及恢复；无需屏幕录制权限。
    static func runInline() async -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let strips = inlineMenuBarStrips()
        let accessibility = AXIsProcessTrusted()
        report("inlinePermissions", status: accessibility && !strips.isEmpty ? "PASS" : "SKIP",
            detail: "仅观察权限布尔值，不发起任何授权请求；本检查不使用录屏权限",
            extra: ["accessibilityGranted": accessibility, "screenRecordingGranted": CGPreflightScreenCaptureAccess(),
                    "displayCount": strips.count, "requiresScreenRecording": false])
        guard accessibility, !strips.isEmpty else {
            report("summary", status: "SKIP", detail: "辅助功能未授权或显示器不可用，未创建测试项或改变分隔项")
            return false
        }
        let fixtures = createInlineFixtures()
        var cleaned = false
        defer {
            // 取消、失败和跳过均恢复所有长度并移除全部自建项。
            if !cleaned { cleanupInlineFixtures(fixtures) }
        }
        var passed = false
        var summaryStatus = "FAIL"
        var summaryDetail = "同一行展开检查未完成"
        NestLog.system.info("开始仅调整自建分隔项长度的同一行展开检查。")
        do {
            let preparation = try await prepareInlineFixtures(fixtures, pid: pid, strips: strips)
            let roles = preparation.roles
            let baseline = preparation.scene
            let homeStrip = preparation.homeStrip
            let safetyLimits = try inlineSafetyLimits(scene: baseline, pid: pid, strips: strips, fixtureCount: fixtures.count)
            try requireInlineSafety(scene: baseline, pid: pid, strips: strips, limits: safetyLimits, baseline: baseline)
            report("inlineSafety", status: "PASS", detail: "所有显示器上的自建组均在其他可见或未知状态项左侧，未移动任何状态项")

            let source = InlineObservationSource(scene: baseline)
            let application = MenuBarSystem.ApplicationInfo(bundleIdentifier: Bundle.main.bundleIdentifier ?? "local.MenuBarNest.InlineSelfCheck",
                name: "自建测试图标")
            let system = MenuBarSystem(windowRecordsProvider: { _, _ in
                source.scene.windows.filter { $0.key.pid == pid }.map {
                    MenuBarSystem.WindowRecord(id: $0.key.id, pid: pid, frame: $0.frame, title: $0.ownTitle,
                        layer: Int(CGWindowLevelForKey(.statusWindow)), isOnScreen: $0.onScreen ?? false)
                }
            }, menuBarStripsProvider: { strips }, applicationInfoProvider: { _ in application })
            let initial = system.scan(excludingPID: -1)
            guard initial.count == fixtures.count, Set(initial.map(\.id)).count == fixtures.count else {
                throw InlineCheckError.failed("初始自身逻辑扫描未正确识别五个独立测试状态项")
            }
            var contentIDs = [String: String]()
            for fixture in roles.contents {
                guard let windowID = fixture.windowID,
                      let entry = initial.first(where: { $0.windowID == windowID && $0.processIdentifier == pid }) else {
                    throw InlineCheckError.skipped("初始自建内容项未全部取得真实原始窗口映射")
                }
                contentIDs[fixture.label] = entry.id
            }
            report("inlineScan", status: "PASS", detail: "五个原始自建状态项仅生成五个逻辑项目，三项内容映射已确认",
                extra: ["expectedLogicalCount": fixtures.count, "actualLogicalCount": initial.count])
            try await observeInlineStage("inlineBaseline", roles: roles, collapsedVisible: true, hiddenVisible: true,
                pid: pid, strips: strips, homeStrip: homeStrip, baseline: baseline, limits: safetyLimits,
                source: source, system: system, contentIDs: contentIDs)

            let expandedLength = max(CGFloat(10_000), strips.reduce(CGFloat(0)) { $0 + $1.width } * 2)
            try await changeInlineBoundaries("inlineCollapse", roles: roles, collapsedLength: expandedLength, hiddenLength: expandedLength,
                collapsedVisible: false, hiddenVisible: false, pid: pid, strips: strips, homeStrip: homeStrip,
                baseline: baseline, limits: safetyLimits, source: source, system: system, contentIDs: contentIDs)
            try await changeInlineBoundaries("inlineExpand", roles: roles, collapsedLength: roles.collapsedDivider.originalLength,
                hiddenLength: expandedLength, collapsedVisible: true, hiddenVisible: false,
                pid: pid, strips: strips, homeStrip: homeStrip, baseline: baseline, limits: safetyLimits,
                source: source, system: system, contentIDs: contentIDs)
            try await changeInlineBoundaries("inlineRecollapse", roles: roles, collapsedLength: expandedLength, hiddenLength: expandedLength,
                collapsedVisible: false, hiddenVisible: false, pid: pid, strips: strips, homeStrip: homeStrip,
                baseline: baseline, limits: safetyLimits, source: source, system: system, contentIDs: contentIDs)
            try await changeInlineBoundaries("inlineRestore", roles: roles, collapsedLength: roles.collapsedDivider.originalLength,
                hiddenLength: roles.hiddenDivider.originalLength, collapsedVisible: true, hiddenVisible: true,
                pid: pid, strips: strips, homeStrip: homeStrip, baseline: baseline, limits: safetyLimits,
                source: source, system: system, contentIDs: contentIDs)
            passed = true
            summaryStatus = "PASS"
            summaryDetail = "自建分区收起、同一行展开、始终隐藏、再次收起及恢复均已验证；未截图或发送鼠标事件"
        } catch InlineCheckError.skipped(let detail) {
            summaryStatus = "SKIP"
            summaryDetail = detail
            NestLog.system.warning("同一行展开自检环境前提不足，已恢复自建状态项。")
        } catch InlineCheckError.failed(let detail) {
            summaryDetail = detail
            NestLog.system.error("同一行展开自检未通过，已恢复自建状态项。")
        } catch {
            summaryStatus = "SKIP"
            summaryDetail = "检查已取消或系统观察中断，已恢复自建状态项"
        }
        // 先清理再报告最终结果，输出文件错误也不能被当作完整通过。
        cleanupInlineFixtures(fixtures)
        cleaned = true
        if reportOutputFailed { passed = false; summaryStatus = "FAIL"; summaryDetail = "检查报告未完整写入显式输出文件" }
        report("summary", status: summaryStatus, detail: summaryDetail)
        return passed && !reportOutputFailed
    }

    /// 创建细窄文字项，不设置菜单、autosaveName 或触发点击，避免写入布局及位置配置。
    private static func createInlineFixtures() -> [InlineFixture] {
        return ["A", "B", "C", "D", "E"].map { label in
            let length = CGFloat(12)
            let item = NSStatusBar.system.statusItem(withLength: length)
            item.isVisible = true
            item.button?.title = label
            item.button?.font = NSFont.systemFont(ofSize: 9)
            return InlineFixture(label: label, item: item, originalLength: length)
        }
    }

    /// 窗口均已创建且真正完整可见后才分配角色；空间不足和自动隐藏均明确跳过。
    private static func prepareInlineFixtures(_ fixtures: [InlineFixture], pid: pid_t, strips: [CGRect]) async throws
        -> (roles: InlineRoles, scene: InlineScene, homeStrip: CGRect) {
        for attempt in 0..<20 {
            try Task.checkCancellation()
            for fixture in fixtures {
                fixture.item.isVisible = true
                fixture.item.button?.title = fixture.label
                fixture.item.button?.font = NSFont.systemFont(ofSize: 9)
            }
            if let scene = inlineScene(pid: pid), scene.incompleteCount == 0 {
                let originals = fixtures.compactMap { inlineOriginalState($0, scene: scene, pid: pid) }
                if originals.count == fixtures.count, let strip = strips.first(where: { strip in
                    originals.allSatisfy { inlineFullyVisible($0, strip: strip) }
                }) {
                    let ordered = fixtures.sorted {
                        (inlineOriginalState($0, scene: scene, pid: pid)?.frame.minX ?? 0) <
                            (inlineOriginalState($1, scene: scene, pid: pid)?.frame.minX ?? 0)
                    }
                    report("inlineReadiness", status: "PASS", detail: "五个细窄原始测试窗口均在同一菜单栏内完整可见")
                    return (InlineRoles(hidden: ordered[0], hiddenDivider: ordered[1], collapsed: ordered[2],
                        collapsedDivider: ordered[3], visible: ordered[4]), scene, strip)
                }
            }
            if attempt < 19 { try await Task.sleep(for: .milliseconds(100)) }
        }
        report("inlineReadiness", status: "SKIP", detail: "原始自建窗口未全部就绪或菜单栏空间不足，未扩大任何分隔项")
        throw InlineCheckError.skipped("五个原始自建项未能在同一行完整显示，当前环境不足以执行分区检查")
    }

    /// 修改前重新核对全部显示器安全性，修改后持续监测，异常立即缩回两个分隔项。
    private static func changeInlineBoundaries(_ check: String, roles: InlineRoles, collapsedLength: CGFloat, hiddenLength: CGFloat,
        collapsedVisible: Bool, hiddenVisible: Bool, pid: pid_t, strips: [CGRect], homeStrip: CGRect,
        baseline: InlineScene, limits: [Int: CGFloat], source: InlineObservationSource, system: MenuBarSystem,
        contentIDs: [String: String]) async throws {
        do {
            guard let scene = inlineScene(pid: pid) else { throw InlineCheckError.skipped("CG 元数据暂不可用，未继续改变自建分隔项") }
            try requireInlineSafety(scene: scene, pid: pid, strips: strips, limits: limits, baseline: baseline)
            roles.hiddenDivider.item.length = hiddenLength
            roles.collapsedDivider.item.length = collapsedLength
            try await observeInlineStage(check, roles: roles, collapsedVisible: collapsedVisible, hiddenVisible: hiddenVisible,
                pid: pid, strips: strips, homeStrip: homeStrip, baseline: baseline, limits: limits,
                source: source, system: system, contentIDs: contentIDs)
        } catch {
            roles.collapsedDivider.item.length = roles.collapsedDivider.originalLength
            roles.hiddenDivider.item.length = roles.hiddenDivider.originalLength
            throw error
        }
    }

    /// 连续三轮以原始窗口及生产逻辑映射确认状态，绝不以其他显示器副本代替同一行验证。
    private static func observeInlineStage(_ check: String, roles: InlineRoles, collapsedVisible: Bool, hiddenVisible: Bool,
        pid: pid_t, strips: [CGRect], homeStrip: CGRect, baseline: InlineScene, limits: [Int: CGFloat],
        source: InlineObservationSource, system: MenuBarSystem, contentIDs: [String: String]) async throws {
        var stableMatches = 0
        var previousFrames = [String: CGRect]()
        for _ in 0..<30 {
            try Task.checkCancellation()
            guard AXIsProcessTrusted(), inlineMenuBarStrips() == strips else {
                throw InlineCheckError.skipped("辅助功能权限或屏幕布局发生变化，已停止分区检查")
            }
            guard let scene = inlineScene(pid: pid) else { throw InlineCheckError.skipped("CG 元数据不可用，无法验证当前分区") }
            try requireInlineSafety(scene: scene, pid: pid, strips: strips, limits: limits, baseline: baseline)
            source.scene = scene
            let entries = system.scan(excludingPID: -1)
            var currentFrames = [String: CGRect]()
            let expected = [(roles.hidden, hiddenVisible), (roles.collapsed, collapsedVisible), (roles.visible, true)]
            let matched = expected.allSatisfy { fixture, shouldBeVisible in
                guard let state = inlineOriginalState(fixture, scene: scene, pid: pid), let onScreen = state.onScreen,
                      abs(state.frame.midY - homeStrip.midY) <= 6,
                      let id = contentIDs[fixture.label],
                      let logical = entries.first(where: { $0.id == id && $0.processIdentifier == pid }),
                      logical.windowID == state.key.id, logical.isOnScreen == onScreen,
                      inlineSameFrame(logical.frame, state.frame) else { return false }
                currentFrames[fixture.label] = state.frame
                if shouldBeVisible { return inlineFullyVisible(state, strip: homeStrip) }
                return !strips.contains { inlineIntersects(state.frame, strip: $0) }
            }
            let framesSettled = currentFrames.count == roles.contents.count && currentFrames.allSatisfy { label, frame in
                previousFrames[label].map { inlineSameFrame($0, frame) } ?? false
            }
            stableMatches = matched && framesSettled ? stableMatches + 1 : 0
            previousFrames = currentFrames
            if stableMatches >= 3 {
                report(check, status: "PASS", detail: "原始窗口与逻辑映射连续稳定；外部状态项可见性及位置未变",
                    extra: ["hiddenVisible": hiddenVisible, "collapsedVisible": collapsedVisible,
                            "alwaysVisible": true, "stableRefreshCount": stableMatches])
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        report(check, status: "FAIL", detail: "自建原始窗口可见性、同一行位置或逻辑身份未达到预期")
        throw InlineCheckError.failed("自建分区的实际状态未通过同一行展开验证")
    }

    /// 收集状态层的几何及可见标志；外部软件名称、标识和图像均不读取。
    private static func inlineScene(pid: pid_t) -> InlineScene? {
        guard let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return nil }
        var incompleteCount = 0
        let windows = rows.compactMap { row -> InlineWindowState? in
            guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.statusWindow)) else { return nil }
            guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let owner = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
                incompleteCount += 1
                return nil
            }
            guard frame.height <= max(40, NSStatusBar.system.thickness + 8) else { return nil }
            return InlineWindowState(key: InlineWindowKey(id: id, pid: owner), frame: frame,
                onScreen: row[kCGWindowIsOnscreen as String] as? Bool,
                ownTitle: owner == pid ? row[kCGWindowName as String] as? String ?? "" : "")
        }
        return InlineScene(windows: windows, incompleteCount: incompleteCount)
    }

    /// 每个有菜单栏窗口的屏幕必须有完整自建组；组的右边界作为所有分隔项的保守安全上界。
    private static func inlineSafetyLimits(scene: InlineScene, pid: pid_t, strips: [CGRect], fixtureCount: Int) throws -> [Int: CGFloat] {
        guard scene.incompleteCount == 0 else { throw InlineCheckError.skipped("存在未能解析的状态窗口，无法确认分区检查安全") }
        var result = [Int: CGFloat]()
        for (index, strip) in strips.enumerated() {
            let row = scene.windows.filter { abs($0.frame.midY - strip.midY) <= 6 && inlineIntersects($0.frame, strip: strip) }
            let own = row.filter { $0.key.pid == pid && $0.onScreen == true }
            let external = row.filter { $0.key.pid != pid && $0.onScreen != false }
            if own.isEmpty && external.isEmpty { continue }
            guard own.count == fixtureCount, let right = own.map({ $0.frame.maxX }).max() else {
                throw InlineCheckError.skipped("某个显示器无法确认完整的自建状态项组，未扩大分隔项")
            }
            result[index] = right
        }
        guard !result.isEmpty else { throw InlineCheckError.skipped("没有可安全验证的完整菜单栏测试组") }
        return result
    }

    /// 外部可见状态及位置必须保持不变；任何可见或未知窗口在分隔项安全上界左侧均禁止继续。
    private static func requireInlineSafety(scene: InlineScene, pid: pid_t, strips: [CGRect], limits: [Int: CGFloat], baseline: InlineScene) throws {
        guard scene.incompleteCount == 0 else { throw InlineCheckError.skipped("状态窗口元数据不完整，无法继续确认安全") }
        let ambiguousGeometryCount = scene.windows.filter { window in
            window.key.pid != pid && window.onScreen != false &&
                strips.contains(where: { abs($0.midY - window.frame.midY) <= 6 }) &&
                !strips.contains(where: { inlineIntersects(window.frame, strip: $0) })
        }.count
        guard ambiguousGeometryCount == 0 else {
            throw InlineCheckError.skipped("存在可见状态未知且无法归属显示器的外部状态窗，未继续改变分隔项")
        }
        let before = Dictionary(baseline.windows.filter { $0.key.pid != pid && $0.onScreen == true }.map { ($0.key, $0.frame) },
            uniquingKeysWith: { first, _ in first })
        let after = Dictionary(scene.windows.filter { $0.key.pid != pid && $0.onScreen == true }.map { ($0.key, $0.frame) },
            uniquingKeysWith: { first, _ in first })
        guard Set(before.keys) == Set(after.keys), before.allSatisfy({ key, frame in after[key].map { inlineSameFrame(frame, $0) } ?? false }) else {
            report("inlineExternalSafety", status: "FAIL", detail: "外部状态项可见性或位置发生变化，正在立即恢复自建分隔项",
                extra: ["baselineVisibleCount": before.count, "currentVisibleCount": after.count])
            throw InlineCheckError.failed("外部状态项可见性或位置发生变化，已立即恢复自建分隔项")
        }
        var blockers = 0
        for (index, strip) in strips.enumerated() {
            let row = scene.windows.filter {
                $0.key.pid != pid && $0.onScreen != false && abs($0.frame.midY - strip.midY) <= 6 && inlineIntersects($0.frame, strip: strip)
            }
            guard let rightLimit = limits[index] else {
                if !row.isEmpty { blockers += row.count }
                continue
            }
            blockers += row.filter { $0.frame.minX < rightLimit - 0.5 }.count
        }
        if blockers > 0 {
            report("inlineSafety", status: "SKIP", detail: "其他可见或未知状态项位于某个显示器测试分隔项左侧，未继续改变长度",
                extra: ["blockerCount": blockers])
            throw InlineCheckError.skipped("不满足所有显示器上的分隔项安全前提，已恢复自建项")
        }
    }

    /// 以当前 AppKit 原始编号和本进程 PID 精确取元数据，不选取多屏副本。
    private static func inlineOriginalState(_ fixture: InlineFixture, scene: InlineScene, pid: pid_t) -> InlineWindowState? {
        guard let id = fixture.windowID else { return nil }
        return scene.windows.first { $0.key.id == id && $0.key.pid == pid }
    }

    /// 真正可见必须由当前系统标志及入口同一菜单栏的完整几何共同证明。
    private static func inlineFullyVisible(_ state: InlineWindowState, strip: CGRect) -> Bool {
        state.onScreen == true && abs(state.frame.midY - strip.midY) <= 6 &&
            state.frame.minX >= strip.minX - 1 && state.frame.maxX <= strip.maxX + 1
    }

    /// 判断状态窗口与指定菜单栏有实际可见交集。
    private static func inlineIntersects(_ frame: CGRect, strip: CGRect) -> Bool {
        let intersection = frame.intersection(strip)
        return !intersection.isNull && intersection.width > 1 && intersection.height > 1
    }

    /// 允许系统不足半点的布局舍入；明显位置变化不能被当作相同快照。
    private static func inlineSameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5 && abs(lhs.minY - rhs.minY) < 0.5 &&
            abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }

    /// 直接读取各显示器 Quartz 条带，避免混用 AppKit 与多屏坐标。
    private static func inlineMenuBarStrips() -> [CGRect] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let bounds = CGDisplayBounds(number.uint32Value)
            guard !bounds.isNull, !bounds.isEmpty else { return nil }
            return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: NSStatusBar.system.thickness)
        }
    }

    /// 恢复全部自建项长度并移除；只记录清理操作，不写用户布局或输出个人数据。
    private static func cleanupInlineFixtures(_ fixtures: [InlineFixture]) {
        for fixture in fixtures { fixture.item.length = fixture.originalLength }
        for fixture in fixtures { NSStatusBar.system.removeStatusItem(fixture.item) }
        report("inlineCleanup", status: "PASS", detail: "全部自建状态项已恢复长度并移除")
    }
}

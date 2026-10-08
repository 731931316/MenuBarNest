import AppKit
import ApplicationServices

/// 实机自检只使用本进程临时创建的状态项，不记录或操作个人图标。
@MainActor
enum SystemSelfCheck {
    /// 仅由显式自检参数指定的逐行 JSON 输出文件。
    private static var reportOutputURL: URL?
    /// 输出文件不可写时不能把自检视为完整通过。
    static var reportOutputFailed = false
    /// 临时自建状态项及其恢复信息。
    @MainActor
    private struct Fixture {
        /// 仅供自检输出使用的测试标签。
        let label: String
        /// 自建状态项对象。
        let item: NSStatusItem
        /// 清理时恢复的长度。
        let originalLength: CGFloat
        /// 设置独立 autosaveName 后、显式显示前的自建项可见状态。
        let autosaveRestoredVisible: Bool
        /// 本进程按钮窗口编号。
        var windowID: CGWindowID? {
            guard let number = item.button?.window?.windowNumber, number > 0,
                  UInt64(number) <= UInt64(CGWindowID.max) else { return nil }
            return CGWindowID(number)
        }
    }

    /// 指定自建窗口的实时位置；不包含其他软件名称或内容。
    private struct Snapshot {
        /// 自建窗口编号。
        let windowID: CGWindowID
        /// 自建窗口的 Quartz 坐标。
        let frame: CGRect
        /// 系统当前报告的可见状态。
        let isOnScreen: Bool
    }

    /// 创建自建图标，依次验证扫描、截图、排序、隐藏与恢复，最终清理全部测试图标。
    static func run() async -> Bool {
        guard configureReportOutput() else { return false }
        if CommandLine.arguments.contains("--inline-only") { return await runInline() }
        let system = MenuBarSystem()
        let pid = ProcessInfo.processInfo.processIdentifier
        let fixtures = createFixtures()
        defer {
            // 无论取消、失败或跳过，先缩回分隔项，再移除所有测试状态项。
            for fixture in fixtures { fixture.item.length = fixture.originalLength }
            for fixture in fixtures { NSStatusBar.system.removeStatusItem(fixture.item) }
            report("cleanup", status: "PASS", detail: "所有自建状态项均已恢复长度并移除")
        }
        NestLog.system.info("开始仅针对自建图标的系统自检")
        do {
            try await Task.sleep(for: .milliseconds(500))
            var allEntries = [MenuBarEntry]()
            var ownEntries = [MenuBarEntry]()
            var windowReadyCount = 0
            var hasButtonCount = 0
            var visibleFixtureCount = 0
            for attempt in 0..<13 {
                // AppKit 完成启动后才可能补建状态按钮窗口；重试配置，不重建状态项。
                configureFixtureButtons(fixtures)
                hasButtonCount = fixtures.filter { $0.item.button != nil }.count
                windowReadyCount = fixtures.filter { $0.windowID != nil }.count
                visibleFixtureCount = fixtures.filter { $0.item.isVisible }.count
                if windowReadyCount == fixtures.count {
                    allEntries = system.scan(excludingPID: -1)
                    ownEntries = fixtureEntries(from: allEntries, fixtures: fixtures, pid: pid)
                    if ownEntries.count == fixtures.count { break }
                }
                if attempt < 12 { try await Task.sleep(for: .milliseconds(250)) }
            }
            let windowsReady = windowReadyCount == fixtures.count
            report("fixtureReadiness", status: windowsReady ? "PASS" : "FAIL",
                detail: windowsReady ? "自建状态按钮窗口已全部创建" : "AppKit 尚未创建全部自建状态按钮窗口",
                extra: ["fixtureCount": fixtures.count, "hasButtonCount": hasButtonCount,
                        "windowReadyCount": windowReadyCount, "visibleFixtureCount": visibleFixtureCount,
                        "autosaveRestoredVisibleCount": fixtures.filter(\.autosaveRestoredVisible).count,
                        "applicationIsRunning": NSApp.isRunning])
            let diagnostics = reportFixtureWindows(fixtures, pid: pid)
            let allOwnEntries = allEntries.filter { $0.processIdentifier == pid }
            // 验证全部逻辑项的数量，禁止只在副本堆中筛出原始四个窗口就宣布通过。
            let uniqueScanPassed = allOwnEntries.count == fixtures.count &&
                Set(allOwnEntries.map(\.id)).count == fixtures.count
            // AX 项可在无可用操作窗口时展示；只对真实可见原窗检查当前映射，不要求代理也被枚举。
            let visibleOriginalIDs = Set(fixtures.compactMap { fixture -> CGWindowID? in
                guard let id = fixture.windowID, let state = snapshot(windowID: id),
                      state.isOnScreen, intersectsMenuBar(state.frame) else { return nil }
                return id
            })
            let missingEligibleIDs = visibleOriginalIDs.subtracting(allOwnEntries.map(\.windowID))
            let scanPassed = uniqueScanPassed && missingEligibleIDs.isEmpty
            let scanStatus = scanPassed ? "PASS" : !missingEligibleIDs.isEmpty ? "FAIL" :
                visibleOriginalIDs.count < fixtures.count ? "SKIP" : "FAIL"
            let scanDetail = scanPassed ? "逻辑扫描枚举四个真实状态项，当前可见原窗映射无遗漏" :
                !windowsReady ? "自建窗口未就绪，未评估公开扫描能力" :
                !missingEligibleIDs.isEmpty ? "存在真实可见但未正确映射的原始自建窗口" :
                !diagnostics.allRecordsMatched ? "原始自建窗口的 CG 元数据不完整，未评估公开扫描能力" :
                visibleOriginalIDs.count < fixtures.count ? "部分原窗当前不可见，且完整 AX 逻辑项未获取，环境前提不足" :
                "逻辑扫描数量不等于四个真实自建状态项"
            report("scan", status: scanStatus, detail: scanDetail,
                extra: ["fixtureCount": fixtures.count, "ownEntryCount": ownEntries.count,
                        "eligibleFixtureCount": diagnostics.eligibleIDs.count,
                        "missingEligibleFixtureCount": missingEligibleIDs.count,
                        "coordinates": coordinates(fixtures)])
            report("scanUnique", status: uniqueScanPassed ? "PASS" : scanStatus == "SKIP" ? "SKIP" : "FAIL",
                detail: uniqueScanPassed ? "全部本进程扫描结果只有四个真实状态项，无窗口副本" :
                    scanStatus == "SKIP" ? "完整扫描前提不足，未评估副本数量" : "全部本进程扫描数量或身份不符合四个真实项",
                extra: ["expectedLogicalCount": fixtures.count, "actualLogicalCount": allOwnEntries.count])
            let managerIdentifier = Bundle.main.bundleIdentifier ?? "local.MenuBarNest"
            report("scanOverview", status: "INFO", detail: "仅输出逻辑项数量，不输出个人应用名称或身份",
                extra: ["totalLogicalCount": allEntries.count, "testLogicalCount": allOwnEntries.count,
                        "externalLogicalCount": allEntries.filter {
                            $0.processIdentifier != pid && $0.bundleIdentifier != managerIdentifier
                        }.count])
            guard scanPassed && uniqueScanPassed else {
                for check in ["capture", "move", "identity", "hide", "offscreenMove", "restore"] {
                    report(check, status: "SKIP", detail: "自建图标完整扫描未通过或环境前提不足，未执行后续操作")
                }
                return false
            }

            if CommandLine.arguments.contains("--scan-only") {
                // 重复枚举回归只观察元数据，不发送鼠标事件、不读取任何窗口图像。
                let initialLogicalIDs = Set(allOwnEntries.map(\.id))
                var stableRefresh = true
                for _ in 0..<3 {
                    try await Task.sleep(for: .milliseconds(120))
                    let refreshed = system.scan(excludingPID: -1).filter { $0.processIdentifier == pid }
                    stableRefresh = stableRefresh && refreshed.count == fixtures.count &&
                        Set(refreshed.map(\.id)) == initialLogicalIDs
                }
                report("scanRefresh", status: stableRefresh ? "PASS" : "FAIL",
                    detail: stableRefresh ? "重复刷新保持四个逻辑项及相同身份" : "重复刷新出现重复、丢失或身份变化")
                let passed = stableRefresh && !reportOutputFailed
                report("summary", status: passed ? "PASS" : "FAIL",
                    detail: passed ? "重复枚举与刷新身份回归通过，未执行截图或鼠标操作" : "重复枚举或刷新身份回归未通过")
                return passed
            }

            // 完整事件链必须有四个可见且已映射的原窗；菜单栏溢出不能被当作扫描数量错误。
            guard ownEntries.count == fixtures.count && visibleOriginalIDs.count == fixtures.count else {
                for check in ["capture", "move", "identity", "hide", "offscreenMove", "restore"] {
                    report(check, status: "SKIP", detail: "部分自建窗口当前不可见或未映射，未执行完整系统事件链")
                }
                report("summary", status: "SKIP", detail: "逻辑数量回归已通过，当前环境不满足全部窗口操作验证前提")
                return false
            }

            let initialIDs = Dictionary(uniqueKeysWithValues: ownEntries.map { ($0.windowID, $0.id) })
            var capturePassed = false
            if CGPreflightScreenCaptureAccess(), let first = ownEntries.first {
                let image = await system.captureIcon(for: first)
                capturePassed = image.map(hasVisiblePixels) ?? false
                report("capture", status: capturePassed ? "PASS" : "FAIL",
                    detail: capturePassed ? "自建图标单窗口截图包含有效像素" : "自建图标单窗口截图为空或不可获取")
            } else {
                report("capture", status: "SKIP", detail: "未授予录屏权限，不主动触发权限请求")
            }

            let ordered = ownEntries.sorted { $0.frame.minX < $1.frame.minX }
            guard let source = ordered.first, ordered.count >= 3 else { return false }
            let target = ordered[2]
            let accessibilityGranted = AXIsProcessTrusted()
            if accessibilityGranted && !safeOwnSegment(from: source.frame, through: target.frame, allEntries: allEntries, pid: pid) {
                report("move", status: "SKIP", detail: "自建图标之间存在其他进程状态项，未执行排序")
                for check in ["identity", "hide", "offscreenMove", "restore"] {
                    report(check, status: "SKIP", detail: "不能确认只操作自建图标")
                }
                return false
            }
            var movePassed = false
            if !accessibilityGranted {
                report("move", status: "SKIP", detail: "未授予辅助功能权限，未发送任何拖动事件")
            } else {
                do {
                    // 目标位于自建测试组内部；禁止跨越个人图标或拖到桌面。
                    try await system.move(source, to: CGPoint(x: target.frame.maxX - 2, y: target.frame.midY))
                    try await Task.sleep(for: .milliseconds(550))
                    let sourceNow = snapshot(windowID: source.windowID)
                    let targetNow = snapshot(windowID: target.windowID)
                    movePassed = sourceNow.map { s in targetNow.map { s.frame.midX > $0.frame.midX } ?? false } ?? false
                    report("move", status: movePassed ? "PASS" : "FAIL",
                        detail: movePassed ? "自建图标 Command 拖动后顺序发生预期变化" : "自建图标最终顺序未达到预期",
                        extra: ["coordinates": coordinates(fixtures)])
                } catch {
                    report("move", status: "FAIL", detail: "系统未接受或未确认自建图标拖动")
                }
            }
            allEntries = system.scan(excludingPID: -1)
            ownEntries = fixtureEntries(from: allEntries, fixtures: fixtures, pid: pid)
            let identityPassed = accessibilityGranted && ownEntries.count == fixtures.count && ownEntries.allSatisfy { initialIDs[$0.windowID] == $0.id }
            report("identity", status: !accessibilityGranted ? "SKIP" : identityPassed ? "PASS" : "FAIL",
                detail: !accessibilityGranted ? "未执行拖动，未验证移动后的身份稳定性" : identityPassed ? "移动后自建状态项身份保持不变" : "移动后自建状态项身份丢失或改变")

            // 排序动画完全结束后再选择分隔项；若有可见阻挡项，只移动自建组。
            try await Task.sleep(for: .milliseconds(550))
            guard let prepared = try await placeOwnGroupSafely(system: system, fixtures: fixtures, pid: pid) else {
                report("hide", status: "SKIP", detail: "无法安全放置自建分隔项，未收起个人图标")
                report("offscreenMove", status: "SKIP", detail: "自建组安全放置未通过")
                report("restore", status: "SKIP", detail: "未扩大任何状态项长度")
                return false
            }
            allEntries = prepared
            ownEntries = fixtureEntries(from: allEntries, fixtures: fixtures, pid: pid)

            let currentOrder = ownEntries.sorted { $0.frame.minX < $1.frame.minX }
            guard currentOrder.count == fixtures.count else {
                for check in ["hide", "offscreenMove", "restore"] { report(check, status: "SKIP", detail: "移动后自建图标扫描不完整") }
                return false
            }
            let left = currentOrder[0]
            let dividerEntry = currentOrder[1]
            let anchor = currentOrder[2]
            let blockers = allEntries.filter {
                $0.processIdentifier != pid && abs($0.frame.midY - dividerEntry.frame.midY) < 8 &&
                $0.frame.minX < dividerEntry.frame.minX
            }
            let unknownBlockers = blockers.filter { snapshot(windowID: $0.windowID) == nil }
            let visibleBlockers = blockers.filter { snapshot(windowID: $0.windowID)?.isOnScreen == true }
            let offscreenBlockers = blockers.filter { snapshot(windowID: $0.windowID)?.isOnScreen == false }
            report("hideSafety", status: visibleBlockers.isEmpty && unknownBlockers.isEmpty ? "PASS" : "SKIP",
                detail: "仅输出阻挡项数量，不记录个人软件身份或位置",
                extra: ["blockerCountVisible": visibleBlockers.count, "blockerCountOffscreen": offscreenBlockers.count,
                        "blockerCountUnknown": unknownBlockers.count])
            guard let divider = fixtures.first(where: { $0.windowID == dividerEntry.windowID }),
                  visibleBlockers.isEmpty, unknownBlockers.isEmpty
            else {
                report("hide", status: "SKIP", detail: "分隔项左侧存在可见或状态未知的其他进程图标，禁止扩大长度")
                report("offscreenMove", status: "SKIP", detail: "收起安全检查未通过")
                report("restore", status: "SKIP", detail: "未扩大任何状态项长度")
                return false
            }

            divider.item.length = 10_000
            try await Task.sleep(for: .milliseconds(500))
            let hidden = snapshot(windowID: left.windowID)
            // 原本屏幕外的个人项只能继续保持不可见；一旦变化立即恢复长度。
            let personalHiddenUnchanged = offscreenBlockers.allSatisfy { snapshot(windowID: $0.windowID)?.isOnScreen == false }
            let hidePassed = (hidden.map { !$0.isOnScreen || !intersectsMenuBar($0.frame) } ?? false) && personalHiddenUnchanged
            report("hide", status: hidePassed ? "PASS" : "FAIL",
                detail: hidePassed ? "只收起了自建分隔项左侧的测试图标" : "分隔项扩大后自建左项未确认隐藏",
                extra: ["coordinates": coordinates(fixtures), "personalHiddenStateUnchanged": personalHiddenUnchanged])
            // 收起后仍需保留同一逻辑项，避免修复重复时把屏幕外项从下拉列表丢掉。
            let hiddenOwnEntries = system.scan(excludingPID: -1).filter { $0.processIdentifier == pid }
            let hiddenIdentityPassed = hiddenOwnEntries.count == fixtures.count &&
                Set(hiddenOwnEntries.map(\.id)) == Set(initialIDs.values)
            report("hiddenIdentity", status: hiddenIdentityPassed ? "PASS" : "FAIL",
                detail: hiddenIdentityPassed ? "收起后四个逻辑身份及数量保持不变" : "收起后逻辑项丢失、重复或身份发生变化")
            if !personalHiddenUnchanged {
                divider.item.length = divider.originalLength
                report("offscreenMove", status: "SKIP", detail: "原本隐藏项状态发生变化，已立即恢复自建分隔项长度")
                report("restore", status: "SKIP", detail: "安全保护已恢复长度，由清理流程移除全部自建项")
                return false
            }

            var offscreenPassed = false
            if !AXIsProcessTrusted() {
                report("offscreenMove", status: "SKIP", detail: "未授予辅助功能权限，未发送屏幕外恢复事件")
            } else if hidePassed, let hidden, let anchorNow = snapshot(windowID: anchor.windowID), anchorNow.isOnScreen {
                // 屏幕外实验只发送给本进程，目标在自建可见锚点内，不给桌面发送事件。
                let destination = CGPoint(x: anchorNow.frame.midX, y: anchorNow.frame.midY)
                offscreenPassed = try await moveOwnOffscreen(left, from: hidden.frame, to: destination, pid: pid)
                report("offscreenMove", status: offscreenPassed ? "PASS" : "FAIL",
                    detail: offscreenPassed ? "公开 postToPid 恢复了屏幕外自建图标" : "公开 postToPid 未恢复屏幕外自建图标",
                    extra: ["coordinates": coordinates(fixtures)])
            } else {
                report("offscreenMove", status: "SKIP", detail: "未形成可安全验证的屏幕外自建图标")
            }

            divider.item.length = divider.originalLength
            try await Task.sleep(for: .milliseconds(500))
            let restorePassed = fixtures.allSatisfy { fixture in
                guard let id = fixture.windowID, let state = snapshot(windowID: id) else { return false }
                return state.isOnScreen && intersectsMenuBar(state.frame)
            } && offscreenBlockers.allSatisfy { snapshot(windowID: $0.windowID)?.isOnScreen == false }
            report("restore", status: restorePassed ? "PASS" : "FAIL",
                detail: restorePassed ? "自建分隔项缩回后全部测试图标恢复可见" : "测试图标未全部确认恢复可见",
                extra: ["coordinates": coordinates(fixtures)])
            let result = uniqueScanPassed && capturePassed && movePassed && identityPassed && hidePassed && hiddenIdentityPassed && offscreenPassed && restorePassed && !reportOutputFailed
            report("summary", status: result ? "PASS" : "FAIL", detail: result ? "自建图标系统自检全部通过" : "存在失败或跳过，真实系统能力未全部验证")
            return result && !reportOutputFailed
        } catch {
            report("summary", status: "FAIL", detail: "自检已取消或发生异常，正在恢复并清理自建图标")
            return false
        }
    }

    /// 以唯一存储名创建临时图标，避免恢复个人或上次运行的位置。
    private static func createFixtures() -> [Fixture] {
        let prefix = "MenuBarNest.SelfCheck." + UUID().uuidString
        return ["A", "B", "C", "D"].map { label in
            let item = NSStatusBar.system.statusItem(withLength: 26)
            item.autosaveName = prefix + "." + label
            let autosaveRestoredVisible = item.isVisible
            // 测试项独立显式显示，避免 autosave 恢复行为影响自检准备阶段。
            item.isVisible = true
            item.button?.title = label
            item.button?.font = NSFont.systemFont(ofSize: 12, weight: .bold)
            let menu = NSMenu(title: "菜单栏收纳自检")
            let menuItem = NSMenuItem(title: "自建测试图标 " + label, action: nil, keyEquivalent: "")
            menuItem.isEnabled = false
            menu.addItem(menuItem)
            item.menu = menu
            return Fixture(label: label, item: item, originalLength: 26, autosaveRestoredVisible: autosaveRestoredVisible)
        }
    }

    /// 反复配置已创建的自建按钮，兼容应用启动后异步补建状态窗口的时序。
    private static func configureFixtureButtons(_ fixtures: [Fixture]) {
        for fixture in fixtures {
            fixture.item.isVisible = true
            fixture.item.button?.title = fixture.label
            fixture.item.button?.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        }
    }

    /// 交叉核对原始测试窗口并输出本进程状态层几何，返回可用于评估扫描遗漏的原始窗口集合。
    private static func reportFixtureWindows(_ fixtures: [Fixture], pid: pid_t) -> (eligibleIDs: Set<CGWindowID>, allRecordsMatched: Bool) {
        let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        let excludedRows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        var ownWindowDiagnostics = [[String: Any]]()
        var eligibleFixtureIDs = Set<CGWindowID>()
        var originalMenuBarCount = 0
        var visibleOriginalMenuBarCount = 0
        var matchedIDCount = 0
        var matchedPIDCount = 0
        var matchedStatusLayerCount = 0
        var excludedIDMatchCount = 0
        var consistentWindowCount = 0
        var parsedRecordCount = 0
        var visibleAppKitWindowCount = 0
        for fixture in fixtures {
            var payload: [String: Any] = ["fixture": fixture.label, "statusItemVisible": fixture.item.isVisible,
                "hasButton": fixture.item.button != nil, "hasWindow": fixture.item.button?.window != nil]
            if let window = fixture.item.button?.window {
                let number = window.windowNumber
                let frame = window.frame
                payload["windowNumber"] = number
                payload["windowVisible"] = window.isVisible
                payload["appKitX"] = frame.minX
                payload["appKitY"] = frame.minY
                payload["appKitWidth"] = frame.width
                payload["appKitHeight"] = frame.height
                if window.isVisible { visibleAppKitWindowCount += 1 }
                let matchedRow = rows?.first {
                    ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == number &&
                    ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                }
                let excludedRow = excludedRows?.first {
                    ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == number &&
                    ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                }
                payload["foundInCGOptionAll"] = matchedRow != nil
                payload["foundInCGExcludeDesktop"] = excludedRow != nil
                if excludedRow != nil { excludedIDMatchCount += 1 }
                if let matchedRow {
                    matchedIDCount += 1
                    let ownerMatches = (matchedRow[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                    let layer = (matchedRow[kCGWindowLayer as String] as? NSNumber)?.intValue
                    payload["cgOwnerMatchesCurrentPID"] = ownerMatches
                    if ownerMatches { matchedPIDCount += 1 }
                    if let layer {
                        payload["cgLayer"] = layer
                        if layer == Int(CGWindowLevelForKey(.statusWindow)) { matchedStatusLayerCount += 1 }
                    }
                    let bounds = matchedRow[kCGWindowBounds as String] as? NSDictionary
                    let parsedBounds = bounds.flatMap { CGRect(dictionaryRepresentation: $0) }
                    payload["cgBoundsPresent"] = bounds != nil
                    payload["cgBoundsParsed"] = parsedBounds != nil
                    payload["cgNumberParsed"] = matchedRow[kCGWindowNumber as String] is NSNumber
                    payload["cgPIDParsed"] = matchedRow[kCGWindowOwnerPID as String] is NSNumber
                    payload["cgLayerParsed"] = layer != nil
                    if let bounds {
                        for field in ["X", "Y", "Width", "Height"] {
                            if let number = bounds[field] as? NSNumber { payload["rawCGBounds" + field] = number }
                        }
                    }
                    if let cgFrame = parsedBounds {
                        payload["cgX"] = cgFrame.minX
                        payload["cgY"] = cgFrame.minY
                        payload["cgWidth"] = cgFrame.width
                        payload["cgHeight"] = cgFrame.height
                        payload["cgOnScreen"] = matchedRow[kCGWindowIsOnscreen as String] as? Bool ?? false
                        payload["passesStatusLayer"] = layer == Int(CGWindowLevelForKey(.statusWindow))
                        payload["passesWidth"] = cgFrame.width > 0 && cgFrame.width < 600
                        payload["passesHeight"] = cgFrame.height > 0 && cgFrame.height <= max(40, NSStatusBar.system.thickness + 8)
                        let minimumYDistance = menuBarStrips().map { abs($0.midY - cgFrame.midY) }.min()
                        if let minimumYDistance { payload["minimumMenuStripYDistance"] = minimumYDistance }
                        let passesMenuStripY = minimumYDistance.map { $0 <= 6 } ?? false
                        payload["passesMenuStripY"] = passesMenuStripY
                        if passesMenuStripY {
                            originalMenuBarCount += 1
                            if matchedRow[kCGWindowIsOnscreen as String] as? Bool == true, intersectsMenuBar(cgFrame) {
                                visibleOriginalMenuBarCount += 1
                            }
                        }
                        if ownerMatches, layer == Int(CGWindowLevelForKey(.statusWindow)),
                           cgFrame.width > 0, cgFrame.width < 600,
                           cgFrame.height > 0, cgFrame.height <= max(40, NSStatusBar.system.thickness + 8),
                           passesMenuStripY, let id = fixture.windowID {
                            eligibleFixtureIDs.insert(id)
                        }
                        if layer != nil, matchedRow[kCGWindowOwnerPID as String] is NSNumber,
                           matchedRow[kCGWindowNumber as String] is NSNumber { parsedRecordCount += 1 }
                        if let excludedRow,
                           let excludedBounds = excludedRow[kCGWindowBounds as String] as? NSDictionary,
                           let excludedFrame = CGRect(dictionaryRepresentation: excludedBounds) {
                            let same = cgFrame == excludedFrame &&
                                (excludedRow[kCGWindowLayer as String] as? NSNumber)?.intValue == layer &&
                                (excludedRow[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ==
                                (matchedRow[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                            payload["sameMetadataWithExcludeDesktop"] = same
                            if same { consistentWindowCount += 1 }
                        }
                    }
                }
            }
            ownWindowDiagnostics.append(payload)
        }
        let ownRows = rows?.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid } ?? []
        let ownStatusRows = ownRows.filter {
            ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.statusWindow))
        }
        let fixtureLabels = Dictionary(uniqueKeysWithValues: fixtures.compactMap { fixture in
            fixture.windowID.map { ($0, fixture.label) }
        })
        var ownStatusMenuBarCount = 0
        var visibleOwnStatusMenuBarCount = 0
        // 仅遍历当前 PID 的状态层窗口；不能借诊断输出其他进程身份或几何。
        let ownStatusDiagnostics: [[String: Any]] = ownStatusRows.map { row in
            let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            let bounds = row[kCGWindowBounds as String] as? NSDictionary
            let frame = bounds.flatMap { CGRect(dictionaryRepresentation: $0) }
            let onScreen = row[kCGWindowIsOnscreen as String] as? Bool ?? false
            var payload: [String: Any] = ["cgBoundsParsed": frame != nil, "cgOnScreen": onScreen,
                "matchesOriginalFixture": id.flatMap { fixtureLabels[$0] } != nil]
            if let id {
                payload["windowNumber"] = id
                if let label = fixtureLabels[id] { payload["fixture"] = label }
            }
            if let frame {
                payload["cgX"] = frame.minX
                payload["cgY"] = frame.minY
                payload["cgWidth"] = frame.width
                payload["cgHeight"] = frame.height
                let minimumYDistance = menuBarStrips().map { abs($0.midY - frame.midY) }.min()
                let passesMenuStripY = minimumYDistance.map { $0 <= 6 } ?? false
                payload["passesMenuStripY"] = passesMenuStripY
                if let minimumYDistance { payload["minimumMenuStripYDistance"] = minimumYDistance }
                if passesMenuStripY {
                    ownStatusMenuBarCount += 1
                    if onScreen, intersectsMenuBar(frame) { visibleOwnStatusMenuBarCount += 1 }
                }
            }
            return payload
        }
        report("fixtureWindowDiagnostics", status: matchedIDCount == fixtures.count && matchedPIDCount == fixtures.count ? "PASS" : "FAIL",
            detail: "仅交叉核对自建 AppKit 窗口与 CG 清单，不输出个人窗口信息",
            extra: ["cgOptionAllAvailable": rows != nil, "fixtureWindowIDMatchCount": matchedIDCount,
                "fixtureWindowPIDMatchCount": matchedPIDCount, "fixtureLayer25MatchCount": matchedStatusLayerCount,
                "cgExcludeDesktopAvailable": excludedRows != nil, "fixtureExcludeDesktopMatchCount": excludedIDMatchCount,
                "fixtureMetadataConsistentCount": consistentWindowCount, "fixtureParsableRecordCount": parsedRecordCount,
                "visibleAppKitWindowCount": visibleAppKitWindowCount, "currentPIDWindowCount": ownRows.count,
                "currentPIDLayer25WindowCount": ownStatusRows.count,
                "originalFixtureMenuBarStripCount": originalMenuBarCount,
                "visibleOriginalFixtureMenuBarCount": visibleOriginalMenuBarCount,
                "eligibleOriginalFixtureCount": eligibleFixtureIDs.count,
                "currentPIDLayer25MenuBarStripCount": ownStatusMenuBarCount,
                "visibleCurrentPIDLayer25MenuBarCount": visibleOwnStatusMenuBarCount,
                "accessibilityGranted": AXIsProcessTrusted(), "screenRecordingGranted": CGPreflightScreenCaptureAccess(),
                "fixtureWindows": ownWindowDiagnostics, "currentPIDLayer25Windows": ownStatusDiagnostics])
        let screens: [[String: Any]] = NSScreen.screens.enumerated().map { index, screen in
            var payload: [String: Any] = ["index": index, "appKitX": screen.frame.minX, "appKitY": screen.frame.minY,
                "appKitWidth": screen.frame.width, "appKitHeight": screen.frame.height,
                "backingScale": screen.backingScaleFactor]
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let cgFrame = CGDisplayBounds(number.uint32Value)
                payload["cgDisplayX"] = cgFrame.minX
                payload["cgDisplayY"] = cgFrame.minY
                payload["cgDisplayWidth"] = cgFrame.width
                payload["cgDisplayHeight"] = cgFrame.height
            }
            return payload
        }
        let strips: [[String: Any]] = menuBarStrips().map {
            ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height]
        }
        report("screenGeometryDiagnostics", status: "PASS", detail: "仅输出显示器几何与推导菜单栏条带，不采集屏幕图像",
            extra: ["statusBarThickness": NSStatusBar.system.thickness, "screens": screens, "derivedMenuBarStrips": strips])
        return (eligibleFixtureIDs, matchedPIDCount == fixtures.count && parsedRecordCount == fixtures.count)
    }

    /// 从公开扫描结果中只选择当前进程创建的测试窗口。
    private static func fixtureEntries(from entries: [MenuBarEntry], fixtures: [Fixture], pid: pid_t) -> [MenuBarEntry] {
        let fixtureIDs = Set(fixtures.compactMap(\.windowID))
        return entries.filter { $0.processIdentifier == pid && fixtureIDs.contains($0.windowID) }
    }

    /// 检查测试拖动区间中没有其他进程状态项。
    private static func safeOwnSegment(from start: CGRect, through end: CGRect, allEntries: [MenuBarEntry], pid: pid_t) -> Bool {
        let lower = min(start.minX, end.minX)
        let upper = max(start.maxX, end.maxX)
        return !allEntries.contains {
            $0.processIdentifier != pid && abs($0.frame.midY - start.midY) < 8 &&
            $0.frame.maxX > lower && $0.frame.minX < upper
        }
    }

    /// 必要时只移动测试组到可见个人项左侧，并核对个人项相对顺序未改变。
    private static func placeOwnGroupSafely(system: MenuBarSystem, fixtures: [Fixture], pid: pid_t) async throws -> [MenuBarEntry]? {
        var allEntries = system.scan(excludingPID: -1)
        var own = fixtureEntries(from: allEntries, fixtures: fixtures, pid: pid).sorted { $0.frame.minX < $1.frame.minX }
        guard own.count == fixtures.count else { return nil }
        let rowY = own[0].frame.midY
        let originalOtherOrder = allEntries.filter {
            $0.processIdentifier != pid && abs($0.frame.midY - rowY) < 8 && snapshot(windowID: $0.windowID)?.isOnScreen == true
        }.sorted { $0.frame.minX < $1.frame.minX }.map(\.windowID)
        let visibleLeftCount = allEntries.filter {
            $0.processIdentifier != pid && abs($0.frame.midY - rowY) < 8 &&
            $0.frame.minX < own[1].frame.minX && snapshot(windowID: $0.windowID)?.isOnScreen == true
        }.count
        if visibleLeftCount == 0 { return allEntries }
        guard AXIsProcessTrusted() else {
            report("fixturePlacement", status: "SKIP", detail: "未授予辅助功能权限，无法只调整自建组的安全位置")
            return nil
        }

        for fixture in fixtures {
            try Task.checkCancellation()
            allEntries = system.scan(excludingPID: -1)
            own = fixtureEntries(from: allEntries, fixtures: fixtures, pid: pid)
            guard let source = own.first(where: { $0.windowID == fixture.windowID }),
                  let leftmostOther = allEntries.filter({
                      $0.processIdentifier != pid && abs($0.frame.midY - rowY) < 8 &&
                      snapshot(windowID: $0.windowID)?.isOnScreen == true
                  }).min(by: { $0.frame.minX < $1.frame.minX })
            else { return nil }
            if source.frame.maxX <= leftmostOther.frame.minX + 1 { continue }
            let destination = CGPoint(x: leftmostOther.frame.minX + 1, y: source.frame.midY)
            // 不跨屏幕、不向桌面发事件；系统移动接口也会再检查真实菜单栏目标。
            guard menuBarStrips().contains(where: {
                $0.contains(CGPoint(x: source.frame.midX, y: source.frame.midY)) && $0.contains(destination)
            }) else {
                report("fixturePlacement", status: "SKIP", detail: "阻挡项位于另一显示器，禁止跨屏幕拖动自建图标")
                return nil
            }
            do {
                try await system.move(source, to: destination)
                try await Task.sleep(for: .milliseconds(550))
            } catch {
                report("fixturePlacement", status: "FAIL", detail: "系统未确认只针对自建图标的安全放置")
                return nil
            }
        }

        allEntries = system.scan(excludingPID: -1)
        let currentOtherOrder = allEntries.filter {
            $0.processIdentifier != pid && abs($0.frame.midY - rowY) < 8 && snapshot(windowID: $0.windowID)?.isOnScreen == true
        }.sorted { $0.frame.minX < $1.frame.minX }.map(\.windowID)
        let orderUnchanged = currentOtherOrder == originalOtherOrder
        report("fixturePlacement", status: orderUnchanged ? "PASS" : "FAIL",
            detail: orderUnchanged ? "只移动自建组，其他进程可见状态项相对顺序保持不变" : "无法确认其他进程状态项的相对顺序保持不变",
            extra: ["coordinates": coordinates(fixtures)])
        return orderUnchanged ? allEntries : nil
    }

    /// 只读取指定自建窗口的元数据，供隐藏与排序结果核对。
    private static func snapshot(windowID: CGWindowID) -> Snapshot? {
        guard let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]],
              let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              let bounds = row[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds)
        else { return nil }
        return Snapshot(windowID: windowID, frame: frame, isOnScreen: row[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }

    /// 直接使用 Quartz 显示器坐标，所有实验目标必须保持在实际菜单栏矩形内。
    private static func menuBarStrips() -> [CGRect] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let bounds = CGDisplayBounds(number.uint32Value)
            guard !bounds.isEmpty, !bounds.isNull else { return nil }
            return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: NSStatusBar.system.thickness)
        }
    }

    /// 检查窗口是否仍然与某个屏幕的菜单栏可见区域相交。
    private static func intersectsMenuBar(_ frame: CGRect) -> Bool {
        menuBarStrips().contains { !$0.intersection(frame).isNull && $0.intersection(frame).width > 1 }
    }

    /// 仅针对本进程隐藏测试图标验证公开定向事件路径；不复用于个人软件。
    private static func moveOwnOffscreen(_ entry: MenuBarEntry, from initial: CGRect, to destination: CGPoint, pid: pid_t) async throws -> Bool {
        try Task.checkCancellation()
        guard entry.processIdentifier == pid, pid == ProcessInfo.processInfo.processIdentifier,
              AXIsProcessTrusted(), menuBarStrips().contains(where: { $0.contains(destination) }),
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              let source = CGEventSource(stateID: .hidSystemState)
        else { return false }
        let token = Int64.random(in: 1...Int64.max)
        let origin = CGPoint(x: initial.midX, y: initial.midY)
        guard let down = fixtureEvent(.leftMouseDown, at: origin, entry: entry, source: source, token: token),
              let drag = fixtureEvent(.leftMouseDragged, at: destination, entry: entry, source: source, token: token),
              let up = fixtureEvent(.leftMouseUp, at: destination, entry: entry, source: source, token: token)
        else { return false }
        var mouseIsDown = false
        defer { if mouseIsDown { up.postToPid(pid) } }
        down.postToPid(pid)
        mouseIsDown = true
        try await Task.sleep(for: .milliseconds(80))
        drag.postToPid(pid)
        try await Task.sleep(for: .milliseconds(100))
        up.postToPid(pid)
        mouseIsDown = false
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if let current = snapshot(windowID: entry.windowID), current.isOnScreen,
               abs(current.frame.midX - destination.x) <= max(12, initial.width + 4), intersectsMenuBar(current.frame) {
                return true
            }
        }
        return false
    }

    /// 生成只指向本进程自建窗口的 Command 鼠标事件。
    private static func fixtureEvent(_ type: CGEventType, at point: CGPoint, entry: MenuBarEntry,
                                     source: CGEventSource, token: Int64) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return nil }
        event.flags = .maskCommand
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(entry.windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(entry.windowID))
        event.setIntegerValueField(.eventSourceUserData, value: token)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        return event
    }

    /// 将截图合成到中性背景并检查亮度变化，纯色或透明空图不会算作通过。
    private static func hasVisiblePixels(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32,
                bitsPerComponent: 8, bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // 黑色模板图标可能 RGB 全零；中性背景让有效透明边缘与笔画产生亮度差。
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            var minimum = 255
            var maximum = 0
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let brightness = (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
                minimum = min(minimum, brightness)
                maximum = max(maximum, brightness)
            }
            return maximum - minimum >= 16
        }
    }

    /// 输出自建测试图标的坐标，绝不输出其他软件的名称、编号或位置。
    private static func coordinates(_ fixtures: [Fixture]) -> [[String: Any]] {
        fixtures.compactMap { fixture in
            guard let id = fixture.windowID, let state = snapshot(windowID: id) else { return nil }
            return ["fixture": fixture.label, "x": state.frame.minX, "y": state.frame.minY,
                "width": state.frame.width, "height": state.frame.height, "onScreen": state.isOnScreen]
        }
    }

    /// 按阶段打印 JSON 的 PASS、FAIL 或 SKIP，避免未执行的检查被算作成功。
    static func report(_ check: String, status: String, detail: String, extra: [String: Any] = [:]) {
        var payload = extra
        payload["check"] = check
        payload["status"] = status
        payload["detail"] = detail
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return }
        print(text)
        guard let reportOutputURL else { return }
        do {
            let handle = try FileHandle(forWritingTo: reportOutputURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            var line = data
            line.append(0x0A)
            try handle.write(contentsOf: line)
        } catch {
            reportOutputFailed = true
            print("{\"check\":\"reportOutput\",\"status\":\"FAIL\",\"detail\":\"无法追加显式自检输出文件\"}")
        }
    }

    /// 仅接受显式参数指定的输出文件；存在时追加，禁止覆盖已有内容。
    private static func configureReportOutput() -> Bool {
        reportOutputURL = nil
        reportOutputFailed = false
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--self-check-output") else { return true }
        guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
            report("reportOutput", status: "FAIL", detail: "缺少显式自检输出文件路径")
            return false
        }
        let path = arguments[index + 1]
        // LaunchServices 可能以根目录为 cwd；相对路径在该情形下不能推测为本次工作目录。
        guard path.hasPrefix("/") || FileManager.default.currentDirectoryPath != "/" else {
            report("reportOutput", status: "FAIL", detail: "当前启动目录为根目录，请传入临时自检输出文件的绝对路径")
            return false
        }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.createFile(atPath: url.path, contents: Data()) {
            report("reportOutput", status: "FAIL", detail: "无法创建显式自检输出文件，请确认临时目录已存在")
            return false
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.close()
        } catch {
            report("reportOutput", status: "FAIL", detail: "显式自检输出文件不可写")
            return false
        }
        reportOutputURL = url
        return true
    }
}

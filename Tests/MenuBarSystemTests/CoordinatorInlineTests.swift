import AppKit
import XCTest
@testable import MenuBarNest

/// 通过匿名系统观测验证真实协调器的同一行开合、回退及权限生命周期。
@MainActor
final class CoordinatorInlineTests: XCTestCase {
    /// 辅助功能已授权且无录屏权限时，原生同一行展开及收起均可完成。
    func testInlineExpansionAndCollapseWithoutScreenRecording() async throws {
        let fixture = InlineFixture()
        let model = makeCoordinator(fixture: fixture)

        model.toggleInlineExpansion()
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.inlineExpanded)
        try await waitUntilIdle(model)

        XCTAssertTrue(model.inlineExpanded)
        XCTAssertTrue(model.managementActive)
        XCTAssertFalse(model.screenRecordingGranted)
        XCTAssertNil(model.errorMessage)
        XCTAssertGreaterThanOrEqual(fixture.scanCount, 3)

        model.toggleInlineExpansion()
        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(model.inlineExpanded)
        try await waitUntilIdle(model)

        XCTAssertFalse(model.inlineExpanded)
        XCTAssertTrue(model.managementActive)
        XCTAssertFalse(model.screenRecordingGranted)
        XCTAssertNil(model.errorMessage)
        XCTAssertGreaterThanOrEqual(fixture.scanCount, 6)
        XCTAssertEqual(fixture.boundaryRequests, [
            BoundaryRequest(collapsed: false, hidden: true),
            BoundaryRequest(collapsed: true, hidden: true)
        ])
        XCTAssertEqual(fixture.forbiddenOperationCount, 0)
    }

    /// 同一异步开合正在确认时，连续点击不会启动反向或重复边界操作。
    func testRapidClicksDoNotStartConcurrentToggle() async throws {
        let fixture = InlineFixture()
        let model = makeCoordinator(fixture: fixture)

        model.toggleInlineExpansion()
        XCTAssertTrue(model.isBusy)
        model.toggleInlineExpansion()
        model.toggleInlineExpansion()
        try await waitUntilIdle(model)

        XCTAssertTrue(model.inlineExpanded)
        XCTAssertTrue(model.managementActive)
        XCTAssertEqual(fixture.boundaryRequests, [BoundaryRequest(collapsed: false, hidden: true)])
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(fixture.forbiddenOperationCount, 0)
    }

    /// 展开项目被挤出菜单栏时，恢复已确认的收起状态且保持管理有效。
    func testInsufficientSpaceRestoresCollapsedState() async throws {
        let fixture = InlineFixture(failure: .expandedItemOutside)
        let model = makeCoordinator(fixture: fixture)

        model.toggleInlineExpansion()
        try await waitUntilIdle(model)

        assertRecoveredCollapsedState(model, fixture: fixture)
        XCTAssertTrue(model.errorMessage?.contains("空间不足") == true)
    }

    /// 缺少当前窗口映射的逻辑项不得被计为展开成功，回退后仍可继续管理。
    func testMissingWindowMappingRestoresCollapsedState() async throws {
        let fixture = InlineFixture(failure: .expandedMissingWindow)
        let model = makeCoordinator(fixture: fixture)

        model.toggleInlineExpansion()
        try await waitUntilIdle(model)

        assertRecoveredCollapsedState(model, fixture: fixture)
    }

    /// 逻辑键相同但当前进程已变化时，旧项目不能通过开合确认。
    func testChangedProcessRestoresCollapsedState() async throws {
        let fixture = InlineFixture(failure: .expandedProcessChanged)
        let model = makeCoordinator(fixture: fixture)

        model.toggleInlineExpansion()
        try await waitUntilIdle(model)

        assertRecoveredCollapsedState(model, fixture: fixture)
    }

    /// 展开后控制入口被挤出菜单栏时，拒绝成功并恢复可访问的收起状态。
    func testControllerOutsideBarRestoresCollapsedState() async throws {
        let fixture = InlineFixture(failure: .expandedControllerOutside)
        let model = makeCoordinator(fixture: fixture)

        model.toggleInlineExpansion()
        try await waitUntilIdle(model)

        assertRecoveredCollapsedState(model, fixture: fixture)
        XCTAssertTrue(model.errorMessage?.contains("空间不足") == true)
    }

    /// 坐标看似正确但实时可见性未知时，不能把展开状态更新为成功。
    func testUnknownVisibilityRestoresCollapsedState() async throws {
        let fixture = InlineFixture(failure: .expandedUnknownVisibility)
        let model = makeCoordinator(fixture: fixture)

        model.toggleInlineExpansion()
        try await waitUntilIdle(model)

        assertRecoveredCollapsedState(model, fixture: fixture)
    }

    /// 控制入口有菜单栏坐标但已不在屏幕上时，仍然必须拒绝展开成功。
    func testControllerNotOnScreenRestoresCollapsedState() async throws {
        let fixture = InlineFixture(failure: .expandedControllerOffscreen)
        let model = makeCoordinator(fixture: fixture)

        model.toggleInlineExpansion()
        try await waitUntilIdle(model)

        assertRecoveredCollapsedState(model, fixture: fixture)
        XCTAssertTrue(model.errorMessage?.contains("空间不足") == true)
    }

    /// 进行中的展开确认遇到辅助功能权限撤销时，撤销全部收纳并暂停管理。
    func testAccessibilityRevokedDuringExpansionSuspendsManagement() async throws {
        let fixture = InlineFixture()
        let model = makeCoordinator(fixture: fixture)
        fixture.onScan = { [weak fixture] in fixture?.accessibilityAllowed = false }

        model.toggleInlineExpansion()
        XCTAssertTrue(model.isBusy)
        try await waitUntilIdle(model)

        XCTAssertFalse(model.inlineExpanded)
        XCTAssertFalse(model.managementActive)
        XCTAssertFalse(model.accessibilityGranted)
        XCTAssertNil(model.appliedLayout)
        XCTAssertEqual(fixture.boundaryRequests, [
            BoundaryRequest(collapsed: false, hidden: true),
            BoundaryRequest(collapsed: false, hidden: false)
        ])
        XCTAssertEqual(fixture.forbiddenOperationCount, 0)
    }

    /// 原软件菜单交互期间自动收起必须等待，交互结束后才确认收起。
    func testAutomaticCollapseWaitsForMenuInteractionToEnd() async throws {
        let fixture = InlineFixture()
        fixture.menuInteractionInProgress = true
        let model = makeCoordinator(fixture: fixture)
        // 直接设置测试内存配置，不调用会写文件的偏好保存方法。
        model.layout.autoCollapse = true
        model.layout.collapseDelay = 0.05

        model.toggleInlineExpansion()
        try await waitUntilIdle(model)
        XCTAssertTrue(model.inlineExpanded)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.inlineExpanded)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(fixture.boundaryRequests, [BoundaryRequest(collapsed: false, hidden: true)])

        fixture.menuInteractionInProgress = false
        try await waitUntilCollapsed(model)
        XCTAssertTrue(model.managementActive)
        XCTAssertEqual(fixture.boundaryRequests, [
            BoundaryRequest(collapsed: false, hidden: true),
            BoundaryRequest(collapsed: true, hidden: true)
        ])
        XCTAssertEqual(fixture.forbiddenOperationCount, 0)

        // 撤销仅本测试创建的计时器；无原始排序及自有状态项，不会移动或点击。
        await model.prepareToTerminate()
        XCTAssertFalse(model.managementActive)
        XCTAssertEqual(fixture.forbiddenOperationCount, 0)
    }

    /// 只创建预览协调器和匿名已应用规则，不安装状态项、不启动轮询、不写配置。
    private func makeCoordinator(fixture: InlineFixture) -> NestCoordinator {
        _ = NSApplication.shared
        let model = NestCoordinator(system: fixture, preview: true, inlineEnvironment: fixture.environment())
        model.configurePreview()
        model.layout.autoCollapse = false
        model.entries = fixture.currentEntries()
        model.managementActive = true
        return model
    }

    /// 在四秒内等待协调器释放忙碌状态，每次等待交还主 actor 的执行权。
    private func waitUntilIdle(_ model: NestCoordinator, file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(4))
        while model.isBusy && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isBusy, "同一行开合未在四秒内结束", file: file, line: line)
    }

    /// 给主线程计时器运行机会，在四秒内等待自动收起及其连续可见性确认完成。
    private func waitUntilCollapsed(_ model: NestCoordinator, file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(4))
        while (model.inlineExpanded || model.isBusy) && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.inlineExpanded, "自动收起未在四秒内完成", file: file, line: line)
        XCTAssertFalse(model.isBusy, "自动收起验证未在四秒内结束", file: file, line: line)
    }

    /// 失败后应保留管理规则及收起状态，普通回退始终保持隐藏边界启用。
    private func assertRecoveredCollapsedState(
        _ model: NestCoordinator, fixture: InlineFixture,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(model.inlineExpanded, file: file, line: line)
        XCTAssertTrue(model.managementActive, file: file, line: line)
        XCTAssertNotNil(model.appliedLayout, file: file, line: line)
        XCTAssertNotNil(model.errorMessage, file: file, line: line)
        XCTAssertEqual(fixture.boundaryRequests, [
            BoundaryRequest(collapsed: false, hidden: true),
            BoundaryRequest(collapsed: true, hidden: true)
        ], file: file, line: line)
        XCTAssertEqual(fixture.forbiddenOperationCount, 0, file: file, line: line)
    }

    /// 匿名记录一次协调器发出的两个边界状态请求。
    private struct BoundaryRequest: Equatable {
        /// 是否收纳收起分区。
        let collapsed: Bool
        /// 是否收纳始终隐藏分区。
        let hidden: Bool

        /// 保存一次不产生真实系统事件的边界请求。
        init(collapsed: Bool, hidden: Bool) {
            self.collapsed = collapsed
            self.hidden = hidden
        }
    }

    /// 仅在请求展开时提供异常观测，收起状态保持可验证，便于覆盖真实回退流程。
    private enum FailureScenario: Equatable {
        /// 各观测均满足请求。
        case none
        /// 展开项目移出菜单栏。
        case expandedItemOutside
        /// 展开项目缺少当前 CG 窗口映射。
        case expandedMissingWindow
        /// 展开项目所属进程变化。
        case expandedProcessChanged
        /// 展开项目实时可见性未知。
        case expandedUnknownVisibility
        /// 展开时控制入口被挤出菜单栏。
        case expandedControllerOutside
        /// 展开时控制入口被系统判为不在屏幕上。
        case expandedControllerOffscreen
    }

    /// 合成系统状态与权限变化，截图、点击和移动接口均禁止调用。
    private final class InlineFixture: MenuBarSystemManaging {
        /// 当前匿名辅助功能授权状态，可在确认过程中模拟撤销。
        var accessibilityAllowed = true
        /// 原生开合不应依赖录屏权限，所有场景默认保持未授权。
        var screenRecordingAllowed = false
        /// 原软件菜单是否仍在交互，自动收起应等待其结束。
        var menuInteractionInProgress = false
        /// 扫描完成回调，用于模拟进行中的权限变更。
        var onScan: (() -> Void)?
        /// 已收到的匿名边界控制请求。
        private(set) var boundaryRequests: [BoundaryRequest] = []
        /// 本次场景扫描次数，用于确认异步验证实际发生。
        private(set) var scanCount = 0
        /// 协调器错误调用截图、点击或移动接口的次数。
        private(set) var forbiddenOperationCount = 0
        /// 已应用规则的初始状态为收起。
        private var collapsedBoundary = true
        /// 已应用规则的隐藏区初始不可见。
        private var hiddenBoundary = true
        /// 当前场景仅在展开期间施加的观测异常。
        private let failure: FailureScenario
        /// 合成菜单栏几何，覆盖真实 22 高条带和 24 高状态窗口差异。
        private let bar = CGRect(x: 0, y: 0, width: 1000, height: 22)
        /// 所有匿名状态项正常状态下共享的合成进程编号。
        private let anonymousPID: pid_t = 9101

        /// 创建不读取真实应用或窗口的开合场景。
        init(failure: FailureScenario = .none) {
            self.failure = failure
        }

        /// 注入纯合成权限、几何、入口及边界控制，不访问真实系统设置。
        func environment() -> InlineMenuBarEnvironment {
            InlineMenuBarEnvironment(
                permissions: { (self.accessibilityAllowed, self.screenRecordingAllowed) },
                menuBarStrips: { [self.bar] },
                controller: { self.controllerEntry() },
                updateBoundaries: { self.updateBoundaries(collapsed: $0, hidden: $1) },
                menuInteractionActive: { self.menuInteractionInProgress }
            )
        }

        /// 依据已请求的边界生成真实语义上的合成观测，绝不采集个人应用清单。
        func currentEntries() -> [MenuBarEntry] {
            let expanded = !collapsedBoundary
            let collapsedFrame = expanded && failure != .expandedItemOutside
                ? CGRect(x: 350, y: -1, width: 24, height: 24)
                : CGRect(x: -100, y: -1, width: 24, height: 24)
            let collapsedWindow: CGWindowID = expanded && failure == .expandedMissingWindow ? 0 : 202
            let collapsedPID: pid_t = expanded && failure == .expandedProcessChanged ? 9102 : anonymousPID
            let collapsedOnScreen: Bool? = expanded && failure == .expandedUnknownVisibility ? nil : expanded
            let hiddenFrame = hiddenBoundary
                ? CGRect(x: -200, y: -1, width: 24, height: 24)
                : CGRect(x: 250, y: -1, width: 24, height: 24)
            return [
                entry(id: "preview-0", pid: anonymousPID, windowID: 201,
                      frame: CGRect(x: 400, y: -1, width: 24, height: 24), onScreen: true),
                entry(id: "preview-2", pid: collapsedPID, windowID: collapsedWindow,
                      frame: collapsedFrame, onScreen: collapsedOnScreen),
                entry(id: "preview-4", pid: anonymousPID, windowID: 204,
                      frame: hiddenFrame, onScreen: !hiddenBoundary)
            ]
        }

        /// 返回合成逻辑项目，回调只影响下一次权限观测。
        func scan(excludingPID: pid_t) -> [MenuBarEntry] {
            scanCount += 1
            let result = currentEntries()
            onScan?()
            return result
        }

        /// 开合不应采集图像，调用时立即使回归测试失败。
        func captureIcon(for entry: MenuBarEntry) async -> NSImage? {
            forbiddenOperationCount += 1
            XCTFail("同一行开合不应调用截图")
            return nil
        }

        /// 开合只调整边界，不应模拟任何状态项拖动。
        func move(_ entry: MenuBarEntry, to destination: CGPoint) async throws {
            forbiddenOperationCount += 1
            XCTFail("同一行开合不应移动状态项")
            throw MenuBarOperationError.unsupported("测试场景禁止移动")
        }

        /// 开合不应点击个人软件，调用时立即使回归测试失败。
        func click(_ entry: MenuBarEntry, rightButton: Bool) async throws {
            forbiddenOperationCount += 1
            XCTFail("同一行开合不应点击状态项")
            throw MenuBarOperationError.unsupported("测试场景禁止点击")
        }

        /// 记录请求并立即改变合成观测，代替真实 NSStatusItem 宽度修改。
        private func updateBoundaries(collapsed: Bool, hidden: Bool) {
            boundaryRequests.append(BoundaryRequest(collapsed: collapsed, hidden: hidden))
            collapsedBoundary = collapsed
            hiddenBoundary = hidden
        }

        /// 返回控制入口的合成实时窗口，异常仅限正在展开的场景。
        private func controllerEntry() -> MenuBarEntry {
            let expanded = !collapsedBoundary
            let frame = expanded && failure == .expandedControllerOutside
                ? CGRect(x: -100, y: -1, width: 24, height: 24)
                : CGRect(x: 500, y: -1, width: 24, height: 24)
            return entry(id: "fixture.controller", pid: anonymousPID, windowID: 205,
                         frame: frame, onScreen: !(expanded && failure == .expandedControllerOffscreen))
        }

        /// 使用匿名固定字段建立测试项目，不读取当前用户的任何软件信息。
        private func entry(id: String, pid: pid_t, windowID: CGWindowID, frame: CGRect, onScreen: Bool?) -> MenuBarEntry {
            MenuBarEntry(id: id, name: "匿名状态项", bundleIdentifier: "local.MenuBarNest.InlineFixture",
                         processIdentifier: pid, windowID: windowID, frame: frame, image: nil,
                         canMove: true, limitation: nil, isOnScreen: onScreen)
        }
    }
}

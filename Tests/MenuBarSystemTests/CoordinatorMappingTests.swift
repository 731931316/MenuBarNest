import AppKit
import XCTest
@testable import MenuBarNest

/// 验证协调器按逻辑身份重新解析点击目标，不依赖旧的 CG 窗口编号。
@MainActor
final class CoordinatorMappingTests: XCTestCase {
    /// 同一真实状态项更换代表窗口后，点击必须发送至重新扫描得到的新目标。
    func testLogicalEntryUsesRemappedWindow() async throws {
        let original = makeEntry(id: "fixture.target", pid: 9001, windowID: 101)
        let current = makeEntry(id: original.id, pid: original.processIdentifier, windowID: 202)
        let scanned = expectation(description: "完成逻辑项重扫")
        let clicked = expectation(description: "点击当前映射目标")
        let system = FakeMenuBarSystem(entries: [current])
        system.onScan = { scanned.fulfill() }
        system.onClick = { clicked.fulfill() }
        let model = makeCoordinator(system: system)

        model.activateItem(original, rightButton: true)
        XCTAssertTrue(model.isBusy)
        await fulfillment(of: [scanned, clicked], timeout: 2)
        try await waitUntilIdle(model)

        XCTAssertEqual(system.clicks.count, 1)
        XCTAssertEqual(system.clicks.first?.entry.id, original.id)
        XCTAssertEqual(system.clicks.first?.entry.processIdentifier, original.processIdentifier)
        XCTAssertEqual(system.clicks.first?.entry.windowID, current.windowID)
        XCTAssertEqual(system.clicks.first?.rightButton, true)
        XCTAssertNil(model.errorMessage)
    }

    /// 同一进程把旧窗口编号分配给另一逻辑项时，不得点击编号复用者。
    func testReusedWindowFromOtherLogicalEntryIsRejected() async throws {
        let original = makeEntry(id: "fixture.target", pid: 9001, windowID: 101)
        let unrelated = makeEntry(id: "fixture.unrelated", pid: original.processIdentifier, windowID: original.windowID)
        let scanned = expectation(description: "完成编号复用场景重扫")
        let system = FakeMenuBarSystem(entries: [unrelated])
        system.onScan = { scanned.fulfill() }
        let model = makeCoordinator(system: system)

        model.activateItem(original)
        XCTAssertTrue(model.isBusy)
        await fulfillment(of: [scanned], timeout: 2)
        try await waitUntilIdle(model)

        XCTAssertTrue(system.clicks.isEmpty)
        XCTAssertEqual(model.errorMessage, MenuBarOperationError.itemUnavailable.localizedDescription)
    }

    /// 同一逻辑键和窗口编号由不同进程持有时，不得向新进程发送旧点击请求。
    func testSameLogicalEntryFromDifferentProcessIsRejected() async throws {
        let original = makeEntry(id: "fixture.target", pid: 9001, windowID: 101)
        let restarted = makeEntry(id: original.id, pid: 9002, windowID: original.windowID)
        let scanned = expectation(description: "完成进程变化场景重扫")
        let system = FakeMenuBarSystem(entries: [restarted])
        system.onScan = { scanned.fulfill() }
        let model = makeCoordinator(system: system)

        model.activateItem(original)
        XCTAssertTrue(model.isBusy)
        await fulfillment(of: [scanned], timeout: 2)
        try await waitUntilIdle(model)

        XCTAssertTrue(system.clicks.isEmpty)
        XCTAssertEqual(model.errorMessage, MenuBarOperationError.itemUnavailable.localizedDescription)
    }

    /// 创建纯合成状态项，不读取用户应用或真实屏幕内容。
    private func makeEntry(id: String, pid: pid_t, windowID: CGWindowID) -> MenuBarEntry {
        MenuBarEntry(
            id: id, name: "测试状态项", bundleIdentifier: "local.MenuBarNest.TestFixture",
            processIdentifier: pid, windowID: windowID,
            frame: CGRect(x: 200, y: 0, width: 24, height: 24),
            image: nil, canMove: true, limitation: nil, isOnScreen: true
        )
    }

    /// 初始化 AppKit 和仅预览协调器，不安装状态项、不启动轮询、不写配置。
    private func makeCoordinator(system: FakeMenuBarSystem) -> NestCoordinator {
        _ = NSApplication.shared
        let model = NestCoordinator(system: system, preview: true)
        model.accessibilityGranted = true
        model.layout.autoCollapse = false
        return model
    }

    /// 在有限时间内等待异步点击结束，明确验证忙碌状态会回落。
    private func waitUntilIdle(_ model: NestCoordinator) async throws {
        // 主 actor 每次等待时交还执行权，最多等待两秒，防止错误路径挂起测试。
        for _ in 0..<100 {
            if !model.isBusy { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("协调器点击操作未在两秒内结束")
    }

    /// 只提供合成扫描结果和点击记录；截图及移动调用会立即使测试失败。
    private final class FakeMenuBarSystem: MenuBarSystemManaging {
        /// 本次扫描返回的合成状态项。
        private let entries: [MenuBarEntry]
        /// 逻辑项重扫完成通知，不操作真实系统。
        var onScan: (() -> Void)?
        /// 合成点击完成通知，不发送鼠标事件。
        var onClick: (() -> Void)?
        /// 被协调器选中的目标和鼠标按钮类型。
        private(set) var clicks: [(entry: MenuBarEntry, rightButton: Bool)] = []

        /// 设置本次场景的当前逻辑项及窗口映射。
        init(entries: [MenuBarEntry]) {
            self.entries = entries
        }

        /// 返回预先构造的逻辑项，不枚举真实窗口或应用进程。
        func scan(excludingPID: pid_t) -> [MenuBarEntry] {
            onScan?()
            return entries
        }

        /// 截图不属于这些回归场景，调用时立即记录测试失败。
        func captureIcon(for entry: MenuBarEntry) async -> NSImage? {
            XCTFail("点击映射回归测试不应调用截图")
            return nil
        }

        /// 移动不属于这些回归场景，调用时立即报告失败且不产生系统事件。
        func move(_ entry: MenuBarEntry, to destination: CGPoint) async throws {
            XCTFail("点击映射回归测试不应移动状态项")
            throw MenuBarOperationError.unsupported("测试场景不允许移动")
        }

        /// 记录协调器选择的当前目标，不产生任何鼠标事件。
        func click(_ entry: MenuBarEntry, rightButton: Bool) async throws {
            clicks.append((entry: entry, rightButton: rightButton))
            onClick?()
        }
    }
}

import ApplicationServices
import XCTest
@testable import MenuBarNest

/// 使用匿名 AX 与 CG 数据回归扫描行为，不读取真实应用、截图或发送系统事件。
final class MenuBarSystemScanTests: XCTestCase {
    /// 一个真实 AX 状态项的主屏、副屏及代理窗口只能产生一个可操作项目。
    func testOneAccessibleItemWithFourWindowsProducesOneEntry() async throws {
        try await MainActor.run {
            let fixture = ScanFixture()
            fixture.accessibleItems = [fixture.accessibleItem(elementPID: 80_001, identifier: "stable-a", name: "状态项甲", x: 212)]
            fixture.windows = fixture.representations(id: 100, x: 200)
            let system = fixture.makeSystem()

            let entries = system.scan(excludingPID: fixture.managerPID)

            let entry = try XCTUnwrap(entries.first)
            XCTAssertEqual(entries.count, 1, "屏幕副本及代理不应增加软件图标数量")
            XCTAssertEqual(entry.name, "状态项甲")
            XCTAssertEqual(entry.windowID, 100, "操作映射必须对应与 AX 位置吻合的真实主屏窗口")
            XCTAssertTrue(entry.canMove)
        }
    }

    /// 九个真实 AX 项对应三十六个 CG 表示时，数量与身份仍以真实项为准。
    func testNineAccessibleItemsWithThirtySixWindowsProduceNineEntries() async {
        await MainActor.run {
            let fixture = ScanFixture()
            for index in 0..<9 {
                let x = CGFloat(100 + index * 70)
                fixture.accessibleItems.append(fixture.accessibleItem(elementPID: pid_t(81_000 + index), identifier: "stable-\(index)", name: "状态项\(index)", x: x + 12))
                fixture.windows.append(contentsOf: fixture.representations(id: CGWindowID(200 + index * 4), x: x))
            }
            let system = fixture.makeSystem()

            let entries = system.scan(excludingPID: fixture.managerPID)

            XCTAssertEqual(entries.count, 9)
            XCTAssertEqual(Set(entries.map(\.id)).count, 9, "每个真实项目应有独立逻辑身份")
            XCTAssertEqual(Set(entries.map(\.name)), Set((0..<9).map { "状态项\($0)" }))
            XCTAssertEqual(Set(entries.map(\.windowID)), Set((0..<9).map { CGWindowID(200 + $0 * 4) }))
            XCTAssertTrue(entries.allSatisfy(\.canMove))
        }
    }

    /// 同进程内两个同名称、同 identifier 的真实 AX 元素不能被合并。
    func testDistinctAccessibleItemsWithSameNameRemainSeparate() async {
        await MainActor.run {
            let fixture = ScanFixture()
            fixture.accessibleItems = [
                fixture.accessibleItem(elementPID: 82_001, identifier: "shared", name: "相同名称", x: 312),
                fixture.accessibleItem(elementPID: 82_002, identifier: "shared", name: "相同名称", x: 382)
            ]
            fixture.windows = [
                fixture.window(id: 500, x: 300),
                fixture.window(id: 501, x: 370)
            ]
            let system = fixture.makeSystem()

            let entries = system.scan(excludingPID: fixture.managerPID)

            XCTAssertEqual(entries.count, 2)
            XCTAssertEqual(Set(entries.map(\.id)).count, 2)
            XCTAssertEqual(entries.map(\.name), ["相同名称", "相同名称"])
            XCTAssertEqual(Set(entries.map(\.windowID)), [500, 501])
            XCTAssertTrue(entries.allSatisfy(\.canMove))
        }
    }

    /// 无 AX 且从未验证的屏幕外、原点及副屏不可见残留不产生图标。
    func testInvisibleResidualWindowsWithoutAccessibleItemsAreIgnored() async {
        await MainActor.run {
            let fixture = ScanFixture()
            fixture.windows = [
                fixture.window(id: 600, x: 0, isOnScreen: false),
                fixture.window(id: 601, x: -900, isOnScreen: false),
                fixture.window(id: 602, x: 1_600, isOnScreen: false),
                fixture.window(id: 603, x: 0, isOnScreen: false)
            ]
            let system = fixture.makeSystem()

            XCTAssertTrue(system.scan(excludingPID: fixture.managerPID).isEmpty)
            XCTAssertTrue(system.scan(excludingPID: fixture.managerPID).isEmpty, "反复刷新不能将残留窗口升级为真实项目")
        }
    }

    /// 真图标完成可见验证后，收起时 AX 暂缺仍保留它的逻辑身份。
    func testPreviouslyVerifiedHiddenItemKeepsLogicalIdentity() async throws {
        try await MainActor.run {
            let fixture = ScanFixture()
            fixture.accessibleItems = [fixture.accessibleItem(elementPID: 83_001, identifier: "hidden-a", name: "收纳项", x: 412)]
            fixture.windows = [fixture.window(id: 700, x: 400)]
            let system = fixture.makeSystem()
            let visible = try XCTUnwrap(system.scan(excludingPID: fixture.managerPID).first)
            XCTAssertTrue(visible.canMove)

            // 模拟已收起的同一窗口；不发送拖动事件，也不把新残留窗口当作已验证项。
            fixture.accessibleItems = []
            fixture.windows = [fixture.window(id: 700, x: -1_600, isOnScreen: false)]
            let hiddenEntries = system.scan(excludingPID: fixture.managerPID)
            let hidden = try XCTUnwrap(hiddenEntries.first)

            XCTAssertEqual(hiddenEntries.count, 1)
            XCTAssertEqual(hidden.id, visible.id)
            XCTAssertEqual(hidden.name, visible.name)
            XCTAssertEqual(hidden.windowID, visible.windowID)
            XCTAssertLessThan(hidden.frame.maxX, 0)
            XCTAssertFalse(hidden.isOnScreen ?? true)
        }
    }

    /// 同一真实 AX 项切换 CG 代表窗口时，逻辑 ID 不得随窗口编号变化。
    func testReplacingRepresentativeWindowDoesNotRenumberItem() async throws {
        try await MainActor.run {
            let fixture = ScanFixture()
            fixture.accessibleItems = [fixture.accessibleItem(elementPID: 84_001, identifier: "", name: "稳定项", x: 512)]
            fixture.windows = [fixture.window(id: 800, x: 500, title: "Item-1")]
            let system = fixture.makeSystem()
            let original = try XCTUnwrap(system.scan(excludingPID: fixture.managerPID).first)

            fixture.windows = [fixture.window(id: 801, x: 500, title: "Item-700")]
            let updatedEntries = system.scan(excludingPID: fixture.managerPID)
            let updated = try XCTUnwrap(updatedEntries.first)

            XCTAssertEqual(updatedEntries.count, 1)
            XCTAssertEqual(updated.id, original.id)
            XCTAssertEqual(updated.name, original.name)
            XCTAssertEqual(updated.windowID, 801, "操作映射应重新绑定当前真实窗口")
            XCTAssertNotEqual(updated.windowID, original.windowID)
        }
    }

    /// PID 与窗口编号被其他软件复用时，旧隐藏缓存不能串入新软件。
    func testReusedPIDAndWindowDoNotRetainAnotherApplicationItem() async throws {
        try await MainActor.run {
            let fixture = ScanFixture()
            fixture.accessibleItems = [fixture.accessibleItem(elementPID: 85_001, identifier: "same-id", name: "旧软件状态项", x: 612)]
            fixture.windows = [fixture.window(id: 900, x: 600)]
            let system = fixture.makeSystem()
            let original = try XCTUnwrap(system.scan(excludingPID: fixture.managerPID).first)

            // 保留相同数值 PID/窗口编号，改变软件所有者，模拟系统资源复用。
            fixture.application = MenuBarSystem.ApplicationInfo(bundleIdentifier: "fixture.invalid.replacement", name: "匿名替代软件", launchDate: Date(timeIntervalSince1970: 200))
            fixture.accessibleItems = []
            fixture.windows = [fixture.window(id: 900, x: -1_600, isOnScreen: false)]
            XCTAssertTrue(system.scan(excludingPID: fixture.managerPID).isEmpty, "新软件不能继承旧软件的已验证隐藏缓存")

            fixture.accessibleItems = [fixture.accessibleItem(elementPID: 85_002, identifier: "same-id", name: "新软件状态项", x: 612)]
            fixture.windows = [fixture.window(id: 900, x: 600)]
            let replacement = try XCTUnwrap(system.scan(excludingPID: fixture.managerPID).first)
            XCTAssertEqual(replacement.bundleIdentifier, fixture.application.bundleIdentifier)
            XCTAssertEqual(replacement.name, "新软件状态项")
            XCTAssertNotEqual(replacement.id, original.id)
        }
    }

    /// 即使软件标识相同，启动时间变化也必须撤销旧进程的隐藏窗口验证。
    func testSameApplicationRelaunchWithReusedPIDInvalidatesHiddenCache() async throws {
        try await MainActor.run {
            let fixture = ScanFixture()
            fixture.accessibleItems = [fixture.accessibleItem(elementPID: 86_001, identifier: "restart-a", name: "重启前状态项", x: 712)]
            fixture.windows = [fixture.window(id: 1_000, x: 700)]
            let system = fixture.makeSystem()
            XCTAssertEqual(system.scan(excludingPID: fixture.managerPID).count, 1)

            fixture.application = MenuBarSystem.ApplicationInfo(bundleIdentifier: fixture.application.bundleIdentifier, name: fixture.application.name, launchDate: Date(timeIntervalSince1970: 300))
            fixture.accessibleItems = []
            fixture.windows = [fixture.window(id: 1_000, x: -1_600, isOnScreen: false)]

            XCTAssertTrue(system.scan(excludingPID: fixture.managerPID).isEmpty, "同 PID、同软件重启后不能沿用上次进程的验证")

            fixture.accessibleItems = [fixture.accessibleItem(elementPID: 86_002, identifier: "restart-a", name: "重启后状态项", x: 712)]
            fixture.windows = [fixture.window(id: 1_001, x: 700)]
            let current = try XCTUnwrap(system.scan(excludingPID: fixture.managerPID).first)
            XCTAssertEqual(current.windowID, 1_001)
            XCTAssertEqual(current.name, "重启后状态项")
        }
    }

    /// 多个可见窗口同样吻合一个真实 AX 项时，仍只显示一项并禁止猜测操作目标。
    func testAmbiguousWindowMappingKeepsOneItemButDisallowsMovement() async throws {
        try await MainActor.run {
            let fixture = ScanFixture()
            fixture.accessibleItems = [fixture.accessibleItem(elementPID: 87_001, identifier: "ambiguous-a", name: "待确认项", x: 812)]
            fixture.windows = (0..<4).map { fixture.window(id: CGWindowID(1_100 + $0), x: 800) }
            let system = fixture.makeSystem()

            let entries = system.scan(excludingPID: fixture.managerPID)
            let entry = try XCTUnwrap(entries.first)

            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entry.name, "待确认项")
            XCTAssertEqual(entry.windowID, kCGNullWindowID)
            XCTAssertFalse(entry.canMove)
            XCTAssertNotNil(entry.limitation, "不能确定原窗口时必须给出可识别的管理限制")
        }
    }

    /// 通用 Item-0 元数据只保留旧布局身份，展示名称应回退软件名称且不重复。
    func testGenericWindowTitleUsesApplicationNameAndPreservesLegacyIdentity() async throws {
        try await MainActor.run {
            let fixture = ScanFixture()
            fixture.accessibleItems = [fixture.accessibleItem(elementPID: 88_001, identifier: "", name: "Item-0", x: 212)]
            fixture.windows = fixture.representations(id: 1_200, x: 200, title: "Item-0")
            let system = fixture.makeSystem()

            let entries = system.scan(excludingPID: fixture.managerPID)
            let entry = try XCTUnwrap(entries.first)

            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entry.name, fixture.application.name, "通用窗口编号不能作为软件展示名称")
            XCTAssertEqual(entry.id, fixture.application.bundleIdentifier + ":Item-0", "已有布局键必须保留兼容")
            XCTAssertEqual(entry.windowID, 1_200)
        }
    }
}

/// 为每个测试提供可变匿名快照；所有生产查询入口均由闭包替代。
@MainActor
private final class ScanFixture {
    /// 匿名被管理进程，仅用作数值关联，不解析系统应用。
    let ownerPID: pid_t = 42_001
    /// 排除管理器自身窗口使用的匿名进程值。
    let managerPID: pid_t = 42_002
    /// 模拟同一进程提供的真实辅助功能状态项。
    var accessibleItems: [MenuBarSystem.AccessibleItem] = []
    /// 模拟当前 Window Server 元数据，允许测试在两次扫描之间更新。
    var windows: [MenuBarSystem.WindowRecord] = []
    /// 匿名软件和进程生命周期信息，不依赖本机运行清单。
    var application = MenuBarSystem.ApplicationInfo(bundleIdentifier: "fixture.invalid.original", name: "匿名软件", launchDate: Date(timeIntervalSince1970: 100))
    /// 两块无刘海屏幕的匿名菜单栏条带。
    let strips = [CGRect(x: 0, y: 0, width: 1_200, height: 24), CGRect(x: 1_400, y: 0, width: 1_200, height: 24)]

    /// 创建只依赖 fixture 快照的扫描适配器，避免读取真实系统状态。
    func makeSystem() -> MenuBarSystem {
        MenuBarSystem(
            windowRecordsProvider: { [unowned self] _, _ in self.windows },
            accessibleItemsProvider: { [unowned self] pid in pid == self.ownerPID ? self.accessibleItems : [] },
            menuBarStripsProvider: { [unowned self] in self.strips },
            applicationInfoProvider: { [unowned self] _ in self.application }
        )
    }

    /// 创建人工 AX 元素，只比较元素身份，不读取属性或触发辅助功能操作。
    func accessibleItem(elementPID: pid_t, identifier: String, name: String, x: CGFloat) -> MenuBarSystem.AccessibleItem {
        MenuBarSystem.AccessibleItem(element: AXUIElementCreateApplication(elementPID), identifier: identifier, name: name, frame: CGRect(x: x, y: 2, width: 20, height: 20))
    }

    /// 创建菜单栏层的匿名窗口，AX 图标宽度有意小于 CG 窗口宽度。
    func window(id: CGWindowID, x: CGFloat, isOnScreen: Bool = true, title: String = "匿名窗口") -> MenuBarSystem.WindowRecord {
        MenuBarSystem.WindowRecord(id: id, pid: ownerPID, frame: CGRect(x: x, y: 0, width: 44, height: 24), title: title, layer: Int(CGWindowLevelForKey(.statusWindow)), isOnScreen: isOnScreen)
    }

    /// 构造一项对应的主屏真实窗口、近框代理、副屏副本和副屏代理。
    func representations(id: CGWindowID, x: CGFloat, title: String = "匿名窗口") -> [MenuBarSystem.WindowRecord] {
        [
            window(id: id, x: x, title: title),
            window(id: id + 1, x: x + 1, isOnScreen: false, title: title),
            window(id: id + 2, x: x + 1_400, title: title),
            window(id: id + 3, x: x + 1_401, isOnScreen: false, title: title)
        ]
    }
}

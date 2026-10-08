import XCTest
@testable import NestCore

/// 验证跨分区排序及应用退出后的持久化位置规则。
final class LayoutStateTests: XCTestCase {
    /// 保存顺序优先，新发现的常显项目追加在末尾，输入重复项只展示一次。
    func testSavedOrderAndNewItems() {
        let layout = LayoutState(placements: [
            ItemPlacement(id: "b", section: .visible),
            ItemPlacement(id: "a", section: .visible),
            ItemPlacement(id: "hidden", section: .hidden)
        ])
        XCTAssertEqual(layout.orderedIDs(in: .visible, among: ["a", "new", "b", "new", "hidden"]), ["b", "a", "new"])
        XCTAssertEqual(layout.orderedIDs(in: .hidden, among: ["hidden", "a"]), ["hidden"])
        XCTAssertEqual(layout.section(for: "unknown"), .visible)
    }

    /// 区内拖拽和跨区拖拽均按目标项目的位置插入。
    func testMoveWithinAndAcrossSections() {
        var layout = LayoutState(placements: [
            ItemPlacement(id: "a", section: .visible),
            ItemPlacement(id: "b", section: .visible),
            ItemPlacement(id: "c", section: .collapsed),
            ItemPlacement(id: "d", section: .collapsed)
        ])
        layout.move(id: "b", to: .visible, before: "a")
        XCTAssertEqual(layout.orderedIDs(in: .visible, among: ["a", "b", "c", "d"]), ["b", "a"])
        layout.move(id: "a", to: .collapsed, before: "d")
        XCTAssertEqual(layout.orderedIDs(in: .collapsed, among: ["a", "b", "c", "d"]), ["c", "a", "d"])
        layout.move(id: "c", to: .collapsed)
        XCTAssertEqual(layout.orderedIDs(in: .collapsed, among: ["a", "b", "c", "d"]), ["a", "d", "c"])
        XCTAssertEqual(layout.orderedIDs(in: .visible, among: ["a", "b", "c", "d"]), ["b"])
    }

    /// 退出应用后保留分区及顺序，重新启动时回到原位置。
    func testExitedApplicationKeepsPlacement() {
        var layout = LayoutState(placements: [
            ItemPlacement(id: "a", section: .collapsed),
            ItemPlacement(id: "b", section: .collapsed)
        ])
        layout.reconcile(discoveredIDs: ["b", "new"])
        XCTAssertEqual(layout.orderedIDs(in: .collapsed, among: ["b", "new"]), ["b"])
        layout.reconcile(discoveredIDs: ["b", "a", "new"])
        XCTAssertEqual(layout.orderedIDs(in: .collapsed, among: ["b", "a", "new"]), ["a", "b"])
        XCTAssertEqual(layout.section(for: "a"), .collapsed)
        XCTAssertEqual(layout.orderedIDs(in: .visible, among: ["b", "a", "new"]), ["new"])
    }

    /// 构建布局及重复发现均不会重复记录项目。
    func testDuplicateInputsKeepFirstPlacement() throws {
        var layout = LayoutState(placements: [
            ItemPlacement(id: "a", section: .hidden),
            ItemPlacement(id: "a", section: .visible)
        ])
        layout.reconcile(discoveredIDs: ["a", "b", "b", "a"])
        XCTAssertEqual(layout.placements.count, 2)
        XCTAssertEqual(layout.section(for: "a"), .hidden)
        let data = Data(#"{"placements":[{"id":"a","section":"hidden"},{"id":"a","section":"visible"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(LayoutState.self, from: data)
        XCTAssertEqual(decoded.placements, [ItemPlacement(id: "a", section: .hidden)])
        XCTAssertFalse(decoded.autoCollapse)
        XCTAssertEqual(decoded.collapseDelay, 8)
    }

    /// 非本区目标不会破坏目标分区顺序，拖回自身不改变布局。
    func testInvalidDropTargetAndSelfDrop() {
        var layout = LayoutState(placements: [
            ItemPlacement(id: "a", section: .visible),
            ItemPlacement(id: "b", section: .collapsed),
            ItemPlacement(id: "c", section: .visible)
        ])
        let original = layout
        layout.move(id: "a", to: .visible, before: "a")
        XCTAssertEqual(layout, original)
        layout.move(id: "new", to: .visible, before: "b")
        XCTAssertEqual(layout.orderedIDs(in: .visible, among: ["a", "b", "c", "new"]), ["a", "c", "new"])
    }

    /// 缺少启用标记的旧配置保留已有设置，同时禁止自动启用管理。
    func testLegacyConfigurationDoesNotEnableManagement() throws {
        let data = Data(#"{"placements":[{"id":"a","section":"collapsed"}],"autoCollapse":false,"collapseDelay":20}"#.utf8)
        let decoded = try JSONDecoder().decode(LayoutState.self, from: data)
        XCTAssertFalse(decoded.managementEnabled)
        XCTAssertFalse(decoded.autoCollapse)
        XCTAssertEqual(decoded.collapseDelay, 20)
        XCTAssertEqual(decoded.placements, [ItemPlacement(id: "a", section: .collapsed)])
    }

    /// 新配置及缺少自动收起字段的旧配置默认等待用户手动收起。
    func testInlineCollapseDefaultsToManual() throws {
        XCTAssertFalse(LayoutState().autoCollapse)
        let decoded = try JSONDecoder().decode(LayoutState.self, from: Data(#"{"placements":[]}"#.utf8))
        XCTAssertFalse(decoded.autoCollapse)
    }

    /// 旧配置中用户明确保存的自动收起开关继续保留，不被新默认值覆盖。
    func testExplicitAutoCollapsePreferencesArePreserved() throws {
        for enabled in [true, false] {
            let data = Data("{\"placements\":[],\"autoCollapse\":\(enabled)}".utf8)
            let decoded = try JSONDecoder().decode(LayoutState.self, from: data)
            XCTAssertEqual(decoded.autoCollapse, enabled)
        }
    }

    /// 恢复默认值同时清空布局记录、自动收起设置及管理启用标记。
    func testResetRestoresDefaults() {
        var layout = LayoutState(placements: [ItemPlacement(id: "a", section: .hidden)], autoCollapse: true, collapseDelay: 20, managementEnabled: true)
        layout.reset()
        XCTAssertEqual(layout, LayoutState())
        XCTAssertFalse(layout.managementEnabled)
        XCTAssertFalse(layout.autoCollapse)
    }
}

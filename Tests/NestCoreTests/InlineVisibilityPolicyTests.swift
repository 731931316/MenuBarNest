import CoreGraphics
import XCTest
@testable import NestCore

/// 使用合成坐标验证同一行展开与收起规则，不访问真实菜单栏。
final class InlineVisibilityPolicyTests: XCTestCase {
    /// 合成的主显示器菜单栏条带。
    private let primaryBar = CGRect(x: 0, y: 0, width: 1000, height: 24)
    /// 合成的正常可见状态项坐标。
    private let visibleFrame = CGRect(x: 200, y: 0, width: 24, height: 24)
    /// 合成的屏幕外状态项坐标。
    private let offscreenFrame = CGRect(x: -100, y: 0, width: 24, height: 24)

    /// 收起时常显及固定项显示，收起及隐藏项目有明确不可见证据。
    func testCollapsedStateConfirmsExpectedVisibility() {
        let items = [
            item("visible", section: .visible, frame: visibleFrame, onScreen: true),
            item("fixed", section: .hidden, frame: visibleFrame, onScreen: true, canMove: false),
            item("collapsed", section: .collapsed, frame: offscreenFrame, onScreen: true),
            item("hidden", section: .hidden, frame: visibleFrame, onScreen: false)
        ]
        XCTAssertEqual(verify(items, isExpanded: false), .confirmed)
    }

    /// 展开时收起项目与常显项目在同一行完整可见，始终隐藏项目继续不可见。
    func testExpandedStateConfirmsExpectedVisibility() {
        let items = [
            item("visible", section: .visible, frame: visibleFrame, onScreen: true),
            item("collapsed", section: .collapsed, frame: CGRect(x: 240, y: 0, width: 24, height: 24), onScreen: true),
            item("hidden", section: .hidden, frame: offscreenFrame, onScreen: false)
        ]
        XCTAssertEqual(verify(items, isExpanded: true), .confirmed)
    }

    /// 普通展开也不能把始终隐藏项目显示出来。
    func testExpandedStateRejectsVisibleHiddenItem() {
        XCTAssertEqual(verify([item("hidden", section: .hidden, frame: visibleFrame, onScreen: true)], isExpanded: true), .unresolved)
    }

    /// 收起状态中的收起项目仍可见时，不能宣称收纳成功。
    func testCollapsedStateRejectsVisibleCollapsedItem() {
        XCTAssertEqual(verify([item("collapsed", section: .collapsed, frame: visibleFrame, onScreen: true)], isExpanded: false), .unresolved)
    }

    /// 应显示的项目被系统判为不在屏幕上或完全出界时，明确报告显示空间不足。
    func testRequiredVisibleItemOutsideBarReportsInsufficientSpace() {
        XCTAssertEqual(verify([item("visible", section: .visible, frame: visibleFrame, onScreen: false)], isExpanded: false), .insufficientSpace)
        XCTAssertEqual(verify([item("visible", section: .visible, frame: offscreenFrame, onScreen: true)], isExpanded: false), .insufficientSpace)
    }

    /// 同一行展开后，收起项目仅部分可见也属于空间不足。
    func testPartiallyVisibleExpandedItemReportsInsufficientSpace() {
        let partial = CGRect(x: -10, y: 0, width: 24, height: 24)
        XCTAssertEqual(verify([item("collapsed", section: .collapsed, frame: partial, onScreen: true)], isExpanded: true), .insufficientSpace)
    }

    /// 隐藏项目部分进入菜单栏时，仍需继续验证而不能视为完全隐藏。
    func testPartiallyVisibleHiddenItemRemainsUnresolved() {
        let partial = CGRect(x: -10, y: 0, width: 24, height: 24)
        XCTAssertEqual(verify([item("hidden", section: .hidden, frame: partial, onScreen: true)], isExpanded: true), .unresolved)
    }

    /// 不可移动的固定项始终必须可见，即使配置分区为隐藏。
    func testFixedItemMustRemainVisible() {
        let fixed = item("fixed", section: .hidden, frame: offscreenFrame, onScreen: false, canMove: false)
        XCTAssertEqual(verify([fixed], isExpanded: false), .insufficientSpace)
        XCTAssertEqual(verify([fixed], isExpanded: true), .insufficientSpace)
    }

    /// 各分区缺少实时状态时，屏幕内或屏幕外坐标都不能替代可见性证据。
    func testUnknownVisibilityNeverConfirms() {
        for section in VisibilitySection.allCases {
            for frame in [visibleFrame, offscreenFrame] {
                let unknown = item("unknown", section: section, frame: frame, onScreen: nil)
                XCTAssertEqual(verify([unknown], isExpanded: false), .unresolved)
                XCTAssertEqual(verify([unknown], isExpanded: true), .unresolved)
            }
        }
    }

    /// 同一轮已有明确空间不足时，不受其他未知观测及输入顺序影响。
    func testKnownInsufficientSpaceTakesPriorityOverUnknownObservation() {
        let unknown = item("unknown", section: .hidden, frame: offscreenFrame, onScreen: nil)
        let outside = item("outside", section: .collapsed, frame: offscreenFrame, onScreen: true)
        XCTAssertEqual(verify([unknown, outside], isExpanded: true), .insufficientSpace)
        XCTAssertEqual(verify([outside, unknown], isExpanded: true), .insufficientSpace)
    }

    /// 控制入口被挤出菜单栏时，即使项目集合为空也不能确认成功。
    func testControllerOutsideBarReportsInsufficientSpace() {
        XCTAssertEqual(verify([], controllerFrame: offscreenFrame, isExpanded: true), .insufficientSpace)
    }

    /// 多显示器允许项目及控制入口完整位于任意一个有效菜单栏条带。
    func testSecondaryDisplayCanContainItemsAndController() {
        let secondary = CGRect(x: -1000, y: 200, width: 1000, height: 24)
        let secondaryItem = CGRect(x: -200, y: 200, width: 24, height: 24)
        let secondaryController = CGRect(x: -150, y: 200, width: 24, height: 24)
        let result = InlineVisibilityPolicy.verify(
            items: [item("secondary", section: .collapsed, frame: secondaryItem, onScreen: true)],
            menuBarStrips: [primaryBar, secondary], controllerFrame: secondaryController, isExpanded: true
        )
        XCTAssertEqual(result, .confirmed)
    }

    /// 主屏入口展开时，不能用另一屏幕菜单栏上的项目证明本行展开成功。
    func testControllerScreenRejectsItemVisibleOnlyOnOtherDisplay() {
        let secondary = CGRect(x: -1000, y: 200, width: 1000, height: 24)
        let secondaryItem = CGRect(x: -200, y: 200, width: 24, height: 24)
        let result = InlineVisibilityPolicy.verify(
            items: [item("secondary-only", section: .collapsed, frame: secondaryItem, onScreen: true)],
            menuBarStrips: [primaryBar, secondary], controllerFrame: visibleFrame, isExpanded: true
        )
        XCTAssertEqual(result, .insufficientSpace)
    }

    /// 控制入口及展开项目处于同一个屏幕菜单栏时，可以确认本行展开成功。
    func testControllerScreenConfirmsItemInSameMenuBarRow() {
        let secondary = CGRect(x: -1000, y: 200, width: 1000, height: 24)
        let primaryItem = CGRect(x: 240, y: 0, width: 24, height: 24)
        let result = InlineVisibilityPolicy.verify(
            items: [item("primary", section: .collapsed, frame: primaryItem, onScreen: true)],
            menuBarStrips: [primaryBar, secondary], controllerFrame: visibleFrame, isExpanded: true
        )
        XCTAssertEqual(result, .confirmed)
    }

    /// 应隐藏项目仍在副屏菜单栏显示时，主屏控制入口不能掩盖未隐藏的事实。
    func testHiddenItemsAreCheckedAcrossAllDisplays() {
        let secondary = CGRect(x: -1000, y: 200, width: 1000, height: 24)
        let secondaryItem = CGRect(x: -200, y: 200, width: 24, height: 24)
        for section in [VisibilitySection.collapsed, .hidden] {
            XCTAssertEqual(InlineVisibilityPolicy.verify(
                items: [item("secondary-visible", section: section, frame: secondaryItem, onScreen: true)],
                menuBarStrips: [primaryBar, secondary], controllerFrame: visibleFrame, isExpanded: false
            ), .unresolved)
        }
        XCTAssertEqual(InlineVisibilityPolicy.verify(
            items: [item("secondary-hidden", section: .hidden, frame: secondaryItem, onScreen: true)],
            menuBarStrips: [primaryBar, secondary], controllerFrame: visibleFrame, isExpanded: true
        ), .unresolved)
    }

    /// 没有指定控制入口的独立规则调用仍允许匹配任意有效菜单栏条带。
    func testMissingControllerAllowsAnyMenuBarStrip() {
        let secondary = CGRect(x: -1000, y: 200, width: 1000, height: 24)
        let secondaryItem = CGRect(x: -200, y: 200, width: 24, height: 24)
        XCTAssertEqual(InlineVisibilityPolicy.verify(
            items: [item("secondary", section: .visible, frame: secondaryItem, onScreen: true)],
            menuBarStrips: [primaryBar, secondary], isExpanded: false
        ), .confirmed)
    }

    /// 横跨两个条带的入口不能被任一条带完整容纳，应报告空间不足。
    func testControllerCannotSpanTwoMenuBars() {
        let secondary = CGRect(x: 1000, y: 0, width: 1000, height: 24)
        let spanning = CGRect(x: 990, y: 0, width: 24, height: 24)
        XCTAssertEqual(InlineVisibilityPolicy.verify(items: [], menuBarStrips: [primaryBar, secondary], controllerFrame: spanning, isExpanded: false), .insufficientSpace)
    }

    /// 系统状态窗口高于菜单栏时，以真实同一行和横向完整范围确认可见。
    func testTallerStatusWindowRemainsVisibleInSameRow() {
        let narrowBar = CGRect(x: 0, y: 0, width: 1000, height: 22)
        let statusWindow = CGRect(x: 200, y: -1, width: 24, height: 24)
        let controller = CGRect(x: 240, y: -1, width: 24, height: 24)
        XCTAssertEqual(InlineVisibilityPolicy.verify(
            items: [item("status", section: .collapsed, frame: statusWindow, onScreen: true)],
            menuBarStrips: [narrowBar], controllerFrame: controller, isExpanded: true
        ), .confirmed)
    }

    /// 横向仅容忍一像点误差，超出容差或不在同一行仍报告空间不足。
    func testHorizontalAndRowTolerances() {
        let edge = CGRect(x: -1, y: 0, width: 24, height: 24)
        let beyondEdge = CGRect(x: -2, y: 0, width: 24, height: 24)
        let otherRow = CGRect(x: 200, y: 7, width: 24, height: 24)
        XCTAssertEqual(verify([item("edge", section: .visible, frame: edge, onScreen: true)], controllerFrame: edge, isExpanded: false), .confirmed)
        XCTAssertEqual(verify([item("outside", section: .visible, frame: beyondEdge, onScreen: true)], isExpanded: false), .insufficientSpace)
        XCTAssertEqual(verify([item("other-row", section: .visible, frame: otherRow, onScreen: true)], isExpanded: false), .insufficientSpace)
        XCTAssertEqual(verify([], controllerFrame: otherRow, isExpanded: false), .insufficientSpace)
    }

    /// 未知或无效几何不能证明某个项目已被隐藏，也不能证明入口可见。
    func testInvalidGeometryRemainsUnresolved() {
        let invalidFrames = [CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 24, height: 24)]
        for frame in invalidFrames {
            XCTAssertEqual(verify([item("invalid", section: .hidden, frame: frame, onScreen: false)], isExpanded: false), .unresolved)
            XCTAssertEqual(verify([], controllerFrame: frame, isExpanded: false), .unresolved)
        }
        XCTAssertEqual(InlineVisibilityPolicy.verify(items: [], menuBarStrips: [], isExpanded: false), .unresolved)
        XCTAssertEqual(InlineVisibilityPolicy.verify(items: [], menuBarStrips: [.zero], isExpanded: false), .unresolved)
    }

    /// 失败说明仅描述通用结果，不输出观测项目的标识。
    func testResultDescriptionDoesNotExposeItemIdentifiers() {
        let identity = "fixture.private.logical-identifier"
        let result = verify([item(identity, section: .hidden, frame: visibleFrame, onScreen: true)], isExpanded: true)
        XCTAssertEqual(result, .unresolved)
        XCTAssertFalse(result.description.contains(identity))
        XCTAssertFalse(result.description.isEmpty)
    }

    /// 创建纯合成观测，避免测试绑定真实系统窗口。
    private func item(_ id: String, section: VisibilitySection, frame: CGRect, onScreen: Bool?, canMove: Bool = true) -> InlineVisibilityPolicy.ObservedItem {
        InlineVisibilityPolicy.ObservedItem(id: id, onScreen: onScreen, frame: frame, section: section, canMove: canMove)
    }

    /// 使用同一组条带执行纯规则验证，支持可选控制入口。
    private func verify(_ items: [InlineVisibilityPolicy.ObservedItem], controllerFrame: CGRect? = nil, isExpanded: Bool) -> InlineVisibilityPolicy.VerificationResult {
        InlineVisibilityPolicy.verify(items: items, menuBarStrips: [primaryBar], controllerFrame: controllerFrame, isExpanded: isExpanded)
    }
}

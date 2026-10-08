import CoreGraphics
import Foundation

/// 仅根据实际观测判断同一行菜单栏是否达到预期，不读取系统或推测缓存状态。
public enum InlineVisibilityPolicy {
    /// 系统适配层提供的一个真实逻辑状态项及本轮观测。
    public struct ObservedItem {
        /// 用于关联布局的稳定逻辑标识，不写入结果说明。
        public let id: String
        /// 本轮可信的窗口可见状态，缺少实时证据时为 nil。
        public let onScreen: Bool?
        /// 本轮可信的 Quartz 坐标，缓存可信度由调用方检查。
        public let frame: CGRect
        /// 当前已应用布局中的项目分区。
        public let section: VisibilitySection
        /// 是否允许移动及收纳；固定项始终要求完整可见。
        public let canMove: Bool

        /// 创建一次观测；不会补造未知可见性或坐标。
        public init(id: String, onScreen: Bool?, frame: CGRect, section: VisibilitySection, canMove: Bool) {
            self.id = id
            self.onScreen = onScreen
            self.frame = frame
            self.section = section
            self.canMove = canMove
        }
    }

    /// 所有实际观测与预期状态比较后的验证结果。
    public enum VerificationResult: Equatable, CustomStringConvertible {
        /// 每个项目及提供的控制入口均满足预期。
        case confirmed
        /// 缺少可信观测，或应隐藏的项目仍可见，无法确认已生效。
        case unresolved
        /// 有明确证据表明应显示的项目或控制入口无法完整显示。
        case insufficientSpace

        /// 不包含个人项目标识的统一中文结果说明。
        public var description: String {
            switch self {
            case .confirmed:
                return "菜单栏同一行的显示状态已确认。"
            case .unresolved:
                return "尚未取得完整可信的显示状态，或指定收起的图标仍然可见。"
            case .insufficientSpace:
                return "当前菜单栏无法完整容纳所有应显示的图标或控制入口。"
            }
        }
    }

    /// 比较真实观测与展开规则，已明确的显示空间不足优先于其他未知观测。
    public static func verify(
        items: [ObservedItem],
        menuBarStrips: [CGRect],
        controllerFrame: CGRect? = nil,
        isExpanded: Bool
    ) -> VerificationResult {
        // 无有效菜单栏坐标时，不以空集合或未知几何证明成功。
        guard !menuBarStrips.isEmpty, menuBarStrips.allSatisfy(isValidFrame) else {
            return .unresolved
        }
        var hasUnresolvedObservation = false
        var hasInsufficientSpace = false
        var verificationStrips = menuBarStrips

        if let controllerFrame {
            if !isValidFrame(controllerFrame) {
                hasUnresolvedObservation = true
            } else {
                // 控制入口确定本次展开的屏幕及菜单栏行，副屏的显示不能替代本行成功。
                verificationStrips = menuBarStrips.filter { isFullyVisible(controllerFrame, among: [$0]) }
                if verificationStrips.isEmpty { hasInsufficientSpace = true }
            }
        }

        for item in items {
            guard let onScreen = item.onScreen, isValidFrame(item.frame) else {
                hasUnresolvedObservation = true
                continue
            }
            let shouldBeVisible = !item.canMove || item.section == .visible ||
                (isExpanded && item.section == .collapsed)
            if shouldBeVisible {
                if !onScreen || !isFullyVisible(item.frame, among: verificationStrips) {
                    hasInsufficientSpace = true
                }
            } else if onScreen && intersectsMenuBar(item.frame, among: menuBarStrips) {
                // 应隐藏项在任何显示器的菜单栏中仍有交集，均不能确认收纳成功。
                hasUnresolvedObservation = true
            }
        }

        if hasInsufficientSpace { return .insufficientSpace }
        return hasUnresolvedObservation ? .unresolved : .confirmed
    }

    /// 拒绝空、无限及非数值坐标，避免把无效框当成屏幕外隐藏证据。
    private static func isValidFrame(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0 &&
            frame.origin.x.isFinite && frame.origin.y.isFinite &&
            frame.width.isFinite && frame.height.isFinite &&
            frame.maxX.isFinite && frame.maxY.isFinite
    }

    /// 要求单个条带横向容纳项目并处于同一行，允许系统窗口略高于菜单栏。
    private static func isFullyVisible(_ frame: CGRect, among strips: [CGRect]) -> Bool {
        strips.contains {
            $0.minX - 1 <= frame.minX && frame.maxX <= $0.maxX + 1 &&
                abs($0.midY - frame.midY) <= 6
        }
    }

    /// 判断实际项目与任一菜单栏是否有非零可见交集。
    private static func intersectsMenuBar(_ frame: CGRect, among strips: [CGRect]) -> Bool {
        strips.contains {
            let intersection = $0.intersection(frame)
            return !intersection.isNull && intersection.width > 0 && intersection.height > 0
        }
    }
}

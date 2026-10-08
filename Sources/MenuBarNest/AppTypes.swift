import AppKit
import NestCore
import OSLog

/// 应用统一日志入口；日志仅记录操作结果与数量，不写入应用清单或屏幕内容。
enum NestLog {
    /// 菜单栏控制及系统交互日志。
    static let system = Logger(subsystem: "local.MenuBarNest", category: "system")
    /// 用户配置读写与界面状态日志。
    static let app = Logger(subsystem: "local.MenuBarNest", category: "app")
}

/// 系统中当前存在的一个菜单栏状态项，和持久化布局通过稳定标识关联。
struct MenuBarEntry: Identifiable {
    /// 尽量使用应用标识及状态项标识组成的稳定键。
    let id: String
    /// 可供用户识别的状态项名称。
    let name: String
    /// 状态项所属应用的 bundle identifier。
    let bundleIdentifier: String
    /// 当前所属进程，重启应用后重新扫描更新。
    let processIdentifier: pid_t
    /// 状态项的 Window Server 窗口编号。
    let windowID: CGWindowID
    /// 使用左上角为原点的 Quartz 屏幕坐标。
    let frame: CGRect
    /// 状态项的局部图像；无录屏权限时可为 nil。
    var image: NSImage?
    /// 系统允许对此项进行拖动及分区管理。
    let canMove: Bool
    /// 无法管理时的具体说明。
    let limitation: String?
    /// 当前已映射窗口的实时可见性；没有可信窗口元数据时保持 nil。
    var isOnScreen: Bool? = nil
}

/// 将跨应用菜单栏交互集中到独立适配层，供控制器及测试使用。
@MainActor
protocol MenuBarSystemManaging {
    /// 扫描状态项，排除管理器自己的控制项。
    func scan(excludingPID: pid_t) -> [MenuBarEntry]
    /// 只截取一个状态项窗口的图像，不采集整个桌面。
    func captureIcon(for entry: MenuBarEntry) async -> NSImage?
    /// 使用 Command 拖动将状态项移动至指定 Quartz 坐标。
    func move(_ entry: MenuBarEntry, to destination: CGPoint) async throws
    /// 点击已恢复可见的原始状态项，调用所属软件菜单。
    func click(_ entry: MenuBarEntry, rightButton: Bool) async throws
}

/// 操作失败原因，可直接向用户展示，避免将失败误报为成功。
enum MenuBarOperationError: LocalizedError {
    /// 用户尚未允许辅助功能控制。
    case accessibilityRequired
    /// 项目不能被系统移动。
    case unsupported(String)
    /// 状态项在处理期间退出或发生变化。
    case itemUnavailable
    /// 系统移动结果未达到目标。
    case movementFailed

    /// 本地化错误说明。
    var errorDescription: String? {
        switch self {
        case .accessibilityRequired: return "请先在系统设置中允许菜单栏收纳的辅助功能权限。"
        case .unsupported(let reason): return reason
        case .itemUnavailable: return "这个图标已退出或发生变化，请刷新后重试。"
        case .movementFailed: return "系统未接受这次图标移动，布局未确认应用成功。"
        }
    }
}

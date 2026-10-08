import AppKit

/// 为同一行开合提供可替换的系统观察点，测试时不创建或移动个人图标。
struct InlineMenuBarEnvironment {
    /// 当前辅助功能与可选录屏授权，由调用方提供实时值。
    let permissions: () -> (accessibility: Bool, screenRecording: Bool)
    /// 各显示器当前的 Quartz 菜单栏条带。
    let menuBarStrips: () -> [CGRect]
    /// 展开按钮的当前窗口证据，缺少证据时不得确认开合成功。
    let controller: () -> MenuBarEntry?
    /// 只调整收起边界和隐藏边界长度，测试实现记录请求而不操作系统。
    let updateBoundaries: (_ collapsed: Bool, _ hidden: Bool) -> Void
    /// 原软件菜单或鼠标交互是否仍在进行，供自动收起避让。
    let menuInteractionActive: () -> Bool

    /// 组合匿名系统观察与边界控制，生产协调器未注入时使用真实 AppKit 状态项。
    init(permissions: @escaping () -> (accessibility: Bool, screenRecording: Bool),
         menuBarStrips: @escaping () -> [CGRect], controller: @escaping () -> MenuBarEntry?,
         updateBoundaries: @escaping (_ collapsed: Bool, _ hidden: Bool) -> Void,
         menuInteractionActive: @escaping () -> Bool) {
        self.permissions = permissions
        self.menuBarStrips = menuBarStrips
        self.controller = controller
        self.updateBoundaries = updateBoundaries
        self.menuInteractionActive = menuInteractionActive
    }
}

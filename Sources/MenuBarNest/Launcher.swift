import AppKit
import ApplicationServices
import SwiftUI

/// AppKit 应用入口，同时提供不触碰真实图标的离屏视觉验证。
@main
struct MenuBarNestLauncher {
    /// 根据显式启动参数运行应用、权限诊断或界面渲染。
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--diagnostics") {
            // 诊断只输出权限布尔值和显示器数量，不读取应用清单或屏幕图像。
            let payload: [String: Any] = [
                "accessibility": AXIsProcessTrusted(),
                "screenRecording": CGPreflightScreenCaptureAccess(),
                "displayCount": NSScreen.screens.count,
                "minimumSystem": "14.0"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) { print(string) }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if arguments.contains("--self-check") {
            // 自检只创建、移动和采集本进程测试图标，所有路径最终都移除测试项。
            app.finishLaunching()
            Task {
                let passed = await SystemSelfCheck.run()
                exit(passed ? 0 : 1)
            }
            app.run()
            return
        }
        if let index = arguments.firstIndex(of: "--render-preview"), arguments.count > index + 1 {
            let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let model = NestCoordinator(preview: true)
                model.configurePreview()
                try render(MainView(model: model), size: NSSize(width: 1060, height: 760),
                           to: directory.appendingPathComponent("management-preview.png"))
                try render(OverflowView(model: model), size: NSSize(width: 430, height: 220),
                           to: directory.appendingPathComponent("overflow-preview.png"))
                // 单独验证最小窗口中的真实未授权状态，不将示例项目混入初始界面。
                model.entries = []
                model.accessibilityGranted = false
                model.screenRecordingGranted = false
                model.layout.reset()
                model.statusMessage = "请先完成权限授权，再刷新真实菜单栏图标。"
                try render(MainView(model: model), size: NSSize(width: 940, height: 640),
                           to: directory.appendingPathComponent("management-permissions.png"))
                print("Preview rendering completed.")
            } catch {
                NestLog.app.error("界面离屏渲染失败。")
                fputs("Preview rendering failed.\n", stderr)
                exit(1)
            }
            return
        }
        let delegate = NestAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    /// 在应用自己的离屏窗口中绘制视图，不申请录屏权限。
    @MainActor
    private static func render<V: View>(_ rootView: V, size: NSSize, to url: URL) throws {
        let host = NSHostingView(rootView: rootView)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        // SwiftUI 需要一次主循环完成列表与字体布局，窗口保持不可见。
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
        window.orderOut(nil)
    }
}

/// 处理应用启动与退出，避免退出期间遗留收纳分区。
@MainActor
final class NestAppDelegate: NSObject, NSApplicationDelegate {
    /// 与窗口及状态栏共享的控制器。
    private var coordinator: NestCoordinator?
    /// 已允许退出，避免异步恢复完成后再次进入恢复流程。
    private var terminationReady = false

    /// 初始化控制器及顶部入口。
    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        coordinator = NestCoordinator()
        coordinator?.start()
    }

    /// 普通关闭管理窗口后保留顶部入口。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 再次打开应用时显示管理窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.showManagementWindow()
        return true
    }

    /// 等待恢复图标可见状态后再完成退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReady { return .terminateNow }
        Task {
            await coordinator?.prepareToTerminate()
            terminationReady = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 保留标准编辑快捷键，确保搜索框支持复制粘贴。
    private func installApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出菜单栏收纳", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}

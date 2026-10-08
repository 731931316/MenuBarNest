import AppKit
import SwiftUI

/// 以实际状态项图像优先展示图标；权限不足时明确使用所属应用图标。
struct EntryArtwork: View {
    /// 系统扫描所得的菜单栏状态项。
    let entry: MenuBarEntry
    /// 由宿主界面决定的图标尺寸。
    var size: CGFloat = 28

    /// 当前可用的应用图标，仅作为缺少状态项图像时的回退。
    private var applicationImage: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// 绘制真实状态项图像、应用图标或无图像占位，避免生成虚假软件图标。
    var body: some View {
        Group {
            if let image = entry.image ?? applicationImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(3)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(entry.image == nil ? "\(entry.name)，应用图标或占位" : "\(entry.name)，菜单栏图标")
    }
}

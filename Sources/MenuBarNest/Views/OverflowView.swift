import AppKit
import SwiftUI

/// 仅供离屏渲染的同一行展开示意，使用明确标示的示例符号且不执行系统操作。
struct InlinePreviewView: View {
    /// 静态示意状态，与真实菜单栏控制器运行状态隔离。
    let expanded: Bool
    /// 展开示意中的收起项符号，不代表本机已安装软件。
    private let collapsedSymbols = ["bubble.left.and.bubble.right.fill", "music.note", "icloud.fill"]
    /// 两种示意中始终显示的符号，不与真实图标或点击目标关联。
    private let visibleSymbols = ["calendar", "network"]

    /// 标明示例来源，并在同一菜单栏行中绘制展开和收起差异。
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(expanded ? "同一行展开示意" : "同一行收起示意", systemImage: "menubar.rectangle")
                    .font(.headline)
                Spacer()
                Text("示例图标 · 不执行系统操作")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
            menuBarRow
            Text(expanded ? "收起的真实图标在系统菜单栏原位展开，展开后直接点击软件原菜单。" : "收起项暂时离开可见区域；点击顶部按钮可在同一行展开，始终隐藏项保持隐藏。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        // 静态示意与渲染入口保持同一尺寸，避免无限高度改变离屏窗口大小。
        .frame(width: 900, height: 220, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 所有符号保持一行，绘制的是静态示例而非仿制可点击的原生菜单。
    private var menuBarRow: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo")
            Text("示例应用").fontWeight(.semibold)
            Text("文件")
            Text("编辑")
            Spacer(minLength: 18)
            if expanded {
                ForEach(collapsedSymbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .foregroundStyle(Color.accentColor)
                }
                Divider().frame(height: 18)
            }
            ForEach(visibleSymbols, id: \.self) { symbol in
                Image(systemName: symbol)
            }
            Image(systemName: expanded ? "chevron.right.circle" : "chevron.left.circle")
                .foregroundStyle(Color.accentColor)
            Image(systemName: "wifi")
            Image(systemName: "battery.100")
            Text("10:38").monospacedDigit()
        }
        .font(.system(size: 16))
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(expanded ? "示例菜单栏已在同一行展开收起图标" : "示例菜单栏已收起部分图标")
    }
}

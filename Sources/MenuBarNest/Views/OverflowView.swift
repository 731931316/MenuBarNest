import NestCore
import SwiftUI

/// 菜单栏下方的收纳面板，只展示用户设为“收起”的真实状态项。
struct OverflowView: View {
    /// 与管理窗口共享真实状态和系统操作能力。
    @ObservedObject var model: NestCoordinator

    /// 面板使用完整收起列表，不受管理窗口的搜索词影响。
    private var collapsedEntries: [MenuBarEntry] {
        model.overflowItems()
    }

    /// 轻量面板显示图标、权限提示及管理入口。
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("收起的图标", systemImage: "tray")
                    .font(.subheadline.weight(.semibold))
                Text("\(collapsedEntries.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.showManagementWindow() } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("管理菜单栏图标")
                Button { model.dismissOverflow() } label: {
                    Image(systemName: "xmark")
                }
                .help("关闭收纳面板")
            }
            .buttonStyle(.plain)

            if !model.screenRecordingGranted {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前显示应用图标")
                            .font(.caption.weight(.medium))
                        Text("授权屏幕录制后可显示原始菜单栏图像。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("授权") { model.requestScreenRecording() }
                        .font(.caption)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }

            if collapsedEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("还没有收起的图标").font(.callout)
                    Button("打开管理窗口") { model.showManagementWindow() }
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(collapsedEntries) { entry in
                            overflowButton(entry)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(model.statusMessage.isEmpty ? "正在打开原软件菜单…" : model.statusMessage)
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !collapsedEntries.isEmpty {
                Text("点击打开原软件菜单 · 右键可选择辅助点击")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: 430)
        .background(.regularMaterial)
    }

    /// 图标点击经控制器恢复原状态项后调用其菜单，不创建仿制菜单。
    private func overflowButton(_ entry: MenuBarEntry) -> some View {
        Button { model.activateItem(entry, rightButton: false) } label: {
            VStack(spacing: 7) {
                EntryArtwork(entry: entry, size: 29)
                    .frame(width: 44, height: 42)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                Text(entry.name)
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 62, height: 26, alignment: .top)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy || !model.accessibilityGranted)
        .help(model.accessibilityGranted ? "打开\(entry.name)的原菜单" : "请先允许辅助功能权限")
        .contextMenu {
            Button("打开原菜单") { model.activateItem(entry, rightButton: false) }
            Button("使用右键打开") { model.activateItem(entry, rightButton: true) }
        }
        .accessibilityLabel("打开\(entry.name)")
    }
}

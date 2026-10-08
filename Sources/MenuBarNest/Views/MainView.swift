import AppKit
import NestCore
import SwiftUI
import UniformTypeIdentifiers

/// 管理窗口：展示真实扫描结果、权限状态和三种布局分区。
struct MainView: View {
    /// 控制扫描、持久化及系统操作的共享控制器。
    @ObservedObject var model: NestCoordinator
    /// 本次拖动的真实状态项键，供同窗口内跨区排序使用。
    @State private var draggedID: String?

    /// 按侧栏选择决定当前显示的分区，不改变原始布局。
    private var displayedSections: [VisibilitySection] {
        if let section = model.selectedSection { return [section] }
        return [.visible, .collapsed, .hidden]
    }

    /// 管理主窗口的双栏原生布局。
    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 190)
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                titleArea
                actionArea
                permissionArea
                feedbackArea
                sectionArea
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 940, idealWidth: 1080, minHeight: 640, idealHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 侧栏提供全部、各分区及收纳偏好入口。
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.topthird.inset.filled")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("菜单栏收纳").font(.headline)
                    Text("让常用图标留在眼前")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 5) {
                navigationButton("全部图标", systemImage: "square.grid.2x2", section: nil)
                ForEach([VisibilitySection.visible, .collapsed, .hidden], id: \.self) { section in
                    navigationButton(section.displayName, systemImage: section.systemImage, section: section)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Text("收纳偏好").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Toggle("自动收回展开图标", isOn: Binding(
                    get: { model.layout.autoCollapse },
                    set: { model.setAutoCollapse($0) }
                ))
                .toggleStyle(.switch)
                .font(.caption)
                if model.layout.autoCollapse {
                    Picker("收回等待", selection: Binding(
                        get: { model.layout.collapseDelay },
                        set: { model.setCollapseDelay($0) }
                    )) {
                        Text("5 秒").tag(5.0)
                        Text("8 秒").tag(8.0)
                        Text("10 秒").tag(10.0)
                        Text("20 秒").tag(20.0)
                    }
                    .font(.caption)
                }
                Divider()
                Button("恢复所有可管理图标") { model.restoreAll() }
                    .font(.caption)
                    .disabled(!model.accessibilityGranted || model.isBusy)
                    .help("将图标恢复到菜单栏可见区域")
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    /// 构建带选中状态的侧栏按钮。
    private func navigationButton(_ title: String, systemImage: String, section: VisibilitySection?) -> some View {
        Button { model.selectedSection = section } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage).frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: model.selectedSection == section ? .semibold : .regular))
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(model.selectedSection == section ? Color.accentColor.opacity(0.13) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(model.selectedSection == section ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    /// 顶部说明把编辑草稿与实际系统变更区分清楚。
    private var titleArea: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.selectedSection?.displayName ?? "整理你的菜单栏")
                    .font(.system(size: 25, weight: .bold))
                Text("拖动图标调整分区和顺序，完成后点击“应用布局”。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isBusy {
                ProgressView().controlSize(.small).padding(.top, 7)
            } else {
                Label(model.managementActive ? "布局管理中" : "尚未应用布局",
                      systemImage: model.managementActive ? "checkmark.circle" : "pencil.circle")
                    .font(.caption)
                    .foregroundStyle(model.managementActive ? Color.green : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    /// 原生操作行直接放入窗口内容，兼容 AppKit 托管窗口及离屏预览。
    private var actionArea: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索菜单栏图标", text: $model.query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("搜索菜单栏图标")
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(9)
            .frame(maxWidth: 300)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            Spacer(minLength: 0)
            Button { model.refresh() } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("重新扫描当前菜单栏图标")
            .disabled(model.isBusy)
            Button { model.applyLayout() } label: {
                Label("应用布局", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.accessibilityGranted || !model.screenRecordingGranted || model.isBusy || model.entries.isEmpty)
        }
    }

    /// 缺少权限时提供真实状态和系统授权入口，不填充模拟数据。
    @ViewBuilder private var permissionArea: some View {
        if !model.accessibilityGranted || !model.screenRecordingGranted {
            HStack(alignment: .top, spacing: 12) {
                if !model.accessibilityGranted {
                    permissionCard(title: "允许管理图标", icon: "hand.point.up.left", detail: "辅助功能权限用于移动图标和打开原软件菜单。", action: { model.requestAccessibility() }, settings: { model.openPrivacySettings(accessibility: true) })
                }
                if !model.screenRecordingGranted {
                    permissionCard(title: "显示原始图标", icon: "rectangle.inset.filled", detail: "下拉原图标展示需要屏幕录制权限；授权后可应用收纳布局，未授权时仅显示应用图标。", action: { model.requestScreenRecording() }, settings: { model.openPrivacySettings(accessibility: false) })
                }
            }
        }
    }

    /// 绘制单项权限说明及授权按钮。
    private func permissionCard(title: String, icon: String, detail: String, action: @escaping () -> Void, settings: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("授权", action: action).buttonStyle(.bordered)
                Button("打开系统设置", action: settings).buttonStyle(.link)
            }
            .font(.caption)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.12)))
    }

    /// 显示控制器确认的错误或操作状态，失败信息不使用成功样式。
    @ViewBuilder private var feedbackArea: some View {
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Color.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        } else if !model.statusMessage.isEmpty {
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    /// 三个分区共享拖动键，支持跨区移动和区内排序。
    private var sectionArea: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(displayedSections, id: \.self) { section in
                sectionColumn(section)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 分区卡片同时提供列表内插入及空白区域追加的放置目标。
    private func sectionColumn(_ section: VisibilitySection) -> some View {
        let items = model.items(in: section)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(section.displayName, systemImage: section.systemImage)
                    .font(.headline)
                Spacer()
                Text("\(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            Text(sectionDetail(section)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    if items.isEmpty {
                        emptySection(section)
                    } else {
                        ForEach(items) { entry in
                            draggableRow(entry, in: section, items: items)
                        }
                    }
                    Color.clear.frame(height: 36)
                        .contentShape(Rectangle())
                        .onDrop(of: [UTType.plainText], delegate: MenuEntryDropDelegate(model: model, section: section, before: nil, draggedID: $draggedID))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        .onDrop(of: [UTType.plainText], delegate: MenuEntryDropDelegate(model: model, section: section, before: nil, draggedID: $draggedID))
    }

    /// 仅可移动项目提供拖动；系统受限项目保留可读说明。
    @ViewBuilder private func draggableRow(_ entry: MenuBarEntry, in section: VisibilitySection, items: [MenuBarEntry]) -> some View {
        if entry.canMove {
            entryRow(entry, in: section, items: items)
                .onDrag {
                    draggedID = entry.id
                    return NSItemProvider(object: entry.id as NSString)
                }
                .onDrop(of: [UTType.plainText], delegate: MenuEntryDropDelegate(model: model, section: section, before: entry.id, draggedID: $draggedID))
        } else {
            entryRow(entry, in: section, items: items)
        }
    }

    /// 单项卡片提供状态切换和键盘可访问的排序菜单。
    private func entryRow(_ entry: MenuBarEntry, in section: VisibilitySection, items: [MenuBarEntry]) -> some View {
        HStack(alignment: .center, spacing: 9) {
            EntryArtwork(entry: entry, size: 25)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                if let limitation = entry.limitation, !entry.canMove {
                    Label(limitation, systemImage: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else if entry.image == nil {
                    Text("应用图标").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if entry.canMove {
                Menu {
                    ForEach([VisibilitySection.visible, .collapsed, .hidden], id: \.self) { destination in
                        Button {
                            model.moveItem(id: entry.id, to: destination, before: nil)
                        } label: {
                            Label(destination.displayName, systemImage: destination.systemImage)
                        }
                        .disabled(destination == section)
                    }
                    Divider()
                    Button("向前移动") { reorder(entry, items: items, in: section, forward: true) }
                        .disabled(items.first?.id == entry.id)
                    Button("向后移动") { reorder(entry, items: items, in: section, forward: false) }
                        .disabled(items.last?.id == entry.id)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("调整\(entry.name)的状态和顺序")
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary.opacity(0.5)))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .help(entry.canMove ? "拖动以调整顺序和分区" : entry.limitation ?? "系统限制，此项目暂不可管理")
    }

    /// 通过现有插入规则实现相邻排序，避免复制控制器的布局逻辑。
    private func reorder(_ entry: MenuBarEntry, items: [MenuBarEntry], in section: VisibilitySection, forward: Bool) {
        guard let index = items.firstIndex(where: { $0.id == entry.id }) else { return }
        if forward, index > 0 {
            model.moveItem(id: entry.id, to: section, before: items[index - 1].id)
        } else if !forward, index + 1 < items.count {
            let nextID = index + 2 < items.count ? items[index + 2].id : nil
            model.moveItem(id: entry.id, to: section, before: nextID)
        }
    }

    /// 空分区不展示模拟图标，按当前权限和搜索条件给出下一步。
    private func emptySection(_ section: VisibilitySection) -> some View {
        VStack(spacing: 10) {
            Image(systemName: model.query.isEmpty ? section.systemImage : "magnifyingglass")
                .font(.system(size: 25))
                .foregroundStyle(.tertiary)
            Text(model.query.isEmpty ? "暂无图标" : "未找到匹配图标")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(!model.accessibilityGranted ? "授权后刷新菜单栏" : model.query.isEmpty ? "将图标拖到此处" : "试试其他关键词")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 35)
    }

    /// 提供三个状态各自的行为说明。
    private func sectionDetail(_ section: VisibilitySection) -> String {
        switch section {
        case .visible: return "保留在顶部菜单栏，随时可用。"
        case .collapsed: return "点击收纳入口，在下方面板中打开。"
        case .hidden: return "收纳面板中也不显示，可在这里恢复。"
        }
    }

    /// 底部说明限制项及应用持续运行的语义。
    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text("隐藏图标不会退出软件。带锁项目由系统限制，无法移动或隐藏。")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// 将拖放数据交给共享控制器，仅允许当前扫描结果中的可管理图标。
private struct MenuEntryDropDelegate: DropDelegate {
    /// 提供布局操作的控制器。
    let model: NestCoordinator
    /// 目标显示分区。
    let section: VisibilitySection
    /// 插入位置；nil 表示移至该区末尾。
    let before: String?
    /// 当前同窗口拖动的图标键。
    @Binding var draggedID: String?

    /// 拖动进入时标明移动而非复制语义。
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    /// 接收文本键并核对来源；外部文件或文本不能生成新的菜单栏项目。
    func performDrop(info: DropInfo) -> Bool {
        // 每次从当前拖放载体取键，避免上次取消拖动留下的键误移动图标。
        guard let provider = info.itemProviders(for: [UTType.plainText]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? String else { return }
            Task { @MainActor in
                guard value != before, model.entries.contains(where: { $0.id == value && $0.canMove }) else { return }
                model.moveItem(id: value, to: section, before: before)
                draggedID = nil
            }
        }
        return true
    }
}

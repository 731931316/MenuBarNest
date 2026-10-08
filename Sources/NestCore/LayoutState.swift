import Foundation
import OSLog

/// 菜单栏项目的显示分区，决定项目是否出现在顶部或展开面板中。
public enum VisibilitySection: String, Codable, CaseIterable, Identifiable {
    /// 始终留在系统菜单栏的项目。
    case visible
    /// 从顶部收起、可在展开面板调用的项目。
    case collapsed
    /// 在顶部及普通展开面板中均不显示的项目。
    case hidden

    /// 供 SwiftUI 使用的稳定分区标识。
    public var id: String { rawValue }

    /// 管理界面中展示的中文名称。
    public var displayName: String {
        switch self {
        case .visible: return "常显"
        case .collapsed: return "收起"
        case .hidden: return "始终隐藏"
        }
    }

    /// 管理界面中用于区分各分区的 SF Symbols 名称。
    public var systemImage: String {
        switch self {
        case .visible: return "menubar.rectangle"
        case .collapsed: return "tray"
        case .hidden: return "eye.slash"
        }
    }
}

/// 一个菜单栏项目的持久化位置，数组内的顺序同时表示分区内的排序。
public struct ItemPlacement: Codable, Equatable {
    /// 由发现服务提供的稳定项目标识。
    public var id: String
    /// 项目所属的显示分区。
    public var section: VisibilitySection

    /// 创建项目的位置记录。
    public init(id: String, section: VisibilitySection) {
        self.id = id
        self.section = section
    }
}

/// 与界面及系统事件无关的布局规则；暂时退出的应用仍保留自己的位置。
public struct LayoutState: Codable, Equatable {
    /// 全部已知项目的位置；每个标识最多出现一次。
    public var placements: [ItemPlacement]
    /// 展开后是否在等待时间结束时自动收起。
    public var autoCollapse: Bool
    /// 自动收起前的等待秒数。
    public var collapseDelay: Double
    /// 用户已确认启用管理，重启后可在权限允许时恢复收纳。
    public var managementEnabled: Bool

    /// 创建布局并消除重复标识，保留第一次出现时的位置。
    public init(
        placements: [ItemPlacement] = [],
        autoCollapse: Bool = true,
        collapseDelay: Double = 8,
        managementEnabled: Bool = false
    ) {
        var seen = Set<String>()
        self.placements = placements.filter { seen.insert($0.id).inserted }
        self.autoCollapse = autoCollapse
        self.collapseDelay = collapseDelay
        self.managementEnabled = managementEnabled
    }

    /// 解码已保存的布局，旧配置缺少启用标记时不自动启用管理。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            placements: try values.decode([ItemPlacement].self, forKey: .placements),
            autoCollapse: try values.decodeIfPresent(Bool.self, forKey: .autoCollapse) ?? true,
            collapseDelay: try values.decodeIfPresent(Double.self, forKey: .collapseDelay) ?? 8,
            managementEnabled: try values.decodeIfPresent(Bool.self, forKey: .managementEnabled) ?? false
        )
    }

    /// 返回项目所属分区，尚未记录的新项目默认常显。
    public func section(for id: String) -> VisibilitySection {
        placements.first { $0.id == id }?.section ?? .visible
    }

    /// 从当前发现的项目中生成分区顺序，保留已保存的顺序并补入新项目。
    public func orderedIDs(in section: VisibilitySection, among ids: [String]) -> [String] {
        let available = Set(ids)
        var seen = Set<String>()
        var ordered = placements.compactMap { placement -> String? in
            guard placement.section == section,
                  available.contains(placement.id),
                  seen.insert(placement.id).inserted else { return nil }
            return placement.id
        }

        // 仅追加属于当前分区的项目；重复发现不会生成重复图标。
        for id in ids where self.section(for: id) == section {
            if seen.insert(id).inserted { ordered.append(id) }
        }
        return ordered
    }

    /// 记录首次发现的项目，不删除当前未运行应用的位置记录。
    public mutating func reconcile(discoveredIDs: [String]) {
        var seen = Set<String>()
        // 防止调用方直接修改数组后出现重复记录。
        placements = placements.filter { seen.insert($0.id).inserted }
        for id in discoveredIDs where seen.insert(id).inserted {
            placements.append(ItemPlacement(id: id, section: .visible))
        }
    }

    /// 把项目移入目标分区，并放在目标项目之前或该分区末尾。
    public mutating func move(id: String, to section: VisibilitySection, before targetID: String? = nil) {
        // 拖回自身不改变位置，也不改变其他分区的顺序。
        if targetID == id, self.section(for: id) == section,
           placements.contains(where: { $0.id == id }) { return }

        placements.removeAll { $0.id == id }
        let placement = ItemPlacement(id: id, section: section)
        if let targetID,
           let index = placements.firstIndex(where: { $0.id == targetID && $0.section == section }) {
            placements.insert(placement, at: index)
        } else if let lastIndex = placements.lastIndex(where: { $0.section == section }) {
            placements.insert(placement, at: lastIndex + 1)
        } else {
            placements.append(placement)
        }
        Self.logger.debug("已更新项目分区和排序")
    }

    /// 恢复默认布局及展开行为，后续发现的项目会重新成为常显。
    public mutating func reset() {
        self = LayoutState()
        Self.logger.info("已恢复默认菜单栏布局")
    }

    /// 持久化布局时使用的字段名。
    private enum CodingKeys: String, CodingKey {
        case placements
        case autoCollapse
        case collapseDelay
        case managementEnabled
    }

    /// 使用应用统一日志通道，避免在日志中输出应用标识和配置内容。
    private static let logger = Logger(subsystem: "local.MenuBarNest", category: "app")
}

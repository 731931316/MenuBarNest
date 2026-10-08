import Foundation
import OSLog

/// 将布局读写到调用方提供的本机配置位置，不依赖开发者个人目录。
public final class LayoutRepository {
    /// 由应用支持目录动态生成的配置文件地址。
    private let fileURL: URL
    /// 统一日志通道，不记录路径或配置内容。
    private let logger = Logger(subsystem: "local.MenuBarNest", category: "app")

    /// 指定布局文件位置；初始化不会创建或覆盖文件。
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 加载布局，首次启动使用默认值；损坏或不可读配置会向调用方报告失败。
    public func load() throws -> LayoutState {
        do {
            let data = try Data(contentsOf: fileURL)
            let state = try JSONDecoder().decode(LayoutState.self, from: data)
            logger.debug("已加载菜单栏布局")
            return state
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // 只有确实不存在配置才使用默认值，权限或其他读取错误仍需报告。
            logger.info("尚无布局配置，使用默认布局")
            return LayoutState()
        } catch {
            // 读取失败时保留原文件，禁止把默认布局自动写回损坏配置。
            logger.error("布局配置读取失败，原配置已保留")
            throw error
        }
    }

    /// 原子保存布局，编码或写入失败时向调用方报告错误。
    public func save(_ state: LayoutState) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)

            // 先完成编码，再创建配置目录；原子替换避免留下半写入文件。
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            logger.info("已保存菜单栏布局")
        } catch {
            logger.error("布局配置保存失败")
            throw error
        }
    }
}

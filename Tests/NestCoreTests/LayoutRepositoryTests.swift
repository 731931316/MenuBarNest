import XCTest
@testable import NestCore

/// 验证原子存储、首次加载和失败保护行为，所有文件均位于独立临时目录。
final class LayoutRepositoryTests: XCTestCase {
    /// 为本次测试生成独立且可回收的临时目录。
    private var temporaryDirectory: URL!

    /// 为每个测试创建独立文件夹，避免测试之间共享配置。
    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    /// 仅清理当前测试创建的临时目录。
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    /// 配置尚不存在时返回默认布局，读取不会创建文件。
    func testMissingConfigurationUsesDefaultsWithoutWriting() throws {
        let file = temporaryDirectory.appendingPathComponent("layout.json")
        let repository = LayoutRepository(fileURL: file)
        XCTAssertEqual(try repository.load(), LayoutState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// 保存会创建父目录，重新加载保持排序及设置一致。
    func testSaveAndLoadPreserveLayout() throws {
        let file = temporaryDirectory.appendingPathComponent("settings/layout.json")
        let repository = LayoutRepository(fileURL: file)
        let state = LayoutState(placements: [
            ItemPlacement(id: "b", section: .collapsed),
            ItemPlacement(id: "a", section: .hidden)
        ], autoCollapse: false, collapseDelay: 16, managementEnabled: true)
        try repository.save(state)
        XCTAssertEqual(try repository.load(), state)
        XCTAssertTrue(try repository.load().managementEnabled)
        var updated = state
        updated.move(id: "a", to: .collapsed, before: "b")
        try repository.save(updated)
        XCTAssertEqual(try repository.load(), updated)
    }

    /// 损坏配置会报告解码失败且保持原始字节，避免静默覆盖。
    func testCorruptConfigurationRemainsIntact() throws {
        let file = temporaryDirectory.appendingPathComponent("layout.json")
        let corrupt = Data("{ invalid configuration".utf8)
        try corrupt.write(to: file)
        let repository = LayoutRepository(fileURL: file)
        XCTAssertThrowsError(try repository.load())
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    /// 无法创建父目录时保存必须报告错误，不得伪装保存成功。
    func testSaveFailureIsReported() throws {
        let blockedParent = temporaryDirectory.appendingPathComponent("blocked")
        try Data("file instead of directory".utf8).write(to: blockedParent)
        let repository = LayoutRepository(fileURL: blockedParent.appendingPathComponent("layout.json"))
        XCTAssertThrowsError(try repository.save(LayoutState()))
        XCTAssertEqual(try String(contentsOf: blockedParent), "file instead of directory")
    }

    /// 无法编码的数值会保留上一次成功写入的文件。
    func testEncodingFailurePreservesPreviousConfiguration() throws {
        let file = temporaryDirectory.appendingPathComponent("layout.json")
        let repository = LayoutRepository(fileURL: file)
        let original = LayoutState(collapseDelay: 10)
        try repository.save(original)
        var invalid = original
        invalid.collapseDelay = .nan
        XCTAssertThrowsError(try repository.save(invalid))
        XCTAssertEqual(try repository.load(), original)
    }
}

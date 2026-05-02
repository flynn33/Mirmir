import Foundation
import XCTest
@testable import ForsettiCore
@testable import ForsettiPlatform

final class PlatformServicesTests: XCTestCase {
    func testDefaultPlatformServicesUseProductionSecureStorage() {
        let services = DefaultForsettiPlatformServices()

        let secureStorage = services.container.resolve(SecureStorageService.self)

        XCTAssertTrue(secureStorage is KeychainSecureStorageService)
    }

    func testInMemorySecureStorageIsExplicitlyAvailableForTests() throws {
        let storage: any SecureStorageService = InMemorySecureStorageService()
        let data = Data("secret".utf8)

        try storage.set(data, forKey: "token")

        XCTAssertEqual(try storage.value(forKey: "token"), data)
    }

    func testFileExportRejectsEmptyFileName() throws {
        let directory = try temporaryDirectory()
        let exporter = LocalFileExportService(directoryURL: directory)

        XCTAssertThrowsError(
            try exporter.export(data: Data("payload".utf8), suggestedFileName: "   ")
        ) { error in
            XCTAssertEqual(error as? LocalFileExportError, .invalidFileName)
        }
    }

    func testFileExportSanitizesPathTraversalFileName() throws {
        let directory = try temporaryDirectory()
        let exporter = LocalFileExportService(directoryURL: directory)

        let exportedURL = try exporter.export(
            data: Data("payload".utf8),
            suggestedFileName: "../../evil.txt"
        )

        XCTAssertEqual(exportedURL.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(exportedURL.lastPathComponent, "evil.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))
    }

    func testFileExportDoesNotWriteOutsideExportDirectoryForAbsolutePath() throws {
        let directory = try temporaryDirectory()
        let exporter = LocalFileExportService(directoryURL: directory)

        let exportedURL = try exporter.export(
            data: Data("payload".utf8),
            suggestedFileName: "/tmp/evil.txt"
        )

        XCTAssertEqual(exportedURL.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(exportedURL.lastPathComponent, "evil.txt")
    }

    func testOSLogLoggerCanBeConstructed() {
        let logger = OSLogForsettiLogger(subsystem: "com.forsetti.tests", category: "PlatformServicesTests")

        logger.log(.info, message: "logger construction test")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForsettiPlatformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

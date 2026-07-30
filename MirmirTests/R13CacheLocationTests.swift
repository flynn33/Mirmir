import Foundation
import XCTest
@testable import Mirmir

final class R13CacheLocationTests: XCTestCase {
    func testDefaultLocationUsesApplicationSupportRoot() throws {
        let fixture = try R13CacheLocationFixture()
        defer { fixture.cleanup() }

        let store = fixture.makeStore()
        let status = store.cacheLocationStatus()
        let configuration = try store.configuration()

        XCTAssertTrue(status.isAvailable)
        XCTAssertFalse(status.selection.isCustom)
        XCTAssertEqual(
            configuration.trustedRootURL,
            resolved(fixture.defaultRoot)
        )
        XCTAssertEqual(
            configuration.jobsRootURL,
            jobsRoot(in: fixture.defaultRoot)
        )
    }

    func testCustomLocationPersistsAndRuntimeSwitchesImmediately()
        throws {
        let fixture = try R13CacheLocationFixture()
        defer { fixture.cleanup() }
        let firstRoot = try fixture.makeDirectory(named: "External")
        let secondRoot = try fixture.makeDirectory(named: "Network Share")
        let store = fixture.makeStore()

        let selected = try store.selectCacheLocation(firstRoot)
        XCTAssertTrue(selected.isAvailable)
        XCTAssertTrue(selected.selection.isCustom)
        XCTAssertEqual(selected.selection.displayPath, firstRoot.path)

        let reopenedStore = fixture.makeStore()
        let service = R13ReleaseUpscalerEngineService(
            media: NoopMediaPipelineService(),
            cacheLocationStore: reopenedStore
        )
        let firstRuntime = try XCTUnwrap(
            try service.resolveHardeningRuntime()
        )
        XCTAssertEqual(
            firstRuntime.jobsRootURL,
            jobsRoot(in: firstRoot)
        )

        _ = try reopenedStore.selectCacheLocation(secondRoot)
        let retainedRuntime = try XCTUnwrap(
            try service.resolveHardeningRuntime()
        )
        XCTAssertEqual(
            retainedRuntime.jobsRootURL,
            jobsRoot(in: firstRoot)
        )

        let switched = try service.selectCacheLocation(secondRoot)
        XCTAssertTrue(switched.isAvailable)
        XCTAssertEqual(switched.selection.displayPath, secondRoot.path)
        XCTAssertNil(service.hardeningRuntime)
        let secondRuntime = try XCTUnwrap(
            try service.resolveHardeningRuntime()
        )
        XCTAssertEqual(
            secondRuntime.jobsRootURL,
            jobsRoot(in: secondRoot)
        )
    }

    func testRuntimeResolutionRetriesAfterConcurrentCacheLocationChange()
        async throws {
        let fixture = try R13CacheLocationFixture()
        defer { fixture.cleanup() }
        let firstRoot = try fixture.makeDirectory(named: "First")
        let secondRoot = try fixture.makeDirectory(named: "Second")
        let bookmarkResolver = R13BlockingCacheLocationBookmarkResolver()
        let store = fixture.makeStore(bookmarkResolver: bookmarkResolver)
        _ = try store.selectCacheLocation(firstRoot)
        bookmarkResolver.blockNextResolution(of: firstRoot)
        let service = R13ReleaseUpscalerEngineService(
            media: NoopMediaPipelineService(),
            cacheLocationStore: store
        )

        let resolution = Task.detached {
            try service.resolveHardeningRuntime()
        }
        defer {
            bookmarkResolver.releaseBlockedResolution()
            resolution.cancel()
        }
        try await bookmarkResolver.waitUntilResolutionIsBlocked()

        let switched = try service.selectCacheLocation(secondRoot)
        XCTAssertTrue(switched.isAvailable)
        bookmarkResolver.releaseBlockedResolution()
        let resolvedRuntime = try await resolution.value
        let runtime = try XCTUnwrap(resolvedRuntime)

        XCTAssertEqual(
            runtime.jobsRootURL,
            jobsRoot(in: secondRoot)
        )
        XCTAssertEqual(
            service.hardeningRuntime?.jobsRootURL,
            runtime.jobsRootURL
        )
    }

    func testUnavailableCustomLocationDoesNotFallBackSilently()
        throws {
        let fixture = try R13CacheLocationFixture()
        defer { fixture.cleanup() }
        let selectedRoot = try fixture.makeDirectory(named: "Offline Share")
        let store = fixture.makeStore()
        _ = try store.selectCacheLocation(selectedRoot)
        try FileManager.default.removeItem(at: selectedRoot)

        let status = store.cacheLocationStatus()

        XCTAssertTrue(status.selection.isCustom)
        XCTAssertEqual(status.selection.displayPath, selectedRoot.path)
        XCTAssertFalse(status.isAvailable)
        XCTAssertEqual(
            status.availabilityError,
            R13CacheLocationError.locationUnavailable.localizedDescription
        )
        XCTAssertThrowsError(try store.configuration()) {
            XCTAssertEqual(
                $0 as? R13CacheLocationError,
                .locationUnavailable
            )
        }
    }

    func testUseDefaultLocationClearsCustomSelection() throws {
        let fixture = try R13CacheLocationFixture()
        defer { fixture.cleanup() }
        let selectedRoot = try fixture.makeDirectory(named: "External")
        let store = fixture.makeStore()
        _ = try store.selectCacheLocation(selectedRoot)

        let status = store.useDefaultCacheLocation()
        let configuration = try store.configuration()

        XCTAssertTrue(status.isAvailable)
        XCTAssertFalse(status.selection.isCustom)
        XCTAssertEqual(
            configuration.trustedRootURL,
            resolved(fixture.defaultRoot)
        )
    }

    func testCacheLocationChangesAreSerialized() throws {
        let fixture = try R13CacheLocationFixture()
        defer { fixture.cleanup() }
        let selectedRoot = try fixture.makeDirectory(named: "External")
        let store = fixture.makeStore()
        let service = R13ReleaseUpscalerEngineService(
            media: NoopMediaPipelineService(),
            cacheLocationStore: store
        )

        _ = try service.performCacheLocationChange {
            XCTAssertThrowsError(
                try service.selectCacheLocation(selectedRoot)
            ) {
                XCTAssertEqual(
                    $0 as? R13CacheLocationError,
                    .changeWhileJobRunning
                )
            }
            return store.cacheLocationStatus()
        }

        XCTAssertTrue(
            try service.selectCacheLocation(selectedRoot).isAvailable
        )
    }

    func testNonFileURLIsRejected() throws {
        let fixture = try R13CacheLocationFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let remoteURL = try XCTUnwrap(
            URL(string: "https://example.invalid/cache")
        )

        XCTAssertThrowsError(
            try store.selectCacheLocation(remoteURL)
        ) {
            XCTAssertEqual(
                $0 as? R13CacheLocationError,
                .invalidDirectory
            )
        }
    }

    func testCorruptPreferenceIsReportedWithoutFallback() throws {
        let fixture = try R13CacheLocationFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(
            Data("{}".utf8),
            forKey: fixture.preferenceKey
        )
        let store = fixture.makeStore()

        let status = store.cacheLocationStatus()

        XCTAssertTrue(status.selection.isCustom)
        XCTAssertFalse(status.isAvailable)
        XCTAssertEqual(
            status.availabilityError,
            R13CacheLocationError.configurationCorrupt
                .localizedDescription
        )
        XCTAssertThrowsError(try store.configuration()) {
            XCTAssertEqual(
                $0 as? R13CacheLocationError,
                .configurationCorrupt
            )
        }
    }

    private func jobsRoot(in root: URL) -> URL {
        resolved(root)
            .appendingPathComponent("Mirmir", isDirectory: true)
            .appendingPathComponent("Jobs", isDirectory: true)
    }

    private func resolved(_ root: URL) -> URL {
        R13RestartPath.resolvingExistingAncestor(of: root)
    }
}

private final class R13CacheLocationFixture {
    let root: URL
    let defaultRoot: URL
    let defaults: UserDefaults
    let preferenceKey: String

    private let defaultsSuiteName: String

    init() throws {
        let identifier = UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-cache-location-\(identifier)",
            isDirectory: true
        )
        defaultRoot = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        defaultsSuiteName = "com.flynn33.MirmirTests.Cache.\(identifier)"
        defaults = try XCTUnwrap(
            UserDefaults(suiteName: defaultsSuiteName)
        )
        preferenceKey = "cache-location-\(identifier)"
        try FileManager.default.createDirectory(
            at: defaultRoot,
            withIntermediateDirectories: true
        )
    }

    func makeStore(
        bookmarkResolver: any R13CacheLocationBookmarkResolving =
            R13TestCacheLocationBookmarkResolver()
    ) -> R13CacheLocationStore {
        R13CacheLocationStore(
            defaults: defaults,
            preferenceKey: preferenceKey,
            bookmarkResolver: bookmarkResolver,
            defaultRootProvider: { [defaultRoot] in defaultRoot }
        )
    }

    func makeDirectory(named name: String) throws -> URL {
        let url = root.appendingPathComponent(
            name,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct R13TestCacheLocationBookmarkResolver:
    R13CacheLocationBookmarkResolving {
    func makeBookmark(for url: URL) throws -> Data {
        Data(url.standardizedFileURL.absoluteString.utf8)
    }

    func resolveBookmark(_ data: Data) throws
        -> R13ResolvedCacheLocationBookmark {
        guard let value = String(data: data, encoding: .utf8),
              let url = URL(string: value),
              url.isFileURL else {
            throw R13CacheLocationError.bookmarkResolutionFailed
        }
        return R13ResolvedCacheLocationBookmark(
            url: url,
            isStale: false,
            startAccessing: { true },
            stopAccessing: {}
        )
    }
}

private final class R13BlockingCacheLocationBookmarkResolver:
    R13CacheLocationBookmarkResolving,
    @unchecked Sendable {
    private let condition = NSCondition()
    private var blockedURL: URL?
    private var resolutionIsBlocked = false
    private var releaseResolution = false

    func makeBookmark(for url: URL) throws -> Data {
        Data(url.standardizedFileURL.absoluteString.utf8)
    }

    func resolveBookmark(_ data: Data) throws
        -> R13ResolvedCacheLocationBookmark {
        guard let value = String(data: data, encoding: .utf8),
              let url = URL(string: value),
              url.isFileURL else {
            throw R13CacheLocationError.bookmarkResolutionFailed
        }
        let standardizedURL = url.standardizedFileURL
        condition.lock()
        if blockedURL == standardizedURL && !resolutionIsBlocked {
            resolutionIsBlocked = true
            condition.broadcast()
            while !releaseResolution {
                condition.wait()
            }
        }
        condition.unlock()
        return R13ResolvedCacheLocationBookmark(
            url: standardizedURL,
            isStale: false,
            startAccessing: { true },
            stopAccessing: {}
        )
    }

    func blockNextResolution(of url: URL) {
        condition.withLock {
            blockedURL = url.standardizedFileURL
            resolutionIsBlocked = false
            releaseResolution = false
        }
    }

    func releaseBlockedResolution() {
        condition.withLock {
            releaseResolution = true
            condition.broadcast()
        }
    }

    func waitUntilResolutionIsBlocked() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition.withLock({ resolutionIsBlocked }) {
            guard clock.now < deadline else {
                throw R13BlockingCacheLocationTestError.resolutionDidNotBlock
            }
            await Task.yield()
        }
    }
}

private enum R13BlockingCacheLocationTestError: Error {
    case resolutionDidNotBlock
}

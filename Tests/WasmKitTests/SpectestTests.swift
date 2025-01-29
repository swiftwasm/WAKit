import WasmKit
import XCTest

@available(macOS 11, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
final class SpectestTests: XCTestCase {
    static let projectDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let testsuite =
        projectDir
        .appendingPathComponent("Vendor/testsuite")
    static var testPaths: [String] {
        [
            Self.testsuite.path,
            Self.testsuite.appendingPathComponent("proposals/memory64").path,
            Self.testsuite.appendingPathComponent("proposals/tail-call").path,
            Self.projectDir.appendingPathComponent("Tests/WasmKitTests/ExtraSuite").path,
        ]
    }

    static var functionReferences: [String] { [Self.testsuite.appendingPathComponent("proposals/function-references").path] }
    static var gcPath: [String] { [Self.testsuite.appendingPathComponent("proposals/gc").path] }

    /// Run all the tests in the spectest suite.
    func testRunAll() async throws {
        let defaultConfig = EngineConfiguration()
        let ok = try await spectest(
            path: Self.testPaths,
            include: [],
            exclude: [],
            parallel: true,
            configuration: defaultConfig
        )
        XCTAssertTrue(ok)
    }

    func testRunAllWithTokenThreading() async throws {
        let defaultConfig = EngineConfiguration()
        guard defaultConfig.threadingModel != .token else { return }
        // Sanity check that non-default threading models work.
        var config = defaultConfig
        config.threadingModel = .token
        let ok = try await spectest(
            path: Self.testPaths,
            parallel: true,
            configuration: config
        )
        XCTAssertTrue(ok)
    }

    func testFunctionReferencesProposals() async throws {
        let defaultConfig = EngineConfiguration()
        let result = try await spectestResult(
            path: Self.functionReferences,
            include: ["function-references/call_ref.wast"],  // focusing on call_ref for now, but will update to run all function-references tests.
            exclude: [],
            parallel: false,
            configuration: defaultConfig
        )

        XCTAssertEqual(result.passed, 7)
        XCTAssertEqual(result.failed, 27)
    }

    /// Run the garbage collection proposal tests
    /// As we add support, we can increase the passed count and delete entries from the failed array.
    func testFunctionReferencesAndGarbageCollectionProposals() async throws {
        let defaultConfig = EngineConfiguration()
        let result = try await spectestResult(
            path: Self.gcPath,
            include: [],
            exclude: [],
            parallel: true,
            configuration: defaultConfig
        )

        XCTAssertEqual(result.passed, 1552)
        XCTAssertEqual(result.failed, 368)
        XCTAssertEqual(
            result.sortedFailedCases(),
            [
                "gc/array.wast",
                "gc/array_copy.wast",
                "gc/array_fill.wast",
                "gc/array_init_data.wast",
                "gc/array_init_elem.wast",
                "gc/br_on_cast.wast",
                "gc/br_on_cast_fail.wast",
                "gc/br_on_non_null.wast",
                "gc/br_on_null.wast",
                "gc/br_table.wast",
                "gc/call_ref.wast",
                "gc/data.wast",
                "gc/elem.wast",
                "gc/extern.wast",
                "gc/func.wast",
                "gc/global.wast",
                "gc/i31.wast",
                "gc/linking.wast",
                "gc/local_init.wast",
                "gc/ref.wast",
                "gc/ref_as_non_null.wast",
                "gc/ref_cast.wast",
                "gc/ref_eq.wast",
                "gc/ref_is_null.wast",
                "gc/ref_null.wast",
                "gc/ref_test.wast",
                "gc/return_call_ref.wast",
                "gc/struct.wast",
                "gc/table-sub.wast",
                "gc/table.wast",
                "gc/type-canon.wast",
                "gc/type-equivalence.wast",
                "gc/type-rec.wast",
                "gc/type-subtyping.wast",
                "gc/unreached-invalid.wast",
                "gc/unreached-valid.wast",
            ]
        )
    }
}

import Foundation
import SystemPackage
import WasmKit
import WasmKitWASI
import XCTest

final class IntegrationTests: XCTestCase {
    func testRunAll() throws {
        let testDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/wasi-testsuite")
        var failedTests: [String: [String]] = [:]
        for testSuitePath in ["tests/assemblyscript/testsuite", "tests/c/testsuite", "tests/rust/testsuite"] {
            let suitePath = testDir.appendingPathComponent(testSuitePath)
            try runTestSuite(path: suitePath, failedTests: &failedTests)
        }
        if !failedTests.isEmpty {
            print("Failed tests:")
            for (suite, cases) in failedTests {
                print("  \(suite):")
                for caseName in cases {
                    print("    \(caseName)")
                }
            }
        }
    }

    struct SuiteManifest: Codable {
        let name: String
    }

    static var skipTests: [String: Set<String>] {
        #if os(Windows)
            return [
                "WASI Assemblyscript tests": [],
                "WASI C tests": [
                    "fdopendir-with-access",
                    "fopen-with-access",
                    "lseek",
                    "pread-with-access",
                    "pwrite-with-access",
                    "stat-dev-ino",
                    "sock_shutdown-not_sock",
                    "sock_shutdown-invalid_fd",
                ],
                "WASI Rust tests": [
                    "close_preopen",
                    "dangling_fd",
                    "dangling_symlink",
                    "directory_seek",
                    "fd_advise",
                    "fd_filestat_set",
                    "fd_flags_set",
                    "fd_readdir",
                    "interesting_paths",
                    "dir_fd_op_failures",
                    "symlink_create",
                    "sched_yield",
                    "overwrite_preopen",
                    "path_link",
                    "poll_oneoff_stdio",
                    "readlink",
                    "renumber",
                    "path_filestat",
                    "remove_directory_trailing_slashes",
                    "path_rename",
                    "stdio",
                    "symlink_filestat",
                    "path_open_read_write",
                    "fd_fdstat_set_rights",
                    "file_allocate",
                    "path_rename_dir_trailing_slashes",
                    "path_open_preopen",
                ],
            ]
        #else
            return [
                "WASI C tests": [
                    "sock_shutdown-not_sock",
                    "sock_shutdown-invalid_fd",
                ],
                "WASI Rust tests": [
                    "dir_fd_op_failures",
                    "symlink_create",
                    "sched_yield",
                    "overwrite_preopen",
                    "path_link",
                    "poll_oneoff_stdio",
                    "readlink",
                    "renumber",
                    "path_filestat",
                    "remove_directory_trailing_slashes",
                    "path_rename",
                    "stdio",
                    "symlink_filestat",
                    "path_open_read_write",
                    "fd_fdstat_set_rights",
                    "file_allocate",
                    "path_rename_dir_trailing_slashes",
                    "path_open_preopen",
                ]
            ]
        #endif
    }

    func runTestSuite(path: URL, failedTests: inout [String: [String]]) throws {
        let manifestPath = path.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(SuiteManifest.self, from: Data(contentsOf: manifestPath))

        // Clean up **/*.cleanup
        do {
            let enumerator = FileManager.default.enumerator(at: path, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])!
            for case let url as URL in enumerator {
                if url.pathExtension == "cleanup" {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }

        print("Running test suite: \(manifest.name)")
        let tests = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil, options: [])

        let skipTests = Self.skipTests[manifest.name] ?? []

        for test in tests {
            guard test.pathExtension == "wasm" else { continue }
            let testName = test.deletingPathExtension().lastPathComponent
            if skipTests.contains(testName) {
                print("Test \(testName) skipped")
                continue
            }
            print("Test \(testName) started")
            switch try runTest(path: test) {
            case .success:
                print("Test \(testName) passed")
            case .failure(let error):
                XCTFail("Test \(testName) failed: \(error)")
                failedTests[manifest.name, default: []].append(testName)
            }
        }
    }

    struct CaseManifest: Codable {
        var dirs: [String]?
        var args: [String]?
        var env: [String: String]?
        var exitCode: UInt32?

        static var empty: CaseManifest {
            CaseManifest(dirs: nil, args: nil, env: nil, exitCode: nil)
        }
    }

    enum TestError: Error {
        case unexpectedExitCode(actual: UInt32, expected: UInt32)
    }

    func runTest(path: URL) throws -> Result<(), Error> {
        let manifestPath = path.deletingPathExtension().appendingPathExtension("json")
        var manifest: CaseManifest
        if FileManager.default.fileExists(atPath: manifestPath.path) {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            manifest = try decoder.decode(CaseManifest.self, from: Data(contentsOf: manifestPath))
        } else {
            manifest = .empty
        }

        // HACK: WasmKit intentionally does not support fd_allocate
        if path.lastPathComponent == "fd_advise.wasm" {
            manifest.env = (manifest.env ?? [:]).merging(["NO_FD_ALLOCATE": "1"]) { _, new in new }
        }

        let suitePath = path.deletingLastPathComponent()

        let wasi = try WASIBridgeToHost(
            args: [path.path] + (manifest.args ?? []),
            environment: manifest.env ?? [:],
            preopens: (manifest.dirs ?? []).reduce(into: [String: String]()) {
                $0[$1] = suitePath.appendingPathComponent($1).path
            }
        )
        let runtime = Runtime(hostModules: wasi.hostModules)
        let module = try parseWasm(filePath: FilePath(path.path))
        let instance = try runtime.instantiate(module: module)
        do {
            let exitCode = try wasi.start(instance, runtime: runtime)
            let expected = manifest.exitCode ?? 0
            if exitCode != expected {
                throw TestError.unexpectedExitCode(actual: exitCode, expected: expected)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

import Foundation
import SystemPackage
import WAT
import WasmKit

private func loadStringArrayFromEnvironment(_ key: String) -> [String] {
    ProcessInfo.processInfo.environment[key]?.split(separator: ",").map(String.init) ?? []
}

@available(macOS 11, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public struct SpectestResult {
    var passed = 0
    var skipped = 0
    var failed = 0
    var total: Int { passed + skipped + failed }
    var failedCases: Set<String> = []

    mutating func append(_ testCase: TestCase, _ result: Result) {
        switch result {
        case .passed:
            passed += 1
        case .skipped:
            skipped += 1
        case .failed:
            failed += 1
            failedCases.insert(testCase.path)
        }
    }

    func percentage(_ numerator: Int, _ denominator: Int) -> String {
        "\(Int(Double(numerator) / Double(denominator) * 100))%"
    }

    func sortedFailedCases() -> [String] {
        failedCases.map { URL(filePath: $0).pathComponents.suffix(2).joined(separator: "/") }.sorted()
    }

    func dump() {
        print(
            "\(passed)/\(total) (\(percentage(passed, total)) passing, \(percentage(skipped, total)) skipped, \(percentage(failed, total)) failed)"
        )
        guard !failedCases.isEmpty else { return }
        print("Failed cases:")
        for testCase in failedCases.sorted() {
            print("  \(testCase)")
        }
    }
}

@available(macOS 11, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public func spectest(
    path: [String],
    include: [String]? = nil,
    exclude: [String]? = nil,
    verbose: Bool = false,
    parallel: Bool = true,
    configuration: EngineConfiguration = .init()
) async throws -> Bool {
    try await spectestResult(path: path, include: include, exclude: exclude, verbose: verbose, parallel: parallel, configuration: configuration).failed == 0
}

@available(macOS 11, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public func spectestResult(
    path: [String],
    include: [String]? = nil,
    exclude: [String]? = nil,
    verbose: Bool = false,
    parallel: Bool = true,
    configuration: EngineConfiguration = .init()
) async throws -> SpectestResult {
    let printVerbose = verbose
    @Sendable func log(_ message: String, verbose: Bool = false) {
        if !verbose || printVerbose {
            fputs(message + "\n", stderr)
        }
    }
    @Sendable func log(_ message: String, path: String, location: Location, verbose: Bool = false) {
        if !verbose || printVerbose {
            let (line, _) = location.computeLineAndColumn()
            fputs("\(path):\(line): " + message + "\n", stderr)
        }
    }
    let include = include ?? loadStringArrayFromEnvironment("WASMKIT_SPECTEST_INCLUDE")
    let exclude = exclude ?? loadStringArrayFromEnvironment("WASMKIT_SPECTEST_EXCLUDE")

    let testCases: [TestCase]
    do {
        testCases = try TestCase.load(include: include, exclude: exclude, in: path, log: { log($0) })
    } catch {
        fatalError("failed to load test: \(error)")
    }

    guard !testCases.isEmpty else {
        log("No test found")
        return SpectestResult()
    }

    // https://github.com/WebAssembly/spec/tree/8a352708cffeb71206ca49a0f743bdc57269fb1a/interpreter#spectest-host-module
    let hostModule = try parseWasm(
        bytes: wat2wasm(
            """
                (module
                  (global (export "global_i32") i32 (i32.const 666))
                  (global (export "global_i64") i64 (i64.const 666))
                  (global (export "global_f32") f32 (f32.const 666.6))
                  (global (export "global_f64") f64 (f64.const 666.6))

                  (table (export "table") 10 20 funcref)
                  (table (export "table64") 10 20 funcref)

                  (memory (export "memory") 1 2)

                  (func (export "print"))
                  (func (export "print_i32") (param i32))
                  (func (export "print_i64") (param i64))
                  (func (export "print_f32") (param f32))
                  (func (export "print_f64") (param f64))
                  (func (export "print_i32_f32") (param i32 f32))
                  (func (export "print_f64_f64") (param f64 f64))
                )
            """))

    @Sendable func runTestCase(testCase: TestCase) throws -> [Result] {
        var testCaseResults = [Result]()
        let logDuration: () -> Void
        if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) {
            let start = ContinuousClock.now
            logDuration = {
                let elapsed = ContinuousClock.now - start
                log("Finished \(testCase.relativePath) in \(elapsed)")
            }
        } else {
            // Fallback on earlier versions
            logDuration = {}
        }
        log("Testing  \(testCase.relativePath)")
        try testCase.run(spectestModule: hostModule, configuration: configuration) { testCase, location, result in
            switch result {
            case let .failed(reason):
                log("\(result.banner) \(reason)", path: testCase.path, location: location)
            case let .skipped(reason):
                log("\(result.banner) \(reason)", path: testCase.path, location: location, verbose: true)
            case .passed:
                log(result.banner, path: testCase.path, location: location, verbose: true)
            }
            testCaseResults.append(result)
        }

        logDuration()

        return testCaseResults
    }

    let result: SpectestResult

    if parallel {
        result = try await withThrowingTaskGroup(of: (TestCase, [Result]).self) { group in
            for testCase in testCases {
                group.addTask {
                    try await Task {
                        let results = try runTestCase(testCase: testCase)
                        return (testCase, results)
                    }.value
                }
            }

            var allResults = SpectestResult()
            for try await (testCase, results) in group {
                for result in results {
                    allResults.append(testCase, result)
                }
            }
            return allResults
        }
    } else {
        var results = SpectestResult()
        for testCase in testCases {
            let testCaseResults = try runTestCase(testCase: testCase)
            for result in testCaseResults {
                results.append(testCase, result)
            }
        }
        result = results
    }

    result.dump()

    return result
}

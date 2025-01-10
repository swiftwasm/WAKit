import Foundation
import WasmParser
import XCTest

@testable import WAT

class EncoderTests: XCTestCase {

    struct CompatibilityTestStats {
        var run: Int = 0
        var failed: Set<String> = []
    }

    private func checkMalformed(wast: URL, module: ModuleDirective, message: String, recordFail: () -> Void) {
        let diagnostic = {
            let (line, column) = module.location.computeLineAndColumn()
            return "\(wast.path):\(line):\(column) should be malformed: \(message)"
        }
        switch module.source {
        case .text(var wat):
            XCTAssertThrowsError(
                try {
                    _ = try wat.encode()
                    recordFail()
                }(), diagnostic())
        case .quote(let bytes):
            XCTAssertThrowsError(
                try {
                    _ = try wat2wasm(String(decoding: bytes, as: UTF8.self))
                    recordFail()
                }(), diagnostic())
        case .binary: break
        }
    }

    func checkWabtCompatibility(
        wast: URL, json: URL, stats parentStats: inout CompatibilityTestStats
    ) throws {
        var stats = parentStats
        defer { parentStats = stats }
        func recordFail() {
            stats.failed.insert(wast.lastPathComponent)
        }
        func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
            XCTAssertEqual(lhs, rhs, file: file, line: line)
            if lhs != rhs {
                recordFail()
            }
        }

        print("Checking\n  wast: \(wast.path)\n  json: \(json.path)")
        var parser = WastParser(try String(contentsOf: wast), features: Spectest.deriveFeatureSet(wast: wast))
        var watModules: [ModuleDirective] = []

        while let directive = try parser.nextDirective() {
            switch directive {
            case .module(let moduleDirective):
                watModules.append(moduleDirective)
            case .assertMalformed(let module, let message):
                checkMalformed(wast: wast, module: module, message: message, recordFail: recordFail)
            default: break
            }
        }
        guard FileManager.default.fileExists(atPath: json.path) else {
            print("Skipping binary comparison because the oracle file (\(json.path)) does not exist.")
            return
        }
        let moduleBinaryFiles = try Spectest.moduleFiles(json: json)
        assertEqual(watModules.count, moduleBinaryFiles.count)

        for (watModule, (moduleBinaryFile, expectedName)) in zip(watModules, moduleBinaryFiles) {
            func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
                XCTAssertEqual(lhs, rhs, moduleBinaryFile.path, file: file, line: line)
                if lhs != rhs {
                    recordFail()
                }
            }
            stats.run += 1
            let moduleBytes: [UInt8]
            let expectedBytes = try Array(Data(contentsOf: moduleBinaryFile))
            do {
                assertEqual(watModule.id, expectedName)
                switch watModule.source {
                case .text(var watModule):
                    moduleBytes = try encode(module: &watModule, options: .default)
                case .binary(let bytes):
                    moduleBytes = bytes
                case .quote(let watText):
                    moduleBytes = try wat2wasm(String(decoding: watText, as: UTF8.self))
                }
            } catch {
                recordFail()
                XCTFail("Error while encoding \(moduleBinaryFile.lastPathComponent): \(error)")
                return
            }
            if moduleBytes != expectedBytes {
                recordFail()
            }
            assertEqual(moduleBytes.count, expectedBytes.count)
            if moduleBytes.count == expectedBytes.count {
                assertEqual(moduleBytes, expectedBytes)
            }
        }
    }

    func testSpectest() throws {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
            throw XCTSkip("Spectest compatibility test requires Foundation.Process")
        #else
            guard let wast2json = TestSupport.lookupExecutable("wast2json") else {
                throw XCTSkip("wast2json not found in PATH")
            }

            var stats = CompatibilityTestStats()
            let excluded: [String] = []
            for wastFile in Spectest.wastFiles(include: [], exclude: excluded) {
                try TestSupport.withTemporaryDirectory { tempDir, shouldRetain in
                    let jsonFileName = wastFile.deletingPathExtension().lastPathComponent + ".json"
                    let json = URL(fileURLWithPath: tempDir).appendingPathComponent(jsonFileName)

                    let wast2jsonProcess = try Process.run(
                        wast2json,
                        arguments: [
                            wastFile.path,
                            "--enable-memory64",
                            "--enable-tail-call",
                            "-o", json.path,
                        ]
                    )
                    wast2jsonProcess.waitUntilExit()

                    do {
                        try checkWabtCompatibility(wast: wastFile, json: json, stats: &stats)
                    } catch {
                        stats.failed.insert(wastFile.lastPathComponent)
                        shouldRetain = true
                        XCTFail("Error while checking compatibility between \(wastFile) and \(json.path): \(error)")
                    }
                }
            }
            print("Spectest compatibility: \(stats.run - stats.failed.count) / \(stats.run)")
            if !stats.failed.isEmpty {
                print("Failed test cases: \(stats.failed.sorted())")
            }
        #endif
    }

    func smokeCheck(wastFile: URL) throws {
        print("Checking \(wastFile.path)")
        var parser = WastParser(
            try String(contentsOf: wastFile),
            features: Spectest.deriveFeatureSet(wast: wastFile)
        )
        while let directive = try parser.nextDirective() {
            switch directive {
            case .module(let directive):
                guard case var .text(wat) = directive.source else {
                    continue
                }
                _ = try wat.encode()
            case .assertMalformed(let module, let message):
                checkMalformed(wast: wastFile, module: module, message: message, recordFail: {})
            default:
                break
            }
        }
    }

    func testFunctionReferencesProposal() throws {
        // NOTE: Perform smoke check for function-references proposal here without
        // bit-to-bit compatibility check with wabt as wabt does not support
        // function-references proposal yet.
        for wastFile in Spectest.wastFiles(
            path: [
                Spectest.testsuitePath.appendingPathComponent("proposals/function-references")
            ], include: [], exclude: []
        ) {
            try smokeCheck(wastFile: wastFile)
        }
    }

    func testEncodeNameSection() throws {
        let bytes = try wat2wasm(
            """
            (module
                (func $foo)
                (func)
                (func $bar)
            )
            """,
            options: EncodeOptions(nameSection: true)
        )

        var parser = WasmParser.Parser(bytes: bytes)
        var customSections: [CustomSection] = []
        while let payload = try parser.parseNext() {
            guard case .customSection(let section) = payload else {
                continue
            }
            customSections.append(section)
        }
        let nameSection = customSections.first(where: { $0.name == "name" })
        let nameParser = NameSectionParser(
            stream: StaticByteStream(bytes: nameSection?.bytes ?? [])
        )
        let names = try nameParser.parseAll()
        XCTAssertEqual(names.count, 1)
        guard case .functions(let functionNames) = try XCTUnwrap(names.first) else {
            XCTFail()
            return
        }
        XCTAssertEqual(functionNames, [0: "foo", 2: "bar"])
    }
}

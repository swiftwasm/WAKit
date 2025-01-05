import Foundation
import WasmParser

enum Spectest {
    static let rootDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // WATTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // Root
    static let vendorDirectory: URL =
        rootDirectory
        .appendingPathComponent("Vendor")

    static var testsuitePath: URL { Self.vendorDirectory.appendingPathComponent("testsuite") }

    static func path(_ file: String) -> URL {
        testsuitePath.appendingPathComponent(file)
    }

    static let defaultSuites = [
        testsuitePath,
        testsuitePath.appendingPathComponent("proposals/memory64"),
        testsuitePath.appendingPathComponent("proposals/tail-call"),
        rootDirectory.appendingPathComponent("Tests/WasmKitTests/ExtraSuite"),
    ]

    static func wastFiles(
        path: [URL] = defaultSuites,
        include: [String] = [],
        exclude: [String] = ["annotations.wast"]
    ) -> AnyIterator<URL> {
        var allFiles = path.flatMap {
            try! FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }.makeIterator()

        return AnyIterator {
            while let filePath = allFiles.next() {
                guard filePath.pathExtension == "wast" else {
                    continue
                }
                guard !filePath.lastPathComponent.starts(with: "simd_") else { continue }
                if !include.isEmpty {
                    guard include.contains(filePath.lastPathComponent) else { continue }
                } else {
                    guard !exclude.contains(filePath.lastPathComponent) else { continue }
                }
                return filePath
            }
            return nil
        }
    }

    static func deriveFeatureSet(wast: URL) -> WasmFeatureSet {
        var features = WasmFeatureSet.default
        if wast.deletingLastPathComponent().path.hasSuffix("proposals/memory64") {
            features.insert(.memory64)
        }
        return features
    }

    struct Command: Decodable {
        enum CommandType: String, Decodable {
            case module
            case action
            case register
            case assertReturn = "assert_return"
            case assertInvalid = "assert_invalid"
            case assertTrap = "assert_trap"
            case assertMalformed = "assert_malformed"
            case assertExhaustion = "assert_exhaustion"
            case assertUnlinkable = "assert_unlinkable"
            case assertUninstantiable = "assert_uninstantiable"
            case assertReturnCanonicalNan = "assert_return_canonical_nan"
            case assertReturnArithmeticNan = "assert_return_arithmetic_nan"
        }

        enum ModuleType: String, Decodable {
            case binary
            case text
        }

        enum ValueType: String, Decodable {
            case i32
            case i64
            case f32
            case f64
            case externref
            case funcref
        }

        struct Value: Decodable {
            let type: ValueType
            let value: String
        }

        struct Expectation: Decodable {
            let type: ValueType
            let value: String?
        }

        struct Action: Decodable {
            enum ActionType: String, Decodable {
                case invoke
                case get
            }

            let type: ActionType
            let module: String?
            let field: String
            let args: [Value]?
        }

        let type: CommandType
        let line: Int
        let `as`: String?
        let name: String?
        let filename: String?
        let text: String?
        let moduleType: ModuleType?
        let action: Action?
        let expected: [Expectation]?
    }

    struct Content: Decodable {
        let sourceFilename: String
        let commands: [Command]
    }

    static func moduleFiles(json: URL) throws -> [(binary: URL, name: String?)] {
        var modules: [(binary: URL, name: String?)] = []
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let content = try decoder.decode(Content.self, from: Data(contentsOf: json))
        for command in content.commands {
            guard command.type == .module else { continue }
            let binary = json.deletingLastPathComponent().appendingPathComponent(command.filename!)
            modules.append((binary, command.name))
        }
        return modules
    }
}

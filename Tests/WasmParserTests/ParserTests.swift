import XCTest
import WasmParser
import WAT

final class ParserTests: XCTestCase {
    func parseAll(bytes: [UInt8]) throws {
        var parser = Parser(bytes: bytes)
        struct NopVisitor: InstructionVisitor {}
        while let payload = try parser.parseNext() {
            switch payload {
            case .codeSection(let section):
                for code in section {
                    var visitor = NopVisitor()
                    try code.parseExpression(visitor: &visitor)
                }
            default: break
            }
        }
    }
    func smokeCheck(wastFile: URL) throws {
        print("Checking \(wastFile.path)")
        var parser = try parseWAST(String(contentsOf: wastFile))
        while let (directive, location) = try parser.nextDirective() {
            switch directive {
            case .module(let directive):
                guard case var .text(wat) = directive.source else {
                    continue
                }
                let diagnostic = {
                    let (line, column) = location.computeLineAndColumn()
                    return "\(wastFile.path):\(line):\(column) should be parsed"
                }
                let bytes = try wat.encode()
                XCTAssertNoThrow(try parseAll(bytes: bytes), diagnostic())
            case .assertMalformed(let module, let message):
                guard case let .binary(bytes) = module.source else {
                    continue
                }
                let diagnostic = {
                    let (line, column) = module.location.computeLineAndColumn()
                    return "\(wastFile.path):\(line):\(column) should be malformed: \(message)"
                }
                XCTAssertThrowsError(try parseAll(bytes: bytes), diagnostic())
            default:
                break
            }
        }
    }

    static let rootDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // WATTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // Root
    static let vendorDirectory: URL =
        rootDirectory
        .appendingPathComponent("Vendor")

    static var testsuitePath: URL { Self.vendorDirectory.appendingPathComponent("testsuite") }

    static func wastFiles(path: [String]) -> [URL] {
        path.flatMap {
            try! FileManager.default.contentsOfDirectory(
                at: Self.testsuitePath.appendingPathComponent($0),
                includingPropertiesForKeys: nil
            )
        }
        .filter { $0.pathExtension == "wast" }
    }

    func testFunctionReferencesProposal() throws {
        for wastFile in Self.wastFiles(path: ["proposals/function-references"]) {
            guard wastFile.pathExtension == "wast" else { continue }
            try smokeCheck(wastFile: wastFile)
        }
    }
}

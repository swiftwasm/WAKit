import LEB
@testable import WAKit
import XCTest

final class WasmParserTests: XCTestCase {
    func testWasmParser() {
        let stream = StaticByteStream(bytes: [1, 2, 3])
        let parser = WasmParser(stream: stream)

        XCTAssertEqual(parser.currentIndex, stream.currentIndex)

        XCTAssertNoThrow(try stream.consumeAny())
        XCTAssertEqual(parser.currentIndex, stream.currentIndex)
    }
}

extension WasmParserTests {
    func testWasmParser_parseInteger() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [0x01])
        parser = WasmParser(stream: stream)
        XCTAssertEqual((try parser.parseInteger() as UInt32).signed, 1)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x7F])
        parser = WasmParser(stream: stream)
        XCTAssertEqual((try parser.parseInteger() as UInt32).signed, -1)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0xFF, 0x00])
        parser = WasmParser(stream: stream)
        XCTAssertEqual((try parser.parseInteger() as UInt32).signed, 127)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x81, 0x7F])
        parser = WasmParser(stream: stream)
        XCTAssertEqual((try parser.parseInteger() as UInt32).signed, -127)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x83])
        parser = WasmParser(stream: stream)
        XCTAssertThrowsError(_ = try parser.parseInteger() as UInt32) { error in
            guard case LEBError.insufficientBytes = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(stream.currentIndex, 1)
        }
    }
}

extension WasmParserTests {
    func testWasmParser_parseName() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [
            0x0F, 0x57, 0x65, 0x62, 0xF0, 0x9F, 0x8C, 0x8F, 0x41, 0x73, 0x73, 0x65, 0x6D, 0x62, 0x6C, 0x79,
        ])

        parser = WasmParser(stream: stream)
        XCTAssertEqual(try parser.parseName(), "Web🌏Assembly")
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x02, 0xDF, 0xFF])
        parser = WasmParser(stream: stream)
        XCTAssertThrowsError(_ = try parser.parseName()) { error in
            guard case let WasmParserError.invalidUTF8(unicode) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(unicode, [0xDF, 0xFF])
            XCTAssertEqual(stream.currentIndex, 3)
        }
    }
}

extension WasmParserTests {
    func testWasmParser_parseValueType() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [0x7F])
        parser = WasmParser(stream: stream)
        XCTAssert(try parser.parseValueType() == .int(.i32))
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x7E])
        parser = WasmParser(stream: stream)
        XCTAssert(try parser.parseValueType() == .int(.i64))
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x7D])
        parser = WasmParser(stream: stream)
        XCTAssert(try parser.parseValueType() == .float(.f32))
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x7C])
        parser = WasmParser(stream: stream)
        XCTAssert(try parser.parseValueType() == .float(.f64))
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x7B])
        parser = WasmParser(stream: stream)
        XCTAssertThrowsError(try parser.parseValueType()) { error in
            guard case let WAKit.StreamError<UInt8>.unexpected(0x7B, 0, expected: expected) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, Set(0x7C ... 0x7F))
            XCTAssertEqual(stream.currentIndex, 0)
        }
    }

    func testWasmParser_parseResultType() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [0x40])
        parser = WasmParser(stream: stream)
        XCTAssert(try parser.parseResultType() == [])
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x7E])
        parser = WasmParser(stream: stream)
        XCTAssert(try parser.parseResultType() == [.int(.i64)])
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x7B])
        parser = WasmParser(stream: stream)
        XCTAssertThrowsError(try parser.parseValueType()) { error in
            guard case let WAKit.StreamError<UInt8>.unexpected(0x7B, 0, expected: expected) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, Set(0x7C ... 0x7F))
            XCTAssertEqual(stream.currentIndex, 0)
        }
    }

    func testWasmParser_parseFunctionType() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [0x60, 0x00, 0x00])
        parser = WasmParser(stream: stream)
        XCTAssert(try parser.parseFunctionType() == .some(parameters: [], results: []))
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x60, 0x01, 0x7E, 0x01, 0x7D])
        parser = WasmParser(stream: stream)
        XCTAssert(try parser.parseFunctionType() == .some(parameters: [.int(.i64)], results: [.float(.f32)]))
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)
    }

    func testWasmParser_parseLimits() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [0x00, 0x01])
        parser = WasmParser(stream: stream)
        XCTAssertEqual(try parser.parseLimits(), Limits(min: 1, max: nil))
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x01, 0x02, 0x03])
        parser = WasmParser(stream: stream)
        XCTAssertEqual(try parser.parseLimits(), Limits(min: 2, max: 3))
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x02])
        parser = WasmParser(stream: stream)
        XCTAssertThrowsError(try parser.parseLimits()) { error in
            guard case let WAKit.StreamError<UInt8>.unexpected(0x02, 0, expected: expected) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, Set(0x00 ... 0x01))
            XCTAssertEqual(stream.currentIndex, 0)
        }
    }

    func testWasmParser_parseMemoryType() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [0x00, 0x01])
        parser = WasmParser(stream: stream)
        XCTAssertEqual(try parser.parseMemoryType(), Limits(min: 1, max: nil))
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x01, 0x02, 0x03])
        parser = WasmParser(stream: stream)
        XCTAssertEqual(try parser.parseMemoryType(), Limits(min: 2, max: 3))
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x02])
        parser = WasmParser(stream: stream)
        XCTAssertThrowsError(try parser.parseMemoryType()) { error in
            guard case let WAKit.StreamError<UInt8>.unexpected(0x02, 0, expected: expected) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, Set(0x00 ... 0x01))
            XCTAssertEqual(stream.currentIndex, 0)
        }
    }

    func testWasmParser_parseTableType() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [0x70, 0x00, 0x01])
        parser = WasmParser(stream: stream)
        XCTAssertEqual(try parser.parseTableType(), TableType(elementType: .any, limits: Limits(min: 1, max: nil)))
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x70, 0x01, 0x02, 0x03])
        parser = WasmParser(stream: stream)
        XCTAssertEqual(try parser.parseTableType(), TableType(elementType: .any, limits: Limits(min: 2, max: 3)))
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x70, 0x02])
        parser = WasmParser(stream: stream)
        XCTAssertThrowsError(try parser.parseTableType()) { error in
            guard case let WAKit.StreamError<UInt8>.unexpected(0x02, 1, expected: expected) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, Set(0x00 ... 0x01))
            XCTAssertEqual(stream.currentIndex, 1)
        }
    }

    func testWasmParser_parseGlobalType() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [0x7F, 0x00])
        parser = WasmParser(stream: stream)
        XCTAssertEqual(try parser.parseGlobalType(), GlobalType(mutability: .constant, valueType: .int(.i32)))
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x7F, 0x01])
        parser = WasmParser(stream: stream)
        XCTAssertEqual(try parser.parseGlobalType(), GlobalType(mutability: .variable, valueType: .int(.i32)))
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [0x7B])
        parser = WasmParser(stream: stream)
        XCTAssertThrowsError(try parser.parseGlobalType()) { error in
            guard case let WAKit.StreamError<UInt8>.unexpected(0x7B, 0, expected: expected) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, Set(0x7C ... 0x7F))
            XCTAssertEqual(stream.currentIndex, 0)
        }

        stream = StaticByteStream(bytes: [0x7F, 0x02])
        parser = WasmParser(stream: stream)
        XCTAssertThrowsError(try parser.parseGlobalType()) { error in
            guard case let WAKit.StreamError<UInt8>.unexpected(0x02, 1, expected: expected) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, Set(0x00 ... 0x01))
            XCTAssertEqual(stream.currentIndex, 1)
        }
    }
}

extension WasmParserTests {
    func testWasmParser_parseExpression() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [0x41, 0x01, 0x04, 0x7F, 0x02, 0x7F, 0x41, 0x01, 0x0B, 0x05, 0x41, 0x02, 0x0B, 0x0B])
        parser = WasmParser(stream: stream)
        do {
            let (expression, lastInstruction) = try parser.parseExpression()
            // TODO: Compare with instruction arguments
            XCTAssertEqual(expression.instructions.map { $0.code }, [.i32_const, .if, .block, .i32_const, .i32_const])
            XCTAssertEqual(lastInstruction.code, .end)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)
    }
}

extension WasmParserTests {
    func testWasmParser_parseCustomSection() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [
            0, // section ID
            0x17, // size
            0x0F, 0x57, 0x65, 0x62, 0xF0, 0x9F, 0x8C, 0x8F, 0x41, 0x73, 0x73, 0x65, 0x6D, 0x62, 0x6C, 0x79, // name
            0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF0, 0xEF, // dummy content
        ])
        parser = WasmParser(stream: stream)
        let expected = Section.custom(name: "Web🌏Assembly", bytes: [0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF0, 0xEF])
        XCTAssertEqual(try parser.parseCustomSection(), expected)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [
            0, // section ID
            0x01, // size
            0x0F, 0x57, 0x65, 0x62, 0xF0, 0x9F, 0x8C, 0x8F, 0x41, 0x73, 0x73, 0x65, 0x6D, 0x62, 0x6C, 0x79, // name
            0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF0, 0xEF, // dummy content
        ])
        parser = WasmParser(stream: stream)
        XCTAssertThrowsError(_ = try parser.parseCustomSection()) { error in
            guard case WasmParserError.invalidSectionSize(1) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(stream.currentIndex, 18)
        }

        stream = StaticByteStream(bytes: [
            0, // section ID
            0x4F, // size
            0x0F, 0x57, 0x65, 0x62, 0xF0, 0x9F, 0x8C, 0x8F, 0x41, 0x73, 0x73, 0x65, 0x6D, 0x62, 0x6C, 0x79, // name
            0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF0, 0xEF, // dummy content
        ])
        parser = WasmParser(stream: stream)
        XCTAssertThrowsError(_ = try parser.parseCustomSection()) { error in
            guard case WAKit.StreamError<UInt8>.unexpectedEnd = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(stream.currentIndex, 26)
        }
    }

    func testWasmParser_parseTypeSection() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [
            0x01, // section ID
            0x0B, // size
            0x02, // vector length
            0x60, 0x01, 0x7F, 0x01, 0x7E, // function type
            0x60, 0x01, 0x7D, 0x01, 0x7C, // function type
        ])
        parser = WasmParser(stream: stream)
        let expected = Section.type([
            .some(parameters: [.int(.i32)], results: [.int(.i64)]),
            .some(parameters: [.float(.f32)], results: [.float(.f64)]),
        ])
        XCTAssertEqual(try parser.parseTypeSection(), expected)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)
    }

    func testWasmParser_parseImportSection() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [
            0x02, // section ID
            0x0D, // size
            0x02, // vector length
            0x01, 0x61, // module name
            0x01, 0x62, // import name
            0x00, 0x12, // import descriptor (function)
            0x01, 0x63, // module name
            0x01, 0x64, // import name
            0x00, 0x34, // import descriptor (function)
        ])
        parser = WasmParser(stream: stream)
        let expected = Section.import([
            Import(module: "a", name: "b", descripter: .function(18)),
            Import(module: "c", name: "d", descripter: .function(52)),
        ])
        XCTAssertEqual(try parser.parseImportSection(), expected)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)
    }

    func testWasmParser_parseFunctionSection() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [
            0x03, // section ID
            0x03, // size
            0x02, // vector length
            0x01, 0x02, // function indices
        ])
        parser = WasmParser(stream: stream)
        let expected = Section.function([0x01, 0x02])
        XCTAssertEqual(try parser.parseFunctionSection(), expected)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)
    }

    func testWasmParser_parseTableSection() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [
            0x04, // section ID
            0x08, // size
            0x02, // vector length
            0x70, // element type
            0x00, 0x12, // limits
            0x70, // element type
            0x01, 0x34, 0x56, // limits
        ])
        parser = WasmParser(stream: stream)
        let expected = Section.table([
            Table(type: TableType(elementType: .any, limits: Limits(min: 18, max: nil))),
            Table(type: TableType(elementType: .any, limits: Limits(min: 52, max: 86))),
        ])
        XCTAssertEqual(try parser.parseTableSection(), expected)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)
    }

    func testWasmParser_parseMemorySection() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [
            0x05, // section ID
            0x06, // size
            0x02, // vector length
            0x00, 0x12, // limits
            0x01, 0x34, 0x56, // limits
        ])
        parser = WasmParser(stream: stream)
        let expected = Section.memory([
            Memory(type: MemoryType(min: 18, max: nil)),
            Memory(type: MemoryType(min: 52, max: 86)),
        ])
        XCTAssertEqual(try parser.parseMemorySection(), expected)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)
    }

    func testWasmParser_parseGlobalSection() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [
            0x06, // section ID
            0x07, // size
            0x02, // vector length
            0x7F, // value type
            0x00, // mutability.constant
            0x0B, // expression end
            0x7E, // value type
            0x01, // mutability.variable
            0x0B, // expression end
        ])
        parser = WasmParser(stream: stream)
        let expected = Section.global([
            Global(
                type: GlobalType(mutability: .constant, valueType: .int(.i32)),
                initializer: Expression(instructions: [])
            ),
            Global(
                type: GlobalType(mutability: .variable, valueType: .int(.i64)),
                initializer: Expression(instructions: [])
            ),
        ])

        XCTAssertEqual(try parser.parseGlobalSection(), expected)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)
    }

    func testWasmParser_parseExportSection() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [
            0x07, // section ID
            0x05, // size
            0x01, // vector length
            0x01, 0x61, // name
            0x00, 0x12, // export descriptor
        ])
        parser = WasmParser(stream: stream)
        let expected = Section.export([
            Export(name: "a", descriptor: .function(18)),
        ])
        XCTAssertEqual(try parser.parseExportSection(), expected)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)
    }

    func testWasmParser_parseStartSection() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [
            0x08, // section ID
            0x01, // size
            0x12, // function index
        ])
        parser = WasmParser(stream: stream)
        let expected = Section.start(18)
        XCTAssertEqual(try parser.parseStartSection(), expected)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)
    }

    func testWasmParser_parseElementSection() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [
            0x09, // section ID
            0x09, // size
            0x02, // vector length
            0x12, // table index
            0x0B, // expression end
            0x01, // vector length
            0x34, // function index
            0x56, // table index
            0x0B, // expression end
            0x01, // vector length
            0x78, // function index
        ])
        parser = WasmParser(stream: stream)
        let expected = Section.element([
            Element(index: 18, offset: Expression(instructions: []), initializer: [52]),
            Element(index: 86, offset: Expression(instructions: []), initializer: [120]),
        ])
        XCTAssertEqual(try parser.parseElementSection(), expected)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)
    }

    func testWasmParser_parseCodeSection() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [
            0x0A, // section ID
            0x0D, // content size
            0x02, // vector length (code)
            0x04, // code size
            0x01, // vector length (locals)
            0x03, // n
            0x7F, // Int32
            0x0B, // expression end
            0x06, // code size
            0x02, // vector length (locals)
            0x01, // n
            0x7E, // Int64
            0x02, // n
            0x7D, // Float32
            0x0B, // expression end
        ])
        parser = WasmParser(stream: stream)
        let expected = Section.code([
            Code(
                locals: [.int(.i32), .int(.i32), .int(.i32)],
                expression: Expression(instructions: [])
            ),
            Code(
                locals: [.int(.i64), .float(.f32), .float(.f32)],
                expression: Expression(instructions: [])
            ),
        ])
        XCTAssertEqual(try parser.parseCodeSection(), expected)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)
    }

    func testWasmParser_parseDataSection() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [
            0x0B, // section ID
            0x0D, // content size
            0x02, // vector length
            0x12, // memory index
            0x0B, // expression end
            0x04, // vector length (bytes)
            0x01, 0x02, 0x03, 0x04, // bytes
            0x34, // memory index
            0x0B, // expression end
            0x02, // vector length (bytes)
            0x05, 0x06, // bytes
        ])
        parser = WasmParser(stream: stream)
        let expected = Section.data([
            Data(
                index: 18,
                offset: Expression(instructions: []),
                initializer: [0x01, 0x02, 0x03, 0x04]
            ),
            Data(
                index: 52,
                offset: Expression(instructions: []),
                initializer: [0x05, 0x06]
            ),
        ])
        XCTAssertEqual(try parser.parseDataSection(), expected)
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)
    }
}

extension WasmParserTests {
    func testWasmParser_parseMagicNumbers() {
        let stream = StaticByteStream(bytes: [0x00, 0x61, 0x73, 0x6D])
        let parser = WasmParser(stream: stream)
        XCTAssertNoThrow(try parser.parseMagicNumber())
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)
    }

    func testWasmParser_parseVersion() {
        let stream = StaticByteStream(bytes: [0x01, 0x00, 0x00, 0x00])
        let parser = WasmParser(stream: stream)
        XCTAssertNoThrow(try parser.parseVersion())
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)
    }

    func testWasmParser_parseModule() {
        var stream: StaticByteStream!
        var parser: WasmParser<StaticByteStream>!

        stream = StaticByteStream(bytes: [
            0x00, 0x61, 0x73, 0x6D, // _asm
            0x01, 0x00, 0x00, 0x00, // version
        ])

        parser = WasmParser(stream: stream)
        XCTAssertEqual(try parser.parseModule(), Module())
        XCTAssertEqual(parser.currentIndex, stream.bytes.count)

        stream = StaticByteStream(bytes: [
            0x00, 0x61, 0x73, 0x6D, // _asm
            0x01, 0x00, 0x00, 0x00, // version
            0x00, // section ID
            0x18, // size
            0x0F, 0x57, 0x65, 0x62, 0xF0, 0x9F, 0x8C, 0x8F, 0x41, 0x73, 0x73, 0x65, 0x6D, 0x62, 0x6C, 0x79, // name
            0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF0, 0xEF, // bytes
        ])
    }
}

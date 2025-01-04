import WasmTypes

import struct SystemPackage.FileDescriptor
import struct SystemPackage.FilePath

#if os(Windows)
    import ucrt
#endif

/// A streaming parser for WebAssembly binary format.
///
/// The parser is designed to be used to incrementally parse a WebAssembly binary bytestream.
public struct Parser<Stream: ByteStream> {
    @usableFromInline
    let stream: Stream
    @usableFromInline let limits: ParsingLimits
    @usableFromInline var orderTracking = OrderTracking()

    @usableFromInline
    enum NextParseTarget {
        case header
        case section
    }
    @usableFromInline
    var nextParseTarget: NextParseTarget

    public let features: WasmFeatureSet
    public var offset: Int {
        return stream.currentIndex
    }

    public init(stream: Stream, features: WasmFeatureSet = .default) {
        self.stream = stream
        self.features = features
        self.nextParseTarget = .header
        self.limits = .default
    }

    @usableFromInline
    internal func makeError(_ message: WasmParserError.Message) -> WasmParserError {
        return WasmParserError(message, offset: offset)
    }
}

extension Parser where Stream == StaticByteStream {

    /// Initialize a new parser with the given bytes
    ///
    /// - Parameters:
    ///   - bytes: The bytes of the WebAssembly binary file to parse
    ///   - features: Enabled WebAssembly features for parsing
    public init(bytes: [UInt8], features: WasmFeatureSet = .default) {
        self.init(stream: StaticByteStream(bytes: bytes), features: features)
    }
}

extension Parser where Stream == FileHandleStream {

    /// Initialize a new parser with the given file handle
    ///
    /// - Parameters:
    ///   - fileHandle: The file handle to the WebAssembly binary file to parse
    ///   - features: Enabled WebAssembly features for parsing
    public init(fileHandle: FileDescriptor, features: WasmFeatureSet = .default) throws {
        self.init(stream: try FileHandleStream(fileHandle: fileHandle), features: features)
    }

    /// Initialize a new parser with the given file path
    ///
    /// - Parameters:
    ///   - filePath: The file path to the WebAssembly binary file to parse
    ///   - features: Enabled WebAssembly features for parsing
    public init(filePath: FilePath, features: WasmFeatureSet = .default) throws {
        #if os(Windows)
            // TODO: Upstream `O_BINARY` to `SystemPackage
            let accessMode = FileDescriptor.AccessMode(
                rawValue: FileDescriptor.AccessMode.readOnly.rawValue | O_BINARY
            )
        #else
            let accessMode: FileDescriptor.AccessMode = .readOnly
        #endif
        let fileHandle = try FileDescriptor.open(filePath, accessMode)
        self.init(stream: try FileHandleStream(fileHandle: fileHandle), features: features)
    }
}

extension Code {
    /// Parse a WebAssembly expression from the given byte stream
    ///
    /// - Parameters:
    ///   - visitor: The instruction visitor to visit the parsed instructions
    /// - Throws: `WasmParserError` if the parsing fails
    ///
    /// The input bytes sequence is usually extracted from a WebAssembly module's code section.
    ///
    /// ```swift
    /// import WasmParser
    ///
    /// struct MyVisitor: InstructionVisitor {
    ///     func visitLocalGet(localIndex: UInt32) {
    ///         print("local.get \(localIndex)")
    ///     }
    /// }
    ///
    /// var parser = WasmParser.Parser(bytes: [
    ///     0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60,
    ///     0x01, 0x7e, 0x01, 0x7e, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03,
    ///     0x66, 0x61, 0x63, 0x00, 0x00, 0x0a, 0x17, 0x01, 0x15, 0x00, 0x20, 0x00,
    ///     0x50, 0x04, 0x7e, 0x42, 0x01, 0x05, 0x20, 0x00, 0x20, 0x00, 0x42, 0x01,
    ///     0x7d, 0x10, 0x00, 0x7e, 0x0b, 0x0b
    /// ])
    /// while let payload = try parser.parseNext() {
    ///     switch payload {
    ///     case .codeSection(let section):
    ///         for code in section {
    ///             var visitor = MyVisitor()
    ///             try code.parseExpression(visitor: &visitor)
    ///         }
    ///     default: break
    ///     }
    /// }
    /// ````
    @inlinable
    public func parseExpression<V: InstructionVisitor>(visitor: inout V) throws {
        var parser = Parser(stream: StaticByteStream(bytes: self.expression), features: self.features)
        var lastIsEnd: Bool?
        while try !parser.stream.hasReachedEnd() {
            lastIsEnd = try parser.parseInstruction(visitor: &visitor)
        }
        guard lastIsEnd == true else {
            throw parser.makeError(.endOpcodeExpected)
        }
    }
}

@_documentation(visibility: internal)
public struct ExpressionParser {
    /// The byte offset of the code in the module
    let codeOffset: Int
    /// The initial byte offset of the code buffer stream
    /// NOTE: This might be different from `codeOffset` if the code buffer
    /// is not a part of the initial `FileHandleStream` buffer
    let initialStreamOffset: Int
    @usableFromInline
    var parser: Parser<StaticByteStream>
    @usableFromInline
    var isLastEnd: Bool?

    public var offset: Int {
        self.codeOffset + self.parser.offset - self.initialStreamOffset
    }

    public init(code: Code) {
        self.parser = Parser(
            stream: StaticByteStream(bytes: code.expression),
            features: code.features
        )
        self.codeOffset = code.offset
        self.initialStreamOffset = self.parser.offset
    }

    @inlinable
    public mutating func visit<V: InstructionVisitor>(visitor: inout V) throws -> Bool {
        isLastEnd = try parser.parseInstruction(visitor: &visitor)
        let shouldContinue = try !parser.stream.hasReachedEnd()
        if !shouldContinue {
            guard isLastEnd == true else {
                throw WasmParserError(.endOpcodeExpected, offset: offset)
            }
        }
        return shouldContinue
    }
}

let WASM_MAGIC: [UInt8] = [0x00, 0x61, 0x73, 0x6D]

/// Flags for enabling/disabling WebAssembly features
public struct WasmFeatureSet: OptionSet {
    /// The raw value of the feature set
    public let rawValue: Int

    /// Initialize a new feature set with the given raw value
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The WebAssembly memory64 proposal
    @_alwaysEmitIntoClient
    public static var memory64: WasmFeatureSet { WasmFeatureSet(rawValue: 1 << 0) }
    /// The WebAssembly reference types proposal
    @_alwaysEmitIntoClient
    public static var referenceTypes: WasmFeatureSet { WasmFeatureSet(rawValue: 1 << 1) }
    /// The WebAssembly threads proposal
    @_alwaysEmitIntoClient
    public static var threads: WasmFeatureSet { WasmFeatureSet(rawValue: 1 << 2) }
    /// The WebAssembly tail-call proposal
    @_alwaysEmitIntoClient
    public static var tailCall: WasmFeatureSet { WasmFeatureSet(rawValue: 1 << 3) }

    /// The default feature set
    public static let `default`: WasmFeatureSet = [.referenceTypes]
    /// The feature set with all features enabled
    public static let all: WasmFeatureSet = [.memory64, .referenceTypes, .threads, .tailCall]
}

/// An error that occurs during parsing of a WebAssembly binary
public struct WasmParserError: Swift.Error {
    @usableFromInline
    struct Message {
        let text: String

        init(_ text: String) {
            self.text = text
        }
    }

    let message: Message
    let offset: Int

    @usableFromInline
    init(_ message: Message, offset: Int) {
        self.message = message
        self.offset = offset
    }
}

extension WasmParserError: CustomStringConvertible {
    public var description: String {
        return "\"\(message)\" at offset 0x\(String(offset, radix: 16))"
    }
}

extension WasmParserError.Message {
    @usableFromInline
    static func invalidMagicNumber(_ bytes: [UInt8]) -> Self {
        Self("magic header not detected: expected \(WASM_MAGIC) but got \(bytes)")
    }

    @usableFromInline
    static func unknownVersion(_ bytes: [UInt8]) -> Self {
        Self("unknown binary version: \(bytes)")
    }

    static func invalidUTF8(_ bytes: [UInt8]) -> Self {
        Self("malformed UTF-8 encoding: \(bytes)")
    }

    @usableFromInline
    static func invalidSectionSize(_ size: UInt32) -> Self {
        // TODO: Remove size parameter
        Self("unexpected end-of-file")
    }

    @usableFromInline
    static func malformedSectionID(_ id: UInt8) -> Self {
        Self("malformed section id: \(id)")
    }

    @usableFromInline static func zeroExpected(actual: UInt8) -> Self {
        Self("Zero expected but got \(actual)")
    }

    @usableFromInline
    static func tooManyLocals(_ count: UInt64, limit: UInt64) -> Self {
        Self("Too many locals: \(count) vs \(limit)")
    }

    @usableFromInline static func expectedRefType(actual: ValueType) -> Self {
        Self("Expected reference type but got \(actual)")
    }

    @usableFromInline
    static func unexpectedElementKind(expected: UInt32, actual: UInt32) -> Self {
        Self("Unexpected element kind: expected \(expected) but got \(actual)")
    }

    @usableFromInline
    static let integerRepresentationTooLong = Self("Integer representation is too long")

    @usableFromInline
    static let endOpcodeExpected = Self("`end` opcode expected but not found")

    @usableFromInline
    static let unexpectedEnd = Self("Unexpected end of the stream")

    @usableFromInline
    static func sectionSizeMismatch(expected: Int, actual: Int) -> Self {
        Self("Section size mismatch: expected \(expected) but got \(actual)")
    }

    @usableFromInline static func illegalOpcode(_ opcode: [UInt8]) -> Self {
        Self("Illegal opcode: \(opcode)")
    }

    @usableFromInline
    static func malformedMutability(_ byte: UInt8) -> Self {
        Self("Malformed mutability: \(byte)")
    }

    @usableFromInline
    static func malformedFunctionType(_ byte: UInt8) -> Self {
        Self("Malformed function type: \(byte)")
    }

    @usableFromInline
    static let sectionOutOfOrder = Self("Sections in the module are out of order")

    @usableFromInline
    static func malformedLimit(_ byte: UInt8) -> Self {
        Self("Malformed limit: \(byte)")
    }

    @usableFromInline static let malformedIndirectCall = Self("Malformed indirect call")

    @usableFromInline static func malformedDataSegmentKind(_ kind: UInt32) -> Self {
        Self("Malformed data segment kind: \(kind)")
    }

    @usableFromInline static func invalidResultArity(expected: Int, actual: Int) -> Self {
        Self("invalid result arity: expected \(expected) but got \(actual)")
    }

    @usableFromInline static func invalidFunctionType(_ index: Int64) -> Self {
        Self("invalid function type index: \(index), expected a unsigned 32-bit integer")
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/binary/conventions.html#vectors>
extension ByteStream {
    @inlinable
    func parseVector<Content>(content parser: () throws -> Content) throws -> [Content] {
        var contents = [Content]()
        let count: UInt32 = try parseUnsigned()
        for _ in 0..<count {
            try contents.append(parser())
        }
        return contents
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/binary/values.html#integers>
extension ByteStream {
    @inlinable
    func parseUnsigned<T: RawUnsignedInteger>(_: T.Type = T.self) throws -> T {
        try decodeLEB128(stream: self)
    }

    @inlinable
    func parseSigned<T: FixedWidthInteger & RawSignedInteger>() throws -> T {
        try decodeLEB128(stream: self)
    }

    @usableFromInline
    func parseVarSigned33() throws -> Int64 {
        try decodeLEB128(stream: self, bitWidth: 33)
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/binary/values.html#names>
extension ByteStream {
    fileprivate func parseName() throws -> String {
        let bytes = try parseVector { () -> UInt8 in
            try consumeAny()
        }

        // TODO(optimize): Utilize ASCII fast path in UTF8 decoder
        var name = ""

        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        Decode: while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar): name.append(Character(scalar))
            case .emptyInput: break Decode
            case .error: throw WasmParserError(.invalidUTF8(bytes), offset: currentIndex)
            }
        }

        return name
    }
}

extension Parser {
    @inlinable
    func parseVector<Content>(content parser: () throws -> Content) throws -> [Content] {
        try stream.parseVector(content: parser)
    }

    @inline(__always)
    @inlinable
    func parseUnsigned<T: RawUnsignedInteger>(_: T.Type = T.self) throws -> T {
        try stream.parseUnsigned(T.self)
    }

    @inlinable
    func parseInteger<T: RawUnsignedInteger>() throws -> T {
        let signed: T.Signed = try stream.parseSigned()
        return T(bitPattern: signed)
    }

    func parseName() throws -> String {
        try stream.parseName()
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/binary/values.html#floating-point>
extension Parser {
    @usableFromInline
    func parseFloat() throws -> UInt32 {
        let consumedLittleEndian = try stream.consume(count: 4).reversed()
        let bitPattern = consumedLittleEndian.reduce(UInt32(0)) { acc, byte in
            acc << 8 + UInt32(byte)
        }
        return bitPattern
    }

    @usableFromInline
    func parseDouble() throws -> UInt64 {
        let consumedLittleEndian = try stream.consume(count: 8).reversed()
        let bitPattern = consumedLittleEndian.reduce(UInt64(0)) { acc, byte in
            acc << 8 + UInt64(byte)
        }
        return bitPattern
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/binary/types.html#types>
extension Parser {
    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/types.html#value-types>
    @usableFromInline
    func parseValueType() throws -> ValueType {
        let b = try stream.consumeAny()

        switch b {
        case 0x7F: return .i32
        case 0x7E: return .i64
        case 0x7D: return .f32
        case 0x7C: return .f64
        case 0x7B: return .f64
        case 0x70: return .ref(.funcRef)
        case 0x71: return .ref(.funcRef)
        case 0x6F: return .ref(.externRef)
        default:
            throw StreamError<Stream.Element>.unexpected(b, index: offset, expected: Set(0x7C...0x7F))
        }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/types.html#result-types>
    @inlinable
    func parseResultType() throws -> BlockType {
        guard let nextByte = try stream.peek() else {
            throw makeError(.unexpectedEnd)
        }
        switch nextByte {
        case 0x40:
            _ = try stream.consumeAny()
            return .empty
        case 0x7C...0x7F, 0x70, 0x6F:
            return try .type(parseValueType())
        default:
            let rawIndex = try stream.parseVarSigned33()
            guard let index = TypeIndex(exactly: rawIndex) else {
                throw makeError(.invalidFunctionType(rawIndex))
            }
            return .funcType(index)
        }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/types.html#function-types>
    @inlinable
    func parseFunctionType() throws -> FunctionType {
        let opcode = try stream.consumeAny()

        // XXX: spectest expects the first byte should be parsed as a LEB128 with 1 byte limit
        // but the spec itself doesn't require it, so just check the continue bit of LEB128 here.
        guard opcode & 0b10000000 == 0 else {
            throw makeError(.integerRepresentationTooLong)
        }
        guard opcode == 0x60 else {
            throw makeError(.malformedFunctionType(opcode))
        }

        let parameters = try parseVector { try parseValueType() }
        let results = try parseVector { try parseValueType() }
        return FunctionType(parameters: parameters, results: results)
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/types.html#limits>
    @usableFromInline
    func parseLimits() throws -> Limits {
        let b = try stream.consumeAny()
        let sharedMask: UInt8 = 0b0010
        let isMemory64Mask: UInt8 = 0b0100

        let hasMax = b & 0b0001 != 0
        let shared = b & sharedMask != 0
        let isMemory64 = b & isMemory64Mask != 0

        var flagMask: UInt8 = 0b0001
        if features.contains(.threads) {
            flagMask |= sharedMask
        }
        if features.contains(.memory64) {
            flagMask |= isMemory64Mask
        }
        guard (b & ~flagMask) == 0 else {
            throw makeError(.malformedLimit(b))
        }

        let min: UInt64
        if isMemory64 {
            min = try parseUnsigned(UInt64.self)
        } else {
            min = try UInt64(parseUnsigned(UInt32.self))
        }
        var max: UInt64?
        if hasMax {
            if isMemory64 {
                max = try parseUnsigned(UInt64.self)
            } else {
                max = try UInt64(parseUnsigned(UInt32.self))
            }
        }
        return Limits(min: min, max: max, isMemory64: isMemory64, shared: shared)
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/types.html#memory-types>
    func parseMemoryType() throws -> MemoryType {
        return try parseLimits()
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/types.html#table-types>
    @inlinable
    func parseTableType() throws -> TableType {
        let elementType: ReferenceType
        let b = try stream.consumeAny()

        switch b {
        case 0x70:
            elementType = .funcRef
        case 0x6F:
            elementType = .externRef
        default:
            throw StreamError.unexpected(b, index: offset, expected: [0x6F, 0x70])
        }

        let limits = try parseLimits()
        return TableType(elementType: elementType, limits: limits)
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/types.html#global-types>
    @inlinable
    func parseGlobalType() throws -> GlobalType {
        let valueType = try parseValueType()
        let mutability = try parseMutability()
        return GlobalType(mutability: mutability, valueType: valueType)
    }

    @inlinable
    func parseMutability() throws -> Mutability {
        let b = try stream.consumeAny()
        switch b {
        case 0x00:
            return .constant
        case 0x01:
            return .variable
        default:
            throw makeError(.malformedMutability(b))
        }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/instructions.html#memory-instructions>
    @inlinable
    func parseMemarg() throws -> MemArg {
        let align: UInt32 = try parseUnsigned()
        let offset: UInt64 = try features.contains(.memory64) ? parseUnsigned(UInt64.self) : UInt64(parseUnsigned(UInt32.self))
        return MemArg(offset: offset, align: align)
    }

    @inlinable func parseVectorBytes() throws -> ArraySlice<UInt8> {
        let count: UInt32 = try parseUnsigned()
        return try stream.consume(count: Int(count))
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/binary/instructions.html>
extension Parser: BinaryInstructionDecoder {
    @inlinable func parseMemoryIndex() throws -> UInt32 {
        let zero = try stream.consumeAny()
        guard zero == 0x00 else {
            throw makeError(.zeroExpected(actual: zero))
        }
        return 0
    }

    @inlinable func visitUnknown(_ opcode: [UInt8]) throws {
        throw makeError(.illegalOpcode(opcode))
    }

    @inlinable mutating func visitBlock() throws -> BlockType { try parseResultType() }
    @inlinable mutating func visitLoop() throws -> BlockType { try parseResultType() }
    @inlinable mutating func visitIf() throws -> BlockType { try parseResultType() }
    @inlinable mutating func visitBr() throws -> UInt32 { try parseUnsigned() }
    @inlinable mutating func visitBrIf() throws -> UInt32 { try parseUnsigned() }
    @inlinable mutating func visitBrTable() throws -> BrTable {
        let labelIndices: [UInt32] = try parseVector { try parseUnsigned() }
        let labelIndex: UInt32 = try parseUnsigned()
        return BrTable(labelIndices: labelIndices, defaultIndex: labelIndex)
    }
    @inlinable mutating func visitCall() throws -> UInt32 { try parseUnsigned() }
    @inlinable mutating func visitCallRef() throws -> UInt32 {
        // TODO reference types checks
        // traps on nil
        try parseUnsigned()
    }

    @inlinable mutating func visitCallIndirect() throws -> (typeIndex: UInt32, tableIndex: UInt32) {
        let typeIndex: TypeIndex = try parseUnsigned()
        if try !features.contains(.referenceTypes) && stream.peek() != 0 {
            // Check that reserved byte is zero when reference-types is disabled
            throw makeError(.malformedIndirectCall)
        }
        let tableIndex: TableIndex = try parseUnsigned()
        return (typeIndex, tableIndex)
    }

    @inlinable mutating func visitReturnCall() throws -> UInt32 {
        try parseUnsigned()
    }

    @inlinable mutating func visitReturnCallIndirect() throws -> (typeIndex: UInt32, tableIndex: UInt32) {
        let typeIndex: TypeIndex = try parseUnsigned()
        let tableIndex: TableIndex = try parseUnsigned()
        return (typeIndex, tableIndex)
    }

    @inlinable mutating func visitReturnCallRef() throws -> UInt32 {
        return 0
    }

    @inlinable mutating func visitTypedSelect() throws -> WasmTypes.ValueType {
        let results = try parseVector { try parseValueType() }
        guard results.count == 1 else {
            throw makeError(.invalidResultArity(expected: 1, actual: results.count))
        }
        return results[0]
    }

    @inlinable mutating func visitLocalGet() throws -> UInt32 { try parseUnsigned() }
    @inlinable mutating func visitLocalSet() throws -> UInt32 { try parseUnsigned() }
    @inlinable mutating func visitLocalTee() throws -> UInt32 { try parseUnsigned() }
    @inlinable mutating func visitGlobalGet() throws -> UInt32 { try parseUnsigned() }
    @inlinable mutating func visitGlobalSet() throws -> UInt32 { try parseUnsigned() }
    @inlinable mutating func visitLoad(_: Instruction.Load) throws -> MemArg { try parseMemarg() }
    @inlinable mutating func visitStore(_: Instruction.Store) throws -> MemArg { try parseMemarg() }
    @inlinable mutating func visitMemorySize() throws -> UInt32 {
        try parseMemoryIndex()
    }
    @inlinable mutating func visitMemoryGrow() throws -> UInt32 {
        try parseMemoryIndex()
    }
    @inlinable mutating func visitI32Const() throws -> Int32 {
        let n: UInt32 = try parseInteger()
        return Int32(bitPattern: n)
    }
    @inlinable mutating func visitI64Const() throws -> Int64 {
        let n: UInt64 = try parseInteger()
        return Int64(bitPattern: n)
    }
    @inlinable mutating func visitF32Const() throws -> IEEE754.Float32 {
        let n = try parseFloat()
        return IEEE754.Float32(bitPattern: n)
    }
    @inlinable mutating func visitF64Const() throws -> IEEE754.Float64 {
        let n = try parseDouble()
        return IEEE754.Float64(bitPattern: n)
    }
    @inlinable mutating func visitRefNull() throws -> WasmTypes.ReferenceType {
        let type = try parseValueType()
        guard case let .ref(refType) = type else {
            throw makeError(.expectedRefType(actual: type))
        }
        return refType
    }
    @inlinable mutating func visitBrOnNull() throws -> UInt32 {
        return 0
    }
    @inlinable mutating func visitBrOnNonNull() throws -> UInt32 {
        return 0
    }

    @inlinable mutating func visitRefFunc() throws -> UInt32 { try parseUnsigned() }
    @inlinable mutating func visitMemoryInit() throws -> UInt32 {
        let dataIndex: DataIndex = try parseUnsigned()
        _ = try parseMemoryIndex()
        return dataIndex
    }

    @inlinable mutating func visitDataDrop() throws -> UInt32 {
        try parseUnsigned()
    }

    @inlinable mutating func visitMemoryCopy() throws -> (dstMem: UInt32, srcMem: UInt32) {
        _ = try parseMemoryIndex()
        _ = try parseMemoryIndex()
        return (0, 0)
    }

    @inlinable mutating func visitMemoryFill() throws -> UInt32 {
        let zero = try stream.consumeAny()
        guard zero == 0x00 else {
            throw makeError(.zeroExpected(actual: zero))
        }
        return 0
    }

    @inlinable mutating func visitTableInit() throws -> (elemIndex: UInt32, table: UInt32) {
        let elementIndex: ElementIndex = try parseUnsigned()
        let tableIndex: TableIndex = try parseUnsigned()
        return (elementIndex, tableIndex)
    }
    @inlinable mutating func visitElemDrop() throws -> UInt32 {
        try parseUnsigned()
    }
    @inlinable mutating func visitTableCopy() throws -> (dstTable: UInt32, srcTable: UInt32) {
        let destination: TableIndex = try parseUnsigned()
        let source: TableIndex = try parseUnsigned()
        return (destination, source)
    }
    @inlinable mutating func visitTableFill() throws -> UInt32 {
        try parseUnsigned()
    }
    @inlinable mutating func visitTableGet() throws -> UInt32 {
        try parseUnsigned()
    }
    @inlinable mutating func visitTableSet() throws -> UInt32 {
        try parseUnsigned()
    }
    @inlinable mutating func visitTableGrow() throws -> UInt32 {
        try parseUnsigned()
    }
    @inlinable mutating func visitTableSize() throws -> UInt32 {
        try parseUnsigned()
    }
    @inlinable func claimNextByte() throws -> UInt8 {
        return try stream.consumeAny()
    }

    @inline(__always)
    @inlinable
    mutating func parseInstruction<V: InstructionVisitor>(visitor v: inout V) throws -> Bool {
        return try parseBinaryInstruction(visitor: &v, decoder: &self)
    }

    @usableFromInline
    struct InstructionFactory: AnyInstructionVisitor {
        @usableFromInline var insts: [Instruction] = []

        @inlinable init() {}

        @inlinable
        mutating func visit(_ instruction: Instruction) throws {
            insts.append(instruction)
        }
    }

    @usableFromInline
    mutating func parseConstExpression() throws -> ConstExpression {
        var factory = InstructionFactory()
        var isEnd: Bool
        repeat {
            isEnd = try self.parseInstruction(visitor: &factory)
        } while !isEnd
        return factory.insts
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/binary/modules.html#sections>
extension Parser {
    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#custom-section>
    @usableFromInline
    func parseCustomSection(size: UInt32) throws -> CustomSection {
        let preNameIndex = stream.currentIndex
        let name = try parseName()
        let nameSize = stream.currentIndex - preNameIndex
        let contentSize = Int(size) - nameSize

        guard contentSize >= 0 else {
            throw makeError(.invalidSectionSize(size))
        }

        let bytes = try stream.consume(count: contentSize)

        return CustomSection(name: name, bytes: bytes)
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#type-section>
    @inlinable
    func parseTypeSection() throws -> [FunctionType] {
        return try parseVector { try parseFunctionType() }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#import-section>
    @usableFromInline
    func parseImportSection() throws -> [Import] {
        return try parseVector {
            let module = try parseName()
            let name = try parseName()
            let descriptor = try parseImportDescriptor()
            return Import(module: module, name: name, descriptor: descriptor)
        }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#binary-importdesc>
    func parseImportDescriptor() throws -> ImportDescriptor {
        let b = try stream.consume(Set(0x00...0x03))
        switch b {
        case 0x00: return try .function(parseUnsigned())
        case 0x01: return try .table(parseTableType())
        case 0x02: return try .memory(parseMemoryType())
        case 0x03: return try .global(parseGlobalType())
        default:
            preconditionFailure("should never reach here")
        }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#function-section>
    @inlinable
    func parseFunctionSection() throws -> [TypeIndex] {
        return try parseVector { try parseUnsigned() }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#table-section>
    @usableFromInline
    func parseTableSection() throws -> [Table] {
        return try parseVector { try Table(type: parseTableType()) }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#memory-section>
    @usableFromInline
    func parseMemorySection() throws -> [Memory] {
        return try parseVector { try Memory(type: parseLimits()) }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#global-section>
    @usableFromInline
    mutating func parseGlobalSection() throws -> [Global] {
        return try parseVector {
            let type = try parseGlobalType()
            let expression = try parseConstExpression()
            return Global(type: type, initializer: expression)
        }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#export-section>
    @usableFromInline
    func parseExportSection() throws -> [Export] {
        return try parseVector {
            let name = try parseName()
            let descriptor = try parseExportDescriptor()
            return Export(name: name, descriptor: descriptor)
        }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#binary-exportdesc>
    func parseExportDescriptor() throws -> ExportDescriptor {
        let b = try stream.consume(Set(0x00...0x03))
        switch b {
        case 0x00: return try .function(parseUnsigned())
        case 0x01: return try .table(parseUnsigned())
        case 0x02: return try .memory(parseUnsigned())
        case 0x03: return try .global(parseUnsigned())
        default:
            preconditionFailure("should never reach here")
        }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#start-section>
    @usableFromInline
    func parseStartSection() throws -> FunctionIndex {
        return try parseUnsigned()
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#element-section>
    @inlinable
    mutating func parseElementSection() throws -> [ElementSegment] {
        return try parseVector {
            let flag = try ElementSegment.Flag(rawValue: parseUnsigned())

            let type: ReferenceType
            let initializer: [ConstExpression]
            let mode: ElementSegment.Mode

            if flag.contains(.isPassiveOrDeclarative) {
                if flag.contains(.isDeclarative) {
                    mode = .declarative
                } else {
                    mode = .passive
                }
            } else {
                let table: TableIndex

                if flag.contains(.hasTableIndex) {
                    table = try parseUnsigned()
                } else {
                    table = 0
                }

                let offset = try parseConstExpression()
                mode = .active(table: table, offset: offset)
            }

            if flag.segmentHasRefType {
                let valueType = try parseValueType()

                guard case let .ref(refType) = valueType else {
                    throw makeError(.expectedRefType(actual: valueType))
                }

                type = refType
            } else {
                type = .funcRef
            }

            if flag.segmentHasElemKind {
                // `elemkind` parsing as defined in the spec
                let elemKind = try parseUnsigned() as UInt32
                guard elemKind == 0x00 else {
                    throw makeError(.unexpectedElementKind(expected: 0x00, actual: elemKind))
                }
            }

            if flag.contains(.usesExpressions) {
                initializer = try parseVector { try parseConstExpression() }
            } else {
                initializer = try parseVector {
                    try [Instruction.refFunc(functionIndex: parseUnsigned() as UInt32)]
                }
            }

            return ElementSegment(type: type, initializer: initializer, mode: mode)
        }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#code-section>
    @inlinable
    func parseCodeSection() throws -> [Code] {
        return try parseVector {
            let size = try parseUnsigned() as UInt32
            let bodyStart = stream.currentIndex
            let localTypes = try parseVector { () -> (n: UInt32, type: ValueType) in
                let n: UInt32 = try parseUnsigned()
                let t = try parseValueType()
                return (n, t)
            }
            let totalLocals = localTypes.reduce(UInt64(0)) { $0 + UInt64($1.n) }
            guard totalLocals < limits.maxFunctionLocals else {
                throw makeError(.tooManyLocals(totalLocals, limit: limits.maxFunctionLocals))
            }

            let locals = localTypes.flatMap { (n: UInt32, type: ValueType) in
                return Array(repeating: type, count: Int(n))
            }
            let expressionStart = stream.currentIndex
            let expressionBytes = try stream.consume(
                count: Int(size) - (expressionStart - bodyStart)
            )
            return Code(
                locals: locals, expression: expressionBytes,
                offset: expressionStart, features: features
            )
        }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#data-section>
    @inlinable
    mutating func parseDataSection() throws -> [DataSegment] {
        return try parseVector {
            let kind: UInt32 = try parseUnsigned()
            switch kind {
            case 0:
                let offset = try parseConstExpression()
                let initializer = try parseVectorBytes()
                return .active(.init(index: 0, offset: offset, initializer: initializer))

            case 1:
                return try .passive(parseVectorBytes())

            case 2:
                let index: UInt32 = try parseUnsigned()
                let offset = try parseConstExpression()
                let initializer = try parseVectorBytes()
                return .active(.init(index: index, offset: offset, initializer: initializer))
            default:
                throw makeError(.malformedDataSegmentKind(kind))
            }
        }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#data-count-section>
    @usableFromInline
    func parseDataCountSection() throws -> UInt32 {
        return try parseUnsigned()
    }
}

public enum ParsingPayload {
    case header(version: [UInt8])
    case customSection(CustomSection)
    case typeSection([FunctionType])
    case importSection([Import])
    case functionSection([TypeIndex])
    case tableSection([Table])
    case memorySection([Memory])
    case globalSection([Global])
    case exportSection([Export])
    case startSection(FunctionIndex)
    case elementSection([ElementSegment])
    case codeSection([Code])
    case dataSection([DataSegment])
    case dataCount(UInt32)
}

/// > Note:
/// <https://webassembly.github.io/spec/core/binary/modules.html#binary-module>
extension Parser {
    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#binary-magic>
    @usableFromInline
    func parseMagicNumber() throws {
        let magicNumber = try stream.consume(count: 4)
        guard magicNumber.elementsEqual(WASM_MAGIC) else {
            throw makeError(.invalidMagicNumber(.init(magicNumber)))
        }
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#binary-version>
    @usableFromInline
    func parseVersion() throws -> [UInt8] {
        let version = try Array(stream.consume(count: 4))
        guard version == [0x01, 0x00, 0x00, 0x00] else {
            throw makeError(.unknownVersion(.init(version)))
        }
        return version
    }

    @usableFromInline
    struct OrderTracking {
        @usableFromInline
        enum Order: UInt8 {
            case initial = 0
            case type
            case _import
            case function
            case table
            case memory
            case tag
            case global
            case export
            case start
            case element
            case dataCount
            case code
            case data
        }

        @usableFromInline
        var last: Order = .initial

        @inlinable
        mutating func track(order: Order, parser: Parser) throws {
            guard last.rawValue < order.rawValue else {
                throw parser.makeError(.sectionOutOfOrder)
            }
            last = order
        }
    }

    /// Attempts to parse a chunk of the Wasm binary stream.
    ///
    /// - Returns: A `ParsingPayload` if the parsing was successful, otherwise `nil`.
    ///
    /// > Note:
    /// <https://webassembly.github.io/spec/core/binary/modules.html#binary-module>
    ///
    /// The following example demonstrates how to use the `Parser` to parse a Wasm binary stream:
    ///
    /// ```swift
    /// import WasmParser
    ///
    /// var parser = Parser(bytes: [
    ///     0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60,
    ///     0x01, 0x7e, 0x01, 0x7e, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03,
    ///     0x66, 0x61, 0x63, 0x00, 0x00, 0x0a, 0x17, 0x01, 0x15, 0x00, 0x20, 0x00,
    ///     0x50, 0x04, 0x7e, 0x42, 0x01, 0x05, 0x20, 0x00, 0x20, 0x00, 0x42, 0x01,
    ///     0x7d, 0x10, 0x00, 0x7e, 0x0b, 0x0b
    /// ])
    ///
    /// while let payload = try parser.parseNext() {
    ///     switch payload {
    ///     case .header(let version):
    ///         print("Wasm version: \(version)")
    ///     default: break
    ///     }
    /// }
    /// ```
    @inlinable
    public mutating func parseNext() throws -> ParsingPayload? {
        switch nextParseTarget {
        case .header:
            try parseMagicNumber()
            let version = try parseVersion()
            self.nextParseTarget = .section
            return .header(version: version)
        case .section:
            guard try !stream.hasReachedEnd() else {
                return nil
            }
            let sectionID = try stream.consumeAny()
            let sectionSize: UInt32 = try parseUnsigned()
            let sectionStart = stream.currentIndex

            let payload: ParsingPayload
            let order: OrderTracking.Order?
            switch sectionID {
            case 0:
                order = nil
                payload = .customSection(try parseCustomSection(size: sectionSize))
            case 1:
                order = .type
                payload = .typeSection(try parseTypeSection())
            case 2:
                order = ._import
                payload = .importSection(try parseImportSection())
            case 3:
                order = .function
                payload = .functionSection(try parseFunctionSection())
            case 4:
                order = .table
                payload = .tableSection(try parseTableSection())
            case 5:
                order = .memory
                payload = .memorySection(try parseMemorySection())
            case 6:
                order = .global
                payload = .globalSection(try parseGlobalSection())
            case 7:
                order = .export
                payload = .exportSection(try parseExportSection())
            case 8:
                order = .start
                payload = .startSection(try parseStartSection())
            case 9:
                order = .element
                payload = .elementSection(try parseElementSection())
            case 10:
                order = .code
                payload = .codeSection(try parseCodeSection())
            case 11:
                order = .data
                payload = .dataSection(try parseDataSection())
            case 12:
                order = .dataCount
                payload = .dataCount(try parseDataCountSection())
            default:
                throw makeError(.malformedSectionID(sectionID))
            }
            if let order = order {
                try orderTracking.track(order: order, parser: self)
            }
            let expectedSectionEnd = sectionStart + Int(sectionSize)
            guard expectedSectionEnd == stream.currentIndex else {
                throw makeError(.sectionSizeMismatch(expected: expectedSectionEnd, actual: offset))
            }
            return payload
        }
    }
}

/// A map of names by its index.
public typealias NameMap = [UInt32: String]

/// Parsed names.
public enum ParsedNames {
    /// Function names.
    case functions(NameMap)
}

/// A parser for the name custom section.
///
/// > Note: <https://webassembly.github.io/spec/core/appendix/custom.html#name-section>
public struct NameSectionParser<Stream: ByteStream> {
    let stream: Stream

    public init(stream: Stream) {
        self.stream = stream
    }

    /// Parses the entire name section.
    ///
    /// - Throws: If the stream is malformed or the section is invalid.
    /// - Returns: A list of parsed names.
    public func parseAll() throws -> [ParsedNames] {
        var results: [ParsedNames] = []
        while try !stream.hasReachedEnd() {
            let id = try stream.consumeAny()
            guard let result = try parseNameSubsection(type: id) else {
                continue
            }
            results.append(result)
        }
        return results
    }

    func parseNameSubsection(type: UInt8) throws -> ParsedNames? {
        let size = try stream.parseUnsigned(UInt32.self)
        switch type {
        case 1:  // function names
            return .functions(try parseNameMap())
        case 0, 2:  // local names
            fallthrough
        default:
            // Just skip other sections for now
            _ = try stream.consume(count: Int(size))
            return nil
        }
    }

    func parseNameMap() throws -> NameMap {
        var nameMap: NameMap = [:]
        _ = try stream.parseVector {
            let index = try stream.parseUnsigned(UInt32.self)
            let name = try stream.parseName()
            nameMap[index] = name
        }
        return nameMap
    }
}

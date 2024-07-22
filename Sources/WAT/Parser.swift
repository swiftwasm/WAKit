import WasmParser

internal struct Parser {
    var lexer: Lexer

    init(_ input: String) {
        self.lexer = Lexer(input: input)
    }

    init(_ lexer: Lexer) {
        self.lexer = lexer
    }

    func peek(_ kind: TokenKind? = nil) throws -> Token? {
        var lexer = lexer
        guard let token = try lexer.lex() else { return nil }
        if let kind {
            guard token.kind == kind else { return nil }
        }
        return token
    }

    func peekKeyword() throws -> String? {
        guard let token = try peek(.keyword) else {
            return nil
        }
        return token.text(from: lexer)
    }

    mutating func take(_ kind: TokenKind) throws -> Bool {
        guard try peek(kind) != nil else { return false }
        try consume()
        return true
    }

    mutating func takeKeyword(_ keyword: String) throws -> Bool {
        guard let token = try peek(.keyword), token.text(from: lexer) == keyword else {
            return false
        }
        try consume()
        return true
    }

    /// Consume a `(keyword` sequence, returning whether the tokens were consumed.
    mutating func takeParenBlockStart(_ keyword: String) throws -> Bool {
        let original = lexer
        guard try take(.leftParen), try takeKeyword(keyword) else {
            lexer = original
            return false
        }
        return true
    }

    mutating func takeUnsignedInt<IntegerType: UnsignedInteger & FixedWidthInteger>(_: IntegerType.Type = IntegerType.self) throws -> IntegerType? {
        guard let token = try peek() else { return nil }
        guard case let .integer(nil, pattern) = token.kind else {
            return nil
        }
        try consume()
        switch pattern {
        case .hexPattern(let pattern):
            guard let index = IntegerType(pattern, radix: 16) else {
                throw WatParserError("invalid index \(pattern)", location: token.location(in: lexer))
            }
            return index
        case .decimalPattern(let pattern):
            guard let index = IntegerType(pattern) else {
                throw WatParserError("invalid index \(pattern)", location: token.location(in: lexer))
            }
            return index
        }
    }

    mutating func takeSignedInt<IntegerType: FixedWidthInteger, UnsignedType: FixedWidthInteger & UnsignedInteger>(
        fromBitPattern: (UnsignedType) -> IntegerType
    ) throws -> IntegerType? {
        guard let token = try peek() else { return nil }
        guard case let .integer(sign, pattern) = token.kind else {
            return nil
        }
        try consume()
        let value: UnsignedType
        switch pattern {
        case .hexPattern(let pattern):
            guard let index = UnsignedType(pattern, radix: 16) else {
                throw WatParserError("invalid index \(pattern)", location: token.location(in: lexer))
            }
            value = index
        case .decimalPattern(let pattern):
            guard let index = UnsignedType(pattern) else {
                throw WatParserError("invalid index \(pattern)", location: token.location(in: lexer))
            }
            value = index
        }
        switch sign {
        case .plus, nil: return fromBitPattern(value)
        case .minus: return fromBitPattern(~value &+ 1)
        }
    }

    mutating func takeStringBytes() throws -> [UInt8]? {
        guard let token = try peek(), case .string(let bytes) = token.kind else { return nil }
        try consume()
        return bytes
    }

    mutating func takeString() throws -> String? {
        guard let bytes = try takeStringBytes() else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func takeIndexOrId() throws -> IndexOrId? {
        let location = lexer.location()
        if let index: UInt32 = try takeUnsignedInt() {
            return .index(index, location)
        } else if let id = try takeId() {
            return .id(id, location)
        }
        return nil
    }

    @discardableResult
    mutating func expect(_ kind: TokenKind) throws -> Token {
        guard let token = try lexer.lex() else {
            throw WatParserError("expected \(kind)", location: lexer.location())
        }
        guard token.kind == kind else {
            throw WatParserError("expected \(kind)", location: token.location(in: lexer))
        }
        return token
    }

    @discardableResult
    mutating func expectKeyword(_ keyword: String? = nil) throws -> String {
        let token = try expect(.keyword)
        let text = token.text(from: lexer)
        if let keyword {
            guard text == keyword else {
                throw WatParserError("expected \(keyword)", location: token.location(in: lexer))
            }
        }
        return text
    }

    mutating func expectStringBytes() throws -> [UInt8] {
        guard let token = try lexer.lex() else {
            throw WatParserError("expected string", location: lexer.location())
        }
        guard case .string(let text) = token.kind else {
            throw WatParserError("expected string but got \(token.kind)", location: token.location(in: lexer))
        }
        return text
    }
    mutating func expectString() throws -> String {
        String(decoding: try expectStringBytes(), as: UTF8.self)
    }

    mutating func expectStringList() throws -> [UInt8] {
        var data: [UInt8] = []
        while try !take(.rightParen) {
            data += try expectStringBytes()
        }
        return data
    }

    mutating func expectUnsignedInt<IntegerType: UnsignedInteger & FixedWidthInteger>(_: IntegerType.Type = IntegerType.self) throws -> IntegerType {
        guard let value: IntegerType = try takeUnsignedInt() else {
            throw WatParserError("expected decimal index without sign", location: lexer.location())
        }
        return value
    }

    mutating func expectSignedInt<IntegerType: FixedWidthInteger, UnsignedType: FixedWidthInteger & UnsignedInteger>(
        fromBitPattern: (UnsignedType) -> IntegerType
    ) throws -> IntegerType {
        guard let value: IntegerType = try takeSignedInt(fromBitPattern: fromBitPattern) else {
            throw WatParserError("expected decimal index with sign", location: lexer.location())
        }
        return value
    }

    mutating func expectFloatingPoint<F: BinaryFloatingPoint & LosslessStringConvertible, BitPattern: FixedWidthInteger>(
        _: F.Type, toBitPattern: (F) -> BitPattern,
        buildBitPattern: (
            _ sign: FloatingPointSign,
            _ exponentBitPattern: UInt,
            _ significandBitPattern: UInt
        ) -> BitPattern
    ) throws -> BitPattern {
        let token = try consume()

        var infinityExponent: UInt {
            return 1 &<< UInt(F.exponentBitCount) - 1
        }

        switch token.kind {
        case let .float(sign, pattern):
            let float: F
            switch pattern {
            case .decimalPattern(let pattern):
                guard let value = F(pattern) else {
                    throw WatParserError("invalid float \(pattern)", location: token.location(in: lexer))
                }
                float = value
            case .hexPattern(let pattern):
                guard let value = F("0x" + pattern) else {
                    throw WatParserError("invalid float \(pattern)", location: token.location(in: lexer))
                }
                float = value
            case .inf:
                float = .infinity
            case .nan(hexPattern: nil):
                float = .nan
            case .nan(let hexPattern?):
                guard let bitPattern = BitPattern(hexPattern, radix: 16) else {
                    throw WatParserError("invalid float \(hexPattern)", location: token.location(in: lexer))
                }
                return buildBitPattern(sign ?? .plus, infinityExponent, UInt(bitPattern))
            }
            return toBitPattern(sign == .minus ? -float : float)
        case let .integer(sign, pattern):
            let float: F
            switch pattern {
            case .hexPattern(let pattern):
                guard let value = F("0x" + pattern) else {
                    throw WatParserError("invalid float \(pattern)", location: token.location(in: lexer))
                }
                float = value
            case .decimalPattern(let pattern):
                guard let value = F(pattern) else {
                    throw WatParserError("invalid float \(pattern)", location: token.location(in: lexer))
                }
                float = value
            }
            return toBitPattern(sign == .minus ? -float : float)
        default:
            throw WatParserError("expected float but got \(token.kind)", location: token.location(in: lexer))
        }
    }

    mutating func expectFloat32() throws -> IEEE754.Float32 {
        let bitPattern = try expectFloatingPoint(
            Float32.self, toBitPattern: \.bitPattern,
            buildBitPattern: {
                UInt32(
                    ($0 == .minus ? 1 : 0) << (Float32.exponentBitCount + Float32.significandBitCount)
                        + ($1 << Float32.significandBitCount) + $2
                )
            }
        )
        return IEEE754.Float32(bitPattern: bitPattern)
    }

    mutating func expectFloat64() throws -> IEEE754.Float64 {
        let bitPattern = try expectFloatingPoint(
            Float64.self, toBitPattern: \.bitPattern,
            buildBitPattern: {
                UInt64(
                    ($0 == .minus ? 1 : 0) << (Float64.exponentBitCount + Float64.significandBitCount)
                        + ($1 << Float64.significandBitCount) + $2
                )
            }
        )
        return IEEE754.Float64(bitPattern: bitPattern)
    }

    mutating func expectIndex() throws -> UInt32 { try expectUnsignedInt(UInt32.self) }

    mutating func expectParenBlockStart(_ keyword: String) throws {
        guard try takeParenBlockStart(keyword) else {
            throw WatParserError("expected \(keyword)", location: lexer.location())
        }
    }

    enum IndexOrId {
        case index(UInt32, Location)
        case id(String, Location)
        var location: Location {
            switch self {
            case .index(_, let location), .id(_, let location):
                return location
            }
        }
    }

    mutating func expectIndexOrId() throws -> IndexOrId {
        guard let indexOrId = try takeIndexOrId() else {
            throw WatParserError("expected index or id", location: lexer.location())
        }
        return indexOrId
    }

    func isEndOfParen() throws -> Bool {
        guard let token = try peek() else { return true }
        return token.kind == .rightParen
    }

    @discardableResult
    mutating func consume() throws -> Token {
        guard let token = try lexer.lex() else {
            throw WatParserError("unexpected EOF", location: lexer.location())
        }
        return token
    }

    mutating func takeId() throws -> String? {
        guard let token = try peek(.id) else { return nil }
        try consume()
        return token.text(from: lexer)
    }

    mutating func skipParenBlock() throws {
        var depth = 1
        while depth > 0 {
            let token = try consume()
            switch token.kind {
            case .leftParen:
                depth += 1
            case .rightParen:
                depth -= 1
            default:
                break
            }
        }
    }
}

struct ExpressionParser<Visitor: InstructionVisitor> {
    typealias LocalsMap = NameMapping<WatParser.LocalDecl>
    private struct LabelStack {
        private var stack: [String?] = []

        /// - Returns: The depth of the label of the given name in the stack.
        /// e.g. `(block $A (block $B (br $A)))`, then `["A"]` at `br $A` will return 1.
        subscript(name: String) -> Int? {
            guard let found = stack.lastIndex(of: name) else { return nil }
            return stack.count - found - 1
        }

        func resolve(use: Parser.IndexOrId) -> Int? {
            switch use {
            case .index(let index, _):
                return Int(index)
            case .id(let name, _):
                return self[name]
            }
        }

        mutating func push(_ name: String?) {
            stack.append(name)
        }

        mutating func pop() {
            stack.removeLast()
        }

        mutating func peek() -> String?? {
            stack.last
        }
    }
    var parser: Parser
    let locals: LocalsMap
    private var labelStack = LabelStack()

    init(
        type: WatParser.FunctionType,
        locals: [WatParser.LocalDecl],
        lexer: Lexer
    ) throws {
        self.parser = Parser(lexer)
        self.locals = try Self.computeLocals(type: type, locals: locals)
    }

    init(lexer: Lexer) {
        self.parser = Parser(lexer)
        self.locals = LocalsMap()
    }

    static func computeLocals(type: WatParser.FunctionType, locals: [WatParser.LocalDecl]) throws -> LocalsMap {
        var localsMap = LocalsMap()
        for (name, type) in zip(type.parameterNames, type.signature.parameters) {
            localsMap.add(WatParser.LocalDecl(id: name, type: type))
        }
        for local in locals {
            localsMap.add(local)
        }
        return localsMap
    }

    mutating func withWatParser<R>(_ body: (inout WatParser) throws -> R) rethrows -> R {
        var watParser = WatParser(parser: parser)
        let result = try body(&watParser)
        parser = watParser.parser
        return result
    }

    /// Block instructions like `block`, `loop`, `if` optionally have repeated labels on `end` and `else`.
    private mutating func checkRepeatedLabelConsistency() throws {
        let location = parser.lexer.location()
        guard let name = try parser.takeId() else {
            return  // No repeated label
        }
        guard let maybeLastLabel = labelStack.peek() else {
            throw WatParserError("no corresponding block for label \(name)", location: location)
        }
        guard let lastLabel = maybeLastLabel else {
            throw WatParserError("unexpected label \(name)", location: location)
        }
        guard lastLabel == name else {
            throw WatParserError("expected label \(lastLabel) but found \(name)", location: location)
        }
    }

    @discardableResult
    mutating func parse(visitor: inout Visitor, watModule: inout WatModule) throws -> Int {
        var numberOfInstructions = 0
        while true {
            guard try instruction(visitor: &visitor, watModule: &watModule) else {
                numberOfInstructions += 1
                break
            }
            // Parse more instructions
        }
        return numberOfInstructions
    }

    mutating func parseElemExprList(visitor: inout Visitor, watModule: inout WatModule) throws {
        while true {
            let needRightParen = try parser.takeParenBlockStart("item")
            guard try instruction(visitor: &visitor, watModule: &watModule) else {
                break
            }
            if needRightParen {
                try parser.expect(.rightParen)
            }
        }
    }

    mutating func parseWastConstInstruction(
        visitor: inout Visitor
    ) throws -> Bool where Visitor: WastConstInstructionVisitor {
        var watModule = WatModule.empty()
        // WAST allows extra const value instruction
        if try parser.takeParenBlockStart("ref.extern") {
            _ = try visitor.visitRefExtern(value: parser.expectUnsignedInt())
            try parser.expect(.rightParen)
            return true
        }
        // WAST const expr only accepts folded instructions
        if try foldedInstruction(visitor: &visitor, watModule: &watModule) {
            return true
        }
        return false
    }

    mutating func parseWastExpectValue() throws -> WastExpectValue? {
        let initialParser = parser
        func takeNaNPattern(canonical: WastExpectValue, arithmetic: WastExpectValue) throws -> WastExpectValue? {
            if try parser.takeKeyword("nan:canonical") {
                try parser.expect(.rightParen)
                return canonical
            }
            if try parser.takeKeyword("nan:arithmetic") {
                try parser.expect(.rightParen)
                return arithmetic
            }
            return nil
        }
        if try parser.takeParenBlockStart("f64.const"),
            let value = try takeNaNPattern(canonical: .f64CanonicalNaN, arithmetic: .f64ArithmeticNaN)
        {
            return value
        }
        if try parser.takeParenBlockStart("f32.const"),
            let value = try takeNaNPattern(canonical: .f32CanonicalNaN, arithmetic: .f32ArithmeticNaN)
        {
            return value
        }
        parser = initialParser
        return nil
    }

    /// Parse "(instr)" or "instr" and visit the instruction.
    /// - Returns: `true` if an instruction was parsed. Otherwise, `false`.
    private mutating func instruction(visitor: inout Visitor, watModule: inout WatModule) throws -> Bool {
        if try nonFoldedInstruction(visitor: &visitor, watModule: &watModule) {
            return true
        }
        if try foldedInstruction(visitor: &visitor, watModule: &watModule) {
            return true
        }
        return false
    }

    /// Parse an instruction without surrounding parentheses.
    private mutating func nonFoldedInstruction(visitor: inout Visitor, watModule: inout WatModule) throws -> Bool {
        if try plainInstruction(visitor: &visitor, watModule: &watModule) {
            return true
        }
        return false
    }

    private struct Suspense {
        let visit: ((inout Visitor, inout ExpressionParser) throws -> Visitor.Output)?
    }

    private mutating func foldedInstruction(visitor: inout Visitor, watModule: inout WatModule) throws -> Bool {
        guard try parser.peek(.leftParen) != nil else {
            return false
        }

        var foldedStack: [Suspense] = []
        repeat {
            if try parser.take(.rightParen) {
                let suspense = foldedStack.popLast()
                _ = try suspense?.visit?(&visitor, &self)
                continue
            }
            try parser.expect(.leftParen)
            let keyword = try parser.expectKeyword()
            guard let visit = try parseTextInstruction(keyword: keyword, watModule: &watModule) else {
                return false
            }
            let suspense: Suspense
            switch keyword {
            case "if":
                // Special handling for "if" because of its special order
                // Usually given (A (B) (C (D)) (E)), we visit B, D, C, E, A
                // But for "if" (if (B) (then (C (D))) (else (E))), we want to visit B, "if", D, C, E

                // Condition may be absent
                if try !parser.takeParenBlockStart("then") {
                    // Visit condition expr
                    _ = try foldedInstruction(visitor: &visitor, watModule: &watModule)
                    try parser.expectParenBlockStart("then")
                }
                // Visit "if"
                _ = try visit(&visitor)
                // Visit "then" block
                try parse(visitor: &visitor, watModule: &watModule)
                try parser.expect(.rightParen)
                // Visit "else" block if present
                if try parser.takeParenBlockStart("else") {
                    // Visit only when "else" block has child expr
                    if try parser.peek(.rightParen) == nil {
                        _ = try visitor.visitElse()
                        try parse(visitor: &visitor, watModule: &watModule)
                    }
                    try parser.expect(.rightParen)
                }
                suspense = Suspense(visit: { visitor, this in
                    this.labelStack.pop()
                    return try visitor.visitEnd()
                })
            case "block", "loop":
                // Visit the block instruction itself
                _ = try visit(&visitor)
                // Visit child expr here because folded "block" and "loop"
                // allows unfolded child instructions unlike others.
                try parse(visitor: &visitor, watModule: &watModule)
                suspense = Suspense(visit: { visitor, this in
                    this.labelStack.pop()
                    return try visitor.visitEnd()
                })
            default:
                suspense = Suspense(visit: { visitor, _ in try visit(&visitor) })
            }
            foldedStack.append(suspense)
        } while !foldedStack.isEmpty
        return true
    }

    /// Parse a single instruction without consuming the surrounding parentheses and instruction keyword.
    private mutating func parseTextInstruction(keyword: String, watModule: inout WatModule) throws -> ((inout Visitor) throws -> Visitor.Output)? {
        switch keyword {
        case "select":
            // Special handling for "select", which have two variants 1. with type, 2. without type
            let results = try withWatParser({ try $0.results() })
            return { visitor in
                if let type = results.first {
                    return try visitor.visitTypedSelect(type: type)
                } else {
                    return try visitor.visitSelect()
                }
            }
        case "else":
            // This path should not be reached when parsing folded "if" instruction.
            // It should be separately handled in foldedInstruction().
            try checkRepeatedLabelConsistency()
            return { visitor in
                return try visitor.visitElse()
            }
        case "end":
            // This path should not be reached when parsing folded block instructions.
            try checkRepeatedLabelConsistency()
            labelStack.pop()
            return { visitor in
                return try visitor.visitEnd()
            }
        default:
            // Other instructions are parsed by auto-generated code.
            return try WAT.parseTextInstruction(keyword: keyword, expressionParser: &self, watModule: &watModule)
        }
    }

    /// - Returns: `true` if a plain instruction was parsed.
    private mutating func plainInstruction(visitor: inout Visitor, watModule: inout WatModule) throws -> Bool {
        guard let keyword = try parser.peekKeyword() else {
            return false
        }
        let originalParser = parser
        try parser.consume()
        guard let visit = try parseTextInstruction(keyword: keyword, watModule: &watModule) else {
            parser = originalParser
            return false
        }
        _ = try visit(&visitor)
        return true
    }

    private mutating func localIndex() throws -> UInt32 {
        let index = try parser.expectIndexOrId()
        return UInt32(try locals.resolve(use: index).index)
    }

    private mutating func functionIndex(watModule: inout WatModule) throws -> UInt32 {
        let funcUse = try parser.expectIndexOrId()
        return UInt32(try watModule.functionsMap.resolve(use: funcUse).index)
    }

    private mutating func memoryIndex(watModule: inout WatModule) throws -> UInt32 {
        guard let use = try parser.takeIndexOrId() else { return 0 }
        return UInt32(try watModule.memories.resolve(use: use).index)
    }

    private mutating func globalIndex(watModule: inout WatModule) throws -> UInt32 {
        guard let use = try parser.takeIndexOrId() else { return 0 }
        return UInt32(try watModule.globals.resolve(use: use).index)
    }

    private mutating func dataIndex(watModule: inout WatModule) throws -> UInt32 {
        guard let use = try parser.takeIndexOrId() else { return 0 }
        return UInt32(try watModule.data.resolve(use: use).index)
    }

    private mutating func tableIndex(watModule: inout WatModule) throws -> UInt32 {
        guard let use = try parser.takeIndexOrId() else { return 0 }
        return UInt32(try watModule.tablesMap.resolve(use: use).index)
    }

    private mutating func elementIndex(watModule: inout WatModule) throws -> UInt32 {
        guard let use = try parser.takeIndexOrId() else { return 0 }
        return UInt32(try watModule.elementsMap.resolve(use: use).index)
    }

    private mutating func blockType(watModule: inout WatModule) throws -> BlockType {
        let results = try withWatParser({ try $0.results() })
        if !results.isEmpty {
            return try watModule.types.resolveBlockType(results: results)
        }
        let typeUse = try withWatParser { try $0.typeUse() }
        return try watModule.types.resolveBlockType(use: typeUse)
    }

    private mutating func labelIndex() throws -> UInt32 {
        guard let index = try takeLabelIndex() else {
            throw WatParserError("expected label index", location: parser.lexer.location())
        }
        return index
    }

    private mutating func takeLabelIndex() throws -> UInt32? {
        guard let labelUse = try parser.takeIndexOrId() else { return nil }
        guard let index = labelStack.resolve(use: labelUse) else {
            throw WatParserError("unknown label \(labelUse)", location: labelUse.location)
        }
        return UInt32(index)
    }

    private mutating func refKind() throws -> ReferenceType {
        if try parser.takeKeyword("func") {
            return .funcRef
        } else if try parser.takeKeyword("extern") {
            return .externRef
        }
        throw WatParserError("expected \"func\" or \"extern\"", location: parser.lexer.location())
    }

    private mutating func memArg(defaultAlign: UInt32) throws -> MemArg {
        var offset: UInt64 = 0
        let offsetPrefix = "offset="
        if let maybeOffset = try parser.peekKeyword(), maybeOffset.starts(with: offsetPrefix) {
            try parser.consume()
            var subParser = Parser(String(maybeOffset.dropFirst(offsetPrefix.count)))
            offset = try subParser.expectUnsignedInt(UInt64.self)
        }
        var align: UInt32 = defaultAlign
        let alignPrefix = "align="
        if let maybeAlign = try parser.peekKeyword(), maybeAlign.starts(with: alignPrefix) {
            try parser.consume()
            var subParser = Parser(String(maybeAlign.dropFirst(alignPrefix.count)))
            align = try subParser.expectUnsignedInt(UInt32.self)
        }
        return MemArg(offset: offset, align: align)
    }

    private mutating func visitLoad(defaultAlign: UInt32) throws -> MemArg {
        return try memArg(defaultAlign: defaultAlign)
    }

    private mutating func visitStore(defaultAlign: UInt32) throws -> MemArg {
        return try memArg(defaultAlign: defaultAlign)
    }
}

extension ExpressionParser {
    mutating func visitBlock(watModule: inout WatModule) throws -> BlockType {
        self.labelStack.push(try parser.takeId())
        return try blockType(watModule: &watModule)
    }
    mutating func visitLoop(watModule: inout WatModule) throws -> BlockType {
        self.labelStack.push(try parser.takeId())
        return try blockType(watModule: &watModule)
    }
    mutating func visitIf(watModule: inout WatModule) throws -> BlockType {
        self.labelStack.push(try parser.takeId())
        return try blockType(watModule: &watModule)
    }
    mutating func visitBr(watModule: inout WatModule) throws -> UInt32 {
        return try labelIndex()
    }
    mutating func visitBrIf(watModule: inout WatModule) throws -> UInt32 {
        return try labelIndex()
    }
    mutating func visitBrTable(watModule: inout WatModule) throws -> BrTable {
        var labelIndices: [UInt32] = []
        while let labelUse = try takeLabelIndex() {
            labelIndices.append(labelUse)
        }
        guard let defaultIndex = labelIndices.popLast() else {
            throw WatParserError("expected at least one label index", location: parser.lexer.location())
        }
        return BrTable(labelIndices: labelIndices, defaultIndex: defaultIndex)
    }
    mutating func visitCall(watModule: inout WatModule) throws -> UInt32 {
        let use = try parser.expectIndexOrId()
        return UInt32(try watModule.functionsMap.resolve(use: use).index)
    }
    mutating func visitCallIndirect(watModule: inout WatModule) throws -> (typeIndex: UInt32, tableIndex: UInt32) {
        let tableIndex: UInt32
        if let tableId = try parser.takeIndexOrId() {
            tableIndex = UInt32(try watModule.tablesMap.resolve(use: tableId).index)
        } else {
            tableIndex = 0
        }
        let typeUse = try withWatParser { try $0.typeUse() }
        let (_, typeIndex) = try watModule.types.resolve(use: typeUse)
        return (UInt32(typeIndex), tableIndex)
    }
    mutating func visitTypedSelect(watModule: inout WatModule) throws -> ValueType {
        fatalError("unreachable because Instruction.json does not define the name of typed select and it is handled in parseTextInstruction() manually")
    }
    mutating func visitLocalGet(watModule: inout WatModule) throws -> UInt32 {
        return try localIndex()
    }
    mutating func visitLocalSet(watModule: inout WatModule) throws -> UInt32 {
        return try localIndex()
    }
    mutating func visitLocalTee(watModule: inout WatModule) throws -> UInt32 {
        return try localIndex()
    }
    mutating func visitGlobalGet(watModule: inout WatModule) throws -> UInt32 {
        return try globalIndex(watModule: &watModule)
    }
    mutating func visitGlobalSet(watModule: inout WatModule) throws -> UInt32 {
        return try globalIndex(watModule: &watModule)
    }
    mutating func visitI32Load(watModule: inout WatModule) throws -> MemArg {
        return try visitLoad(defaultAlign: 4)
    }
    mutating func visitI64Load(watModule: inout WatModule) throws -> MemArg {
        return try visitLoad(defaultAlign: 8)
    }
    mutating func visitF32Load(watModule: inout WatModule) throws -> MemArg {
        return try visitLoad(defaultAlign: 4)
    }
    mutating func visitF64Load(watModule: inout WatModule) throws -> MemArg {
        return try visitLoad(defaultAlign: 8)
    }
    mutating func visitI32Load8S(watModule: inout WatModule) throws -> MemArg {
        return try visitLoad(defaultAlign: 1)
    }
    mutating func visitI32Load8U(watModule: inout WatModule) throws -> MemArg {
        return try visitLoad(defaultAlign: 1)
    }
    mutating func visitI32Load16S(watModule: inout WatModule) throws -> MemArg {
        return try visitLoad(defaultAlign: 2)
    }
    mutating func visitI32Load16U(watModule: inout WatModule) throws -> MemArg {
        return try visitLoad(defaultAlign: 2)
    }
    mutating func visitI64Load8S(watModule: inout WatModule) throws -> MemArg {
        return try visitLoad(defaultAlign: 1)
    }
    mutating func visitI64Load8U(watModule: inout WatModule) throws -> MemArg {
        return try visitLoad(defaultAlign: 1)
    }
    mutating func visitI64Load16S(watModule: inout WatModule) throws -> MemArg {
        return try visitLoad(defaultAlign: 2)
    }
    mutating func visitI64Load16U(watModule: inout WatModule) throws -> MemArg {
        return try visitLoad(defaultAlign: 2)
    }
    mutating func visitI64Load32S(watModule: inout WatModule) throws -> MemArg {
        return try visitLoad(defaultAlign: 4)
    }
    mutating func visitI64Load32U(watModule: inout WatModule) throws -> MemArg {
        return try visitLoad(defaultAlign: 4)
    }
    mutating func visitI32Store(watModule: inout WatModule) throws -> MemArg {
        return try visitStore(defaultAlign: 4)
    }
    mutating func visitI64Store(watModule: inout WatModule) throws -> MemArg {
        return try visitStore(defaultAlign: 8)
    }
    mutating func visitF32Store(watModule: inout WatModule) throws -> MemArg {
        return try visitStore(defaultAlign: 4)
    }
    mutating func visitF64Store(watModule: inout WatModule) throws -> MemArg {
        return try visitStore(defaultAlign: 8)
    }
    mutating func visitI32Store8(watModule: inout WatModule) throws -> MemArg {
        return try visitStore(defaultAlign: 1)
    }
    mutating func visitI32Store16(watModule: inout WatModule) throws -> MemArg {
        return try visitStore(defaultAlign: 2)
    }
    mutating func visitI64Store8(watModule: inout WatModule) throws -> MemArg {
        return try visitStore(defaultAlign: 1)
    }
    mutating func visitI64Store16(watModule: inout WatModule) throws -> MemArg {
        return try visitStore(defaultAlign: 2)
    }
    mutating func visitI64Store32(watModule: inout WatModule) throws -> MemArg {
        return try visitStore(defaultAlign: 4)
    }
    mutating func visitMemorySize(watModule: inout WatModule) throws -> UInt32 {
        return try memoryIndex(watModule: &watModule)
    }
    mutating func visitMemoryGrow(watModule: inout WatModule) throws -> UInt32 {
        return try memoryIndex(watModule: &watModule)
    }
    mutating func visitI32Const(watModule: inout WatModule) throws -> Int32 {
        return try parser.expectSignedInt(fromBitPattern: Int32.init(bitPattern:))
    }
    mutating func visitI64Const(watModule: inout WatModule) throws -> Int64 {
        return try parser.expectSignedInt(fromBitPattern: Int64.init(bitPattern:))
    }
    mutating func visitF32Const(watModule: inout WatModule) throws -> IEEE754.Float32 {
        return try parser.expectFloat32()
    }
    mutating func visitF64Const(watModule: inout WatModule) throws -> IEEE754.Float64 {
        return try parser.expectFloat64()
    }
    mutating func visitRefNull(watModule: inout WatModule) throws -> ReferenceType {
        return try refKind()
    }
    mutating func visitRefFunc(watModule: inout WatModule) throws -> UInt32 {
        return try functionIndex(watModule: &watModule)
    }
    mutating func visitMemoryInit(watModule: inout WatModule) throws -> UInt32 {
        return try dataIndex(watModule: &watModule)
    }
    mutating func visitDataDrop(watModule: inout WatModule) throws -> UInt32 {
        return try dataIndex(watModule: &watModule)
    }
    mutating func visitMemoryCopy(watModule: inout WatModule) throws -> (dstMem: UInt32, srcMem: UInt32) {
        let dest = try memoryIndex(watModule: &watModule)
        let source = try memoryIndex(watModule: &watModule)
        return (dest, source)
    }
    mutating func visitMemoryFill(watModule: inout WatModule) throws -> UInt32 {
        return try memoryIndex(watModule: &watModule)
    }
    mutating func visitTableInit(watModule: inout WatModule) throws -> (elemIndex: UInt32, table: UInt32) {
        // Accept two-styles (the first one is informal, but used in testsuite...)
        //   table.init $elemidx
        //   table.init $tableidx $elemidx
        let elementUse: Parser.IndexOrId
        let tableUse: Parser.IndexOrId?
        let use1 = try parser.expectIndexOrId()
        if let use2 = try parser.takeIndexOrId() {
            elementUse = use2
            tableUse = use1
        } else {
            elementUse = use1
            tableUse = nil
        }
        let table = try tableUse.map { UInt32(try watModule.tablesMap.resolve(use: $0).index) } ?? 0
        let elemIndex = UInt32(try watModule.elementsMap.resolve(use: elementUse).index)
        return (elemIndex, table)
    }
    mutating func visitElemDrop(watModule: inout WatModule) throws -> UInt32 {
        return try elementIndex(watModule: &watModule)
    }
    mutating func visitTableCopy(watModule: inout WatModule) throws -> (dstTable: UInt32, srcTable: UInt32) {
        if let destUse = try parser.takeIndexOrId() {
            let (_, destIndex) = try watModule.tablesMap.resolve(use: destUse)
            let sourceUse = try parser.expectIndexOrId()
            let (_, sourceIndex) = try watModule.tablesMap.resolve(use: sourceUse)
            return (UInt32(destIndex), UInt32(sourceIndex))
        }
        return (0, 0)
    }
    mutating func visitTableFill(watModule: inout WatModule) throws -> UInt32 {
        return try tableIndex(watModule: &watModule)
    }
    mutating func visitTableGet(watModule: inout WatModule) throws -> UInt32 {
        return try tableIndex(watModule: &watModule)
    }
    mutating func visitTableSet(watModule: inout WatModule) throws -> UInt32 {
        return try tableIndex(watModule: &watModule)
    }
    mutating func visitTableGrow(watModule: inout WatModule) throws -> UInt32 {
        return try tableIndex(watModule: &watModule)
    }
    mutating func visitTableSize(watModule: inout WatModule) throws -> UInt32 {
        return try tableIndex(watModule: &watModule)
    }
}

public struct WatParserError: Error, CustomStringConvertible {
    public let message: String
    public let location: Location?

    public var description: String {
        if let location {
            let (line, column) = location.computeLineAndColumn()
            return "\(line):\(column): \(message)"
        } else {
            return message
        }
    }

    init(_ message: String, location: Location?) {
        self.message = message
        self.location = location
    }
}

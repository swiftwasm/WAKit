import WasmParser
import WasmTypes

struct ExpressionParser<Visitor: InstructionVisitor> {
    typealias LocalsMap = NameMapping<WatParser.ResolvedLocalDecl>
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
                return self[name.value]
            }
        }

        mutating func push(_ name: Name?) {
            stack.append(name?.value)
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
    let features: WasmFeatureSet
    private var labelStack = LabelStack()

    init(
        type: WatParser.FunctionType,
        locals: [WatParser.LocalDecl],
        lexer: Lexer,
        features: WasmFeatureSet,
        typeMap: TypesNameMapping
    ) throws {
        self.parser = Parser(lexer)
        self.locals = try Self.computeLocals(type: type, locals: locals, typeMap: typeMap)
        self.features = features
    }

    init(lexer: Lexer, features: WasmFeatureSet) {
        self.parser = Parser(lexer)
        self.locals = LocalsMap()
        self.features = features
    }

    static func computeLocals(
        type: WatParser.FunctionType,
        locals: [WatParser.LocalDecl],
        typeMap: TypesNameMapping
    ) throws -> LocalsMap {
        var localsMap = LocalsMap()
        for (name, type) in zip(type.parameterNames, type.signature.parameters) {
            try localsMap.add(.init(id: name, type: type))
        }
        for local in locals {
            try localsMap.add(local.resolve(typeMap))
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
        guard lastLabel == name.value else {
            throw WatParserError("expected label \(lastLabel) but found \(name)", location: location)
        }
    }

    mutating func parse(visitor: inout Visitor, wat: inout Wat) throws {
        while try instruction(visitor: &visitor, wat: &wat) {
            // Parse more instructions
        }
    }

    mutating func parseElemExprList(visitor: inout Visitor, wat: inout Wat) throws {
        while true {
            let needRightParen = try parser.takeParenBlockStart("item")
            guard try instruction(visitor: &visitor, wat: &wat) else {
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
        var wat = Wat.empty(features: features)
        // WAST allows extra const value instruction
        if try parser.takeParenBlockStart("ref.extern") {
            try visitor.visitRefExtern(value: parser.expectUnsignedInt())
            try parser.expect(.rightParen)
            return true
        }
        // WAST const expr only accepts folded instructions
        if try foldedInstruction(visitor: &visitor, wat: &wat) {
            return true
        }
        return false
    }

    mutating func parseConstInstruction(visitor: inout Visitor) throws -> Bool {
        var wat = Wat.empty(features: features)
        if try foldedInstruction(visitor: &visitor, wat: &wat) {
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

        // WAST predication allows omitting some concrete specifiers
        if try parser.takeParenBlockStart("ref.null"), try parser.isEndOfParen() {
            return .refNull(nil)
        }
        if try parser.takeParenBlockStart("ref.func"), try parser.isEndOfParen() {
            return .refFunc(functionIndex: nil)
        }
        if try parser.takeParenBlockStart("ref.extern"), try parser.isEndOfParen() {
            return .refFunc(functionIndex: nil)
        }
        parser = initialParser
        return nil
    }

    /// Parse "(instr)" or "instr" and visit the instruction.
    /// - Returns: `true` if an instruction was parsed. Otherwise, `false`.
    mutating func instruction(visitor: inout Visitor, wat: inout Wat) throws -> Bool {
        if try nonFoldedInstruction(visitor: &visitor, wat: &wat) {
            return true
        }
        if try foldedInstruction(visitor: &visitor, wat: &wat) {
            return true
        }
        return false
    }

    /// Parse an instruction without surrounding parentheses.
    private mutating func nonFoldedInstruction(visitor: inout Visitor, wat: inout Wat) throws -> Bool {
        if try plainInstruction(visitor: &visitor, wat: &wat) {
            return true
        }
        return false
    }

    private struct Suspense {
        let visit: ((inout Visitor, inout ExpressionParser) throws -> Void)?
    }

    private mutating func foldedInstruction(visitor: inout Visitor, wat: inout Wat) throws -> Bool {
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
            let visit = try parseTextInstruction(keyword: keyword, wat: &wat)
            let suspense: Suspense
            switch keyword {
            case "if":
                // Special handling for "if" because of its special order
                // Usually given (A (B) (C (D)) (E)), we visit B, D, C, E, A
                // But for "if" (if (B) (then (C (D))) (else (E))), we want to visit B, "if", D, C, E

                // Condition may be absent
                if try !parser.takeParenBlockStart("then") {
                    // Visit condition instructions
                    while true {
                        guard try foldedInstruction(visitor: &visitor, wat: &wat) else {
                            break
                        }
                        if try parser.takeParenBlockStart("then") {
                            break
                        }
                    }
                }
                // Visit "if"
                _ = try visit(&visitor)
                // Visit "then" block
                try parse(visitor: &visitor, wat: &wat)
                try parser.expect(.rightParen)
                // Visit "else" block if present
                if try parser.takeParenBlockStart("else") {
                    // Visit only when "else" block has child expr
                    if try parser.peek(.rightParen) == nil {
                        _ = try visitor.visitElse()
                        try parse(visitor: &visitor, wat: &wat)
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
                try parse(visitor: &visitor, wat: &wat)
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
    private mutating func parseTextInstruction(keyword: String, wat: inout Wat) throws -> ((inout Visitor) throws -> Void) {
        switch keyword {
        case "select":
            // Special handling for "select", which have two variants 1. with type, 2. without type
            let results = try withWatParser({ try $0.results() })
            let types = wat.types
            return { visitor in
                if let type = results.first {
                    let type = try type.resolve(types)
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
            guard let visit = try WAT.parseTextInstruction(keyword: keyword, expressionParser: &self, wat: &wat) else {
                throw WatParserError("unknown instruction \(keyword)", location: parser.lexer.location())
            }
            return visit
        }
    }

    /// - Returns: `true` if a plain instruction was parsed.
    private mutating func plainInstruction(visitor: inout Visitor, wat: inout Wat) throws -> Bool {
        guard let keyword = try parser.peekKeyword() else {
            return false
        }
        try parser.consume()
        let visit = try parseTextInstruction(keyword: keyword, wat: &wat)
        _ = try visit(&visitor)
        return true
    }

    private mutating func localIndex() throws -> UInt32 {
        let index = try parser.expectIndexOrId()
        return UInt32(try locals.resolve(use: index).index)
    }

    private mutating func functionIndex(wat: inout Wat) throws -> UInt32 {
        let funcUse = try parser.expectIndexOrId()
        return UInt32(try wat.functionsMap.resolve(use: funcUse).index)
    }

    private mutating func memoryIndex(wat: inout Wat) throws -> UInt32 {
        guard let use = try parser.takeIndexOrId() else { return 0 }
        return UInt32(try wat.memories.resolve(use: use).index)
    }

    private mutating func globalIndex(wat: inout Wat) throws -> UInt32 {
        guard let use = try parser.takeIndexOrId() else { return 0 }
        return UInt32(try wat.globals.resolve(use: use).index)
    }

    private mutating func dataIndex(wat: inout Wat) throws -> UInt32 {
        guard let use = try parser.takeIndexOrId() else { return 0 }
        return UInt32(try wat.data.resolve(use: use).index)
    }

    private mutating func tableIndex(wat: inout Wat) throws -> UInt32 {
        guard let use = try parser.takeIndexOrId() else { return 0 }
        return UInt32(try wat.tablesMap.resolve(use: use).index)
    }

    private mutating func elementIndex(wat: inout Wat) throws -> UInt32 {
        guard let use = try parser.takeIndexOrId() else { return 0 }
        return UInt32(try wat.elementsMap.resolve(use: use).index)
    }

    private mutating func blockType(wat: inout Wat) throws -> BlockType {
        let results = try withWatParser {
            try $0.results().map { try $0.resolve(wat.types) }
        }
        if !results.isEmpty {
            return try wat.types.resolveBlockType(results: results)
        }
        let typeUse = try withWatParser { try $0.typeUse(mayHaveName: false) }
        return try wat.types.resolveBlockType(use: typeUse)
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

    /// https://webassembly.github.io/function-references/core/text/types.html#text-heaptype
    private mutating func heapType(wat: inout Wat) throws -> HeapType {
        if try parser.takeKeyword("func") {
            return .funcRef
        } else if try parser.takeKeyword("extern") {
            return .externRef
        } else if let id = try parser.takeIndexOrId() {
            let (_, index) = try wat.types.resolve(use: id)
            return .concrete(typeIndex: UInt32(index))
        }
        throw WatParserError("expected \"func\", \"extern\" or type index", location: parser.lexer.location())
    }

    private mutating func memArg(defaultAlign: UInt32) throws -> MemArg {
        var offset: UInt64 = 0
        let offsetPrefix = "offset="
        if let maybeOffset = try parser.peekKeyword(), maybeOffset.starts(with: offsetPrefix) {
            try parser.consume()
            var subParser = Parser(String(maybeOffset.dropFirst(offsetPrefix.count)))
            offset = try subParser.expectUnsignedInt(UInt64.self)

            if !features.contains(.memory64), offset > UInt32.max {
                throw WatParserError("memory offset must be less than or equal to \(UInt32.max)", location: subParser.lexer.location())
            }
        }
        var align: UInt32 = defaultAlign
        let alignPrefix = "align="
        if let maybeAlign = try parser.peekKeyword(), maybeAlign.starts(with: alignPrefix) {
            try parser.consume()
            var subParser = Parser(String(maybeAlign.dropFirst(alignPrefix.count)))
            let rawAlign = try subParser.expectUnsignedInt(UInt32.self)

            if rawAlign == 0 || rawAlign & (rawAlign - 1) != 0 {
                throw WatParserError("alignment must be a power of 2", location: subParser.lexer.location())
            }
            align = UInt32(rawAlign.trailingZeroBitCount)
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
    mutating func visitBlock(wat: inout Wat) throws -> BlockType {
        self.labelStack.push(try parser.takeId())
        return try blockType(wat: &wat)
    }
    mutating func visitLoop(wat: inout Wat) throws -> BlockType {
        self.labelStack.push(try parser.takeId())
        return try blockType(wat: &wat)
    }
    mutating func visitIf(wat: inout Wat) throws -> BlockType {
        self.labelStack.push(try parser.takeId())
        return try blockType(wat: &wat)
    }
    mutating func visitBr(wat: inout Wat) throws -> UInt32 {
        return try labelIndex()
    }
    mutating func visitBrIf(wat: inout Wat) throws -> UInt32 {
        return try labelIndex()
    }
    mutating func visitBrTable(wat: inout Wat) throws -> BrTable {
        var labelIndices: [UInt32] = []
        while let labelUse = try takeLabelIndex() {
            labelIndices.append(labelUse)
        }
        guard let defaultIndex = labelIndices.popLast() else {
            throw WatParserError("expected at least one label index", location: parser.lexer.location())
        }
        return BrTable(labelIndices: labelIndices, defaultIndex: defaultIndex)
    }
    mutating func visitCall(wat: inout Wat) throws -> UInt32 {
        let use = try parser.expectIndexOrId()
        return UInt32(try wat.functionsMap.resolve(use: use).index)
    }
    mutating func visitCallRef(wat: inout Wat) throws -> UInt32 {
        let use = try parser.expectIndexOrId()
        return UInt32(try wat.types.resolve(use: use).index)
    }
    mutating func visitReturnCallRef(wat: inout Wat) throws -> UInt32 {
        return try visitCallRef(wat: &wat)
    }
    mutating func visitBrOnNull(wat: inout Wat) throws -> UInt32 {
        return try labelIndex()
    }
    mutating func visitBrOnNonNull(wat: inout Wat) throws -> UInt32 {
        return try labelIndex()
    }
    mutating func visitCallIndirect(wat: inout Wat) throws -> (typeIndex: UInt32, tableIndex: UInt32) {
        let tableIndex: UInt32
        if let tableId = try parser.takeIndexOrId() {
            tableIndex = UInt32(try wat.tablesMap.resolve(use: tableId).index)
        } else {
            tableIndex = 0
        }
        let typeUse = try withWatParser { try $0.typeUse(mayHaveName: false) }
        let (_, typeIndex) = try wat.types.resolve(use: typeUse)
        return (UInt32(typeIndex), tableIndex)
    }
    mutating func visitReturnCall(wat: inout Wat) throws -> UInt32 {
        return try visitCall(wat: &wat)
    }
    mutating func visitReturnCallIndirect(wat: inout Wat) throws -> (typeIndex: UInt32, tableIndex: UInt32) {
        return try visitCallIndirect(wat: &wat)
    }
    mutating func visitTypedSelect(wat: inout Wat) throws -> ValueType {
        fatalError("unreachable because Instruction.json does not define the name of typed select and it is handled in parseTextInstruction() manually")
    }
    mutating func visitLocalGet(wat: inout Wat) throws -> UInt32 {
        return try localIndex()
    }
    mutating func visitLocalSet(wat: inout Wat) throws -> UInt32 {
        return try localIndex()
    }
    mutating func visitLocalTee(wat: inout Wat) throws -> UInt32 {
        return try localIndex()
    }
    mutating func visitGlobalGet(wat: inout Wat) throws -> UInt32 {
        return try globalIndex(wat: &wat)
    }
    mutating func visitGlobalSet(wat: inout Wat) throws -> UInt32 {
        return try globalIndex(wat: &wat)
    }
    mutating func visitLoad(_ load: Instruction.Load, wat: inout Wat) throws -> MemArg {
        return try visitLoad(defaultAlign: UInt32(load.naturalAlignment))
    }
    mutating func visitStore(_ store: Instruction.Store, wat: inout Wat) throws -> MemArg {
        return try visitStore(defaultAlign: UInt32(store.naturalAlignment))
    }
    mutating func visitMemorySize(wat: inout Wat) throws -> UInt32 {
        return try memoryIndex(wat: &wat)
    }
    mutating func visitMemoryGrow(wat: inout Wat) throws -> UInt32 {
        return try memoryIndex(wat: &wat)
    }
    mutating func visitI32Const(wat: inout Wat) throws -> Int32 {
        return try parser.expectSignedInt(fromBitPattern: Int32.init(bitPattern:))
    }
    mutating func visitI64Const(wat: inout Wat) throws -> Int64 {
        return try parser.expectSignedInt(fromBitPattern: Int64.init(bitPattern:))
    }
    mutating func visitF32Const(wat: inout Wat) throws -> IEEE754.Float32 {
        return try parser.expectFloat32()
    }
    mutating func visitF64Const(wat: inout Wat) throws -> IEEE754.Float64 {
        return try parser.expectFloat64()
    }
    mutating func visitRefNull(wat: inout Wat) throws -> HeapType {
        return try heapType(wat: &wat)
    }
    mutating func visitRefFunc(wat: inout Wat) throws -> UInt32 {
        return try functionIndex(wat: &wat)
    }
    mutating func visitMemoryInit(wat: inout Wat) throws -> UInt32 {
        return try dataIndex(wat: &wat)
    }
    mutating func visitDataDrop(wat: inout Wat) throws -> UInt32 {
        return try dataIndex(wat: &wat)
    }
    mutating func visitMemoryCopy(wat: inout Wat) throws -> (dstMem: UInt32, srcMem: UInt32) {
        let dest = try memoryIndex(wat: &wat)
        let source = try memoryIndex(wat: &wat)
        return (dest, source)
    }
    mutating func visitMemoryFill(wat: inout Wat) throws -> UInt32 {
        return try memoryIndex(wat: &wat)
    }
    mutating func visitTableInit(wat: inout Wat) throws -> (elemIndex: UInt32, table: UInt32) {
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
        let table = try tableUse.map { UInt32(try wat.tablesMap.resolve(use: $0).index) } ?? 0
        let elemIndex = UInt32(try wat.elementsMap.resolve(use: elementUse).index)
        return (elemIndex, table)
    }
    mutating func visitElemDrop(wat: inout Wat) throws -> UInt32 {
        return try elementIndex(wat: &wat)
    }
    mutating func visitTableCopy(wat: inout Wat) throws -> (dstTable: UInt32, srcTable: UInt32) {
        if let destUse = try parser.takeIndexOrId() {
            let (_, destIndex) = try wat.tablesMap.resolve(use: destUse)
            let sourceUse = try parser.expectIndexOrId()
            let (_, sourceIndex) = try wat.tablesMap.resolve(use: sourceUse)
            return (UInt32(destIndex), UInt32(sourceIndex))
        }
        return (0, 0)
    }
    mutating func visitTableFill(wat: inout Wat) throws -> UInt32 {
        return try tableIndex(wat: &wat)
    }
    mutating func visitTableGet(wat: inout Wat) throws -> UInt32 {
        return try tableIndex(wat: &wat)
    }
    mutating func visitTableSet(wat: inout Wat) throws -> UInt32 {
        return try tableIndex(wat: &wat)
    }
    mutating func visitTableGrow(wat: inout Wat) throws -> UInt32 {
        return try tableIndex(wat: &wat)
    }
    mutating func visitTableSize(wat: inout Wat) throws -> UInt32 {
        return try tableIndex(wat: &wat)
    }
}

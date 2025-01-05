import WasmParser
import WasmTypes

protocol WastConstInstructionVisitor: InstructionVisitor {
    mutating func visitRefExtern(value: UInt32) throws
}

/// A parser for WAST format.
/// You can find its grammar definition in the [WebAssembly spec repository](https://github.com/WebAssembly/spec/blob/wg-1.0/interpreter/README.md#scripts)
struct WastParser {
    var parser: Parser
    let features: WasmFeatureSet

    init(_ input: String, features: WasmFeatureSet) {
        self.parser = Parser(input)
        self.features = features
    }

    mutating func nextDirective() throws -> WastDirective? {
        var originalParser = parser
        guard (try parser.peek(.leftParen)) != nil else { return nil }
        try parser.consume()
        guard try WastDirective.peek(wastParser: self) else {
            if try peekModuleField() {
                // Parse inline module, which doesn't include surrounding (module)
                let location = originalParser.lexer.location()
                return .module(
                    ModuleDirective(
                        source: .text(try parseWAT(&originalParser, features: features)), id: nil, location: location
                    ))
            }
            throw WatParserError("unexpected wast directive token", location: parser.lexer.location())
        }
        let directive = try WastDirective.parse(wastParser: &self)
        return directive
    }

    private func peekModuleField() throws -> Bool {
        guard let keyword = try parser.peekKeyword() else { return false }
        switch keyword {
        case "data", "elem", "tag", "export", "func",
            "type", "global", "import", "memory",
            "start", "table":
            return true
        default:
            return false
        }
    }

    mutating func parens<T>(_ body: (inout WastParser) throws -> T) throws -> T {
        try parser.expect(.leftParen)
        let result = try body(&self)
        return result
    }

    struct ConstExpressionCollector: WastConstInstructionVisitor {
        let addValue: (WastConstValue) -> Void

        mutating func visitI32Const(value: Int32) throws { addValue(.i32(UInt32(bitPattern: value))) }
        mutating func visitI64Const(value: Int64) throws { addValue(.i64(UInt64(bitPattern: value))) }
        mutating func visitF32Const(value: IEEE754.Float32) throws { addValue(.f32(value.bitPattern)) }
        mutating func visitF64Const(value: IEEE754.Float64) throws { addValue(.f64(value.bitPattern)) }
        mutating func visitRefFunc(functionIndex: UInt32) throws {
            addValue(.refFunc(functionIndex: functionIndex))
        }
        mutating func visitRefNull(type: HeapType) throws {
            addValue(.refNull(type))
        }
        func visitRefExtern(value: UInt32) throws {
            addValue(.refExtern(value: value))
        }
    }

    mutating func argumentValues() throws -> [WastConstValue] {
        var values: [WastConstValue] = []
        var collector = ConstExpressionCollector(addValue: { values.append($0) })
        var exprParser = ExpressionParser<ConstExpressionCollector>(lexer: parser.lexer, features: features)
        while try exprParser.parseWastConstInstruction(visitor: &collector) {}
        parser = exprParser.parser
        return values
    }

    mutating func expectationValues() throws -> [WastExpectValue] {
        var values: [WastExpectValue] = []
        var collector = ConstExpressionCollector(addValue: {
            let value: WastExpectValue
            switch $0 {
            case .i32(let v): value = .i32(v)
            case .i64(let v): value = .i64(v)
            case .f32(let v): value = .f32(v)
            case .f64(let v): value = .f64(v)
            case .refNull(let heapTy): value = .refNull(heapTy)
            case .refFunc(let index): value = .refFunc(functionIndex: index)
            case .refExtern(let v): value = .refExtern(value: v)
            }
            values.append(value)
        })
        var exprParser = ExpressionParser<ConstExpressionCollector>(lexer: parser.lexer, features: features)
        while true {
            if let expectValue = try exprParser.parseWastExpectValue() {
                values.append(expectValue)
            }
            if try exprParser.parseWastConstInstruction(visitor: &collector) {
                continue
            }
            break
        }
        parser = exprParser.parser
        return values
    }
}

public enum WastExecute {
    case invoke(WastInvoke)
    case wat(Wat)
    case get(module: String?, globalName: String)

    static func parse(wastParser: inout WastParser) throws -> WastExecute {
        let keyword = try wastParser.parser.peekKeyword()
        let execute: WastExecute
        switch keyword {
        case "invoke":
            execute = .invoke(try WastInvoke.parse(wastParser: &wastParser))
        case "module":
            try wastParser.parser.consume()
            execute = .wat(try parseWAT(&wastParser.parser, features: wastParser.features))
            try wastParser.parser.skipParenBlock()
        case "get":
            try wastParser.parser.consume()
            let module = try wastParser.parser.takeId()
            let globalName = try wastParser.parser.expectString()
            execute = .get(module: module?.value, globalName: globalName)
            try wastParser.parser.expect(.rightParen)
        case let keyword?:
            throw WatParserError(
                "unexpected wast execute \(keyword)",
                location: wastParser.parser.lexer.location()
            )
        case nil:
            throw WatParserError("unexpected eof", location: wastParser.parser.lexer.location())
        }
        return execute
    }
}

public enum WastConstValue {
    case i32(UInt32)
    case i64(UInt64)
    case f32(UInt32)
    case f64(UInt64)
    case refNull(HeapType)
    case refFunc(functionIndex: UInt32)
    case refExtern(value: UInt32)
}

public struct WastInvoke {
    public let module: String?
    public let name: String
    public let args: [WastConstValue]

    static func parse(wastParser: inout WastParser) throws -> WastInvoke {
        try wastParser.parser.expectKeyword("invoke")
        let module = try wastParser.parser.takeId()
        let name = try wastParser.parser.expectString()
        let args = try wastParser.argumentValues()
        try wastParser.parser.expect(.rightParen)
        let invoke = WastInvoke(module: module?.value, name: name, args: args)
        return invoke
    }
}

public enum WastExpectValue {
    case i32(UInt32)
    case i64(UInt64)
    case f32(UInt32)
    case f64(UInt64)

    /// A value that is expected to be a null reference,
    /// optionally with a specific type.
    case refNull(HeapType?)
    /// A value that is expected to be a non-null reference
    /// to a function, optionally with a specific index.
    case refFunc(functionIndex: UInt32?)
    /// A value that is expected to be a non-null reference
    /// to an extern, optionally with a specific value.
    case refExtern(value: UInt32?)
    /// A value that is expected to be a canonical NaN.
    /// Corresponds to `f32.const nan:canonical` in WAST.
    case f32CanonicalNaN
    /// A value that is expected to be an arithmetic NaN.
    /// Corresponds to `f32.const nan:arithmetic` in WAST.
    case f32ArithmeticNaN
    /// A value that is expected to be a canonical NaN.
    /// Corresponds to `f64.const nan:canonical` in WAST.
    case f64CanonicalNaN
    /// A value that is expected to be an arithmetic NaN.
    /// Corresponds to `f64.const nan:arithmetic` in WAST.
    case f64ArithmeticNaN
}

/// A directive in a WAST script.
public enum WastDirective {
    case module(ModuleDirective)
    case assertInvalid(module: ModuleDirective, message: String)
    case assertMalformed(module: ModuleDirective, message: String)
    case assertReturn(execute: WastExecute, results: [WastExpectValue])
    case assertTrap(execute: WastExecute, message: String)
    case assertExhaustion(call: WastInvoke, message: String)
    case assertUnlinkable(module: Wat, message: String)
    case register(name: String, moduleId: String?)
    case invoke(WastInvoke)

    static func peek(wastParser: WastParser) throws -> Bool {
        guard let keyword = try wastParser.parser.peekKeyword() else { return false }
        return keyword.starts(with: "assert_") || keyword == "module" || keyword == "register" || keyword == "invoke"
    }

    /// Parse a directive in a WAST script from "keyword ...)" form.
    /// Leading left parenthesis is already consumed, and the trailing right parenthesis should be consumed by this function.
    static func parse(wastParser: inout WastParser) throws -> WastDirective {
        let keyword = try wastParser.parser.peekKeyword()
        switch keyword {
        case "module":
            return .module(try ModuleDirective.parse(wastParser: &wastParser))
        case "assert_invalid":
            try wastParser.parser.consume()
            let module = try wastParser.parens { try ModuleDirective.parse(wastParser: &$0) }
            let message = try wastParser.parser.expectString()
            try wastParser.parser.expect(.rightParen)
            return .assertInvalid(module: module, message: message)
        case "assert_malformed":
            try wastParser.parser.consume()
            let module = try wastParser.parens { try ModuleDirective.parse(wastParser: &$0) }
            let message = try wastParser.parser.expectString()
            try wastParser.parser.expect(.rightParen)
            return .assertMalformed(module: module, message: message)
        case "assert_return":
            try wastParser.parser.consume()
            let execute = try wastParser.parens { try WastExecute.parse(wastParser: &$0) }
            let results = try wastParser.expectationValues()
            try wastParser.parser.expect(.rightParen)
            return .assertReturn(execute: execute, results: results)
        case "assert_trap":
            try wastParser.parser.consume()
            let execute = try wastParser.parens { try WastExecute.parse(wastParser: &$0) }
            let message = try wastParser.parser.expectString()
            try wastParser.parser.expect(.rightParen)
            return .assertTrap(execute: execute, message: message)
        case "assert_exhaustion":
            try wastParser.parser.consume()
            let call = try wastParser.parens { try WastInvoke.parse(wastParser: &$0) }
            let message = try wastParser.parser.expectString()
            try wastParser.parser.expect(.rightParen)
            return .assertExhaustion(call: call, message: message)
        case "assert_unlinkable":
            try wastParser.parser.consume()
            let features = wastParser.features
            let module = try wastParser.parens {
                try $0.parser.expectKeyword("module")
                let wat = try parseWAT(&$0.parser, features: features)
                try $0.parser.skipParenBlock()
                return wat
            }
            let message = try wastParser.parser.expectString()
            try wastParser.parser.expect(.rightParen)
            return .assertUnlinkable(module: module, message: message)
        case "register":
            try wastParser.parser.consume()
            let name = try wastParser.parser.expectString()
            let module = try wastParser.parser.takeId()
            try wastParser.parser.expect(.rightParen)
            return .register(name: name, moduleId: module?.value)
        case "invoke":
            let invoke = try WastInvoke.parse(wastParser: &wastParser)
            return .invoke(invoke)
        case let keyword?:
            throw WatParserError(
                "unexpected wast directive \(keyword)",
                location: wastParser.parser.lexer.location()
            )
        case nil:
            throw WatParserError("unexpected eof", location: wastParser.parser.lexer.location())
        }
    }
}

/// A module representation in "(module ...)" form in WAST.
public struct ModuleDirective {
    /// The source of the module
    public let source: ModuleSource
    /// The name of the module specified in $id form
    public let id: String?
    /// The location of the module in the source
    public let location: Location

    static func parse(wastParser: inout WastParser) throws -> ModuleDirective {
        let location = wastParser.parser.lexer.location()
        try wastParser.parser.expectKeyword("module")
        let id = try wastParser.parser.takeId()
        let source = try ModuleSource.parse(wastParser: &wastParser)
        return ModuleDirective(source: source, id: id?.value, location: location)
    }
}

/// The source of a module in WAST.
public enum ModuleSource {
    /// A parsed WAT module
    case text(Wat)
    /// A text form of WAT module
    case quote([UInt8])
    /// A binary form of WebAssembly module
    case binary([UInt8])

    static func parse(wastParser: inout WastParser) throws -> ModuleSource {
        if let headKeyword = try wastParser.parser.peekKeyword() {
            if headKeyword == "binary" {
                // (module binary "..." "..." ...)
                try wastParser.parser.consume()
                return .binary(try wastParser.parser.expectStringList())
            } else if headKeyword == "quote" {
                // (module quote "..." "..." ...)
                try wastParser.parser.consume()
                return .quote(try wastParser.parser.expectStringList())
            }
        }

        let watModule = try parseWAT(&wastParser.parser, features: wastParser.features)
        try wastParser.parser.skipParenBlock()
        return .text(watModule)
    }
}

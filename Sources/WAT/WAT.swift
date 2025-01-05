import WasmParser

/// Options for encoding a WebAssembly module into a binary format.
public struct EncodeOptions {
    /// Whether to include the name section.
    public var nameSection: Bool

    /// The default encoding options.
    public static let `default` = EncodeOptions()

    /// Creates a new encoding options instance.
    public init(nameSection: Bool = false) {
        self.nameSection = nameSection
    }
}

/// Transforms a WebAssembly text format (WAT) string into a WebAssembly binary format byte array.
/// - Parameter input: The WAT string to transform
/// - Returns: The WebAssembly binary format byte array
///
/// ```swift
/// import WAT
///
/// let wasm = try wat2wasm("""
/// (module
///   (func $add (param i32 i32) (result i32)
///     local.get 0
///     local.get 1
///     i32.add)
///   (export "add" (func $add))
/// )
/// """)
/// ```
public func wat2wasm(
    _ input: String,
    features: WasmFeatureSet = .default,
    options: EncodeOptions = .default
) throws -> [UInt8] {
    var wat = try parseWAT(input, features: features)
    return try encode(module: &wat, options: options)
}

/// A WAT module representation.
public struct Wat {
    var types: TypesMap
    let functionsMap: NameMapping<WatParser.FunctionDecl>
    let tablesMap: NameMapping<WatParser.TableDecl>
    let tables: [Table]
    let memories: NameMapping<WatParser.MemoryDecl>
    let globals: NameMapping<WatParser.GlobalDecl>
    let elementsMap: NameMapping<WatParser.ElementDecl>
    let data: NameMapping<WatParser.DataSegmentDecl>
    let start: FunctionIndex?
    let imports: [Import]
    let exports: [Export]
    let customSections = [CustomSection]()
    let features: WasmFeatureSet

    let parser: Parser

    static func empty(features: WasmFeatureSet) -> Wat {
        Wat(
            types: TypesMap(),
            functionsMap: NameMapping<WatParser.FunctionDecl>(),
            tablesMap: NameMapping<WatParser.TableDecl>(),
            tables: [],
            memories: NameMapping<WatParser.MemoryDecl>(),
            globals: NameMapping<WatParser.GlobalDecl>(),
            elementsMap: NameMapping<WatParser.ElementDecl>(),
            data: NameMapping<WatParser.DataSegmentDecl>(),
            start: nil,
            imports: [],
            exports: [],
            features: features,
            parser: Parser("")
        )
    }

    /// Encodes the module into a WebAssembly binary format byte array.
    ///
    /// - Returns: The WebAssembly binary format byte array
    ///
    /// This method effectively consumes the module value, encoding it into a
    /// binary format byte array. If you need to encode the module multiple times,
    /// you should create a copy of the module value before encoding it.
    public mutating func encode(options: EncodeOptions = .default) throws -> [UInt8] {
        try WAT.encode(module: &self, options: options)
    }
}

/// Parses a WebAssembly text format (WAT) string into a `Wat` instance.
/// - Parameter input: The WAT string to parse
/// - Returns: The parsed `Wat` instance
///
/// The `Wat` instance can be used to encode the module into a WebAssembly binary format byte array.
///
/// ```swift
/// import WAT
///
/// var wat = try parseWAT("""
/// (module
///   (func $add (param i32 i32) (result i32)
///     local.get 0
///     local.get 1
///     i32.add)
///   (export "add" (func $add))
/// )
/// """)
///
/// let wasm = try wat.encode()
/// ```
public func parseWAT(_ input: String, features: WasmFeatureSet = .default) throws -> Wat {
    var parser = Parser(input)
    let wat: Wat
    if try parser.takeParenBlockStart("module") {
        wat = try parseWAT(&parser, features: features)
        try parser.skipParenBlock()
    } else {
        // The root (module) may be omitted
        wat = try parseWAT(&parser, features: features)
    }
    return wat
}

/// A WAST script representation.
public struct Wast {
    var parser: WastParser

    init(_ input: String, features: WasmFeatureSet) {
        self.parser = WastParser(input, features: features)
    }

    /// Parses the next directive in the WAST script.
    ///
    /// - Returns: A tuple containing the parsed directive and its location in the WAST script
    ///   or `nil` if there are no more directives to parse.
    public mutating func nextDirective() throws -> (directive: WastDirective, location: Location)? {
        let location = try parser.parser.peek()?.location(in: parser.parser.lexer) ?? parser.parser.lexer.location()
        if let directive = try parser.nextDirective() {
            return (directive, location)
        } else {
            return nil
        }
    }
}

/// Parses a WebAssembly script test format (WAST) string into a `Wast` instance.
///
/// - Parameter input: The WAST string to parse
/// - Returns: The parsed `Wast` instance
///
/// The returned `Wast` instance can be used to iterate over the directives in the WAST script.
///
/// ```swift
/// var wast = try parseWAST("""
/// (module
///   (func $add (param i32 i32) (result i32)
///     local.get 0
///     local.get 1
///     i32.add)
///   (export "add" (func $add))
/// )
/// (assert_return (invoke "add" (i32.const 1) (i32.const 2)) (i32.const 3))
/// """)
///
/// while let (directive, location) = try wast.nextDirective() {
///     print("\(location): \(directive)")
/// }
/// ```
public func parseWAST(_ input: String, features: WasmFeatureSet = .default) throws -> Wast {
    return Wast(input, features: features)
}

func parseWAT(_ parser: inout Parser, features: WasmFeatureSet) throws -> Wat {
    // This parser is 2-pass: first it collects all module items and creates a mapping of names to indices.

    let initialParser = parser

    var typesMap = TypesMap()

    do {
        var unresolvedTypesMapping = NameMapping<WatParser.FunctionTypeDecl>()
        // 1. Collect module type decls and resolve symbolic references inside
        // their definitions.
        var watParser = WatParser(parser: initialParser)
        while let decl = try watParser.next() {
            guard case let .type(decl) = decl.kind else { continue }
            try unresolvedTypesMapping.add(decl)
        }
        for decl in unresolvedTypesMapping {
            try typesMap.add(
                TypesMap.NamedResolvedType(
                    id: decl.id, type: decl.type.resolve(unresolvedTypesMapping)
                ))
        }
    }

    var importFactories: [() throws -> Import] = []
    var functionsMap = NameMapping<WatParser.FunctionDecl>()
    var tablesMap = NameMapping<WatParser.TableDecl>()
    var memoriesMap = NameMapping<WatParser.MemoryDecl>()
    var elementSegmentsMap = NameMapping<WatParser.ElementDecl>()
    var dataSegmentsMap = NameMapping<WatParser.DataSegmentDecl>()
    var globalsMap = NameMapping<WatParser.GlobalDecl>()
    var start: Parser.IndexOrId?

    var exportDecls: [WatParser.ExportDecl] = []

    var hasNonImport = false
    func visitDecl(decl: WatParser.ModuleField) throws {
        let location = decl.location

        func addExports(_ exports: [String], index: Int, kind: WatParser.ExternalKind) {
            for export in exports {
                exportDecls.append(WatParser.ExportDecl(name: export, id: .index(UInt32(index), location), kind: kind))
            }
        }

        func addImport(_ importNames: WatParser.ImportNames, makeDescriptor: @escaping () throws -> ImportDescriptor) {
            importFactories.append {
                return Import(
                    module: importNames.module, name: importNames.name,
                    descriptor: try makeDescriptor()
                )
            }
        }

        // Verify that imports precede all non-import module fields
        func checkImportOrder(_ importNames: WatParser.ImportNames?) throws {
            if importNames != nil {
                if hasNonImport {
                    throw WatParserError("Imports must precede all non-import module fields", location: location)
                }
            } else {
                hasNonImport = true
            }
        }

        switch decl.kind {
        case let .type(decl): break
        case let .function(decl):
            try checkImportOrder(decl.importNames)
            let index = try functionsMap.add(decl)
            addExports(decl.exports, index: index, kind: .function)
            switch decl.kind {
            case .definition: break
            case .imported(let importNames):
                addImport(importNames) {
                    let typeIndex = try typesMap.resolveIndex(use: decl.typeUse)
                    return .function(TypeIndex(typeIndex))
                }
            }
        case let .table(decl):
            try checkImportOrder(decl.importNames)
            let index = try tablesMap.add(decl)
            addExports(decl.exports, index: index, kind: .table)
            if var inlineElement = decl.inlineElement {
                inlineElement.mode = .active(
                    table: .index(UInt32(index), location), offset: .synthesized(0)
                )
                try elementSegmentsMap.add(inlineElement)
            }
            if let importNames = decl.importNames {
                addImport(importNames) { try .table(decl.type.resolve(typesMap)) }
            }
        case let .memory(decl):
            try checkImportOrder(decl.importNames)
            let index = try memoriesMap.add(decl)
            if var inlineData = decl.inlineData {
                // Associate the memory with the inline data
                inlineData.memory = .index(UInt32(index), location)
                inlineData.offset = .synthesized(0)
                try dataSegmentsMap.add(inlineData)
            }
            addExports(decl.exports, index: index, kind: .memory)
            if let importNames = decl.importNames {
                addImport(importNames) { .memory(decl.type) }
            }
        case let .global(decl):
            try checkImportOrder(decl.importNames)
            let index = try globalsMap.add(decl)
            addExports(decl.exports, index: index, kind: .global)
            switch decl.kind {
            case .definition: break
            case .imported(let importNames):
                addImport(importNames) { try .global(decl.type.resolve(typesMap)) }
            }
        case let .element(decl):
            try elementSegmentsMap.add(decl)
        case let .export(decl):
            exportDecls.append(decl)
        case let .data(decl):
            try dataSegmentsMap.add(decl)
        case let .start(startIndex):
            guard start == nil else {
                throw WatParserError("Multiple start sections", location: location)
            }
            start = startIndex
        }
    }

    // 2. Collect module decls and create name -> index mapping
    var watParser = WatParser(parser: initialParser)
    while let decl = try watParser.next() {
        try visitDecl(decl: decl)
    }

    // 3. Resolve a part of module items that reference other module items.
    // Remaining items like $id references like (call $func) are resolved during encoding.
    let exports: [Export] = try exportDecls.compactMap {
        let descriptor: ExportDescriptor
        switch $0.kind {
        case .function:
            descriptor = try .function(FunctionIndex(functionsMap.resolveIndex(use: $0.id)))
        case .table:
            descriptor = try .table(TableIndex(tablesMap.resolveIndex(use: $0.id)))
        case .memory:
            descriptor = try .memory(MemoryIndex(memoriesMap.resolveIndex(use: $0.id)))
        case .global:
            descriptor = try .global(GlobalIndex(globalsMap.resolveIndex(use: $0.id)))
        }
        return Export(name: $0.name, descriptor: descriptor)
    }

    let imports = try importFactories.map { try $0() }
    let startIndex = try start.map { try FunctionIndex(functionsMap.resolveIndex(use: $0)) }

    parser = watParser.parser

    return Wat(
        types: typesMap,
        functionsMap: functionsMap,
        tablesMap: tablesMap,
        tables: try tablesMap.map {
            try Table(type: $0.type.resolve(typesMap))
        },
        memories: memoriesMap,
        globals: globalsMap,
        elementsMap: elementSegmentsMap,
        data: dataSegmentsMap,
        start: startIndex,
        imports: imports,
        exports: exports,
        features: features,
        parser: parser
    )
}

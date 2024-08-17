import WasmParser

struct ModuleImports {
    let numberOfFunctions: Int
    let numberOfGlobals: Int
    let numberOfMemories: Int
    let numberOfTables: Int

    static func build(
        from imports: [Import],
        functionTypeIndices: inout [TypeIndex],
        globalTypes: inout [GlobalType],
        memoryTypes: inout [MemoryType],
        tableTypes: inout [TableType]
    ) -> ModuleImports {
        var numberOfFunctions: Int = 0
        var numberOfGlobals: Int = 0
        var numberOfMemories: Int = 0
        var numberOfTables: Int = 0
        for item in imports {
            switch item.descriptor {
            case .function(let typeIndex):
                numberOfFunctions += 1
                functionTypeIndices.append(typeIndex)
            case .table(let tableType):
                numberOfTables += 1
                tableTypes.append(tableType)
            case .memory(let memoryType):
                numberOfMemories += 1
                memoryTypes.append(memoryType)
            case .global(let globalType):
                numberOfGlobals += 1
                globalTypes.append(globalType)
            }
        }
        return ModuleImports(
            numberOfFunctions: numberOfFunctions,
            numberOfGlobals: numberOfGlobals,
            numberOfMemories: numberOfMemories,
            numberOfTables: numberOfTables
        )
    }
}

/// A unit of stateless WebAssembly code, which is a direct representation of a module file. You can get one
/// by calling either ``parseWasm(bytes:features:)`` or ``parseWasm(filePath:features:)``.
/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/modules.html#modules>
public struct Module {
    public var types: [FunctionType] {
        translatorContext.typeSection
    }
    var functions: [GuestFunction]
    let elements: [ElementSegment]
    let data: [DataSegment]
    let start: FunctionIndex?
    let globals: [WasmParser.Global]
    public let imports: [Import]
    public let exports: [Export]
    public let customSections: [CustomSection]

    let translatorContext: TranslatorModuleContext
    let allocator: ISeqAllocator
    let features: WasmFeatureSet
    let hasDataCount: Bool

    init(
        functions: [GuestFunction],
        elements: [ElementSegment],
        data: [DataSegment],
        start: FunctionIndex?,
        imports: [Import],
        exports: [Export],
        globals: [WasmParser.Global],
        customSections: [CustomSection],
        translatorContext: TranslatorModuleContext,
        allocator: ISeqAllocator,
        features: WasmFeatureSet,
        hasDataCount: Bool
    ) {
        self.functions = functions
        self.elements = elements
        self.data = data
        self.start = start
        self.imports = imports
        self.exports = exports
        self.globals = globals
        self.customSections = customSections
        self.translatorContext = translatorContext
        self.allocator = allocator
        self.features = features
        self.hasDataCount = hasDataCount
    }

    /// Materialize lazily-computed elements in this module
    public mutating func materializeAll() throws {
        let allocator = ISeqAllocator()
        let funcTypeInterner = Interner<FunctionType>()
        for function in functions {
            _ = try function.compile(module: self, funcTypeInterner: funcTypeInterner, allocator: allocator)
        }
    }
}

extension Module {
    var internalMemories: ArraySlice<MemoryType> {
        return translatorContext.memoryTypes[translatorContext.imports.numberOfMemories...]
    }
    var internalTables: ArraySlice<TableType> {
        return translatorContext.tableTypes[translatorContext.imports.numberOfTables...]
    }
}

// MARK: - Module Entity Indices
// <https://webassembly.github.io/spec/core/syntax/modules.html#syntax-typeidx>

/// Index type for function types within a module
typealias TypeIndex = UInt32
/// Index type for tables within a module
typealias FunctionIndex = UInt32
/// Index type for tables within a module
typealias TableIndex = UInt32
/// Index type for memories within a module
typealias MemoryIndex = UInt32
/// Index type for globals within a module
typealias GlobalIndex = UInt32
/// Index type for elements within a module
typealias ElementIndex = UInt32
/// Index type for data segments within a module
typealias DataIndex = UInt32
/// Index type for labels within a function
typealias LocalIndex = UInt32
/// Index type for labels within a function
typealias LabelIndex = UInt32

// MARK: - Module Entities

/// TODO: Rename to `GuestFunctionEntity`
///
/// An executable function representation in a module
/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/modules.html#functions>
struct GuestFunction {
    let type: FunctionType
    let code: Code

    func compile(module: Module, funcTypeInterner: Interner<FunctionType>, allocator: ISeqAllocator) throws -> InstructionSequence {
        throw TranslationError("Compile without instantiation is no longer supported")
    }
}

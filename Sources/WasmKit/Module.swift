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
    var functions: [GuestFunction]
    let elements: [ElementSegment]
    let data: [DataSegment]
    let start: FunctionIndex?
    let globals: [WasmParser.Global]
    public let imports: [Import]
    public let exports: [Export]
    public let customSections: [CustomSection]
    public let types: [FunctionType]

    let moduleImports: ModuleImports
    let memoryTypes: [MemoryType]
    let tableTypes: [TableType]
    let allocator: ISeqAllocator
    let features: WasmFeatureSet
    let hasDataCount: Bool

    init(
        types: [FunctionType],
        functions: [GuestFunction],
        elements: [ElementSegment],
        data: [DataSegment],
        start: FunctionIndex?,
        imports: [Import],
        exports: [Export],
        globals: [WasmParser.Global],
        memories: [MemoryType],
        tables: [TableType],
        customSections: [CustomSection],
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
        self.allocator = allocator
        self.features = features
        self.hasDataCount = hasDataCount

        var functionTypeIndices: [TypeIndex] = []
        var globalTypes: [GlobalType] = []
        var memoryTypes: [MemoryType] = []
        var tableTypes: [TableType] = []

        self.moduleImports = ModuleImports.build(
            from: imports,
            functionTypeIndices: &functionTypeIndices,
            globalTypes: &globalTypes,
            memoryTypes: &memoryTypes,
            tableTypes: &tableTypes
        )
        self.types = types
        self.memoryTypes = memoryTypes + memories
        self.tableTypes = tableTypes + tables
    }

    static func resolveType(_ index: TypeIndex, typeSection: [FunctionType]) throws -> FunctionType {
        guard Int(index) < typeSection.count else {
            throw TranslationError("Type index \(index) is out of range")
        }
        return typeSection[Int(index)]
    }

    /// Instantiate this module in the given imports.
    ///
    /// - Parameters:
    ///   - store: The ``Store`` to allocate the instance in.
    ///   - imports: The imports to use for instantiation. All imported entities
    ///     must be allocated in the given store.
    public func instantiate(store: Store, imports: Imports = [:]) throws -> Instance {
        Instance(handle: try self.instantiateHandle(store: store, imports: imports), store: store)
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/exec/modules.html#instantiation>
    private func instantiateHandle(store: Store, imports: Imports) throws -> InternalInstance {
        // Steps 5-8.

        // Step 9.
        // Process `elem.init` evaluation during allocation

        // Step 11.
        let instance = try store.allocator.allocate(
            module: self, engine: store.engine,
            resourceLimiter: store.resourceLimiter,
            imports: imports
        )

        if let nameSection = customSections.first(where: { $0.name == "name" }) {
            // FIXME?: Just ignore parsing error of name section for now.
            // Should emit warning instead of just discarding it?
            try? store.nameRegistry.register(instance: instance, nameSection: nameSection)
        }

        // Step 12-13.

        // Steps 14-15.
        do {
            for element in elements {
                guard case let .active(tableIndex, offset) = element.mode else { continue }
                let offsetValue = try offset.evaluate(context: instance)
                let table = try instance.tables[validating: Int(tableIndex)]
                try table.withValue { table in
                    guard let offset = offsetValue.maybeAddressOffset(table.limits.isMemory64) else {
                        throw InstantiationError.unsupported(
                            "Expect \(ValueType.addressType(isMemory64: table.limits.isMemory64)) offset of active element segment but got \(offsetValue)"
                        )
                    }
                    let references = try element.evaluateInits(context: instance)
                    try table.initialize(
                        elements: references, from: 0, to: Int(offset), count: references.count
                    )
                }
            }
        } catch Trap.undefinedElement, Trap.tableSizeOverflow, Trap.outOfBoundsTableAccess {
            throw InstantiationError.outOfBoundsTableAccess
        } catch {
            throw error
        }

        // Step 16.
        do {
            for case let .active(data) in data {
                let offsetValue = try data.offset.evaluate(context: instance)
                let memory = try instance.memories[validating: Int(data.index)]
                try memory.withValue { memory in
                    guard let offset = offsetValue.maybeAddressOffset(memory.limit.isMemory64) else {
                        throw InstantiationError.unsupported(
                            "Expect \(ValueType.addressType(isMemory64: memory.limit.isMemory64)) offset of active data segment but got \(offsetValue)"
                        )
                    }
                    try memory.write(offset: Int(offset), bytes: data.initializer)
                }
            }
        } catch Trap.outOfBoundsMemoryAccess {
            throw InstantiationError.outOfBoundsMemoryAccess
        } catch {
            throw error
        }

        // Step 17.
        if let startIndex = start {
            let startFunction = try instance.functions[validating: Int(startIndex)]
            _ = try startFunction.invoke([], store: store)
        }

        return instance
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
        return memoryTypes[moduleImports.numberOfMemories...]
    }
    var internalTables: ArraySlice<TableType> {
        return tableTypes[moduleImports.numberOfTables...]
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

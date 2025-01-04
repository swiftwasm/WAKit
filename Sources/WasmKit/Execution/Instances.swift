import WasmParser

@_exported import struct WasmParser.GlobalType
@_exported import struct WasmParser.Limits
@_exported import struct WasmParser.MemoryType
@_exported import struct WasmParser.TableType

// This file defines the internal representation of WebAssembly entities and
// their public API.
//
// Typically, the internal representation is an unowned handle to an entity
// storage, and the public API provides a memory-safe way to access and
// manipulate the entity. The handle is usually owned by a ``StoreAllocator``
// that manages the lifetime of the entity storage. The public API must ensure
// that the entity handle does not outlive the ``StoreAllocator``.
//
// # Naming Conventions
// - Internal entity storage: `${Name}Entity`
// - Entity handle: `Internal${Name}`
// - Public entity: `${Name}`
//
// +--- Public API -----------------------------------------------+
// |                                                              |
// |     allocator: StoreAllocator  ---------+                    |
// |     handle: Internal${Name}             |                    |
// |        |                                v                    |
// |        |                    +--- StoreAllocator ---+         |
// |        v                    |                      |         |
// |   +---------------+         |  +-----------------+ |         |
// |   | Entity handle | ---------->| Entity storage  | |         |
// |   +---------------+         |  +-----------------+ |         |
// |                             |                      |         |
// |                             +----------------------+         |
// |                                                              |
// +--------------------------------------------------------------+

/// Internal representation of a reference to a WebAssembly entity.
///
/// This type is designed to eliminate ARC retain/release for entities
/// known to be alive during a VM execution.
@dynamicMemberLookup
struct EntityHandle<T>: Equatable, Hashable {
    private let pointer: UnsafeMutablePointer<T>

    init(unsafe pointer: UnsafeMutablePointer<T>) {
        self.pointer = pointer
    }

    init?(bitPattern: UInt) {
        guard let pointer = UnsafeMutablePointer<T>(bitPattern: bitPattern) else { return nil }
        self.pointer = pointer
    }

    subscript<R>(dynamicMember keyPath: KeyPath<T, R>) -> R {
        pointer.pointee[keyPath: keyPath]
    }

    @inline(__always)
    func withValue<R>(_ body: (inout T) throws -> R) rethrows -> R {
        return try body(&pointer.pointee)
    }

    var bitPattern: Int {
        return Int(bitPattern: pointer)
    }
}

extension EntityHandle: ValidatableEntity where T: ValidatableEntity {
    static func createOutOfBoundsError(index: Int, count: Int) -> Error {
        T.createOutOfBoundsError(index: index, count: count)
    }
}

struct InstanceEntity /* : ~Copyable */ {
    var types: [FunctionType]
    var functions: ImmutableArray<InternalFunction>
    var tables: ImmutableArray<InternalTable>
    var memories: ImmutableArray<InternalMemory>
    var globals: ImmutableArray<InternalGlobal>
    var elementSegments: ImmutableArray<InternalElementSegment>
    var dataSegments: ImmutableArray<InternalDataSegment>
    var exports: [String: InternalExternalValue]
    var functionRefs: Set<InternalFunction>
    var features: WasmFeatureSet
    var dataCount: UInt32?

    static var empty: InstanceEntity {
        InstanceEntity(
            types: [],
            functions: ImmutableArray(),
            tables: ImmutableArray(),
            memories: ImmutableArray(),
            globals: ImmutableArray(),
            elementSegments: ImmutableArray(),
            dataSegments: ImmutableArray(),
            exports: [:],
            functionRefs: [],
            features: [],
            dataCount: nil
        )
    }

    internal func compileAllFunctions(store: Store) throws {
        let store = StoreRef(store)
        for function in functions {
            guard function.isWasm else { continue }
            try function.wasm.ensureCompiled(store: store)
        }
    }
}

typealias InternalInstance = EntityHandle<InstanceEntity>

/// A map of exported entities by name.
public struct Exports: Sequence {
    let store: Store
    let items: [String: InternalExternalValue]

    /// A collection of exported entities without their names.
    public var values: [ExternalValue] {
        self.map { $0.value }
    }

    /// Returns the exported entity with the given name.
    public subscript(_ name: String) -> ExternalValue? {
        guard let entity = items[name] else { return nil }
        return ExternalValue(handle: entity, store: store)
    }

    /// Returns the exported function with the given name.
    public subscript(function name: String) -> Function? {
        guard case .function(let function) = self[name] else { return nil }
        return function
    }

    /// Returns the exported table with the given name.
    public subscript(table name: String) -> Table? {
        guard case .table(let table) = self[name] else { return nil }
        return table
    }

    /// Returns the exported memory with the given name.
    public subscript(memory name: String) -> Memory? {
        guard case .memory(let memory) = self[name] else { return nil }
        return memory
    }

    /// Returns the exported global with the given name.
    public subscript(global name: String) -> Global? {
        guard case .global(let global) = self[name] else { return nil }
        return global
    }

    public struct Iterator: IteratorProtocol {
        private let store: Store
        private var iterator: Dictionary<String, InternalExternalValue>.Iterator

        init(parent: Exports) {
            self.store = parent.store
            self.iterator = parent.items.makeIterator()
        }

        public mutating func next() -> (name: String, value: ExternalValue)? {
            guard let (name, entity) = iterator.next() else { return nil }
            return (name, ExternalValue(handle: entity, store: store))
        }
    }

    public func makeIterator() -> Iterator {
        Iterator(parent: self)
    }
}

/// A stateful instance of a WebAssembly module.
/// Usually instantiated by ``Module/instantiate(store:imports:)``.
/// > Note:
/// <https://webassembly.github.io/spec/core/exec/runtime.html#module-instances>
public struct Instance {
    let handle: InternalInstance
    let store: Store

    init(handle: InternalInstance, store: Store) {
        self.handle = handle
        self.store = store
    }

    /// Finds an exported entity by name.
    ///
    /// - Parameter name: The name of the exported entity.
    /// - Returns: The exported entity if found, otherwise `nil`.
    public func export(_ name: String) -> ExternalValue? {
        guard let entity = handle.exports[name] else { return nil }
        return ExternalValue(handle: entity, store: store)
    }

    /// Finds an exported function by name.
    ///
    /// - Parameter name: The name of the exported function.
    /// - Returns: The address of the exported function if found, otherwise `nil`.
    func exportedFunction(name: String) -> Function? {
        guard case .function(let function) = self.export(name) else { return nil }
        return function
    }

    /// A dictionary of exported entities by name.
    public var exports: Exports {
        Exports(store: store, items: handle.exports)
    }

    /// Dumps the textual representation of all functions in the instance.
    ///
    /// - Precondition: The instance must be compiled with the token threading model.
    @_spi(OnlyForCLI)
    public func dumpFunctions<Target>(to target: inout Target, module: Module) throws where Target: TextOutputStream {
        for (offset, function) in self.handle.functions.enumerated() {
            let index = offset
            guard function.isWasm else { continue }
            target.write("==== Function[\(index)]")
            if let name = try? store.nameRegistry.lookup(function) {
                target.write(" '\(name)'")
            }
            target.write(" ====\n")
            guard case .uncompiled(let code) = function.wasm.code else {
                fatalError("Already compiled!?")
            }
            try function.wasm.ensureCompiled(store: StoreRef(store))
            let (iseq, locals, _) = function.assumeCompiled()

            // Print slot space information
            let stackLayout = try StackLayout(
                type: store.engine.funcTypeInterner.resolve(function.type),
                numberOfLocals: locals,
                codeSize: code.expression.count
            )
            stackLayout.dump(to: &target, iseq: iseq)

            var context = InstructionPrintingContext(
                shouldColor: true,
                function: Function(handle: function, store: store),
                nameRegistry: store.nameRegistry
            )
            iseq.write(to: &target, context: &context)
        }
    }
}

extension Instance {
    @available(*, unavailable, message: "Address-based APIs has been removed; use `Instance/export` to access exported memories")
    public var memoryAddresses: [Never] { [] }
    @available(*, unavailable, message: "Address-based APIs has been removed; use `Instance/export` to access exported globals")
    public var globalAddresses: [Never] { [] }
    @available(*, unavailable, message: "Address-based APIs has been removed;")
    public var elementAddresses: [Never] { [] }
    @available(*, unavailable, message: "Address-based APIs has been removed;")
    public var dataAddresses: [Never] { [] }
    @available(*, unavailable, message: "Address-based APIs has been removed;")
    public var exportInstances: [Never] { [] }
}

/// Deprecated typealias for `Instance`.
@available(*, deprecated, renamed: "Instance", message: "ModuleInstance has been renamed to Instance to match the terminology in the WebAssembly ecosystem")
public typealias ModuleInstance = Instance

/// > Note:
/// <https://webassembly.github.io/spec/core/exec/runtime.html#table-instances>
struct TableEntity /* : ~Copyable */ {
    var elements: [Reference]
    let tableType: TableType
    var limits: Limits { tableType.limits }

    static func maxSize(isMemory64: Bool) -> UInt64 {
        return UInt64(UInt32.max)
    }

    init(_ tableType: TableType, resourceLimiter: any ResourceLimiter) throws {
        let emptyElement: Reference
        switch tableType.elementType.heapType {
        case .funcRef:
            emptyElement = .function(nil)
        case .externRef:
            emptyElement = .extern(nil)
        }

        let numberOfElements = Int(tableType.limits.min)
        guard try resourceLimiter.limitTableGrowth(to: numberOfElements) else {
            throw Trap(.initialTableSizeExceedsLimit(numberOfElements: numberOfElements))
        }
        elements = Array(repeating: emptyElement, count: numberOfElements)
        self.tableType = tableType
    }

    /// > Note: https://webassembly.github.io/spec/core/exec/modules.html#grow-table
    /// Returns true if gorwth succeeds, otherwise returns false
    mutating func grow(by growthSize: UInt64, value: Reference, resourceLimiter: any ResourceLimiter) throws -> Bool {
        let oldSize = UInt64(elements.count)
        guard !UInt64(elements.count).addingReportingOverflow(growthSize).overflow else {
            return false
        }

        let maxLimit = limits.max ?? (limits.isMemory64 ? UInt64.max : UInt64(UInt32.max))

        let newSize = oldSize + growthSize
        if newSize > maxLimit {
            return false
        }
        guard try resourceLimiter.limitTableGrowth(to: Int(newSize)) else {
            return false
        }
        elements.append(contentsOf: Array(repeating: value, count: Int(growthSize)))
        return true
    }

    mutating func initialize(_ segment: InternalElementSegment, from source: Int, to destination: Int, count: Int) throws {
        try self.initialize(segment.references, from: source, to: destination, count: count)
    }

    mutating func initialize(_ references: [Reference], from source: Int, to destination: Int, count: Int) throws {
        let (destinationEnd, destinationOverflow) = destination.addingReportingOverflow(count)
        let (sourceEnd, sourceOverflow) = source.addingReportingOverflow(count)

        guard !destinationOverflow, destinationEnd <= elements.count else {
            throw Trap(.tableOutOfBounds(destinationEnd))
        }
        guard !sourceOverflow, sourceEnd <= references.count else {
            throw Trap(.tableOutOfBounds(sourceEnd))
        }

        elements.withUnsafeMutableBufferPointer { table in
            references.withUnsafeBufferPointer { segment in
                _ = table[destination..<destination + count].initialize(from: segment[source..<source + count])
            }
        }
    }

    mutating func fill(repeating value: Reference, from index: Int, count: Int) throws {
        let (end, overflow) = index.addingReportingOverflow(count)
        guard !overflow, end <= elements.count else { throw Trap(.tableOutOfBounds(end)) }

        elements.withUnsafeMutableBufferPointer {
            $0[index..<index + count].initialize(repeating: value)
        }
    }

    static func copy(
        _ sourceTable: UnsafeBufferPointer<Reference>,
        _ destinationTable: UnsafeMutableBufferPointer<Reference>,
        from source: Int, to destination: Int, count: Int
    ) throws {
        let (destinationEnd, destinationOverflow) = destination.addingReportingOverflow(count)
        let (sourceEnd, sourceOverflow) = source.addingReportingOverflow(count)

        guard !destinationOverflow, destinationEnd <= destinationTable.count else {
            throw Trap(.tableOutOfBounds(Int(destinationEnd)))
        }
        guard !sourceOverflow, sourceEnd <= sourceTable.count else {
            throw Trap(.tableOutOfBounds(Int(sourceEnd)))
        }

        let source = UnsafeBufferPointer(rebasing: sourceTable[source..<source + count])
        let destination = UnsafeMutableBufferPointer(rebasing: destinationTable[destination..<destination + count])

        // Note: Do not use `UnsafeMutableBufferPointer.update(from:)` overload here because it does not
        // provide the same semantics as `memmove` for overlapping memory regions.
        // TODO: We can optimize this to use `memcpy` if the source and destination tables are known to be different
        // at translation time.
        _ = destination.update(fromContentsOf: source)
    }
}

extension TableEntity: ValidatableEntity {
    static func createOutOfBoundsError(index: Int, count: Int) -> Error {
        ValidationError(.indexOutOfBounds("table", index, max: count))
    }
}

typealias InternalTable = EntityHandle<TableEntity>

extension InternalTable {
    func copy(_ sourceTable: InternalTable, from source: Int, to destination: Int, count: Int) throws {
        // Check if the source and destination tables are the same for dynamic exclusive
        // access enforcement
        if self == sourceTable {
            try withValue {
                try $0.elements.withUnsafeMutableBufferPointer {
                    try TableEntity.copy(UnsafeBufferPointer($0), $0, from: source, to: destination, count: count)
                }
            }
        } else {
            try withValue { destinationTable in
                try sourceTable.withValue { sourceTable in
                    try destinationTable.elements.withUnsafeMutableBufferPointer { dest in
                        try sourceTable.elements.withUnsafeBufferPointer { src in
                            try TableEntity.copy(src, dest, from: source, to: destination, count: count)
                        }
                    }
                }
            }
        }
    }
}

/// A WebAssembly `table` instance.
/// > Note:
/// <https://webassembly.github.io/spec/core/exec/runtime.html#table-instances>
public struct Table: Equatable {
    let handle: InternalTable
    let allocator: StoreAllocator

    init(handle: InternalTable, allocator: StoreAllocator) {
        self.handle = handle
        self.allocator = allocator
    }

    /// Creates a new WebAssembly `table` instance with the given type.
    ///
    /// - Parameters:
    ///   - store: The store that to allocate the global instance in.
    ///   - type: The type of the table instance.
    /// - Throws: `Trap` if the initial and maximum table size exceeds the resource limit.
    ///
    /// ```swift
    /// let engine = Engine()
    /// let store = Store(engine: engine)
    /// let tableType = TableType(elementType: .funcRef, limits: Limits(min: 1))
    /// let table = try Table(store: store, type: tableType)
    ///
    /// let module = try parseWasm(
    ///     bytes: try wat2wasm(#"(module (table (import "env" "table") 1 funcref))"#)
    /// )
    /// let imports: Imports = ["env": ["table": table]]
    /// let instance = try module.instantiate(store: store, imports: imports)
    /// ```
    public init(store: Store, type: TableType) throws {
        self.init(
            handle: try store.allocator.allocate(tableType: type, resourceLimiter: store.resourceLimiter),
            allocator: store.allocator
        )
    }

    /// The type of the table instance.
    public var type: TableType {
        handle.tableType
    }

    /// Accesses the element at the given index.
    public subscript(index: Int) -> Reference {
        get { handle.elements[index] }
        nonmutating set { handle.withValue { $0.elements[index] = newValue } }
    }
}

struct MemoryEntity /* : ~Copyable */ {
    static let pageSize = 64 * 1024

    static func maxPageCount(isMemory64: Bool) -> UInt64 {
        isMemory64 ? UInt64.max : UInt64(1 << 32) / UInt64(pageSize)
    }

    var data: [UInt8]
    let maxPageCount: UInt64
    let limit: Limits

    init(_ memoryType: MemoryType, resourceLimiter: any ResourceLimiter) throws {
        let byteSize = Int(memoryType.min) * Self.pageSize
        guard try resourceLimiter.limitMemoryGrowth(to: byteSize) else {
            throw Trap(.initialMemorySizeExceedsLimit(byteSize: byteSize))
        }
        data = Array(repeating: 0, count: byteSize)
        let defaultMaxPageCount = Self.maxPageCount(isMemory64: memoryType.isMemory64)
        maxPageCount = memoryType.max ?? defaultMaxPageCount
        limit = memoryType
    }

    /// > Note:
    /// <https://webassembly.github.io/spec/core/exec/modules.html#grow-mem>
    mutating func grow(by pageCount: Int, resourceLimiter: any ResourceLimiter) throws -> Value {
        let newPageCount = data.count / Self.pageSize + pageCount

        guard newPageCount <= maxPageCount else {
            return limit.isMemory64 ? .i64((-1 as Int64).unsigned) : .i32((-1 as Int32).unsigned)
        }
        guard try resourceLimiter.limitMemoryGrowth(to: newPageCount * Self.pageSize) else {
            return limit.isMemory64 ? .i64((-1 as Int64).unsigned) : .i32((-1 as Int32).unsigned)
        }

        let result = Int32(data.count / MemoryEntity.pageSize).unsigned
        data.append(contentsOf: Array(repeating: 0, count: Int(pageCount) * MemoryEntity.pageSize))

        return limit.isMemory64 ? .i64(UInt64(result)) : .i32(result)
    }

    mutating func copy(from source: UInt64, to destination: UInt64, count: UInt64) throws {
        let (destinationEnd, destinationOverflow) = destination.addingReportingOverflow(count)
        let (sourceEnd, sourceOverflow) = source.addingReportingOverflow(count)

        guard !destinationOverflow, destinationEnd <= data.count,
            !sourceOverflow, sourceEnd <= data.count
        else {
            throw Trap(.memoryOutOfBounds)
        }
        data.withUnsafeMutableBufferPointer {
            guard let base = UnsafeMutableRawPointer($0.baseAddress) else { return }
            let dest = base.advanced(by: Int(destination))
            let src = base.advanced(by: Int(source))
            dest.copyMemory(from: src, byteCount: Int(count))
        }
    }

    mutating func initialize(_ segment: InternalDataSegment, from source: UInt32, to destination: UInt64, count: UInt32) throws {
        let (destinationEnd, destinationOverflow) = destination.addingReportingOverflow(UInt64(count))
        let (sourceEnd, sourceOverflow) = source.addingReportingOverflow(count)

        guard !destinationOverflow, destinationEnd <= data.count,
            !sourceOverflow, sourceEnd <= segment.data.count
        else {
            throw Trap(.memoryOutOfBounds)
        }
        data.withUnsafeMutableBufferPointer { memory in
            segment.data.withUnsafeBufferPointer { segment in
                guard
                    let memory = UnsafeMutableRawPointer(memory.baseAddress),
                    let segment = UnsafeRawPointer(segment.baseAddress)
                else { return }
                let dest = memory.advanced(by: Int(destination))
                let src = segment.advanced(by: Int(source))
                dest.copyMemory(from: src, byteCount: Int(count))
            }
        }
    }

    mutating func write(offset: Int, bytes: ArraySlice<UInt8>) throws {
        let endOffset = offset + bytes.count
        guard endOffset <= data.count else {
            throw Trap(.memoryOutOfBounds)
        }
        data[offset..<endOffset] = bytes
    }
}

extension MemoryEntity: ValidatableEntity {
    static func createOutOfBoundsError(index: Int, count: Int) -> Error {
        ValidationError(.indexOutOfBounds("memory", index, max: count))
    }
}

typealias InternalMemory = EntityHandle<MemoryEntity>

/// A WebAssembly `memory` instance.
/// > Note:
/// <https://webassembly.github.io/spec/core/exec/runtime.html#memory-instances>
public struct Memory: Equatable {
    let handle: InternalMemory
    let allocator: StoreAllocator

    init(handle: InternalMemory, allocator: StoreAllocator) {
        self.handle = handle
        self.allocator = allocator
    }

    /// Creates a new WebAssembly `memory` instance with the given type.
    ///
    /// - Parameters:
    ///   - store: The store that to allocate the global instance in.
    ///   - type: The type of the memory instance.
    /// - Throws: `Trap` if the initial and maximum memory size exceeds the resource limit.
    ///
    /// ```swift
    /// import WasmKit
    /// import WAT
    ///
    /// let engine = Engine()
    /// let store = Store(engine: engine)
    /// let memoryType = MemoryType(min: 1, max: nil)
    /// let memory = try Memory(store: store, type: memoryType)
    ///
    /// let module = try parseWasm(
    ///     bytes: try wat2wasm(#"(module (memory (import "env" "memory") 1))"#)
    /// )
    /// let imports: Imports = ["env": ["memory": memory]]
    /// let instance = try module.instantiate(store: store, imports: imports)
    /// ```
    public init(store: Store, type: MemoryType) throws {
        // Validate the memory type because the type is not validated at instantiation time.
        try ModuleValidator.checkMemoryType(type, features: store.engine.configuration.features)

        self.init(
            handle: try store.allocator.allocate(memoryType: type, resourceLimiter: store.resourceLimiter),
            allocator: store.allocator
        )
    }

    /// Returns a copy of the memory data.
    public var data: [UInt8] {
        handle.data
    }

    /// The type of the memory instance.
    public var type: MemoryType {
        handle.limit
    }
}

extension Memory: GuestMemory {
    /// Executes the given closure with a mutable buffer pointer to the host memory region mapped as guest memory.
    public func withUnsafeMutableBufferPointer<T>(
        offset: UInt,
        count: Int,
        _ body: (UnsafeMutableRawBufferPointer) throws -> T
    ) rethrows -> T {
        try handle.withValue { memory in
            try memory.data.withUnsafeMutableBufferPointer { buffer in
                try body(UnsafeMutableRawBufferPointer(start: buffer.baseAddress! + Int(offset), count: count))
            }
        }
    }
}

/// An entity representing a WebAssembly `global` instance storage.
struct GlobalEntity /* : ~Copyable */ {
    var rawValue: UntypedValue
    var value: Value {
        get { rawValue.cast(to: globalType.valueType) }
        set { rawValue = UntypedValue(newValue) }
    }
    let globalType: GlobalType

    init(globalType: GlobalType, initialValue: Value) throws {
        try initialValue.checkType(globalType.valueType)
        rawValue = UntypedValue(initialValue)
        self.globalType = globalType
    }
}

extension GlobalEntity: ValidatableEntity {
    static func createOutOfBoundsError(index: Int, count: Int) -> Error {
        ValidationError(.indexOutOfBounds("global", index, max: count))
    }
}

typealias InternalGlobal = EntityHandle<GlobalEntity>

/// A WebAssembly `global` instance.
/// > Note:
/// <https://webassembly.github.io/spec/core/exec/runtime.html#global-instances>
public struct Global: Equatable {
    let handle: InternalGlobal
    let allocator: StoreAllocator

    /// The value of the global instance.
    public var value: Value {
        handle.value
    }

    /// Assigns a new value to the global instance.
    ///
    /// - Parameter value: The new value to assign.
    /// - Throws: `Trap` if the global is immutable.
    public func assign(_ value: Value) throws {
        try handle.withValue { global in
            guard global.globalType.mutability == .variable else {
                throw Trap(.cannotAssignToImmutableGlobal)
            }
            global.value = value
        }
    }

    init(handle: InternalGlobal, allocator: StoreAllocator) {
        self.handle = handle
        self.allocator = allocator
    }

    /// Initializes a new global instance with the given type and initial value.
    /// The returned global instance may be used to instantiate a new
    /// WebAssembly module.
    @available(*, deprecated, renamed: "init(store:type:value:)")
    public init(globalType: GlobalType, initialValue: Value, store: Store) {
        try! self.init(store: store, type: globalType, value: initialValue)
    }

    /// Create a new WebAssembly `global` instance.
    ///
    /// - Parameters:
    ///   - store: The store that to allocate the global instance in.
    ///   - type: The type of the global instance.
    ///   - value: Initial value of the global instance.
    /// - Throws: `Trap` if the initial value does not match the global type.
    ///
    /// ```swift
    /// import WasmKit
    /// import WAT
    ///
    /// let engine = Engine()
    /// let store = Store(engine: engine)
    /// let globalType = GlobalType(mutability: .constant, valueType: .i32)
    /// let i32Global = try Global(store: store, type: globalType, value: .i32(42))
    ///
    /// let module = try parseWasm(
    ///     bytes: try wat2wasm(#"(module (global (import "env" "i32-global") i32))"#)
    /// )
    /// let imports: Imports = ["env": ["i32-global": i32Global]]
    /// let instance = try module.instantiate(store: store, imports: imports)
    /// ```
    public init(store: Store, type: GlobalType, value: Value) throws {
        let handle = try store.allocator.allocate(globalType: type, initialValue: value)
        self.init(handle: handle, allocator: store.allocator)
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/exec/runtime.html#element-instances>
struct ElementSegmentEntity {
    let type: ReferenceType
    var references: [Reference]

    mutating func drop() {
        self.references = []
    }
}

extension ElementSegmentEntity: ValidatableEntity {
    static func createOutOfBoundsError(index: Int, count: Int) -> Error {
        ValidationError(.indexOutOfBounds("element", index, max: count))
    }
}

typealias InternalElementSegment = EntityHandle<ElementSegmentEntity>

/// > Note:
/// <https://webassembly.github.io/spec/core/exec/runtime.html#syntax-datainst>
struct DataSegmentEntity {
    /// Bytes stored in this data instance.
    let data: ArraySlice<UInt8>

    mutating func drop() {
        self = DataSegmentEntity(data: [])
    }
}

typealias InternalDataSegment = EntityHandle<DataSegmentEntity>

/// > Note:
/// <https://webassembly.github.io/spec/core/exec/runtime.html#syntax-externval>
public enum ExternalValue: Equatable {
    case function(Function)
    case table(Table)
    case memory(Memory)
    case global(Global)

    init(handle: InternalExternalValue, store: Store) {
        switch handle {
        case .function(let function):
            self = .function(Function(handle: function, store: store))
        case .table(let table):
            self = .table(Table(handle: table, allocator: store.allocator))
        case .memory(let memory):
            self = .memory(Memory(handle: memory, allocator: store.allocator))
        case .global(let global):
            self = .global(Global(handle: global, allocator: store.allocator))
        }
    }

    func internalize() -> (InternalExternalValue, StoreAllocator) {
        switch self {
        case .function(let function):
            return (.function(function.handle), function.store.allocator)
        case .table(let table):
            return (.table(table.handle), table.allocator)
        case .memory(let memory):
            return (.memory(memory.handle), memory.allocator)
        case .global(let global):
            return (.global(global.handle), global.allocator)
        }
    }
}

enum InternalExternalValue {
    case function(InternalFunction)
    case table(InternalTable)
    case memory(InternalMemory)
    case global(InternalGlobal)
}

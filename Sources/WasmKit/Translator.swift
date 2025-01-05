import WasmParser
import WasmTypes

class ISeqAllocator {

    private var buffers: [UnsafeMutableRawBufferPointer] = []

    func allocateBrTable(capacity: Int) -> UnsafeMutableBufferPointer<Instruction.BrTableOperand.Entry> {
        assert(_isPOD(Instruction.BrTableOperand.Entry.self), "Instruction.BrTableOperand.Entry must be POD")
        let buffer = UnsafeMutableBufferPointer<Instruction.BrTableOperand.Entry>.allocate(capacity: capacity)
        self.buffers.append(UnsafeMutableRawBufferPointer(buffer))
        return buffer
    }

    func allocateConstants(_ slots: [UntypedValue]) -> UnsafeBufferPointer<UntypedValue> {
        let buffer = UnsafeMutableBufferPointer<UntypedValue>.allocate(capacity: slots.count)
        _ = buffer.initialize(fromContentsOf: slots)
        self.buffers.append(UnsafeMutableRawBufferPointer(buffer))
        return UnsafeBufferPointer(buffer)
    }

    func allocateInstructions(capacity: Int) -> UnsafeMutableBufferPointer<UInt64> {
        assert(_isPOD(Instruction.self), "Instruction must be POD")
        let buffer = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: capacity)
        self.buffers.append(UnsafeMutableRawBufferPointer(buffer))
        return buffer
    }

    deinit {
        for buffer in buffers {
            buffer.deallocate()
        }
    }
}

protocol TranslatorContext {
    func resolveType(_ index: TypeIndex) throws -> FunctionType
    func resolveBlockType(_ blockType: BlockType) throws -> FunctionType
    func functionType(_ index: FunctionIndex, interner: Interner<FunctionType>) throws -> FunctionType
    func globalType(_ index: GlobalIndex) throws -> ValueType
    func isMemory64(memoryIndex index: MemoryIndex) throws -> Bool
    func isMemory64(tableIndex index: TableIndex) throws -> Bool
    func tableType(_ index: TableIndex) throws -> TableType
    func elementType(_ index: ElementIndex) throws -> ReferenceType
    func resolveCallee(_ index: FunctionIndex) -> InternalFunction?
    func isSameInstance(_ instance: InternalInstance) -> Bool
    func resolveGlobal(_ index: GlobalIndex) -> InternalGlobal?
    func validateFunctionIndex(_ index: FunctionIndex) throws
    var dataCount: UInt32? { get }
}

extension TranslatorContext {
    func addressType(memoryIndex: MemoryIndex) throws -> ValueType {
        return ValueType.addressType(isMemory64: try isMemory64(memoryIndex: memoryIndex))
    }
    func addressType(tableIndex: TableIndex) throws -> ValueType {
        return ValueType.addressType(isMemory64: try isMemory64(tableIndex: tableIndex))
    }
    func validateElementSegment(_ index: ElementIndex) throws {
        _ = try elementType(index)
    }
}

extension InternalInstance: TranslatorContext {
    func resolveType(_ index: TypeIndex) throws -> FunctionType {
        guard Int(index) < self.types.count else {
            throw ValidationError(.indexOutOfBounds("type", index, max: UInt32(self.types.count)))
        }
        return self.types[Int(index)]
    }
    func resolveBlockType(_ blockType: BlockType) throws -> FunctionType {
        try FunctionType(blockType: blockType, typeSection: self.types)
    }
    func functionType(_ index: FunctionIndex, interner: Interner<FunctionType>) throws -> FunctionType {
        return try interner.resolve(self.functions[validating: Int(index)].type)
    }
    func globalType(_ index: GlobalIndex) throws -> ValueType {
        return try self.globals[validating: Int(index)].globalType.valueType
    }
    func isMemory64(memoryIndex index: MemoryIndex) throws -> Bool {
        return try self.memories[validating: Int(index)].limit.isMemory64
    }
    func isMemory64(tableIndex index: TableIndex) throws -> Bool {
        return try self.tables[validating: Int(index)].limits.isMemory64
    }
    func tableType(_ index: TableIndex) throws -> TableType {
        return try self.tables[validating: Int(index)].tableType
    }
    func elementType(_ index: ElementIndex) throws -> ReferenceType {
        try self.elementSegments[validating: Int(index)].type
    }

    func resolveCallee(_ index: FunctionIndex) -> InternalFunction? {
        return self.functions[Int(index)]
    }
    func resolveGlobal(_ index: GlobalIndex) -> InternalGlobal? {
        return self.globals[Int(index)]
    }
    func isSameInstance(_ instance: InternalInstance) -> Bool {
        return instance == self
    }
    func validateFunctionIndex(_ index: FunctionIndex) throws {
        let function = try self.functions[validating: Int(index)]
        guard self.functionRefs.contains(function) else {
            throw ValidationError(.functionIndexNotDeclared(index: index))
        }
    }
    var dataCount: UInt32? {
        self.withValue { $0.dataCount }
    }
}

private struct MetaProgramCounter {
    let offsetFromHead: Int
}

/// The layout of the function stack frame.
///
/// A function call frame starts with a "frame header" which contains
/// the function parameters and the result values. The size of the frame
/// header is determined by the maximum number of parameters and results
/// of the function type. While executing the function, the frame header
/// is used as a storage for parameters. On function return, the frame
/// header is used as a storage for the result values.
///
/// On function entry, the stack frame looks like:
///
/// ```
/// | Offset                             | Description          |
/// |------------------------------------|----------------------|
/// | 0                                  | Function parameter 0 |
/// | 1                                  | Function parameter 1 |
/// | ...                                | ...                  |
/// | len(params)-1                      | Function parameter N |
/// ```
///
/// On function return, the stack frame looks like:
/// ```
/// | Offset                             | Description          |
/// |------------------------------------|----------------------|
/// | 0                                  | Function result 0    |
/// | 1                                  | Function result 1    |
/// | ...                                | ...                  |
/// | len(results)-1                     | Function result N    |
/// ```
///
/// The end of the frame header is usually referred to as "stack pointer"
/// (SP). "local" variables and the value stack space are allocated after
/// the frame header. The value stack space is used to store intermediate
/// values usually corresponding to Wasm's value stack. Unlike the Wasm's
/// value stack, a value slot in the value stack space might be absent if
/// the value is backed by a local variable.
/// The slot index is referred to as "register". The register index is
/// relative to the stack pointer, so the register indices for parameters
/// and results are negative.
///
/// ```
/// | Offset                             | Description          |
/// |------------------------------------|----------------------|
/// | SP-(max(params, results)+3)        | Param/result slots   |------+
/// | ...                                | ...                  |      |
/// | SP-3                               | Saved Instance       |  Frame header
/// | SP-2                               | Saved PC             |      |
/// | SP-1                               | Saved SP             |------+
/// | SP+0                               | Local variable 0     |
/// | SP+1                               | Local variable 1     |
/// | ...                                | ...                  |
/// | SP+len(locals)-1                   | Local variable N     |
/// | SP+len(locals)                     | Const 0              |
/// | SP+len(locals)+1                   | Const 1              |
/// | ...                                | ...                  |
/// | SP+len(locals)+C                   | Const C              |
/// | SP+len(locals)+C                   | Value stack 0        |
/// | SP+len(locals)+C+1                 | Value stack 1        |
/// | ...                                | ...                  |
/// | SP+len(locals)+C+heighest(stack)-1 | Value stack N        |
/// ```
/// where `C` is the number of constant slots.
///
/// ## Example
///
/// Consider the following Wasm function:
///
/// ```wat
/// (func (param i32 i32) (result i32)
///   (local i32)
///   (local i64)
///   (local.set 2 (i32.add (local.get 0) (i32.const 42)))
///   (return (local.get 2))
/// )
/// ```
///
/// Then the stack frame layout looks like:
///
/// ```
/// | Offset                             | Description          |
/// |------------------------------------|----------------------|
/// | -5                                 | Param 0 / Result 0   |------+
/// | -4                                 | Param 1              |      |
/// | -3                                 | Saved Instance       |  Frame header
/// | -2                                 | Saved PC             |      |
/// | -1                                 | Saved SP             |------+
/// | 0                                  | Local 0 (i32)        |
/// | 1                                  | Local 1 (i64)        |
/// | 2                                  | Const 0 (i32:42)     |
/// ```

struct FrameHeaderLayout {
    let type: FunctionType
    let size: VReg

    init(type: FunctionType) {
        self.type = type
        self.size = Self.size(of: type)
    }

    func paramReg(_ index: Int) -> VReg {
        VReg(index) - size
    }

    func returnReg(_ index: Int) -> VReg {
        return VReg(index) - size
    }

    internal static func size(of: FunctionType) -> VReg {
        size(parameters: of.parameters.count, results: of.results.count)
    }
    internal static func size(parameters: Int, results: Int) -> VReg {
        VReg(max(parameters, results)) + VReg(numberOfSavingSlots)
    }
    /// The number of slots used to save the current instance, PC, and SP
    internal static var numberOfSavingSlots: Int { 3 }
}

struct StackLayout {
    let frameHeader: FrameHeaderLayout
    let constantSlotSize: Int
    let numberOfLocals: Int

    var stackRegBase: VReg {
        return VReg(numberOfLocals + constantSlotSize)
    }

    init(type: FunctionType, numberOfLocals: Int, codeSize: Int) throws {
        self.frameHeader = FrameHeaderLayout(type: type)
        self.numberOfLocals = numberOfLocals
        // The number of constant slots is determined by the code size
        // This is a heuristic value to balance the fast access to constants
        // and the size of stack frame. Cap the slot size to avoid size explosion.
        self.constantSlotSize = min(max(codeSize / 20, 4), 128)
        let (maxSlots, overflow) = self.constantSlotSize.addingReportingOverflow(numberOfLocals)
        guard !overflow, maxSlots < VReg.max else {
            throw TranslationError("The number of constant slots overflows")
        }
    }

    func localReg(_ index: LocalIndex) -> VReg {
        if isParameter(index) {
            return frameHeader.paramReg(Int(index))
        } else {
            return VReg(index) - VReg(frameHeader.type.parameters.count)
        }
    }

    func isParameter(_ index: LocalIndex) -> Bool {
        index < frameHeader.type.parameters.count
    }

    func constReg(_ index: Int) -> VReg {
        return VReg(numberOfLocals + index)
    }

    func dump<Target: TextOutputStream>(to target: inout Target, iseq: InstructionSequence) {
        let frameHeaderSize = FrameHeaderLayout.size(of: frameHeader.type)
        let slotMinIndex = VReg(-frameHeaderSize)
        let slotMaxIndex = VReg(stackRegBase - 1)
        let slotIndexWidth = max(String(slotMinIndex).count, String(slotMaxIndex).count)
        func writeSlot(_ target: inout Target, _ index: VReg, _ description: String) {
            var index = String(index)
            index = String(repeating: " ", count: slotIndexWidth - index.count) + index

            target.write(" [\(index)] \(description)\n")
        }
        func hex(_ value: UInt64) -> String {
            let value = String(value, radix: 16)
            return String(repeating: "0", count: 16 - value.count) + value
        }

        let savedItems: [String] = ["Instance", "Pc", "Sp"]
        for i in 0..<frameHeaderSize - VReg(savedItems.count) {
            var descriptions: [String] = []
            if i < frameHeader.type.parameters.count {
                descriptions.append("Param \(i)")
            }
            if i < frameHeader.type.results.count {
                descriptions.append("Result \(i)")
            }
            writeSlot(&target, VReg(i - frameHeaderSize), descriptions.joined(separator: ", "))
        }

        for (i, name) in savedItems.enumerated() {
            writeSlot(&target, VReg(i - savedItems.count), "Saved \(name)")
        }

        for i in 0..<numberOfLocals {
            writeSlot(&target, VReg(i), "Local \(i)")
        }
        for i in 0..<iseq.constants.count {
            writeSlot(&target, VReg(numberOfLocals + i), "Const \(i) = \(iseq.constants[i])")
        }
    }
}

struct InstructionTranslator<Context: TranslatorContext>: InstructionVisitor {
    typealias Output = Void

    typealias LabelRef = Int
    typealias ValueType = WasmTypes.ValueType

    struct ControlStack {
        typealias BlockType = FunctionType

        struct ControlFrame {
            enum Kind {
                case block(root: Bool)
                case loop
                case `if`(elseLabel: LabelRef, endLabel: LabelRef, isElse: Bool)

                static var block: Kind { .block(root: false) }
            }

            let blockType: BlockType
            /// The height of `ValueStack` without including the frame parameters
            let stackHeight: Int
            let continuation: LabelRef
            var kind: Kind
            var reachable: Bool = true

            var copyTypes: [ValueType] {
                switch self.kind {
                case .block, .if:
                    return blockType.results
                case .loop:
                    return blockType.parameters
                }
            }
            var copyCount: UInt16 {
                return UInt16(copyTypes.count)
            }
        }

        private var frames: [ControlFrame] = []

        var numberOfFrames: Int { frames.count }

        mutating func pushFrame(_ frame: ControlFrame) {
            self.frames.append(frame)
        }

        mutating func popFrame() -> ControlFrame? {
            self.frames.popLast()
        }

        mutating func markUnreachable() throws {
            try setReachability(false)
        }
        mutating func resetReachability() throws {
            try setReachability(true)
        }

        private mutating func setReachability(_ value: Bool) throws {
            guard !self.frames.isEmpty else {
                throw ValidationError(.controlStackEmpty)
            }
            self.frames[self.frames.count - 1].reachable = value
        }

        func currentFrame() throws -> ControlFrame {
            guard let frame = self.frames.last else {
                throw ValidationError(.controlStackEmpty)
            }
            return frame
        }

        func branchTarget(relativeDepth: UInt32) throws -> ControlFrame {
            let index = frames.count - 1 - Int(relativeDepth)
            guard frames.indices.contains(index) else {
                throw ValidationError(.relativeDepthOutOfRange(relativeDepth: relativeDepth))
            }
            return frames[index]
        }
    }

    enum MetaValue: Equatable {
        case some(ValueType)
        case unknown
    }

    enum MetaValueOnStack {
        case local(ValueType, LocalIndex)
        case stack(MetaValue)
        case const(ValueType, Int)

        var type: MetaValue {
            switch self {
            case .local(let type, _): return .some(type)
            case .stack(let type): return type
            case .const(let type, _): return .some(type)
            }
        }
    }

    enum ValueSource {
        case vreg(VReg)
        case const(Int, ValueType)
        case local(LocalIndex)
    }

    struct ValueStack {
        private var values: [MetaValueOnStack] = []
        /// The maximum height of the stack within the function
        private(set) var maxHeight: Int = 0
        var height: Int { values.count }
        let stackRegBase: VReg
        let stackLayout: StackLayout

        init(stackLayout: StackLayout) {
            self.stackRegBase = stackLayout.stackRegBase
            self.stackLayout = stackLayout
        }

        mutating func push(_ value: ValueType) -> VReg {
            push(.some(value))
        }
        mutating func push(_ value: MetaValue) -> VReg {
            // Record the maximum height of the stack we have seen
            maxHeight = max(maxHeight, height)
            let usedRegister = self.values.count
            self.values.append(.stack(value))
            assert(height < UInt16.max)
            return stackRegBase + VReg(usedRegister)
        }
        mutating func pushLocal(_ localIndex: LocalIndex, locals: inout Locals) throws {
            let type = try locals.type(of: localIndex)
            self.values.append(.local(type, localIndex))
        }
        mutating func pushConst(_ index: Int, type: ValueType) {
            assert(index < stackLayout.constantSlotSize)
            self.values.append(.const(type, index))
        }
        mutating func preserveLocalsOnStack(_ localIndex: LocalIndex) -> [VReg] {
            var copyTo: [VReg] = []
            for i in 0..<values.count {
                guard case .local(let type, localIndex) = self.values[i] else { continue }
                self.values[i] = .stack(.some(type))
                copyTo.append(stackRegBase + VReg(i))
            }
            return copyTo
        }

        mutating func preserveLocalsOnStack(depth: Int) -> [(source: LocalIndex, to: VReg)] {
            var copies: [(source: LocalIndex, to: VReg)] = []
            for offset in 0..<min(depth, self.values.count) {
                let valueIndex = self.values.count - 1 - offset
                let value = self.values[valueIndex]
                guard case .local(let type, let localIndex) = value else { continue }
                self.values[valueIndex] = .stack(.some(type))
                copies.append((localIndex, self.stackRegBase + VReg(valueIndex)))
            }
            return copies
        }

        mutating func preserveConstsOnStack(depth: Int) -> [(source: VReg, to: VReg)] {
            var copies: [(source: VReg, to: VReg)] = []
            for offset in 0..<min(depth, self.values.count) {
                let valueIndex = self.values.count - 1 - offset
                let value = self.values[valueIndex]
                guard case .const(let type, let index) = value else { continue }
                self.values[valueIndex] = .stack(.some(type))
                copies.append((stackLayout.constReg(index), self.stackRegBase + VReg(valueIndex)))
            }
            return copies
        }

        func peek(depth: Int) -> ValueSource {
            return makeValueSource(self.values[height - 1 - depth])
        }

        func peekType(depth: Int) -> MetaValue {
            return self.values[height - 1 - depth].type
        }

        private func makeValueSource(_ value: MetaValueOnStack) -> ValueSource {
            let source: ValueSource
            switch value {
            case .local(_, let localIndex):
                source = .local(localIndex)
            case .stack:
                source = .vreg(stackRegBase + VReg(height))
            case .const(let type, let index):
                source = .const(index, type)
            }
            return source
        }

        mutating func pop() throws -> (MetaValue, ValueSource) {
            guard let value = self.values.popLast() else {
                throw TranslationError("Expected a value on stack but it's empty")
            }
            let source = makeValueSource(value)
            return (value.type, source)
        }
        mutating func pop(_ expected: ValueType) throws -> ValueSource {
            let (value, register) = try pop()
            switch value {
            case .some(let actual):
                guard actual == expected else {
                    throw TranslationError("Expected \(expected) on the stack top but got \(actual)")
                }
            case .unknown: break  // OK
            }
            return register
        }
        mutating func popRef() throws -> ValueSource {
            let (value, register) = try pop()
            switch value {
            case .some(let actual):
                guard case .ref = actual else {
                    throw TranslationError("Expected reference value on the stack top but got \(actual)")
                }
            case .unknown: break  // OK
            }
            return register
        }
        mutating func truncate(height: Int) throws {
            guard height <= self.height else {
                throw TranslationError("Truncating to \(height) but the stack height is \(self.height)")
            }
            while height != self.height {
                guard self.values.popLast() != nil else {
                    throw TranslationError("Internal consistency error: Stack height is \(self.height) but failed to pop")
                }
            }
        }
    }

    fileprivate struct ISeqBuilder {
        typealias InstructionFactoryWithLabel = (
            ISeqBuilder,
            // The position of the next slot of the creating instruction
            _ source: MetaProgramCounter,
            // The position of the resolved label
            _ target: MetaProgramCounter
        ) -> (WasmKit.Instruction)
        typealias BrTableEntryFactory = (ISeqBuilder, MetaProgramCounter) -> Instruction.BrTableOperand.Entry
        typealias BuildingBrTable = UnsafeMutableBufferPointer<Instruction.BrTableOperand.Entry>

        enum OnPinAction {
            case emitInstruction(
                insertAt: MetaProgramCounter,
                source: MetaProgramCounter,
                InstructionFactoryWithLabel
            )
            case fillBrTableEntry(
                buildingTable: BuildingBrTable,
                index: Int, make: BrTableEntryFactory
            )
        }
        struct LabelUser: CustomStringConvertible {
            let action: OnPinAction
            let sourceLine: UInt

            var description: String {
                "LabelUser:\(sourceLine)"
            }
        }
        enum LabelEntry {
            case unpinned(users: [LabelUser])
            case pinned(MetaProgramCounter)
        }

        typealias ResultRelink = (_ result: VReg) -> Instruction
        fileprivate struct LastEmission {
            let position: MetaProgramCounter
            let resultRelink: ResultRelink?
        }

        private var labels: [LabelEntry] = []
        private var unpinnedLabels: Set<LabelRef> = []
        private var instructions: [UInt64] = []
        private var lastEmission: LastEmission?
        fileprivate var insertingPC: MetaProgramCounter {
            MetaProgramCounter(offsetFromHead: instructions.count)
        }
        let engineConfiguration: EngineConfiguration

        init(engineConfiguration: EngineConfiguration) {
            self.engineConfiguration = engineConfiguration
        }

        func assertDanglingLabels() throws {
            for ref in unpinnedLabels {
                let label = labels[ref]
                switch label {
                case .unpinned(let users):
                    guard !users.isEmpty else { continue }
                    throw TranslationError("Internal consistency error: Label (#\(ref)) is used but not pinned at finalization-time: \(users)")
                case .pinned: break  // unreachable in theory
                }
            }
        }

        func trace(_ message: @autoclosure () -> String) {
            #if WASMKIT_TRANSLATOR_TRACE
                print(message())
            #endif
        }

        private mutating func assign(at index: Int, _ instruction: Instruction) {
            trace("assign: \(instruction)")
            let headSlot = instruction.headSlot(threadingModel: engineConfiguration.threadingModel)
            trace("        [\(index)] = 0x\(String(headSlot, radix: 16))")
            self.instructions[index] = headSlot
            if let immediate = instruction.rawImmediate {
                var slots: [CodeSlot] = []
                immediate.emit(to: { slots.append($0) })
                for (i, slot) in slots.enumerated() {
                    let slotIndex = index + 1 + i
                    trace("        [\(slotIndex)] = 0x\(String(slot, radix: 16))")
                    self.instructions[slotIndex] = slot
                }
            }
        }

        mutating func resetLastEmission() {
            lastEmission = nil
        }

        mutating func relinkLastInstructionResult(_ newResult: VReg) -> Bool {
            guard let lastEmission = self.lastEmission,
                let resultRelink = lastEmission.resultRelink
            else { return false }
            let newInstruction = resultRelink(newResult)
            assign(at: lastEmission.position.offsetFromHead, newInstruction)
            resetLastEmission()
            return true
        }

        private mutating func emitSlot(_ codeSlot: CodeSlot) {
            trace("emitSlot[\(instructions.count)]: 0x\(String(codeSlot, radix: 16))")
            self.instructions.append(codeSlot)
        }

        func dump() {
            for instruction in instructions {
                print(instruction)
            }
        }

        func finalize() -> [UInt64] {
            return instructions
        }

        mutating func emit(_ instruction: Instruction, resultRelink: ResultRelink? = nil) {
            self.lastEmission = LastEmission(position: insertingPC, resultRelink: resultRelink)
            trace("emitInstruction: \(instruction)")
            emitSlot(instruction.headSlot(threadingModel: engineConfiguration.threadingModel))
            if let immediate = instruction.rawImmediate {
                var slots: [CodeSlot] = []
                immediate.emit(to: { slots.append($0) })
                for slot in slots { emitSlot(slot) }
            }
        }

        mutating func putLabel() -> LabelRef {
            let ref = labels.count
            self.labels.append(.pinned(insertingPC))
            return ref
        }

        mutating func allocLabel() -> LabelRef {
            let ref = labels.count
            self.labels.append(.unpinned(users: []))
            self.unpinnedLabels.insert(ref)
            return ref
        }

        fileprivate func resolveLabel(_ ref: LabelRef) -> MetaProgramCounter? {
            let entry = self.labels[ref]
            switch entry {
            case .pinned(let pc): return pc
            case .unpinned: return nil
            }
        }

        fileprivate mutating func pinLabel(_ ref: LabelRef, pc: MetaProgramCounter) throws {
            switch self.labels[ref] {
            case .pinned(let oldPC):
                throw TranslationError("Internal consistency error: Label \(ref) is already pinned at \(oldPC), but tried to pin at \(pc) again")
            case .unpinned(let users):
                self.labels[ref] = .pinned(pc)
                self.unpinnedLabels.remove(ref)
                for user in users {
                    switch user.action {
                    case let .emitInstruction(insertAt, source, make):
                        assign(at: insertAt.offsetFromHead, make(self, source, pc))
                    case let .fillBrTableEntry(brTable, index, make):
                        brTable[index] = make(self, pc)
                    }
                }
            }
        }

        mutating func pinLabelHere(_ ref: LabelRef) throws {
            try pinLabel(ref, pc: insertingPC)
        }

        /// Emit an instruction at the current insertion point with resolved label position
        /// - Parameters:
        ///   - ref: Label reference to be resolved
        ///   - make: Factory closure to make an inserting instruction
        mutating func emitWithLabel<Immediate: InstructionImmediate>(
            _ makeInstruction: @escaping (Immediate) -> Instruction,
            _ ref: LabelRef,
            line: UInt = #line,
            make: @escaping (
                ISeqBuilder,
                // The position of the next slot of the creating instruction
                _ source: MetaProgramCounter,
                // The position of the resolved label
                _ target: MetaProgramCounter
            ) -> (Immediate)
        ) {
            let insertAt = insertingPC

            // Emit dummy instruction to be replaced later
            emitSlot(0)  // dummy opcode
            var immediateSlots = 0
            Immediate.emit(to: { _ in immediateSlots += 1 })
            for _ in 0..<immediateSlots { emitSlot(0) }

            // Schedule actual emission
            emitWithLabel(
                ref, insertAt: insertAt, line: line,
                make: {
                    makeInstruction(make($0, $1, $2))
                })
        }

        /// Emit an instruction at the specified position with resolved label position
        /// - Parameters:
        ///   - ref: Label reference to be resolved
        ///   - insertAt: Instruction sequence offset to insert at
        ///   - make: Factory closure to make an inserting instruction
        private mutating func emitWithLabel(
            _ ref: LabelRef, insertAt: MetaProgramCounter,
            line: UInt = #line, make: @escaping InstructionFactoryWithLabel
        ) {
            switch self.labels[ref] {
            case .pinned(let pc):
                assign(at: insertAt.offsetFromHead, make(self, insertingPC, pc))
            case .unpinned(var users):
                users.append(LabelUser(action: .emitInstruction(insertAt: insertAt, source: insertingPC, make), sourceLine: line))
                self.labels[ref] = .unpinned(users: users)
            }
        }

        /// Schedule to fill a br_table entry with the resolved label position
        /// - Parameters:
        ///   - ref: Label reference to be resolved
        ///   - table: Building br_table buffer
        ///   - index: Index of the entry to fill
        ///   - make: Factory closure to make an br_table entry
        mutating func fillBrTableEntry(
            _ ref: LabelRef,
            table: BuildingBrTable,
            index: Int, line: UInt = #line,
            make: @escaping BrTableEntryFactory
        ) {
            switch self.labels[ref] {
            case .pinned(let pc):
                table[index] = make(self, pc)
            case .unpinned(var users):
                users.append(LabelUser(action: .fillBrTableEntry(buildingTable: table, index: index, make: make), sourceLine: line))
                self.labels[ref] = .unpinned(users: users)
            }
        }
    }

    struct Locals {
        let types: [ValueType]

        var count: Int { types.count }

        func type(of localIndex: UInt32) throws -> ValueType {
            guard Int(localIndex) < types.count else {
                throw TranslationError("Local index \(localIndex) is out of range")
            }
            return self.types[Int(localIndex)]
        }
    }

    struct ConstSlots {
        private(set) var values: [UntypedValue]
        private var indexByValue: [UntypedValue: Int]
        let stackLayout: StackLayout

        init(stackLayout: StackLayout) {
            self.values = []
            self.indexByValue = [:]
            self.stackLayout = stackLayout
        }

        mutating func allocate(_ value: Value) -> Int? {
            let untyped = UntypedValue(value)
            if let allocated = indexByValue[untyped] {
                // NOTE: Share the same const slot for exactly the same bit pattern
                // values even having different types
                return allocated
            }
            guard values.count < stackLayout.constantSlotSize else { return nil }
            let constSlotIndex = values.count
            values.append(untyped)
            indexByValue[untyped] = constSlotIndex
            return constSlotIndex
        }
    }

    let allocator: ISeqAllocator
    let funcTypeInterner: Interner<FunctionType>
    let module: Context
    private var iseqBuilder: ISeqBuilder
    var controlStack: ControlStack
    var valueStack: ValueStack
    var locals: Locals
    let type: FunctionType
    let stackLayout: StackLayout
    /// The index of the function in the module
    let functionIndex: FunctionIndex
    /// Whether a call to this function should be intercepted
    let intercepting: Bool
    var constantSlots: ConstSlots
    let validator: InstructionValidator<Context>

    init(
        allocator: ISeqAllocator,
        engineConfiguration: EngineConfiguration,
        funcTypeInterner: Interner<FunctionType>,
        module: Context,
        type: FunctionType,
        locals: [WasmTypes.ValueType],
        functionIndex: FunctionIndex,
        codeSize: Int,
        intercepting: Bool
    ) throws {
        self.allocator = allocator
        self.funcTypeInterner = funcTypeInterner
        self.type = type
        self.module = module
        self.iseqBuilder = ISeqBuilder(engineConfiguration: engineConfiguration)
        self.controlStack = ControlStack()
        self.stackLayout = try StackLayout(
            type: type,
            numberOfLocals: locals.count,
            codeSize: codeSize
        )
        self.valueStack = ValueStack(stackLayout: stackLayout)
        self.locals = Locals(types: type.parameters + locals)
        self.functionIndex = functionIndex
        self.intercepting = intercepting
        self.constantSlots = ConstSlots(stackLayout: stackLayout)
        self.validator = InstructionValidator(context: module)

        do {
            let endLabel = self.iseqBuilder.allocLabel()
            let rootFrame = ControlStack.ControlFrame(
                blockType: type,
                stackHeight: 0,
                continuation: endLabel,
                kind: .block(root: true)
            )
            self.controlStack.pushFrame(rootFrame)
        }
    }

    private func returnReg(_ index: Int) -> VReg {
        return stackLayout.frameHeader.returnReg(index)
    }
    private func localReg(_ index: LocalIndex) -> VReg {
        return stackLayout.localReg(index)
    }

    private mutating func emit(_ instruction: Instruction, resultRelink: ISeqBuilder.ResultRelink? = nil) {
        iseqBuilder.emit(instruction, resultRelink: resultRelink)
    }

    @discardableResult
    private mutating func emitCopyStack(from source: VReg, to dest: VReg) -> Bool {
        guard source != dest else { return false }
        emit(.copyStack(Instruction.CopyStackOperand(source: LVReg(source), dest: LVReg(dest))))
        return true
    }

    private mutating func preserveOnStack(depth: Int) {
        preserveLocalsOnStack(depth: depth)
        for (source, dest) in valueStack.preserveConstsOnStack(depth: depth) {
            emitCopyStack(from: source, to: dest)
        }
    }

    private mutating func preserveLocalsOnStack(_ localIndex: LocalIndex) {
        for copyTo in valueStack.preserveLocalsOnStack(localIndex) {
            emitCopyStack(from: localReg(localIndex), to: copyTo)
        }
    }

    /// Emit copy instructions to ensure local variable values on the logical
    /// stack are on the physical stack.
    ///
    /// - Parameter depth: The depth of the logical stack to ensure the values
    ///   are on the physical stack.
    private mutating func preserveLocalsOnStack(depth: Int) {
        for (sourceLocal, destReg) in valueStack.preserveLocalsOnStack(depth: depth) {
            emitCopyStack(from: localReg(sourceLocal), to: destReg)
        }
    }

    /// Perform a precondition check for pop operation on value stack.
    ///
    /// - Parameter typeHint: A type expected to be popped. Only used for diagnostic purpose.
    /// - Returns: `true` if check succeed. `false` if the pop operation is going to be performed in unreachable code path.
    private func checkBeforePop(typeHint: ValueType?, depth: Int = 0, controlFrame: ControlStack.ControlFrame) throws -> Bool {
        if _slowPath(valueStack.height - depth <= controlFrame.stackHeight) {
            if controlFrame.reachable {
                throw ValidationError(.expectedTypeOnStackButEmpty(expected: typeHint))
            }
            // Too many pop on unreachable path is ignored
            return false
        }
        return true
    }
    private func checkBeforePop(typeHint: ValueType?, depth: Int = 0) throws -> Bool {
        let controlFrame = try controlStack.currentFrame()
        return try self.checkBeforePop(typeHint: typeHint, depth: depth, controlFrame: controlFrame)
    }
    private mutating func ensureOnVReg(_ source: ValueSource) -> VReg {
        // TODO: Copy to stack if source is on preg
        // let copyTo = valueStack.stackRegBase + VReg(valueStack.height)
        switch source {
        case .vreg(let register):
            return register
        case .local(let index):
            return stackLayout.localReg(index)
        case .const(let index, _):
            return stackLayout.constReg(index)
        }
    }
    private mutating func ensureOnStack(_ source: ValueSource) -> VReg {
        let copyTo = valueStack.stackRegBase + VReg(valueStack.height)
        switch source {
        case .vreg(let vReg):
            return vReg
        case .local(let localIndex):
            emitCopyStack(from: localReg(localIndex), to: copyTo)
            return copyTo
        case .const(let index, _):
            emitCopyStack(from: stackLayout.constReg(index), to: copyTo)
            return copyTo
        }
    }
    private mutating func popOperand(_ type: ValueType) throws -> ValueSource? {
        guard try checkBeforePop(typeHint: type) else {
            return nil
        }
        iseqBuilder.resetLastEmission()
        return try valueStack.pop(type)
    }

    private mutating func popOnStackOperand(_ type: ValueType) throws -> VReg? {
        guard let op = try popOperand(type) else { return nil }
        return ensureOnStack(op)
    }

    private mutating func popVRegOperand(_ type: ValueType) throws -> VReg? {
        guard let op = try popOperand(type) else { return nil }
        return ensureOnVReg(op)
    }

    private mutating func popAnyOperand() throws -> (MetaValue, ValueSource?) {
        guard try checkBeforePop(typeHint: nil) else {
            return (.unknown, nil)
        }
        iseqBuilder.resetLastEmission()
        return try valueStack.pop()
    }

    @discardableResult
    private mutating func popPushValues(_ valueTypes: [ValueType]) throws -> Int {
        var values: [ValueSource?] = []
        for type in valueTypes.reversed() {
            values.append(try popOperand(type))
        }
        let stackHeight = self.valueStack.height
        for (type, value) in zip(valueTypes, values.reversed()) {
            switch value {
            case .local(let localIndex):
                // Re-push local variables to the stack
                _ = try valueStack.pushLocal(localIndex, locals: &locals)
            case .vreg, nil:
                _ = valueStack.push(type)
            case .const(let index, let type):
                valueStack.pushConst(index, type: type)
            }
        }
        return stackHeight
    }

    private func checkStackTop(_ valueTypes: [ValueType]) throws {
        for (stackDepth, type) in valueTypes.reversed().enumerated() {
            guard try checkBeforePop(typeHint: type, depth: stackDepth) else { return }
            let actual = valueStack.peekType(depth: stackDepth)
            switch actual {
            case .some(let actualType):
                guard actualType == type else {
                    throw ValidationError(.expectedTypeOnStack(expected: type, actual: actualType))
                }
            case .unknown: break
            }
        }
    }

    private mutating func visitReturnLike() throws {
        try copyValuesIntoResultSlots(self.type.results, frameHeader: stackLayout.frameHeader)
    }

    /// Pop values from the stack and copy them to the return slots.
    ///
    /// - Parameter valueTypes: The types of the values to copy.
    private mutating func copyValuesIntoResultSlots(_ valueTypes: [ValueType], frameHeader: FrameHeaderLayout) throws {
        var copies: [(source: VReg, dest: VReg)] = []
        for (index, resultType) in valueTypes.enumerated().reversed() {
            guard let operand = try popOperand(resultType) else { continue }
            var source = ensureOnVReg(operand)
            if case .local(let localIndex) = operand, stackLayout.isParameter(localIndex) {
                // Parameter space is shared with return values, so we need to copy it to the stack
                // before copying to the return slot to avoid overwriting the parameter value.
                let copyTo = valueStack.stackRegBase + VReg(valueStack.height)
                emitCopyStack(from: localReg(localIndex), to: copyTo)
                source = copyTo
            }
            let dest = frameHeader.returnReg(index)
            copies.append((source, dest))
        }
        for (source, dest) in copies {
            emitCopyStack(from: source, to: dest)
        }
    }

    @discardableResult
    private mutating func copyOnBranch(targetFrame frame: ControlStack.ControlFrame) throws -> Bool {
        preserveOnStack(depth: min(Int(frame.copyCount), valueStack.height - frame.stackHeight))
        let copyCount = VReg(frame.copyCount)
        let sourceBase = valueStack.stackRegBase + VReg(valueStack.height)
        let destBase = valueStack.stackRegBase + VReg(frame.stackHeight)
        var emittedCopy = false
        for i in (0..<copyCount).reversed() {
            let source = sourceBase - 1 - VReg(i)
            let dest: VReg
            if case .block(root: true) = frame.kind {
                dest = returnReg(Int(copyCount - 1 - i))
            } else {
                dest = destBase + copyCount - 1 - VReg(i)
            }
            let copied = emitCopyStack(from: source, to: dest)
            emittedCopy = emittedCopy || copied
        }
        return emittedCopy
    }
    private mutating func translateReturn() throws {
        if intercepting {
            // Emit `onExit` instruction before every `return` instruction
            emit(.onExit(functionIndex))
        }
        try visitReturnLike()
        iseqBuilder.emit(._return)
    }
    private mutating func markUnreachable() throws {
        try controlStack.markUnreachable()
        let currentFrame = try controlStack.currentFrame()
        try valueStack.truncate(height: currentFrame.stackHeight)
    }

    private mutating func finalize() throws -> InstructionSequence {
        if controlStack.numberOfFrames > 1 {
            throw ValidationError(.expectedMoreEndInstructions(count: controlStack.numberOfFrames - 1))
        }
        // Check dangling labels
        try iseqBuilder.assertDanglingLabels()

        iseqBuilder.emit(._return)
        let instructions = iseqBuilder.finalize()
        // TODO: Figure out a way to avoid the copy here while keeping the execution performance.
        let buffer = allocator.allocateInstructions(capacity: instructions.count)
        for (idx, instruction) in instructions.enumerated() {
            buffer[idx] = instruction
        }
        let constants = allocator.allocateConstants(self.constantSlots.values)
        return InstructionSequence(
            instructions: buffer,
            maxStackHeight: Int(valueStack.stackRegBase) + valueStack.maxHeight,
            constants: constants
        )
    }

    // MARK: Main entry point

    /// Translate a Wasm expression into a sequence of instructions.
    mutating func translate(
        code: Code,
        instance: InternalInstance
    ) throws -> InstructionSequence {
        if intercepting {
            // Emit `onEnter` instruction at the beginning of the function
            emit(.onEnter(functionIndex))
        }
        var parser = ExpressionParser(code: code)
        var offset = parser.offset
        do {
            while try parser.visit(visitor: &self) {
                offset = parser.offset
            }
        } catch var error as ValidationError {
            error.offset = offset
            throw error
        }
        return try finalize()
    }

    // MARK: - Visitor

    mutating func visitUnreachable() throws -> Output {
        emit(.unreachable)
        try markUnreachable()
    }
    mutating func visitNop() -> Output { emit(.nop) }

    mutating func visitBlock(blockType: WasmParser.BlockType) throws -> Output {
        let blockType = try module.resolveBlockType(blockType)
        let endLabel = iseqBuilder.allocLabel()
        self.preserveLocalsOnStack(depth: self.valueStack.height)
        let stackHeight = try popPushValues(blockType.parameters)
        controlStack.pushFrame(ControlStack.ControlFrame(blockType: blockType, stackHeight: stackHeight, continuation: endLabel, kind: .block))
    }

    mutating func visitLoop(blockType: WasmParser.BlockType) throws -> Output {
        let blockType = try module.resolveBlockType(blockType)
        preserveOnStack(depth: blockType.parameters.count)
        iseqBuilder.resetLastEmission()
        for param in blockType.parameters.reversed() {
            _ = try popOperand(param)
        }
        let headLabel = iseqBuilder.putLabel()
        let stackHeight = self.valueStack.height
        for param in blockType.parameters {
            _ = valueStack.push(param)
        }
        controlStack.pushFrame(ControlStack.ControlFrame(blockType: blockType, stackHeight: stackHeight, continuation: headLabel, kind: .loop))
    }

    mutating func visitIf(blockType: WasmParser.BlockType) throws -> Output {
        // Pop condition value
        let condition = try popVRegOperand(.i32)
        let blockType = try module.resolveBlockType(blockType)
        self.preserveLocalsOnStack(depth: self.valueStack.height)
        preserveOnStack(depth: blockType.parameters.count)
        let endLabel = iseqBuilder.allocLabel()
        let elseLabel = iseqBuilder.allocLabel()
        for param in blockType.parameters.reversed() {
            _ = try popOperand(param)
        }
        let stackHeight = self.valueStack.height
        for param in blockType.parameters {
            _ = valueStack.push(param)
        }
        controlStack.pushFrame(
            ControlStack.ControlFrame(
                blockType: blockType, stackHeight: stackHeight, continuation: endLabel,
                kind: .if(elseLabel: elseLabel, endLabel: endLabel, isElse: false)
            )
        )
        guard let condition = condition else { return }
        iseqBuilder.emitWithLabel(Instruction.brIfNot, endLabel) { iseqBuilder, selfPC, endPC in
            let targetPC: MetaProgramCounter
            if let elsePC = iseqBuilder.resolveLabel(elseLabel) {
                targetPC = elsePC
            } else {
                targetPC = endPC
            }
            let elseOrEnd = UInt32(targetPC.offsetFromHead - selfPC.offsetFromHead)
            return Instruction.BrIfOperand(condition: LVReg(condition), offset: Int32(elseOrEnd))
        }
    }

    mutating func visitElse() throws -> Output {
        var frame = try controlStack.currentFrame()
        guard case let .if(elseLabel, endLabel, _) = frame.kind else {
            throw ValidationError(.expectedIfControlFrame)
        }
        preserveOnStack(depth: valueStack.height - frame.stackHeight)
        try controlStack.resetReachability()
        iseqBuilder.resetLastEmission()
        iseqBuilder.emitWithLabel(Instruction.br, endLabel) { _, selfPC, endPC in
            let offset = endPC.offsetFromHead - selfPC.offsetFromHead
            return Int32(offset)
        }
        for result in frame.blockType.results.reversed() {
            guard try checkBeforePop(typeHint: result, controlFrame: frame) else { continue }
            _ = try valueStack.pop(result)
        }
        guard valueStack.height == frame.stackHeight else {
            throw ValidationError(.valuesRemainingAtEndOfBlock)
        }
        _ = controlStack.popFrame()
        frame.kind = .if(elseLabel: elseLabel, endLabel: endLabel, isElse: true)
        frame.reachable = true
        controlStack.pushFrame(frame)

        // Re-push parameters
        for parameter in frame.blockType.parameters {
            _ = valueStack.push(parameter)
        }
        try iseqBuilder.pinLabelHere(elseLabel)
    }

    mutating func visitEnd() throws -> Output {
        let toBePopped = try controlStack.currentFrame()
        iseqBuilder.resetLastEmission()
        if case .block(root: true) = toBePopped.kind {
            try translateReturn()
            guard valueStack.height == toBePopped.stackHeight else {
                throw ValidationError(.valuesRemainingAtEndOfBlock)
            }
            try iseqBuilder.pinLabelHere(toBePopped.continuation)
            return
        }

        if case .if(_, _, isElse: false) = toBePopped.kind {
            let blockType = toBePopped.blockType
            guard blockType.parameters == blockType.results else {
                throw ValidationError(.parameterResultTypeMismatch(blockType: blockType))
            }
        }

        preserveOnStack(depth: Int(valueStack.height - toBePopped.stackHeight))
        switch toBePopped.kind {
        case .block:
            try iseqBuilder.pinLabelHere(toBePopped.continuation)
        case .loop: break
        case .if:
            try iseqBuilder.pinLabelHere(toBePopped.continuation)
        }
        for result in toBePopped.blockType.results.reversed() {
            guard try checkBeforePop(typeHint: result, controlFrame: toBePopped) else { continue }
            _ = try valueStack.pop(result)
        }
        guard valueStack.height == toBePopped.stackHeight else {
            throw ValidationError(.valuesRemainingAtEndOfBlock)
        }
        for result in toBePopped.blockType.results {
            _ = valueStack.push(result)
        }
        _ = controlStack.popFrame()
    }

    private static func computePopCount(
        destination: ControlStack.ControlFrame,
        currentFrame: ControlStack.ControlFrame,
        currentHeight: Int
    ) throws -> UInt32 {
        let popCount: UInt32
        if _fastPath(currentFrame.reachable) {
            let count = currentHeight - Int(destination.copyCount) - destination.stackHeight
            guard count >= 0 else {
                throw ValidationError(.stackHeightUnderflow(available: currentHeight, required: destination.stackHeight + Int(destination.copyCount)))
            }
            popCount = UInt32(count)
        } else {
            // Slow path: This path is taken when "br" is placed after "unreachable"
            // It's ok to put the fake popCount because it will not be executed at runtime.
            popCount = 0
        }
        return popCount
    }

    private mutating func emitBranch<Immediate: InstructionImmediate>(
        _ makeInstruction: @escaping (Immediate) -> Instruction,
        relativeDepth: UInt32,
        make: @escaping (_ offset: Int32, _ copyCount: UInt32, _ popCount: UInt32) -> Immediate
    ) throws {
        let frame = try controlStack.branchTarget(relativeDepth: relativeDepth)
        let copyCount = frame.copyCount
        let popCount = try Self.computePopCount(
            destination: frame,
            currentFrame: try controlStack.currentFrame(),
            currentHeight: valueStack.height
        )
        iseqBuilder.emitWithLabel(makeInstruction, frame.continuation) { _, selfPC, continuation in
            let relativeOffset = continuation.offsetFromHead - selfPC.offsetFromHead
            return make(Int32(relativeOffset), UInt32(copyCount), popCount)
        }
    }
    mutating func visitBr(relativeDepth: UInt32) throws -> Output {
        let frame = try controlStack.branchTarget(relativeDepth: relativeDepth)

        // Copy from the stack top to the bottom to avoid overwrites
        //              [BLOCK1]
        //              [      ]
        //              [      ]
        //              [BLOCK2] () -> (i32, i64)
        // copy [1] +-->[  i32 ]
        //          +---[  i32 ]<--+ copy [2]
        //              [  i64 ]---+
        try copyOnBranch(targetFrame: frame)
        try emitBranch(Instruction.br, relativeDepth: relativeDepth) { offset, copyCount, popCount in
            return offset
        }
        for type in frame.copyTypes.reversed() {
            _ = try popOperand(type)
        }
        try markUnreachable()
    }

    mutating func visitBrIf(relativeDepth: UInt32) throws -> Output {
        let frame = try controlStack.branchTarget(relativeDepth: relativeDepth)
        let condition = try popVRegOperand(.i32)

        if frame.copyCount == 0 {
            guard let condition else { return }
            // Optimization where we don't need copying values when the branch taken
            iseqBuilder.emitWithLabel(Instruction.brIf, frame.continuation) { _, selfPC, continuation in
                let relativeOffset = continuation.offsetFromHead - selfPC.offsetFromHead
                return Instruction.BrIfOperand(
                    condition: LVReg(condition), offset: Int32(relativeOffset)
                )
            }
            return
        }
        preserveOnStack(depth: valueStack.height - frame.stackHeight)

        if let condition {
            // If branch taken, fallthrough to landing pad, copy stack values
            // then branch to the actual place
            // If branch not taken, branch to the next of the landing pad
            //
            // (block (result i32)
            //   (i32.const 42)
            //   (i32.const 24)
            //   (local.get 0)
            //   (br_if 0) ------+
            //   (local.get 1)   |
            // )         <-------+
            //
            // [0x00] (i32.const 42 reg:0)
            // [0x01] (i32.const 24 reg:1)
            // [0x02] (local.get 0 result=reg:2)
            // [0x03] (br_if_z offset=+0x3 cond=reg:2) --+
            // [0x04] (stack.copy reg:1 -> reg:0)        |
            // [0x05] (br offset=+0x2) --------+         |
            // [0x06] (local.get 1 reg:2) <----|---------+
            // [0x07] ...              <-------+
            let onBranchNotTaken = iseqBuilder.allocLabel()
            iseqBuilder.emitWithLabel(Instruction.brIfNot, onBranchNotTaken) { _, conditionCheckAt, continuation in
                let relativeOffset = continuation.offsetFromHead - conditionCheckAt.offsetFromHead
                return Instruction.BrIfOperand(condition: LVReg(condition), offset: Int32(relativeOffset))
            }
            try copyOnBranch(targetFrame: frame)
            try emitBranch(Instruction.br, relativeDepth: relativeDepth) { offset, copyCount, popCount in
                return offset
            }
            try iseqBuilder.pinLabelHere(onBranchNotTaken)
        }
        try popPushValues(frame.copyTypes)
    }

    mutating func visitBrTable(targets: WasmParser.BrTable) throws -> Output {
        guard let index = try popVRegOperand(.i32) else { return }

        let defaultFrame = try controlStack.branchTarget(relativeDepth: targets.defaultIndex)

        // If this instruction is unreachable, copyCount might be greater than the actual stack height
        try preserveOnStack(
            depth: min(
                Int(defaultFrame.copyCount),
                valueStack.height - controlStack.currentFrame().stackHeight
            )
        )
        let allLabelIndices = targets.labelIndices + [targets.defaultIndex]
        let tableBuffer = allocator.allocateBrTable(capacity: allLabelIndices.count)
        let operand = Instruction.BrTableOperand(
            baseAddress: tableBuffer.baseAddress!,
            count: UInt16(tableBuffer.count), index: index
        )
        iseqBuilder.emit(.brTable(operand))
        let brTableAt = iseqBuilder.insertingPC

        //
        // (block $l1 (result i32)
        //   (i32.const 63)
        //   (block $l2 (result i32)
        //     (i32.const 42)
        //     (i32.const 24)
        //     (local.get 0)
        //     (br_table $l1 $l2) ---+
        //                           |
        //   )               <-------+
        //   (i32.const 36)          |
        // )              <----------+
        //
        //
        //           [0x00] (i32.const 63 reg:0)
        //           [0x01] (i32.const 42 reg:1)
        //           [0x02] (i32.const 24 reg:2)
        //           [0x03] (local.get 0 result=reg:3)
        //           [0x04] (br_table index=reg:3 offsets=[
        //                    +0x01       -----------------+
        //                    +0x03       -----------------|----+
        //                  ])                             |    |
        //           [0x05] (stack.copy reg:2 -> reg:0) <--+    |
        //  +------- [0x06] (br offset=+0x03)                   |
        //  |        [0x07] (stack.copy reg:2 -> reg:1)  <------+
        //  |  +---- [0x08] (br offset=+0x03)
        //  +--|---> [0x09] (i32.const 36 reg:2)
        //     |     [0x0a] (stack.copy reg:2 -> reg:0)
        //     +---> [0x0b] ...
        for (entryIndex, labelIndex) in allLabelIndices.enumerated() {
            let frame = try controlStack.branchTarget(relativeDepth: labelIndex)

            // Check copyTypes consistency
            guard frame.copyTypes.count == defaultFrame.copyTypes.count else {
                throw ValidationError(.expectedSameCopyTypes(frameCopyTypes: frame.copyTypes, defaultFrameCopyTypes: defaultFrame.copyTypes))
            }
            try checkStackTop(frame.copyTypes)

            do {
                let relativeOffset = iseqBuilder.insertingPC.offsetFromHead - brTableAt.offsetFromHead
                tableBuffer[entryIndex] = Instruction.BrTableOperand.Entry(
                    offset: Int32(relativeOffset)
                )
            }
            let emittedCopy = try copyOnBranch(targetFrame: frame)
            if emittedCopy {
                iseqBuilder.emitWithLabel(Instruction.br, frame.continuation) { _, brAt, continuation in
                    let relativeOffset = continuation.offsetFromHead - brAt.offsetFromHead
                    return Int32(relativeOffset)
                }
            } else {
                // Optimization: If no value is copied, we can directly jump to the target
                iseqBuilder.fillBrTableEntry(frame.continuation, table: tableBuffer, index: entryIndex) { _, continuation in
                    return Instruction.BrTableOperand.Entry(offset: Int32(continuation.offsetFromHead - brTableAt.offsetFromHead))
                }
            }
        }
        // Pop branch copy values for type checking
        for type in defaultFrame.copyTypes.reversed() {
            _ = try popOperand(type)
        }
        try markUnreachable()
    }

    mutating func visitReturn() throws -> Output {
        try translateReturn()
        try markUnreachable()
    }

    private mutating func visitCallLike(calleeType: FunctionType) throws -> VReg? {
        for parameter in calleeType.parameters.reversed() {
            guard (try popOnStackOperand(parameter)) != nil else { return nil }
        }

        let spAddend =
            valueStack.stackRegBase + VReg(valueStack.height)
            + FrameHeaderLayout.size(of: calleeType)

        for result in calleeType.results {
            _ = valueStack.push(result)
        }
        return VReg(spAddend)
    }
    mutating func visitCall(functionIndex: UInt32) throws -> Output {
        let calleeType = try self.module.functionType(functionIndex, interner: funcTypeInterner)
        guard let spAddend = try visitCallLike(calleeType: calleeType) else { return }
        guard let callee = self.module.resolveCallee(functionIndex) else {
            // Skip actual code emission if validation-only mode
            return
        }
        if callee.isWasm {
            if module.isSameInstance(callee.wasm.instance) {
                emit(.compilingCall(Instruction.CallOperand(callee: callee, spAddend: spAddend)))
                return
            }
        }
        emit(.call(Instruction.CallOperand(callee: callee, spAddend: spAddend)))
    }

    mutating func visitCallIndirect(typeIndex: UInt32, tableIndex: UInt32) throws -> Output {
        let addressType = try module.addressType(tableIndex: tableIndex)
        let address = try popVRegOperand(addressType)  // function address
        let calleeType = try self.module.resolveType(typeIndex)
        guard let spAddend = try visitCallLike(calleeType: calleeType) else { return }
        guard let address = address else { return }
        let internType = funcTypeInterner.intern(calleeType)
        let operand = Instruction.CallIndirectOperand(
            tableIndex: tableIndex,
            type: internType,
            index: address,
            spAddend: spAddend
        )
        emit(.callIndirect(operand))
    }

    /// Emit instructions to prepare the frame header for a return call to replace the
    /// current frame header with the callee's frame header layout.
    ///
    /// The frame header should have the callee's frame header layout and parameter
    /// slots are filled with arguments on the caller's stack.
    ///
    /// - Parameters:
    ///   - calleeType: The type of the callee function.
    ///   - stackTopHeightToCopy: The height of the stack top needed to be available at the
    ///     return-call-like instruction point.
    private mutating func prepareFrameHeaderForReturnCall(calleeType: FunctionType, stackTopHeightToCopy: Int) throws {
        let calleeFrameHeader = FrameHeaderLayout(type: calleeType)
        if calleeType == self.type {
            // Fast path: If the callee and the caller have the same signature, we can
            // skip reconstructing the frame header and we can just copy the parameters.
        } else {
            // Ensure all parameters are on stack to avoid conflicting with the next resize.
            preserveOnStack(depth: calleeType.parameters.count)
            // Resize the current frame header while moving stack slots after the header
            // to the resized positions
            let newHeaderSize = FrameHeaderLayout.size(of: calleeType)
            let delta = newHeaderSize - FrameHeaderLayout.size(of: type)
            let sizeToCopy = VReg(FrameHeaderLayout.numberOfSavingSlots) + valueStack.stackRegBase + VReg(stackTopHeightToCopy)
            emit(.resizeFrameHeader(Instruction.ResizeFrameHeaderOperand(delta: delta, sizeToCopy: sizeToCopy)))
        }
        try copyValuesIntoResultSlots(calleeType.parameters, frameHeader: calleeFrameHeader)
    }

    mutating func visitReturnCall(functionIndex: UInt32) throws {
        let calleeType = try self.module.functionType(functionIndex, interner: funcTypeInterner)
        try validator.validateReturnCallLike(calleeType: calleeType, callerType: type)

        guard let callee = self.module.resolveCallee(functionIndex) else {
            // Skip actual code emission if validation-only mode
            return
        }
        try prepareFrameHeaderForReturnCall(calleeType: calleeType, stackTopHeightToCopy: valueStack.height)
        emit(.returnCall(Instruction.ReturnCallOperand(callee: callee)))
        try markUnreachable()
    }

    mutating func visitReturnCallIndirect(typeIndex: UInt32, tableIndex: UInt32) throws {
        let stackTopHeightToCopy = valueStack.height
        let addressType = try module.addressType(tableIndex: tableIndex)
        // Preserve function index slot on stack
        let address = try popOnStackOperand(addressType)  // function address
        guard let address = address else { return }

        let calleeType = try self.module.resolveType(typeIndex)
        let internType = funcTypeInterner.intern(calleeType)

        try prepareFrameHeaderForReturnCall(
            calleeType: calleeType,
            // Keep the stack space including the function index slot to be
            // accessible at the `return_call_indirect` instruction point.
            stackTopHeightToCopy: stackTopHeightToCopy
        )

        let operand = Instruction.ReturnCallIndirectOperand(
            tableIndex: tableIndex,
            type: internType,
            index: address
        )
        emit(.returnCallIndirect(operand))
        try markUnreachable()
    }

    mutating func visitDrop() throws -> Output {
        _ = try popAnyOperand()
        iseqBuilder.resetLastEmission()
    }
    mutating func visitSelect() throws -> Output {
        let condition = try popVRegOperand(.i32)
        let (value1Type, value1) = try popAnyOperand()
        let (value2Type, value2) = try popAnyOperand()
        switch (value1Type, value2Type) {
        case (.some(.ref(_)), _), (_, .some(.ref(_))):
            throw ValidationError(.cannotSelectOnReferenceTypes)
        case let (.some(type1), .some(type2)):
            guard type1 == type2 else {
                throw ValidationError(.typeMismatchOnSelect(expected: type1, actual: type2))
            }
        case (.unknown, _), (_, .unknown):
            break
        }
        let result = valueStack.push(value1Type)
        if let condition = condition, let value1 = value1, let value2 = value2 {
            let operand = Instruction.SelectOperand(
                result: result,
                condition: condition,
                onTrue: ensureOnVReg(value2),
                onFalse: ensureOnVReg(value1)
            )
            emit(.select(operand))
        }
    }
    mutating func visitTypedSelect(type: WasmTypes.ValueType) throws -> Output {
        let condition = try popVRegOperand(.i32)
        let (value1Type, value1) = try popAnyOperand()
        let (_, value2) = try popAnyOperand()
        // TODO: Perform actual validation
        // guard value1 == ValueType(type) else {
        //     throw TranslationError("Type mismatch on `select`. Expected \(value1) and \(type) to be same")
        // }
        // guard value2 == ValueType(type) else {
        //     throw TranslationError("Type mismatch on `select`. Expected \(value2) and \(type) to be same")
        // }
        let result = valueStack.push(value1Type)
        if let condition = condition, let value1 = value1, let value2 = value2 {
            let operand = Instruction.SelectOperand(
                result: result,
                condition: condition,
                onTrue: ensureOnVReg(value2),
                onFalse: ensureOnVReg(value1)
            )
            emit(.select(operand))
        }
    }
    mutating func visitLocalGet(localIndex: UInt32) throws -> Output {
        iseqBuilder.resetLastEmission()
        try valueStack.pushLocal(localIndex, locals: &locals)
    }
    mutating func visitLocalSetOrTee(localIndex: UInt32, isTee: Bool) throws {
        preserveLocalsOnStack(localIndex)
        let type = try locals.type(of: localIndex)
        let result = localReg(localIndex)

        guard try checkBeforePop(typeHint: type) else { return }
        let op = try valueStack.pop(type)

        if case .const(let slotIndex, _) = op {
            // Optimize (local.set $x (i32.const $c)) to reg:$x = 42 rather than through const slot
            let value = constantSlots.values[slotIndex]
            let is32Bit = type == .i32 || type == .f32
            if is32Bit {
                emit(.const32(Instruction.Const32Operand(value: UInt32(value.storage), result: LVReg(result))))
            } else {
                emit(.const64(Instruction.Const64Operand(value: value, result: LLVReg(result))))
            }
            return
        }

        let value = ensureOnVReg(op)
        guard try controlStack.currentFrame().reachable else { return }
        if !isTee, iseqBuilder.relinkLastInstructionResult(result) {
            // Good news, copyStack is optimized out :)
            return
        }
        emitCopyStack(from: value, to: result)
    }
    mutating func visitLocalSet(localIndex: UInt32) throws -> Output {
        try visitLocalSetOrTee(localIndex: localIndex, isTee: false)
    }
    mutating func visitLocalTee(localIndex: UInt32) throws -> Output {
        try visitLocalSetOrTee(localIndex: localIndex, isTee: true)
        _ = try valueStack.pushLocal(localIndex, locals: &locals)
    }
    mutating func visitGlobalGet(globalIndex: UInt32) throws -> Output {
        let type = try module.globalType(globalIndex)
        let result = valueStack.push(type)
        guard let global = module.resolveGlobal(globalIndex) else {
            // Skip actual code emission if validation-only mode
            return
        }
        emit(.globalGet(Instruction.GlobalAndVRegOperand(reg: LLVReg(result), global: global)))
    }
    mutating func visitGlobalSet(globalIndex: UInt32) throws -> Output {
        let type = try module.globalType(globalIndex)
        guard let value = try popVRegOperand(type) else { return }
        guard let global = module.resolveGlobal(globalIndex) else {
            // Skip actual code emission if validation-only mode
            return
        }
        try validator.validateGlobalSet(global.globalType)
        emit(.globalSet(Instruction.GlobalAndVRegOperand(reg: LLVReg(value), global: global)))
    }

    private mutating func pushEmit(
        _ type: ValueType,
        _ instruction: @escaping (VReg) -> Instruction
    ) {
        let register = valueStack.push(type)
        emit(
            instruction(register),
            resultRelink: { newResult in
                instruction(newResult)
            })
    }
    private mutating func popPushEmit(
        _ pop: ValueType,
        _ push: ValueType,
        _ instruction: @escaping (_ popped: VReg, _ result: VReg, ValueStack) -> Instruction
    ) throws {
        let value = try popVRegOperand(pop)
        let result = valueStack.push(push)
        if let value = value {
            emit(
                instruction(value, result, valueStack),
                resultRelink: { [valueStack] newResult in
                    instruction(value, newResult, valueStack)
                })
        }
    }

    private mutating func pop3Emit(
        _ pops: (ValueType, ValueType, ValueType),
        _ instruction: (
            _ popped: (VReg, VReg, VReg),
            inout ValueStack
        ) -> Instruction
    ) throws {
        guard let pop1 = try popVRegOperand(pops.0),
            let pop2 = try popVRegOperand(pops.1),
            let pop3 = try popVRegOperand(pops.2)
        else { return }
        emit(instruction((pop1, pop2, pop3), &valueStack))
    }

    private mutating func pop2Emit(
        _ pops: (ValueType, ValueType),
        _ instruction: (
            _ popped: (VReg, VReg),
            inout ValueStack
        ) -> Instruction
    ) throws {
        guard let pop1 = try popVRegOperand(pops.0),
            let pop2 = try popVRegOperand(pops.1)
        else { return }
        emit(instruction((pop1, pop2), &valueStack))
    }

    private mutating func pop2PushEmit(
        _ pops: (ValueType, ValueType),
        _ push: ValueType,
        _ instruction: @escaping (
            _ popped: (VReg, VReg),
            _ result: VReg
        ) -> Instruction
    ) throws {
        guard let pop1 = try popVRegOperand(pops.0),
            let pop2 = try popVRegOperand(pops.1)
        else { return }
        let result = valueStack.push(push)
        emit(
            instruction((pop1, pop2), result),
            resultRelink: { result in
                instruction((pop1, pop2), result)
            })
    }

    private mutating func visitLoad(
        _ memarg: MemArg,
        _ type: ValueType,
        _ naturalAlignment: Int,
        _ instruction: @escaping (Instruction.LoadOperand) -> Instruction
    ) throws {
        let isMemory64 = try module.isMemory64(memoryIndex: 0)
        try validator.validateMemArg(memarg, naturalAlignment: naturalAlignment)
        try popPushEmit(.address(isMemory64: isMemory64), type) { value, result, stack in
            let loadOperand = Instruction.LoadOperand(
                offset: memarg.offset,
                pointer: value,
                result: result
            )
            return instruction(loadOperand)
        }
    }
    private mutating func visitStore(
        _ memarg: MemArg,
        _ type: ValueType,
        _ naturalAlignment: Int,
        _ instruction: (Instruction.StoreOperand) -> Instruction
    ) throws {
        let isMemory64 = try module.isMemory64(memoryIndex: 0)
        try validator.validateMemArg(memarg, naturalAlignment: naturalAlignment)
        let value = try popVRegOperand(type)
        let pointer = try popVRegOperand(.address(isMemory64: isMemory64))
        if let value = value, let pointer = pointer {
            let storeOperand = Instruction.StoreOperand(
                offset: memarg.offset,
                pointer: pointer,
                value: value
            )
            emit(instruction(storeOperand))
        }
    }

    mutating func visitLoad(_ load: WasmParser.Instruction.Load, memarg: MemArg) throws {
        let instruction: (Instruction.LoadOperand) -> Instruction
        switch load {
        case .i32Load: instruction = Instruction.i32Load
        case .i64Load: instruction = Instruction.i64Load
        case .f32Load: instruction = Instruction.f32Load
        case .f64Load: instruction = Instruction.f64Load
        case .i32Load8S: instruction = Instruction.i32Load8S
        case .i32Load8U: instruction = Instruction.i32Load8U
        case .i32Load16S: instruction = Instruction.i32Load16S
        case .i32Load16U: instruction = Instruction.i32Load16U
        case .i64Load8S: instruction = Instruction.i64Load8S
        case .i64Load8U: instruction = Instruction.i64Load8U
        case .i64Load16S: instruction = Instruction.i64Load16S
        case .i64Load16U: instruction = Instruction.i64Load16U
        case .i64Load32S: instruction = Instruction.i64Load32S
        case .i64Load32U: instruction = Instruction.i64Load32U
        }
        try visitLoad(memarg, load.type, load.naturalAlignment, instruction)
    }

    mutating func visitStore(_ store: WasmParser.Instruction.Store, memarg: MemArg) throws {
        let instruction: (Instruction.StoreOperand) -> Instruction
        switch store {
        case .i32Store: instruction = Instruction.i32Store
        case .i64Store: instruction = Instruction.i64Store
        case .f32Store: instruction = Instruction.f32Store
        case .f64Store: instruction = Instruction.f64Store
        case .i32Store8: instruction = Instruction.i32Store8
        case .i32Store16: instruction = Instruction.i32Store16
        case .i64Store8: instruction = Instruction.i64Store8
        case .i64Store16: instruction = Instruction.i64Store16
        case .i64Store32: instruction = Instruction.i64Store32
        }
        try visitStore(memarg, store.type, store.naturalAlignment, instruction)
    }
    mutating func visitMemorySize(memory: UInt32) throws -> Output {
        let sizeType: ValueType = try module.isMemory64(memoryIndex: memory) ? .i64 : .i32
        pushEmit(sizeType, { .memorySize(Instruction.MemorySizeOperand(memoryIndex: memory, result: LVReg($0))) })
    }
    mutating func visitMemoryGrow(memory: UInt32) throws -> Output {
        let isMemory64 = try module.isMemory64(memoryIndex: memory)
        let sizeType = ValueType.address(isMemory64: isMemory64)
        // Just pop/push the same type (i64 or i32) value
        try popPushEmit(sizeType, sizeType) { value, result, stack in
            .memoryGrow(
                Instruction.MemoryGrowOperand(
                    result: result, delta: value, memory: memory
                ))
        }
    }

    private mutating func visitConst(_ type: ValueType, _ value: Value) {
        if let constSlotIndex = constantSlots.allocate(value) {
            valueStack.pushConst(constSlotIndex, type: type)
            iseqBuilder.resetLastEmission()
            return
        }
        let value = UntypedValue(value)
        let is32Bit = type == .i32 || type == .f32
        if is32Bit {
            pushEmit(
                type,
                {
                    .const32(Instruction.Const32Operand(value: UInt32(value.storage), result: LVReg($0)))
                })
        } else {
            pushEmit(type, { .const64(Instruction.Const64Operand(value: value, result: LLVReg($0))) })
        }
    }
    mutating func visitI32Const(value: Int32) -> Output { visitConst(.i32, .i32(UInt32(bitPattern: value))) }
    mutating func visitI64Const(value: Int64) -> Output { visitConst(.i64, .i64(UInt64(bitPattern: value))) }
    mutating func visitF32Const(value: IEEE754.Float32) -> Output { visitConst(.f32, .f32(value.bitPattern)) }
    mutating func visitF64Const(value: IEEE754.Float64) -> Output { visitConst(.f64, .f64(value.bitPattern)) }
    mutating func visitRefNull(type: HeapType) throws {
        guard case let .abstract(abstractType) = type else {
            throw TranslationError("concrete heap type is not implemented yet")
        }
        let typeToPush = ReferenceType(isNullable: true, heapType: type)
        pushEmit(.ref(typeToPush), { .refNull(Instruction.RefNullOperand(result: $0, type: abstractType)) })
    }
    mutating func visitRefIsNull() throws -> Output {
        let value = try valueStack.popRef()
        let result = valueStack.push(.i32)
        emit(.refIsNull(Instruction.RefIsNullOperand(value: LVReg(ensureOnVReg(value)), result: LVReg(result))))
    }
    mutating func visitRefFunc(functionIndex: UInt32) throws -> Output {
        try validator.validateRefFunc(functionIndex: functionIndex)
        pushEmit(.ref(.funcRef), { .refFunc(Instruction.RefFuncOperand(index: functionIndex, result: LVReg($0))) })
    }

    private mutating func visitUnary(_ operand: ValueType, _ instruction: @escaping (Instruction.UnaryOperand) -> Instruction) throws {
        try popPushEmit(operand, operand) { value, result, stack in
            return instruction(Instruction.UnaryOperand(result: LVReg(result), input: LVReg(value)))
        }
    }
    private mutating func visitBinary(
        _ operand: ValueType,
        _ result: ValueType,
        _ instruction: @escaping (Instruction.BinaryOperand) -> Instruction
    ) throws {
        let rhs = try popVRegOperand(operand)
        let lhs = try popVRegOperand(operand)
        let result = valueStack.push(result)
        guard let lhs = lhs, let rhs = rhs else { return }
        emit(
            instruction(Instruction.BinaryOperand(result: LVReg(result), lhs: lhs, rhs: rhs)),
            resultRelink: { result in
                return instruction(Instruction.BinaryOperand(result: LVReg(result), lhs: lhs, rhs: rhs))
            }
        )
    }
    private mutating func visitCmp(_ operand: ValueType, _ instruction: @escaping (Instruction.BinaryOperand) -> Instruction) throws {
        try visitBinary(operand, .i32, instruction)
    }
    private mutating func visitConversion(_ from: ValueType, _ to: ValueType, _ instruction: @escaping (Instruction.UnaryOperand) -> Instruction) throws {
        try popPushEmit(from, to) { value, result, stack in
            return instruction(Instruction.UnaryOperand(result: LVReg(result), input: LVReg(value)))
        }
    }
    mutating func visitI32Eqz() throws -> Output {
        try popPushEmit(.i32, .i32) { value, result, stack in
            .i32Eqz(Instruction.UnaryOperand(result: LVReg(result), input: LVReg(value)))
        }
    }
    mutating func visitCmp(_ cmp: WasmParser.Instruction.Cmp) throws {
        let operand: ValueType
        let instruction: (Instruction.BinaryOperand) -> Instruction
        switch cmp {
        case .i32Eq: (operand, instruction) = (.i32, Instruction.i32Eq)
        case .i32Ne: (operand, instruction) = (.i32, Instruction.i32Ne)
        case .i32LtS: (operand, instruction) = (.i32, Instruction.i32LtS)
        case .i32LtU: (operand, instruction) = (.i32, Instruction.i32LtU)
        case .i32GtS: (operand, instruction) = (.i32, Instruction.i32GtS)
        case .i32GtU: (operand, instruction) = (.i32, Instruction.i32GtU)
        case .i32LeS: (operand, instruction) = (.i32, Instruction.i32LeS)
        case .i32LeU: (operand, instruction) = (.i32, Instruction.i32LeU)
        case .i32GeS: (operand, instruction) = (.i32, Instruction.i32GeS)
        case .i32GeU: (operand, instruction) = (.i32, Instruction.i32GeU)
        case .i64Eq: (operand, instruction) = (.i64, Instruction.i64Eq)
        case .i64Ne: (operand, instruction) = (.i64, Instruction.i64Ne)
        case .i64LtS: (operand, instruction) = (.i64, Instruction.i64LtS)
        case .i64LtU: (operand, instruction) = (.i64, Instruction.i64LtU)
        case .i64GtS: (operand, instruction) = (.i64, Instruction.i64GtS)
        case .i64GtU: (operand, instruction) = (.i64, Instruction.i64GtU)
        case .i64LeS: (operand, instruction) = (.i64, Instruction.i64LeS)
        case .i64LeU: (operand, instruction) = (.i64, Instruction.i64LeU)
        case .i64GeS: (operand, instruction) = (.i64, Instruction.i64GeS)
        case .i64GeU: (operand, instruction) = (.i64, Instruction.i64GeU)
        case .f32Eq: (operand, instruction) = (.f32, Instruction.f32Eq)
        case .f32Ne: (operand, instruction) = (.f32, Instruction.f32Ne)
        case .f32Lt: (operand, instruction) = (.f32, Instruction.f32Lt)
        case .f32Gt: (operand, instruction) = (.f32, Instruction.f32Gt)
        case .f32Le: (operand, instruction) = (.f32, Instruction.f32Le)
        case .f32Ge: (operand, instruction) = (.f32, Instruction.f32Ge)
        case .f64Eq: (operand, instruction) = (.f64, Instruction.f64Eq)
        case .f64Ne: (operand, instruction) = (.f64, Instruction.f64Ne)
        case .f64Lt: (operand, instruction) = (.f64, Instruction.f64Lt)
        case .f64Gt: (operand, instruction) = (.f64, Instruction.f64Gt)
        case .f64Le: (operand, instruction) = (.f64, Instruction.f64Le)
        case .f64Ge: (operand, instruction) = (.f64, Instruction.f64Ge)
        }
        try visitCmp(operand, instruction)
    }
    public mutating func visitBinary(_ binary: WasmParser.Instruction.Binary) throws {
        let operand: ValueType
        let result: ValueType
        let instruction: (Instruction.BinaryOperand) -> Instruction
        switch binary {
        case .i32Add: (operand, result, instruction) = (.i32, .i32, Instruction.i32Add)
        case .i32Sub: (operand, result, instruction) = (.i32, .i32, Instruction.i32Sub)
        case .i32Mul: (operand, result, instruction) = (.i32, .i32, Instruction.i32Mul)
        case .i32DivS: (operand, result, instruction) = (.i32, .i32, Instruction.i32DivS)
        case .i32DivU: (operand, result, instruction) = (.i32, .i32, Instruction.i32DivU)
        case .i32RemS: (operand, result, instruction) = (.i32, .i32, Instruction.i32RemS)
        case .i32RemU: (operand, result, instruction) = (.i32, .i32, Instruction.i32RemU)
        case .i32And: (operand, result, instruction) = (.i32, .i32, Instruction.i32And)
        case .i32Or: (operand, result, instruction) = (.i32, .i32, Instruction.i32Or)
        case .i32Xor: (operand, result, instruction) = (.i32, .i32, Instruction.i32Xor)
        case .i32Shl: (operand, result, instruction) = (.i32, .i32, Instruction.i32Shl)
        case .i32ShrS: (operand, result, instruction) = (.i32, .i32, Instruction.i32ShrS)
        case .i32ShrU: (operand, result, instruction) = (.i32, .i32, Instruction.i32ShrU)
        case .i32Rotl: (operand, result, instruction) = (.i32, .i32, Instruction.i32Rotl)
        case .i32Rotr: (operand, result, instruction) = (.i32, .i32, Instruction.i32Rotr)
        case .i64Add: (operand, result, instruction) = (.i64, .i64, Instruction.i64Add)
        case .i64Sub: (operand, result, instruction) = (.i64, .i64, Instruction.i64Sub)
        case .i64Mul: (operand, result, instruction) = (.i64, .i64, Instruction.i64Mul)
        case .i64DivS: (operand, result, instruction) = (.i64, .i64, Instruction.i64DivS)
        case .i64DivU: (operand, result, instruction) = (.i64, .i64, Instruction.i64DivU)
        case .i64RemS: (operand, result, instruction) = (.i64, .i64, Instruction.i64RemS)
        case .i64RemU: (operand, result, instruction) = (.i64, .i64, Instruction.i64RemU)
        case .i64And: (operand, result, instruction) = (.i64, .i64, Instruction.i64And)
        case .i64Or: (operand, result, instruction) = (.i64, .i64, Instruction.i64Or)
        case .i64Xor: (operand, result, instruction) = (.i64, .i64, Instruction.i64Xor)
        case .i64Shl: (operand, result, instruction) = (.i64, .i64, Instruction.i64Shl)
        case .i64ShrS: (operand, result, instruction) = (.i64, .i64, Instruction.i64ShrS)
        case .i64ShrU: (operand, result, instruction) = (.i64, .i64, Instruction.i64ShrU)
        case .i64Rotl: (operand, result, instruction) = (.i64, .i64, Instruction.i64Rotl)
        case .i64Rotr: (operand, result, instruction) = (.i64, .i64, Instruction.i64Rotr)
        case .f32Add: (operand, result, instruction) = (.f32, .f32, Instruction.f32Add)
        case .f32Sub: (operand, result, instruction) = (.f32, .f32, Instruction.f32Sub)
        case .f32Mul: (operand, result, instruction) = (.f32, .f32, Instruction.f32Mul)
        case .f32Div: (operand, result, instruction) = (.f32, .f32, Instruction.f32Div)
        case .f32Min: (operand, result, instruction) = (.f32, .f32, Instruction.f32Min)
        case .f32Max: (operand, result, instruction) = (.f32, .f32, Instruction.f32Max)
        case .f32Copysign: (operand, result, instruction) = (.f32, .f32, Instruction.f32CopySign)
        case .f64Add: (operand, result, instruction) = (.f64, .f64, Instruction.f64Add)
        case .f64Sub: (operand, result, instruction) = (.f64, .f64, Instruction.f64Sub)
        case .f64Mul: (operand, result, instruction) = (.f64, .f64, Instruction.f64Mul)
        case .f64Div: (operand, result, instruction) = (.f64, .f64, Instruction.f64Div)
        case .f64Min: (operand, result, instruction) = (.f64, .f64, Instruction.f64Min)
        case .f64Max: (operand, result, instruction) = (.f64, .f64, Instruction.f64Max)
        case .f64Copysign: (operand, result, instruction) = (.f64, .f64, Instruction.f64CopySign)
        }
        try visitBinary(operand, result, instruction)
    }
    mutating func visitI64Eqz() throws -> Output {
        try popPushEmit(.i64, .i32) { value, result, stack in
            .i64Eqz(Instruction.UnaryOperand(result: LVReg(result), input: LVReg(value)))
        }
    }
    mutating func visitUnary(_ unary: WasmParser.Instruction.Unary) throws {
        let operand: ValueType
        let instruction: (Instruction.UnaryOperand) -> Instruction
        switch unary {
        case .i32Clz: (operand, instruction) = (.i32, Instruction.i32Clz)
        case .i32Ctz: (operand, instruction) = (.i32, Instruction.i32Ctz)
        case .i32Popcnt: (operand, instruction) = (.i32, Instruction.i32Popcnt)
        case .i64Clz: (operand, instruction) = (.i64, Instruction.i64Clz)
        case .i64Ctz: (operand, instruction) = (.i64, Instruction.i64Ctz)
        case .i64Popcnt: (operand, instruction) = (.i64, Instruction.i64Popcnt)
        case .f32Abs: (operand, instruction) = (.f32, Instruction.f32Abs)
        case .f32Neg: (operand, instruction) = (.f32, Instruction.f32Neg)
        case .f32Ceil: (operand, instruction) = (.f32, Instruction.f32Ceil)
        case .f32Floor: (operand, instruction) = (.f32, Instruction.f32Floor)
        case .f32Trunc: (operand, instruction) = (.f32, Instruction.f32Trunc)
        case .f32Nearest: (operand, instruction) = (.f32, Instruction.f32Nearest)
        case .f32Sqrt: (operand, instruction) = (.f32, Instruction.f32Sqrt)
        case .f64Abs: (operand, instruction) = (.f64, Instruction.f64Abs)
        case .f64Neg: (operand, instruction) = (.f64, Instruction.f64Neg)
        case .f64Ceil: (operand, instruction) = (.f64, Instruction.f64Ceil)
        case .f64Floor: (operand, instruction) = (.f64, Instruction.f64Floor)
        case .f64Trunc: (operand, instruction) = (.f64, Instruction.f64Trunc)
        case .f64Nearest: (operand, instruction) = (.f64, Instruction.f64Nearest)
        case .f64Sqrt: (operand, instruction) = (.f64, Instruction.f64Sqrt)
        case .i32Extend8S: (operand, instruction) = (.i32, Instruction.i32Extend8S)
        case .i32Extend16S: (operand, instruction) = (.i32, Instruction.i32Extend16S)
        case .i64Extend8S: (operand, instruction) = (.i64, Instruction.i64Extend8S)
        case .i64Extend16S: (operand, instruction) = (.i64, Instruction.i64Extend16S)
        case .i64Extend32S: (operand, instruction) = (.i64, Instruction.i64Extend32S)
        }
        try visitUnary(operand, instruction)
    }
    mutating func visitConversion(_ conversion: WasmParser.Instruction.Conversion) throws {
        let from: ValueType
        let to: ValueType
        let instruction: (Instruction.UnaryOperand) -> Instruction
        switch conversion {
        case .i32WrapI64: (from, to, instruction) = (.i64, .i32, Instruction.i32WrapI64)
        case .i32TruncF32S: (from, to, instruction) = (.f32, .i32, Instruction.i32TruncF32S)
        case .i32TruncF32U: (from, to, instruction) = (.f32, .i32, Instruction.i32TruncF32U)
        case .i32TruncF64S: (from, to, instruction) = (.f64, .i32, Instruction.i32TruncF64S)
        case .i32TruncF64U: (from, to, instruction) = (.f64, .i32, Instruction.i32TruncF64U)
        case .i64ExtendI32S: (from, to, instruction) = (.i32, .i64, Instruction.i64ExtendI32S)
        case .i64ExtendI32U: (from, to, instruction) = (.i32, .i64, Instruction.i64ExtendI32U)
        case .i64TruncF32S: (from, to, instruction) = (.f32, .i64, Instruction.i64TruncF32S)
        case .i64TruncF32U: (from, to, instruction) = (.f32, .i64, Instruction.i64TruncF32U)
        case .i64TruncF64S: (from, to, instruction) = (.f64, .i64, Instruction.i64TruncF64S)
        case .i64TruncF64U: (from, to, instruction) = (.f64, .i64, Instruction.i64TruncF64U)
        case .f32ConvertI32S: (from, to, instruction) = (.i32, .f32, Instruction.f32ConvertI32S)
        case .f32ConvertI32U: (from, to, instruction) = (.i32, .f32, Instruction.f32ConvertI32U)
        case .f32ConvertI64S: (from, to, instruction) = (.i64, .f32, Instruction.f32ConvertI64S)
        case .f32ConvertI64U: (from, to, instruction) = (.i64, .f32, Instruction.f32ConvertI64U)
        case .f32DemoteF64: (from, to, instruction) = (.f64, .f32, Instruction.f32DemoteF64)
        case .f64ConvertI32S: (from, to, instruction) = (.i32, .f64, Instruction.f64ConvertI32S)
        case .f64ConvertI32U: (from, to, instruction) = (.i32, .f64, Instruction.f64ConvertI32U)
        case .f64ConvertI64S: (from, to, instruction) = (.i64, .f64, Instruction.f64ConvertI64S)
        case .f64ConvertI64U: (from, to, instruction) = (.i64, .f64, Instruction.f64ConvertI64U)
        case .f64PromoteF32: (from, to, instruction) = (.f32, .f64, Instruction.f64PromoteF32)
        case .i32ReinterpretF32: (from, to, instruction) = (.f32, .i32, Instruction.i32ReinterpretF32)
        case .i64ReinterpretF64: (from, to, instruction) = (.f64, .i64, Instruction.i64ReinterpretF64)
        case .f32ReinterpretI32: (from, to, instruction) = (.i32, .f32, Instruction.f32ReinterpretI32)
        case .f64ReinterpretI64: (from, to, instruction) = (.i64, .f64, Instruction.f64ReinterpretI64)
        case .i32TruncSatF32S: (from, to, instruction) = (.f32, .i32, Instruction.i32TruncSatF32S)
        case .i32TruncSatF32U: (from, to, instruction) = (.f32, .i32, Instruction.i32TruncSatF32U)
        case .i32TruncSatF64S: (from, to, instruction) = (.f64, .i32, Instruction.i32TruncSatF64S)
        case .i32TruncSatF64U: (from, to, instruction) = (.f64, .i32, Instruction.i32TruncSatF64U)
        case .i64TruncSatF32S: (from, to, instruction) = (.f32, .i64, Instruction.i64TruncSatF32S)
        case .i64TruncSatF32U: (from, to, instruction) = (.f32, .i64, Instruction.i64TruncSatF32U)
        case .i64TruncSatF64S: (from, to, instruction) = (.f64, .i64, Instruction.i64TruncSatF64S)
        case .i64TruncSatF64U: (from, to, instruction) = (.f64, .i64, Instruction.i64TruncSatF64U)
        }
        try visitConversion(from, to, instruction)
    }

    mutating func visitMemoryInit(dataIndex: UInt32) throws -> Output {
        try self.validator.validateDataSegment(dataIndex)
        let addressType = try module.addressType(memoryIndex: 0)
        try pop3Emit((.i32, .i32, addressType)) { values, stack in
            let (size, sourceOffset, destOffset) = values
            return .memoryInit(
                Instruction.MemoryInitOperand(
                    segmentIndex: dataIndex,
                    destOffset: destOffset,
                    sourceOffset: sourceOffset,
                    size: size
                )
            )
        }
    }
    mutating func visitDataDrop(dataIndex: UInt32) throws -> Output {
        try self.validator.validateDataSegment(dataIndex)
        emit(.memoryDataDrop(Instruction.MemoryDataDropOperand(segmentIndex: dataIndex)))
    }
    mutating func visitMemoryCopy(dstMem: UInt32, srcMem: UInt32) throws -> Output {
        //     C.mems[0] = it limits
        // -----------------------------
        // C ⊦ memory.fill : [it i32 it] → []
        // https://github.com/WebAssembly/memory64/blob/main/proposals/memory64/Overview.md
        let addressType = try module.addressType(memoryIndex: 0)
        try pop3Emit((addressType, addressType, addressType)) { values, stack in
            let (size, sourceOffset, destOffset) = values
            return .memoryCopy(
                Instruction.MemoryCopyOperand(
                    destOffset: destOffset,
                    sourceOffset: sourceOffset,
                    size: LVReg(size)
                )
            )
        }
    }
    mutating func visitMemoryFill(memory: UInt32) throws -> Output {
        //     C.mems[0] = it limits
        // -----------------------------
        // C ⊦ memory.fill : [it i32 it] → []
        // https://github.com/WebAssembly/memory64/blob/main/proposals/memory64/Overview.md
        let addressType = try module.addressType(memoryIndex: 0)
        try pop3Emit((addressType, .i32, addressType)) { values, stack in
            let (size, value, destOffset) = values
            return .memoryFill(
                Instruction.MemoryFillOperand(
                    destOffset: destOffset,
                    value: value,
                    size: LVReg(size)
                )
            )
        }
    }
    mutating func visitTableInit(elemIndex: UInt32, table: UInt32) throws -> Output {
        try validator.validateTableInit(elemIndex: elemIndex, table: table)

        try pop3Emit((.i32, .i32, module.addressType(tableIndex: table))) { values, stack in
            let (size, sourceOffset, destOffset) = values
            return .tableInit(
                Instruction.TableInitOperand(
                    tableIndex: table,
                    segmentIndex: elemIndex,
                    destOffset: destOffset,
                    sourceOffset: sourceOffset,
                    size: size
                )
            )
        }
    }
    mutating func visitElemDrop(elemIndex: UInt32) throws -> Output {
        try self.module.validateElementSegment(elemIndex)
        emit(.tableElementDrop(Instruction.TableElementDropOperand(index: elemIndex)))
    }
    mutating func visitTableCopy(dstTable: UInt32, srcTable: UInt32) throws -> Output {
        //   C.tables[d] = iN limits t   C.tables[s] = iM limits t    K = min {N, M}
        // -----------------------------------------------------------------------------
        // C ⊦ table.copy d s : [iN iM iK] → []
        // https://github.com/WebAssembly/memory64/blob/main/proposals/memory64/Overview.md
        try validator.validateTableCopy(dest: dstTable, source: srcTable)
        let destIsMemory64 = try module.isMemory64(tableIndex: dstTable)
        let sourceIsMemory64 = try module.isMemory64(tableIndex: srcTable)
        let lengthIsMemory64 = destIsMemory64 && sourceIsMemory64
        try pop3Emit(
            (
                .address(isMemory64: lengthIsMemory64),
                .address(isMemory64: sourceIsMemory64),
                .address(isMemory64: destIsMemory64)
            )
        ) { values, stack in
            let (size, sourceOffset, destOffset) = values
            return .tableCopy(
                Instruction.TableCopyOperand(
                    sourceIndex: srcTable,
                    destIndex: dstTable,
                    destOffset: destOffset,
                    sourceOffset: sourceOffset,
                    size: size
                )
            )
        }
    }
    mutating func visitTableFill(table: UInt32) throws -> Output {
        let address = try module.addressType(tableIndex: table)
        let type = try module.tableType(table)
        try pop3Emit((address, .ref(type.elementType), address)) { values, stack in
            let (size, value, destOffset) = values
            return .tableFill(
                Instruction.TableFillOperand(
                    tableIndex: table,
                    destOffset: destOffset,
                    value: value,
                    size: size
                )
            )
        }
    }
    mutating func visitTableGet(table: UInt32) throws -> Output {
        let type = try module.tableType(table)
        try popPushEmit(
            module.addressType(tableIndex: table),
            .ref(type.elementType)
        ) { index, result, stack in
            return .tableGet(
                Instruction.TableGetOperand(
                    index: index,
                    result: result,
                    tableIndex: table
                )
            )
        }
    }
    mutating func visitTableSet(table: UInt32) throws -> Output {
        let type = try module.tableType(table)
        try pop2Emit((.ref(type.elementType), module.addressType(tableIndex: table))) { values, stack in
            let (value, index) = values
            return .tableSet(
                Instruction.TableSetOperand(
                    index: index,
                    value: value,
                    tableIndex: table
                )
            )
        }
    }
    mutating func visitTableGrow(table: UInt32) throws -> Output {
        let address = try module.addressType(tableIndex: table)
        let type = try module.tableType(table)
        try pop2PushEmit((address, .ref(type.elementType)), address) { values, result in
            let (delta, value) = values
            return .tableGrow(
                Instruction.TableGrowOperand(
                    tableIndex: table,
                    result: result,
                    delta: delta,
                    value: value
                )
            )
        }
    }
    mutating func visitTableSize(table: UInt32) throws -> Output {
        pushEmit(try module.addressType(tableIndex: table)) { result in
            return .tableSize(Instruction.TableSizeOperand(tableIndex: table, result: LVReg(result)))
        }
    }
}

struct TranslationError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

extension FunctionType {
    fileprivate init(blockType: WasmParser.BlockType, typeSection: [FunctionType]) throws {
        switch blockType {
        case .type(let valueType):
            self.init(parameters: [], results: [valueType])
        case .empty:
            self.init(parameters: [], results: [])
        case let .funcType(typeIndex):
            let typeIndex = Int(typeIndex)
            guard typeIndex < typeSection.count else {
                throw ValidationError(.indexOutOfBounds("type", typeIndex, max: typeSection.count))
            }
            let funcType = typeSection[typeIndex]
            self.init(
                parameters: funcType.parameters,
                results: funcType.results
            )
        }
    }
}

extension ValueType {
    fileprivate static func address(isMemory64: Bool) -> ValueType {
        return isMemory64 ? .i64 : .i32
    }
}

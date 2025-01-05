import WasmParser

/// A register that is used to store a value in the stack.
typealias VReg = Int16

/// A register value that is pre-shifted to avoid runtime shift operation.
protocol ShiftedVReg {
    associatedtype Storage: FixedWidthInteger

    /// The value of the shifted register.
    /// Must be a multiple of `MemoryLayout<StackSlot>.size`.
    var value: Storage { get }
}

/// A larger (32-bit) version of `VReg`
/// Used to utilize halfword loads instructions.
struct LVReg: Equatable, ShiftedVReg, CustomStringConvertible {
    let value: Int32

    init(_ value: VReg) {
        // Pre-shift to avoid runtime shift operation by using
        // unused high bits.
        self.value = Int32(value) * Int32(MemoryLayout<StackSlot>.size)
    }

    init(storage: Int32) {
        self.value = storage
    }

    var description: String {
        "\(value / Int32(MemoryLayout<StackSlot>.size))"
    }
}

/// A larger (64-bit) version of `VReg`
/// Used to utilize word loads instructions.
struct LLVReg: Equatable, ShiftedVReg, CustomStringConvertible {
    let value: Int64

    init(_ value: VReg) {
        // Pre-shift to avoid runtime shift operation by using
        // unused high bits.
        self.value = Int64(value) * Int64(MemoryLayout<StackSlot>.size)
    }

    init(storage: Int64) {
        self.value = storage
    }

    var description: String {
        "\(value / Int64(MemoryLayout<StackSlot>.size))"
    }
}

// MARK: - Immediate load/emit support

/// A protocol that represents an immediate associated with an instruction.
protocol InstructionImmediate {
    /// Loads an immediate from the instruction sequence.
    ///
    /// - Parameter pc: The program counter to read from.
    /// - Returns: The loaded immediate.
    static func load(from pc: inout Pc) -> Self

    /// Emits the layout of the immediate to be emitted.
    ///
    /// - Parameter emitSlot: The closure to schedule a slot emission.
    ///             This closure receives a builder closure that builds the slot.
    ///
    /// - Note: This method is intended to work at meta-level to allow
    ///         knowing the size of slots without actual immediate values.
    static func emit(to emitSlot: @escaping ((Self) -> CodeSlot) -> Void)
}

extension InstructionImmediate {
    /// Emits the immediate value
    ///
    /// - Parameter emitSlot: The closure to emit a slot.
    func emit(to emitSlot: @escaping (CodeSlot) -> Void) {
        Self.emit { buildCodeSlot in
            emitSlot(buildCodeSlot(self))
        }
    }
}

extension UInt32: InstructionImmediate {
    static func load(from pc: inout Pc) -> Self {
        UInt32(pc.read(UInt64.self))
    }
    static func emit(to emitSlot: @escaping ((Self) -> CodeSlot) -> Void) {
        emitSlot { CodeSlot($0) }
    }
}

extension Int32: InstructionImmediate {
    static func load(from pc: inout Pc) -> Self {
        Int32(bitPattern: UInt32(pc.read(UInt64.self)))
    }
    static func emit(to emitSlot: @escaping ((Self) -> CodeSlot) -> Void) {
        emitSlot { CodeSlot(UInt32(bitPattern: $0)) }
    }
}

// MARK: - Immediate type extensions

extension Instruction.RefNullOperand {
    init(result: VReg, type: AbstractHeapType) {
        self.init(result: result, rawType: type.rawValue)  // need to figure out rawType here
    }

    var type: AbstractHeapType {
        AbstractHeapType(rawValue: rawType).unsafelyUnwrapped
    }
}

extension Instruction.GlobalAndVRegOperand {
    init(reg: LLVReg, global: InternalGlobal) {
        self.init(reg: reg, rawGlobal: UInt64(UInt(bitPattern: global.bitPattern)))
    }
    var global: InternalGlobal {
        InternalGlobal(bitPattern: UInt(rawGlobal)).unsafelyUnwrapped
    }
}

extension Instruction.BrTableOperand {
    struct Entry {
        var offset: Int32
    }

    init(baseAddress: UnsafePointer<Entry>, count: UInt16, index: VReg) {
        self.init(rawBaseAddress: UInt64(UInt(bitPattern: baseAddress)), count: count, index: index)
    }

    var baseAddress: UnsafePointer<Entry> {
        UnsafePointer(bitPattern: UInt(rawBaseAddress)).unsafelyUnwrapped
    }
}

extension Instruction.CallOperand {
    init(callee: InternalFunction, spAddend: VReg) {
        self.init(rawCallee: UInt64(UInt(bitPattern: callee.bitPattern)), spAddend: spAddend)
    }

    var callee: InternalFunction {
        InternalFunction(bitPattern: Int(bitPattern: UInt(rawCallee)))
    }
}

extension Instruction.CallIndirectOperand {

    init(tableIndex: UInt32, type: InternedFuncType, index: VReg, spAddend: VReg) {
        self.init(tableIndex: tableIndex, rawType: type.id, index: index, spAddend: spAddend)
    }

    var type: InternedFuncType {
        InternedFuncType(id: rawType)
    }
}

extension Instruction.ReturnCallOperand {
    init(callee: InternalFunction) {
        self.init(rawCallee: UInt64(UInt(bitPattern: callee.bitPattern)))
    }

    var callee: InternalFunction {
        InternalFunction(bitPattern: Int(bitPattern: UInt(rawCallee)))
    }
}

extension Instruction.ReturnCallIndirectOperand {

    init(tableIndex: UInt32, type: InternedFuncType, index: VReg) {
        self.init(tableIndex: tableIndex, rawType: type.id, index: index)
    }

    var type: InternedFuncType {
        InternedFuncType(id: rawType)
    }
}

extension Instruction {
    typealias BrOperand = Int32
    typealias OnEnterOperand = FunctionIndex
    typealias OnExitOperand = FunctionIndex
}

extension RawUnsignedInteger {
    init(_ slot: CodeSlot, shiftWidth: Int) {
        let mask = CodeSlot(Self.max)
        let bitPattern = (slot >> shiftWidth) & mask
        self = Self(bitPattern)
    }

    func bits(shiftWidth: Int) -> CodeSlot {
        CodeSlot(self) << shiftWidth
    }
}

extension RawSignedInteger {
    init(_ slot: CodeSlot, shiftWidth: Int) {
        self.init(bitPattern: Unsigned(slot, shiftWidth: shiftWidth))
    }

    func bits(shiftWidth: Int) -> CodeSlot {
        Unsigned(bitPattern: self).bits(shiftWidth: shiftWidth)
    }
}

extension UntypedValue {
    init(_ slot: CodeSlot, shiftWidth: Int) {
        self.init(storage: slot)
    }

    func bits(shiftWidth: Int) -> CodeSlot { storage }
}

/// The type of an opcode identifier.
typealias OpcodeID = UInt64

extension Instruction {
    func headSlot(threadingModel: EngineConfiguration.ThreadingModel) -> CodeSlot {
        switch threadingModel {
        case .direct:
            return CodeSlot(handler)
        case .token:
            return opcodeID
        }
    }
}

// MARK: - Instruction printing support

extension InstructionSequence {
    func write<Target>(to target: inout Target, context: inout InstructionPrintingContext) where Target: TextOutputStream {
        var hexOffsetWidth = String(instructions.count - 1, radix: 16).count
        hexOffsetWidth = (hexOffsetWidth + 1) & ~1

        guard let cursorStart = instructions.baseAddress else { return }
        let cursorEnd = cursorStart.advanced(by: instructions.count)

        var cursor = cursorStart
        while cursor < cursorEnd {
            let index = cursor - cursorStart
            var hexOffset = String(index, radix: 16)
            while hexOffset.count < hexOffsetWidth {
                hexOffset = "0" + hexOffset
            }
            target.write("0x\(hexOffset): ")
            let instruction = Instruction.load(from: &cursor)
            context.print(
                instruction: instruction,
                instructionOffset: cursor - cursorStart,
                to: &target
            )
            target.write("\n")
        }
    }
}

struct InstructionPrintingContext {
    let shouldColor: Bool
    let function: Function
    var nameRegistry: NameRegistry

    func reg<R: FixedWidthInteger>(_ reg: R) -> String {
        let adjusted = R(FrameHeaderLayout.size(of: function.type)) + reg
        if shouldColor {
            let regColor = adjusted < 15 ? "\u{001B}[3\(adjusted + 1)m" : ""
            return "\(regColor)reg:\(reg)\u{001B}[0m"
        } else {
            return "reg:\(reg)"
        }
    }
    func reg<R: ShiftedVReg>(_ x: R) -> String { reg(Int(x.value) / MemoryLayout<StackSlot>.size) }

    func offset(_ offset: UInt64) -> String {
        "offset: \(offset)"
    }

    func branchTarget(_ instructionOffset: Int, _ offset: Int) -> String {
        let iseqOffset = instructionOffset + offset
        return "\(offset > 0 ? "+" : "")\(offset) ; 0x\(String(iseqOffset, radix: 16))"
    }

    mutating func callee(_ callee: InternalFunction) -> String {
        return "'" + nameRegistry.symbolicate(callee) + "'"
    }

    func hex<T: BinaryInteger>(_ value: T) -> String {
        let hex = String(value, radix: 16)
        return "0x\(String(repeating: "0", count: 16 - hex.count) + hex)"
    }

    func global(_ global: InternalGlobal) -> String {
        "global:\(hex(global.bitPattern))"
    }

    func value(_ value: UntypedValue) -> String {
        "untyped:\(hex(value.storage))"
    }

    mutating func print<Target>(
        instruction: Instruction,
        instructionOffset: Int,
        to target: inout Target
    ) where Target: TextOutputStream {
        func binop(_ name: String, _ op: Instruction.BinaryOperand) {
            target.write("\(reg(op.result)) = \(name) \(reg(op.lhs)), \(reg(op.rhs))")
        }
        func unop(_ name: String, _ op: Instruction.UnaryOperand) {
            target.write("\(reg(op.result)) = \(name) \(reg(op.input))")
        }
        func load(_ name: String, _ op: Instruction.LoadOperand) {
            target.write("\(reg(op.result)) = \(name) \(reg(op.pointer)), \(offset(op.offset))")
        }
        func store(_ name: String, _ op: Instruction.StoreOperand) {
            target.write("\(name) \(reg(op.pointer)) + \(offset(op.offset)), \(reg(op.value))")
        }
        switch instruction {
        case .unreachable:
            target.write("unreachable")
        case .nop:
            target.write("nop")
        case .copyStack(let op):
            target.write("\(reg(op.dest)) = copy \(reg(op.source))")
        case .globalGet(let op):
            target.write("\(reg(op.reg)) = global.get \(global(op.global))")
        case .globalSet(let op):
            target.write("global.set \(global(op.global)), \(reg(op.reg))")
        case .const32(let op):
            target.write("\(reg(op.result)) = \(hex(op.value))")
        case .call(let op):
            target.write("call \(callee(op.callee)), sp: +\(op.spAddend)")
        case .callIndirect(let op):
            target.write("call_indirect \(reg(op.index)), \(op.tableIndex), (func_ty id:\(op.type.id)), sp: +\(op.spAddend)")
        case .compilingCall(let op):
            target.write("compiling_call \(callee(op.callee)), sp: +\(op.spAddend)")
        case .returnCall(let op):
            target.write("return_call \(callee(op.callee))")
        case .i32Load(let op): load("i32.load", op)
        case .i64Load(let op): load("i64.load", op)
        case .f32Load(let op): load("f32.load", op)
        case .f64Load(let op): load("f64.load", op)
        case .i32Add(let op): binop("i32.add", op)
        case .i32Sub(let op): binop("i32.sub", op)
        case .i32Mul(let op): binop("i32.mul", op)
        case .i32DivS(let op): binop("i32.div_s", op)
        case .i32RemS(let op): binop("i32.rem_s", op)
        case .i32And(let op): binop("i32.and", op)
        case .i32Or(let op): binop("i32.or", op)
        case .i32Xor(let op): binop("i32.xor", op)
        case .i32Shl(let op): binop("i32.shl", op)
        case .i32ShrS(let op): binop("i32.shr_s", op)
        case .i32ShrU(let op): binop("i32.shr_u", op)
        case .i32Rotl(let op): binop("i32.rotl", op)
        case .i32Rotr(let op): binop("i32.rotr", op)
        case .i32LtU(let op): binop("i32.lt_u", op)
        case .i32GeU(let op): binop("i32.ge_u", op)
        case .i32Eq(let op): binop("i32.eq", op)
        case .i32Eqz(let op): unop("i32.eqz", op)
        case .i64Add(let op): binop("i64.add", op)
        case .i64Sub(let op): binop("i64.sub", op)
        case .i64Mul(let op): binop("i64.mul", op)
        case .i64DivS(let op): binop("i64.div_s", op)
        case .i64RemS(let op): binop("i64.rem_s", op)
        case .i64And(let op): binop("i64.and", op)
        case .i64Or(let op): binop("i64.or", op)
        case .i64Xor(let op): binop("i64.xor", op)
        case .i64Shl(let op): binop("i64.shl", op)
        case .i64ShrS(let op): binop("i64.shr_s", op)
        case .i64ShrU(let op): binop("i64.shr_u", op)
        case .i64Eq(let op): binop("i64.eq", op)
        case .i64Eqz(let op): unop("i64.eqz", op)
        case .i32Store(let op): store("i32.store", op)
        case .brIfNot(let op):
            target.write("br_if_not \(reg(op.condition)), \(branchTarget(instructionOffset, Int(op.offset)))")
        case .brIf(let op):
            target.write("br_if \(reg(op.condition)), \(branchTarget(instructionOffset, Int(op.offset)))")
        case .br(let offset):
            target.write("br \(branchTarget(instructionOffset, Int(offset)))")
        case .brTable(let table):
            target.write("br_table \(reg(table.index)), \(table.count) cases")
            for i in 0..<table.count {
                target.write("\n  \(i): \(branchTarget(instructionOffset, Int(table.baseAddress[Int(i)].offset)) )")
            }
        case ._return:
            target.write("return")
        default:
            target.write(String(describing: instruction))
        }
    }
}

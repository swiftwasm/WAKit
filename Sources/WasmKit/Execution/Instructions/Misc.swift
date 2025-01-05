/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/instructions.html#variable-instructions>
extension Execution {
    mutating func globalGet(sp: Sp, immediate: Instruction.GlobalAndVRegOperand) {
        immediate.global.withValue {
            sp[immediate.reg] = $0.rawValue
        }
    }
    mutating func globalSet(sp: Sp, immediate: Instruction.GlobalAndVRegOperand) {
        let value = sp[immediate.reg]
        immediate.global.withValue { $0.rawValue = value }
    }

    mutating func copyStack(sp: Sp, immediate: Instruction.CopyStackOperand) {
        sp[immediate.dest] = sp[immediate.source]
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/exec/instructions.html#reference-instructions>
extension Execution {
    mutating func refNull(sp: Sp, immediate: Instruction.RefNullOperand) {
        let value: Value
        switch immediate.type {
        case .externRef:
            value = .ref(.extern(nil))
        case .funcRef:
            value = .ref(.function(nil))
        }
        sp[immediate.result] = UntypedValue(value)
    }
    mutating func refIsNull(sp: Sp, immediate: Instruction.RefIsNullOperand) {
        let value = sp[immediate.value]

        let result: Value
        if value.isNullRef {
            result = .i32(1)
        } else {
            result = .i32(0)
        }
        sp[immediate.result] = UntypedValue(result)
    }
    mutating func refFunc(sp: Sp, immediate: Instruction.RefFuncOperand) {
        let function = currentInstance(sp: sp).functions[Int(immediate.index)]
        sp[immediate.result] = UntypedValue(.ref(.function(from: function)))
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/exec/instructions.html#numeric-instructions>
extension Execution {
    @inline(__always)
    mutating func const32(sp: Sp, immediate: Instruction.Const32Operand) {
        sp[immediate.result] = UntypedValue(storage32: immediate.value)
    }
    @inline(__always)
    mutating func const64(sp: Sp, immediate: Instruction.Const64Operand) {
        sp[immediate.result] = immediate.value
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/exec/instructions.html#parametric-instructions>
extension Execution {
    mutating func select(sp: Sp, immediate: Instruction.SelectOperand) {
        let flag = sp[i32: immediate.condition]
        let selected = flag != 0 ? immediate.onTrue : immediate.onFalse
        let value = sp[selected]
        sp[immediate.result] = value
    }
}

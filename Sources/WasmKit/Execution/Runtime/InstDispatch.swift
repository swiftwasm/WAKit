// This file is generated by Utilities/generate_inst_dispatch.swift
extension ExecutionState {
    @inline(__always)
    mutating func doExecute(_ instruction: Instruction, runtime: Runtime, stack: inout Stack, locals: UnsafeMutablePointer<Value>) throws -> Bool {
        switch instruction {
        case .unreachable:
            try self.unreachable(runtime: runtime, stack: &stack)
            return true
        case .nop:
            try self.nop(runtime: runtime, stack: &stack)
            return true
        case .block(let endRef, let type):
            self.block(runtime: runtime, stack: &stack, endRef: endRef, type: type)
            return true
        case .loop(let type):
            self.loop(runtime: runtime, stack: &stack, type: type)
            return true
        case .ifThen(let endRef, let type):
            self.ifThen(runtime: runtime, stack: &stack, endRef: endRef, type: type)
            return true
        case .ifThenElse(let elseRef, let endRef, let type):
            self.ifThenElse(runtime: runtime, stack: &stack, elseRef: elseRef, endRef: endRef, type: type)
            return true
        case .end:
            self.end(runtime: runtime, stack: &stack)
            return true
        case .`else`:
            self.`else`(runtime: runtime, stack: &stack)
            return true
        case .br(let labelIndex, let offset, let copyCount, let popCount):
            try self.br(runtime: runtime, stack: &stack, labelIndex: labelIndex, offset: offset, copyCount: copyCount, popCount: popCount)
            return false
        case .brIf(let labelIndex, let offset, let copyCount, let popCount):
            try self.brIf(runtime: runtime, stack: &stack, labelIndex: labelIndex, offset: offset, copyCount: copyCount, popCount: popCount)
            return false
        case .legacyBrIf(let labelIndex):
            try self.legacyBrIf(runtime: runtime, stack: &stack, labelIndex: labelIndex)
            return false
        case .brTable(let brTable):
            try self.brTable(runtime: runtime, stack: &stack, brTable: brTable)
            return false
        case .`return`:
            try self.`return`(runtime: runtime, stack: &stack)
            return false
        case .call(let functionIndex):
            try self.call(runtime: runtime, stack: &stack, functionIndex: functionIndex)
            return false
        case .callIndirect(let tableIndex, let typeIndex):
            try self.callIndirect(runtime: runtime, stack: &stack, tableIndex: tableIndex, typeIndex: typeIndex)
            return false
        case .endOfFunction:
            try self.endOfFunction(runtime: runtime, stack: &stack)
            return false
        case .endOfExecution:
            try self.endOfExecution(runtime: runtime, stack: &stack)
            return false
        case .i32Load(let memarg):
            try self.i32Load(runtime: runtime, stack: &stack, memarg: memarg)
        case .i64Load(let memarg):
            try self.i64Load(runtime: runtime, stack: &stack, memarg: memarg)
        case .f32Load(let memarg):
            try self.f32Load(runtime: runtime, stack: &stack, memarg: memarg)
        case .f64Load(let memarg):
            try self.f64Load(runtime: runtime, stack: &stack, memarg: memarg)
        case .i32Load8S(let memarg):
            try self.i32Load8S(runtime: runtime, stack: &stack, memarg: memarg)
        case .i32Load8U(let memarg):
            try self.i32Load8U(runtime: runtime, stack: &stack, memarg: memarg)
        case .i32Load16S(let memarg):
            try self.i32Load16S(runtime: runtime, stack: &stack, memarg: memarg)
        case .i32Load16U(let memarg):
            try self.i32Load16U(runtime: runtime, stack: &stack, memarg: memarg)
        case .i64Load8S(let memarg):
            try self.i64Load8S(runtime: runtime, stack: &stack, memarg: memarg)
        case .i64Load8U(let memarg):
            try self.i64Load8U(runtime: runtime, stack: &stack, memarg: memarg)
        case .i64Load16S(let memarg):
            try self.i64Load16S(runtime: runtime, stack: &stack, memarg: memarg)
        case .i64Load16U(let memarg):
            try self.i64Load16U(runtime: runtime, stack: &stack, memarg: memarg)
        case .i64Load32S(let memarg):
            try self.i64Load32S(runtime: runtime, stack: &stack, memarg: memarg)
        case .i64Load32U(let memarg):
            try self.i64Load32U(runtime: runtime, stack: &stack, memarg: memarg)
        case .i32Store(let memarg):
            try self.i32Store(runtime: runtime, stack: &stack, memarg: memarg)
        case .i64Store(let memarg):
            try self.i64Store(runtime: runtime, stack: &stack, memarg: memarg)
        case .f32Store(let memarg):
            try self.f32Store(runtime: runtime, stack: &stack, memarg: memarg)
        case .f64Store(let memarg):
            try self.f64Store(runtime: runtime, stack: &stack, memarg: memarg)
        case .i32Store8(let memarg):
            try self.i32Store8(runtime: runtime, stack: &stack, memarg: memarg)
        case .i32Store16(let memarg):
            try self.i32Store16(runtime: runtime, stack: &stack, memarg: memarg)
        case .i64Store8(let memarg):
            try self.i64Store8(runtime: runtime, stack: &stack, memarg: memarg)
        case .i64Store16(let memarg):
            try self.i64Store16(runtime: runtime, stack: &stack, memarg: memarg)
        case .i64Store32(let memarg):
            try self.i64Store32(runtime: runtime, stack: &stack, memarg: memarg)
        case .memorySize:
            self.memorySize(runtime: runtime, stack: &stack)
        case .memoryGrow:
            try self.memoryGrow(runtime: runtime, stack: &stack)
        case .memoryInit(let dataIndex):
            try self.memoryInit(runtime: runtime, stack: &stack, dataIndex: dataIndex)
        case .memoryDataDrop(let dataIndex):
            self.memoryDataDrop(runtime: runtime, stack: &stack, dataIndex: dataIndex)
        case .memoryCopy:
            try self.memoryCopy(runtime: runtime, stack: &stack)
        case .memoryFill:
            try self.memoryFill(runtime: runtime, stack: &stack)
        case .numericConst(let value):
            self.numericConst(runtime: runtime, stack: &stack, value: value)
        case .numericFloatUnary(let floatUnary):
            self.numericFloatUnary(runtime: runtime, stack: &stack, floatUnary: floatUnary)
        case .numericIntBinary(let intBinary):
            try self.numericIntBinary(runtime: runtime, stack: &stack, intBinary: intBinary)
        case .numericFloatBinary(let floatBinary):
            self.numericFloatBinary(runtime: runtime, stack: &stack, floatBinary: floatBinary)
        case .numericConversion(let conversion):
            try self.numericConversion(runtime: runtime, stack: &stack, conversion: conversion)
        case .i32Add:
            self.i32Add(runtime: runtime, stack: &stack)
        case .i64Add:
            self.i64Add(runtime: runtime, stack: &stack)
        case .f32Add:
            self.f32Add(runtime: runtime, stack: &stack)
        case .f64Add:
            self.f64Add(runtime: runtime, stack: &stack)
        case .i32Sub:
            self.i32Sub(runtime: runtime, stack: &stack)
        case .i64Sub:
            self.i64Sub(runtime: runtime, stack: &stack)
        case .f32Sub:
            self.f32Sub(runtime: runtime, stack: &stack)
        case .f64Sub:
            self.f64Sub(runtime: runtime, stack: &stack)
        case .i32Mul:
            self.i32Mul(runtime: runtime, stack: &stack)
        case .i64Mul:
            self.i64Mul(runtime: runtime, stack: &stack)
        case .f32Mul:
            self.f32Mul(runtime: runtime, stack: &stack)
        case .f64Mul:
            self.f64Mul(runtime: runtime, stack: &stack)
        case .i32Eq:
            self.i32Eq(runtime: runtime, stack: &stack)
        case .i64Eq:
            self.i64Eq(runtime: runtime, stack: &stack)
        case .f32Eq:
            self.f32Eq(runtime: runtime, stack: &stack)
        case .f64Eq:
            self.f64Eq(runtime: runtime, stack: &stack)
        case .i32Ne:
            self.i32Ne(runtime: runtime, stack: &stack)
        case .i64Ne:
            self.i64Ne(runtime: runtime, stack: &stack)
        case .f32Ne:
            self.f32Ne(runtime: runtime, stack: &stack)
        case .f64Ne:
            self.f64Ne(runtime: runtime, stack: &stack)
        case .i32LtS:
            self.i32LtS(runtime: runtime, stack: &stack)
        case .i64LtS:
            self.i64LtS(runtime: runtime, stack: &stack)
        case .i32LtU:
            self.i32LtU(runtime: runtime, stack: &stack)
        case .i64LtU:
            self.i64LtU(runtime: runtime, stack: &stack)
        case .i32GtS:
            self.i32GtS(runtime: runtime, stack: &stack)
        case .i64GtS:
            self.i64GtS(runtime: runtime, stack: &stack)
        case .i32GtU:
            self.i32GtU(runtime: runtime, stack: &stack)
        case .i64GtU:
            self.i64GtU(runtime: runtime, stack: &stack)
        case .i32LeS:
            self.i32LeS(runtime: runtime, stack: &stack)
        case .i64LeS:
            self.i64LeS(runtime: runtime, stack: &stack)
        case .i32LeU:
            self.i32LeU(runtime: runtime, stack: &stack)
        case .i64LeU:
            self.i64LeU(runtime: runtime, stack: &stack)
        case .i32GeS:
            self.i32GeS(runtime: runtime, stack: &stack)
        case .i64GeS:
            self.i64GeS(runtime: runtime, stack: &stack)
        case .i32GeU:
            self.i32GeU(runtime: runtime, stack: &stack)
        case .i64GeU:
            self.i64GeU(runtime: runtime, stack: &stack)
        case .i32Clz:
            self.i32Clz(runtime: runtime, stack: &stack)
        case .i64Clz:
            self.i64Clz(runtime: runtime, stack: &stack)
        case .i32Ctz:
            self.i32Ctz(runtime: runtime, stack: &stack)
        case .i64Ctz:
            self.i64Ctz(runtime: runtime, stack: &stack)
        case .i32Popcnt:
            self.i32Popcnt(runtime: runtime, stack: &stack)
        case .i64Popcnt:
            self.i64Popcnt(runtime: runtime, stack: &stack)
        case .i32Eqz:
            self.i32Eqz(runtime: runtime, stack: &stack)
        case .i64Eqz:
            self.i64Eqz(runtime: runtime, stack: &stack)
        case .drop:
            self.drop(runtime: runtime, stack: &stack)
        case .select:
            try self.select(runtime: runtime, stack: &stack)
        case .refNull(let referenceType):
            self.refNull(runtime: runtime, stack: &stack, referenceType: referenceType)
        case .refIsNull:
            self.refIsNull(runtime: runtime, stack: &stack)
        case .refFunc(let functionIndex):
            self.refFunc(runtime: runtime, stack: &stack, functionIndex: functionIndex)
        case .tableGet(let tableIndex):
            try self.tableGet(runtime: runtime, stack: &stack, tableIndex: tableIndex)
        case .tableSet(let tableIndex):
            try self.tableSet(runtime: runtime, stack: &stack, tableIndex: tableIndex)
        case .tableSize(let tableIndex):
            self.tableSize(runtime: runtime, stack: &stack, tableIndex: tableIndex)
        case .tableGrow(let tableIndex):
            self.tableGrow(runtime: runtime, stack: &stack, tableIndex: tableIndex)
        case .tableFill(let tableIndex):
            try self.tableFill(runtime: runtime, stack: &stack, tableIndex: tableIndex)
        case .tableCopy(let dest, let src):
            try self.tableCopy(runtime: runtime, stack: &stack, dest: dest, src: src)
        case .tableInit(let tableIndex, let elementIndex):
            try self.tableInit(runtime: runtime, stack: &stack, tableIndex: tableIndex, elementIndex: elementIndex)
        case .tableElementDrop(let elementIndex):
            self.tableElementDrop(runtime: runtime, stack: &stack, elementIndex: elementIndex)
        case .localGet(let index):
            self.localGet(runtime: runtime, stack: &stack, locals: locals, index: index)
        case .localSet(let index):
            self.localSet(runtime: runtime, stack: &stack, locals: locals, index: index)
        case .localTee(let index):
            self.localTee(runtime: runtime, stack: &stack, locals: locals, index: index)
        case .globalGet(let index):
            try self.globalGet(runtime: runtime, stack: &stack, index: index)
        case .globalSet(let index):
            try self.globalSet(runtime: runtime, stack: &stack, index: index)
        }
        programCounter += 1
        return true
    }
}

extension Instruction {
    var name: String {
        switch self {
        case .unreachable: return "unreachable"
        case .nop: return "nop"
        case .block: return "block"
        case .loop: return "loop"
        case .ifThen: return "ifThen"
        case .ifThenElse: return "ifThenElse"
        case .end: return "end"
        case .`else`: return "`else`"
        case .br: return "br"
        case .brIf: return "brIf"
        case .legacyBrIf: return "legacyBrIf"
        case .brTable: return "brTable"
        case .`return`: return "`return`"
        case .call: return "call"
        case .callIndirect: return "callIndirect"
        case .endOfFunction: return "endOfFunction"
        case .endOfExecution: return "endOfExecution"
        case .i32Load: return "i32Load"
        case .i64Load: return "i64Load"
        case .f32Load: return "f32Load"
        case .f64Load: return "f64Load"
        case .i32Load8S: return "i32Load8S"
        case .i32Load8U: return "i32Load8U"
        case .i32Load16S: return "i32Load16S"
        case .i32Load16U: return "i32Load16U"
        case .i64Load8S: return "i64Load8S"
        case .i64Load8U: return "i64Load8U"
        case .i64Load16S: return "i64Load16S"
        case .i64Load16U: return "i64Load16U"
        case .i64Load32S: return "i64Load32S"
        case .i64Load32U: return "i64Load32U"
        case .i32Store: return "i32Store"
        case .i64Store: return "i64Store"
        case .f32Store: return "f32Store"
        case .f64Store: return "f64Store"
        case .i32Store8: return "i32Store8"
        case .i32Store16: return "i32Store16"
        case .i64Store8: return "i64Store8"
        case .i64Store16: return "i64Store16"
        case .i64Store32: return "i64Store32"
        case .memorySize: return "memorySize"
        case .memoryGrow: return "memoryGrow"
        case .memoryInit: return "memoryInit"
        case .memoryDataDrop: return "memoryDataDrop"
        case .memoryCopy: return "memoryCopy"
        case .memoryFill: return "memoryFill"
        case .numericConst: return "numericConst"
        case .numericFloatUnary: return "numericFloatUnary"
        case .numericIntBinary: return "numericIntBinary"
        case .numericFloatBinary: return "numericFloatBinary"
        case .numericConversion: return "numericConversion"
        case .i32Add: return "i32Add"
        case .i64Add: return "i64Add"
        case .f32Add: return "f32Add"
        case .f64Add: return "f64Add"
        case .i32Sub: return "i32Sub"
        case .i64Sub: return "i64Sub"
        case .f32Sub: return "f32Sub"
        case .f64Sub: return "f64Sub"
        case .i32Mul: return "i32Mul"
        case .i64Mul: return "i64Mul"
        case .f32Mul: return "f32Mul"
        case .f64Mul: return "f64Mul"
        case .i32Eq: return "i32Eq"
        case .i64Eq: return "i64Eq"
        case .f32Eq: return "f32Eq"
        case .f64Eq: return "f64Eq"
        case .i32Ne: return "i32Ne"
        case .i64Ne: return "i64Ne"
        case .f32Ne: return "f32Ne"
        case .f64Ne: return "f64Ne"
        case .i32LtS: return "i32LtS"
        case .i64LtS: return "i64LtS"
        case .i32LtU: return "i32LtU"
        case .i64LtU: return "i64LtU"
        case .i32GtS: return "i32GtS"
        case .i64GtS: return "i64GtS"
        case .i32GtU: return "i32GtU"
        case .i64GtU: return "i64GtU"
        case .i32LeS: return "i32LeS"
        case .i64LeS: return "i64LeS"
        case .i32LeU: return "i32LeU"
        case .i64LeU: return "i64LeU"
        case .i32GeS: return "i32GeS"
        case .i64GeS: return "i64GeS"
        case .i32GeU: return "i32GeU"
        case .i64GeU: return "i64GeU"
        case .i32Clz: return "i32Clz"
        case .i64Clz: return "i64Clz"
        case .i32Ctz: return "i32Ctz"
        case .i64Ctz: return "i64Ctz"
        case .i32Popcnt: return "i32Popcnt"
        case .i64Popcnt: return "i64Popcnt"
        case .i32Eqz: return "i32Eqz"
        case .i64Eqz: return "i64Eqz"
        case .drop: return "drop"
        case .select: return "select"
        case .refNull: return "refNull"
        case .refIsNull: return "refIsNull"
        case .refFunc: return "refFunc"
        case .tableGet: return "tableGet"
        case .tableSet: return "tableSet"
        case .tableSize: return "tableSize"
        case .tableGrow: return "tableGrow"
        case .tableFill: return "tableFill"
        case .tableCopy: return "tableCopy"
        case .tableInit: return "tableInit"
        case .tableElementDrop: return "tableElementDrop"
        case .localGet: return "localGet"
        case .localSet: return "localSet"
        case .localTee: return "localTee"
        case .globalGet: return "globalGet"
        case .globalSet: return "globalSet"
        }
    }
}

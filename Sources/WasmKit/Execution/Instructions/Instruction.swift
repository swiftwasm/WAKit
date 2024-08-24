enum Instruction: Equatable {
    case copyStack(Instruction.CopyStackOperand)
    case globalGet(Instruction.GlobalGetOperand)
    case globalSet(Instruction.GlobalSetOperand)
    case call(Instruction.CallOperand)
    case compilingCall(Instruction.CompilingCallOperand)
    case internalCall(Instruction.InternalCallOperand)
    case callIndirect(Instruction.CallIndirectOperand)
    case unreachable
    case nop
    case ifThen(Instruction.IfOperand)
    case br(offset: Int32)
    case brIf(Instruction.BrIfOperand)
    case brIfNot(Instruction.BrIfOperand)
    case brTable(Instruction.BrTableOperand)
    case `return`
    case endOfExecution
    case i32Load(Instruction.LoadOperand)
    case i64Load(Instruction.LoadOperand)
    case f32Load(Instruction.LoadOperand)
    case f64Load(Instruction.LoadOperand)
    case i32Load8S(Instruction.LoadOperand)
    case i32Load8U(Instruction.LoadOperand)
    case i32Load16S(Instruction.LoadOperand)
    case i32Load16U(Instruction.LoadOperand)
    case i64Load8S(Instruction.LoadOperand)
    case i64Load8U(Instruction.LoadOperand)
    case i64Load16S(Instruction.LoadOperand)
    case i64Load16U(Instruction.LoadOperand)
    case i64Load32S(Instruction.LoadOperand)
    case i64Load32U(Instruction.LoadOperand)
    case i32Store(Instruction.StoreOperand)
    case i64Store(Instruction.StoreOperand)
    case f32Store(Instruction.StoreOperand)
    case f64Store(Instruction.StoreOperand)
    case i32Store8(Instruction.StoreOperand)
    case i32Store16(Instruction.StoreOperand)
    case i64Store8(Instruction.StoreOperand)
    case i64Store16(Instruction.StoreOperand)
    case i64Store32(Instruction.StoreOperand)
    case memorySize(Instruction.MemorySizeOperand)
    case memoryGrow(Instruction.MemoryGrowOperand)
    case memoryInit(Instruction.MemoryInitOperand)
    case memoryDataDrop(DataIndex)
    case memoryCopy(Instruction.MemoryCopyOperand)
    case memoryFill(Instruction.MemoryFillOperand)
    case numericConst(Instruction.ConstOperand)
    case numericFloatUnary(NumericInstruction.FloatUnary, Instruction.UnaryOperand)
    case numericIntBinary(NumericInstruction.IntBinary, Instruction.BinaryOperand)
    case numericFloatBinary(NumericInstruction.FloatBinary, Instruction.BinaryOperand)
    case numericConversion(NumericInstruction.Conversion, Instruction.UnaryOperand)
    case i32Add(Instruction.BinaryOperand)
    case i64Add(Instruction.BinaryOperand)
    case f32Add(Instruction.BinaryOperand)
    case f64Add(Instruction.BinaryOperand)
    case i32Sub(Instruction.BinaryOperand)
    case i64Sub(Instruction.BinaryOperand)
    case f32Sub(Instruction.BinaryOperand)
    case f64Sub(Instruction.BinaryOperand)
    case i32Mul(Instruction.BinaryOperand)
    case i64Mul(Instruction.BinaryOperand)
    case f32Mul(Instruction.BinaryOperand)
    case f64Mul(Instruction.BinaryOperand)
    case i32Eq(Instruction.BinaryOperand)
    case i64Eq(Instruction.BinaryOperand)
    case f32Eq(Instruction.BinaryOperand)
    case f64Eq(Instruction.BinaryOperand)
    case i32Ne(Instruction.BinaryOperand)
    case i64Ne(Instruction.BinaryOperand)
    case f32Ne(Instruction.BinaryOperand)
    case f64Ne(Instruction.BinaryOperand)
    case i32LtS(Instruction.BinaryOperand)
    case i64LtS(Instruction.BinaryOperand)
    case i32LtU(Instruction.BinaryOperand)
    case i64LtU(Instruction.BinaryOperand)
    case i32GtS(Instruction.BinaryOperand)
    case i64GtS(Instruction.BinaryOperand)
    case i32GtU(Instruction.BinaryOperand)
    case i64GtU(Instruction.BinaryOperand)
    case i32LeS(Instruction.BinaryOperand)
    case i64LeS(Instruction.BinaryOperand)
    case i32LeU(Instruction.BinaryOperand)
    case i64LeU(Instruction.BinaryOperand)
    case i32GeS(Instruction.BinaryOperand)
    case i64GeS(Instruction.BinaryOperand)
    case i32GeU(Instruction.BinaryOperand)
    case i64GeU(Instruction.BinaryOperand)
    case i32And(Instruction.BinaryOperand)
    case i64And(Instruction.BinaryOperand)
    case i32Or(Instruction.BinaryOperand)
    case i64Or(Instruction.BinaryOperand)
    case i32Xor(Instruction.BinaryOperand)
    case i64Xor(Instruction.BinaryOperand)
    case i32Shl(Instruction.BinaryOperand)
    case i64Shl(Instruction.BinaryOperand)
    case i32ShrS(Instruction.BinaryOperand)
    case i64ShrS(Instruction.BinaryOperand)
    case i32ShrU(Instruction.BinaryOperand)
    case i64ShrU(Instruction.BinaryOperand)
    case i32Rotl(Instruction.BinaryOperand)
    case i64Rotl(Instruction.BinaryOperand)
    case i32Rotr(Instruction.BinaryOperand)
    case i64Rotr(Instruction.BinaryOperand)
    case i32Clz(Instruction.UnaryOperand)
    case i64Clz(Instruction.UnaryOperand)
    case i32Ctz(Instruction.UnaryOperand)
    case i64Ctz(Instruction.UnaryOperand)
    case i32Popcnt(Instruction.UnaryOperand)
    case i64Popcnt(Instruction.UnaryOperand)
    case i32Eqz(Instruction.UnaryOperand)
    case i64Eqz(Instruction.UnaryOperand)
    case f32Div(Instruction.BinaryOperand)
    case f64Div(Instruction.BinaryOperand)
    case select(Instruction.SelectOperand)
    case refNull(Instruction.RefNullOperand)
    case refIsNull(Instruction.RefIsNullOperand)
    case refFunc(Instruction.RefFuncOperand)
    case tableGet(Instruction.TableGetOperand)
    case tableSet(Instruction.TableSetOperand)
    case tableSize(Instruction.TableSizeOperand)
    case tableGrow(Instruction.TableGrowOperand)
    case tableFill(Instruction.TableFillOperand)
    case tableCopy(Instruction.TableCopyOperand)
    case tableInit(Instruction.TableInitOperand)
    case tableElementDrop(ElementIndex)
    case onEnter(Instruction.OnEnterOperand)
    case onExit(Instruction.OnExitOperand)
}

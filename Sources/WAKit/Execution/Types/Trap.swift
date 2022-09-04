public enum Trap: Error {
    // FIXME: for debugging purposes, to be eventually deleted
    case _raw(String)
    case _unimplemented(description: String, file: StaticString, line: UInt)

    case unreachable

    // Stack
    case stackTypeMismatch(expected: Any.Type, actual: Any.Type)
    case stackValueTypesMismatch(expected: ValueType, actual: [Any.Type])
    case stackNotFound(Any.Type, index: Int)
    case localIndexOutOfRange(index: UInt32)

    // Store
    case globalIndexOutOfRange(index: UInt32)
    case globalImmutable(index: UInt32)

    // Invocation
    case exportedFunctionNotFound(ModuleInstance, name: String)
    case invalidTypeForInstruction(Any.Type, Instruction)
    case importsAndExternalValuesMismatch
    case tableUninitialized
    case tableOutOfRange
    case callIndirectFunctionTypeMismatch(actual: FunctionType, expected: FunctionType)
    case outOfBoundsMemoryAccess
    case invalidFunctionIndex(Int)
    case poppedLabelMismatch
    case labelMismatch
    case integerDividedByZero
    case integerOverflowed
    case invalidConversionToInteger

    static func unimplemented(_ description: String = "", file: StaticString = #file, line: UInt = #line) -> Trap {
        return ._unimplemented(description: description, file: file, line: line)
    }

    /// Human-readable text representation of the trap that `.wast` text format expects in assertions
    public var assertionText: String {
        switch self {
        case .outOfBoundsMemoryAccess:
            return "out of bounds memory access"
        case .integerDividedByZero:
            return "integer divide by zero"
        case .integerOverflowed:
            return "integer overflow"
        case .invalidConversionToInteger:
            return "invalid conversion to integer"
        default:
            return String(describing: self)
        }
    }
}

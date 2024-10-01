import WasmTypes

public enum Trap: Error {
    // FIXME: for debugging purposes, to be eventually deleted
    case _raw(String)

    case unreachable

    // Stack
    /// Stack overflow
    case stackOverflow
    /// The stack value type does not match the expected type
    case stackValueTypesMismatch(expected: WasmTypes.ValueType, actual: WasmTypes.ValueType)
    /// Too deep call stack
    case callStackExhausted

    // Store
    /// Out of bounds table access
    case outOfBoundsTableAccess(Int)
    /// Reading a dropped reference
    case readingDroppedReference(index: Int)

    // Invocation
    /// Exported function not found
    case exportedFunctionNotFound(Instance, name: String)
    /// The table element is not initialized
    case tableUninitialized(Int)
    /// Undefined element in the table
    case undefinedElement
    /// Table size overflow
    case tableSizeOverflow
    /// Indirect call type mismatch
    case callIndirectFunctionTypeMismatch(actual: FunctionType, expected: FunctionType)
    /// Out of bounds memory access
    case outOfBoundsMemoryAccess
    /// Invalid function index
    case invalidFunctionIndex(Int)
    /// Integer divided by zero
    case integerDividedByZero
    /// Integer overflowed during arithmetic operation
    case integerOverflowed
    /// Invalid conversion to integer
    case invalidConversionToInteger

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
        case .undefinedElement:
            return "undefined element"
        case let .tableUninitialized(elementIndex):
            return "uninitialized element \(elementIndex)"
        case .callIndirectFunctionTypeMismatch:
            return "indirect call type mismatch"
        case .outOfBoundsTableAccess, .tableSizeOverflow:
            return "out of bounds table access"
        case .callStackExhausted:
            return "call stack exhausted"
        default:
            return String(describing: self)
        }
    }
}

public enum InstantiationError: Error {
    case importsAndExternalValuesMismatch
    case invalidTableExpression
    case outOfBoundsTableAccess
    case outOfBoundsMemoryAccess
    case unsupported(String)
    case exportIndexOutOfBounds(kind: String, index: Int, count: Int)

    /// Human-readable text representation of the trap that `.wast` text format expects in assertions
    public var assertionText: String {
        switch self {
        case .outOfBoundsTableAccess:
            return "out of bounds table access"
        case .outOfBoundsMemoryAccess:
            return "out of bounds memory access"
        case .unsupported(let message):
            return "unsupported operation: \(message)"
        default:
            return String(describing: self)
        }
    }
}

public enum ImportError: Error {
    case unknownImport(moduleName: String, externalName: String)
    case incompatibleImportType
    case importedEntityFromDifferentStore
    case moduleInstanceAlreadyRegistered(String)

    /// Human-readable text representation of the trap that `.wast` text format expects in assertions
    public var assertionText: String {
        switch self {
        case .unknownImport:
            return "unknown import"
        case .incompatibleImportType:
            return "incompatible import type"
        case .importedEntityFromDifferentStore:
            return "imported entity from different store"
        case let .moduleInstanceAlreadyRegistered(name):
            return "a module instance is already registered under a name `\(name)"
        }
    }
}

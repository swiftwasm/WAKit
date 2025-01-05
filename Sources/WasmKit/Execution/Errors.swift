import WasmTypes

import struct WasmParser.Import

/// The backtrace of the trap.
struct Backtrace: CustomStringConvertible {
    /// A symbol in the backtrace.
    struct Symbol {
        /// The function that the symbol represents.
        let function: Function

        /// The name of the symbol.
        let name: String?
    }

    /// The symbols in the backtrace.
    let symbols: [Symbol?]

    /// Textual description of the backtrace.
    var description: String {
        symbols.enumerated().map { (index, symbol) in
            let name = symbol?.name ?? "unknown"
            return "    \(index): \(name)"
        }.joined(separator: "\n")
    }
}

/// An error that occurs during execution of a WebAssembly module.
public struct Trap: Error, CustomStringConvertible {
    /// The reason for the trap.
    var reason: TrapReason

    /// The backtrace of the trap.
    private(set) var backtrace: Backtrace?

    init(_ code: TrapReason, backtrace: Backtrace? = nil) {
        self.reason = code
        self.backtrace = backtrace
    }

    init(_ message: TrapReason.Message, backtrace: Backtrace? = nil) {
        self.init(.message(message), backtrace: backtrace)
    }

    /// The description of the trap.
    public var description: String {
        var desc = "Trap: \(reason)"
        if let backtrace = backtrace {
            desc += "\n\(backtrace)"
        }
        return desc
    }

    func withBacktrace(_ backtrace: Backtrace) -> Trap {
        var trap = self
        trap.backtrace = backtrace
        return trap
    }
}

/// A reason for a trap that occurred during execution of a WebAssembly module.
enum TrapReason: Error, CustomStringConvertible {
    struct Message {
        let text: String

        init(_ text: String) {
            self.text = text
        }
    }
    /// A trap with a string message
    case message(Message)
    /// `unreachable` instruction executed
    case unreachable
    /// Too deep call stack
    ///
    /// Note: When this trap occurs, consider extending ``EngineConfiguration/stackSize``.
    case callStackExhausted
    /// Out of bounds table access
    case tableOutOfBounds(Int)
    /// Out of bounds memory access
    case memoryOutOfBounds
    /// `call_indirect` instruction called an uninitialized table element.
    case indirectCallToNull(Int)
    /// Indirect call type mismatch
    case typeMismatchCall(actual: FunctionType, expected: FunctionType)
    /// Integer divided by zero
    case integerDividedByZero
    /// Integer overflowed during arithmetic operation
    case integerOverflow
    /// Invalid conversion to integer
    case invalidConversionToInteger

    /// The description of the trap reason.
    var description: String {
        switch self {
        case .message(let message):
            return message.text
        case .unreachable:
            return "unreachable"
        case .callStackExhausted:
            return "call stack exhausted"
        case .memoryOutOfBounds:
            return "out of bounds memory access"
        case .integerDividedByZero:
            return "integer divide by zero"
        case .integerOverflow:
            return "integer overflow"
        case .invalidConversionToInteger:
            return "invalid conversion to integer"
        case let .indirectCallToNull(elementIndex):
            return "indirect call to null element (uninitialized element \(elementIndex))"
        case .typeMismatchCall(let actual, let expected):
            return "indirect call type mismatch, expected \(expected), got \(actual)"
        case .tableOutOfBounds(let index):
            return "out of bounds table access at \(index) (undefined element)"
        }
    }
}

extension TrapReason.Message {
    static func initialTableSizeExceedsLimit(numberOfElements: Int) -> Self {
        Self("initial table size exceeds the resource limit: \(numberOfElements) elements")
    }
    static func initialMemorySizeExceedsLimit(byteSize: Int) -> Self {
        Self("initial memory size exceeds the resource limit: \(byteSize) bytes")
    }
    static func parameterTypesMismatch(expected: [ValueType], got: [Value]) -> Self {
        Self("parameter types don't match, expected \(expected), got \(got)")
    }
    static func resultTypesMismatch(expected: [ValueType], got: [Value]) -> Self {
        Self("result types don't match, expected \(expected), got \(got)")
    }
    static var cannotAssignToImmutableGlobal: Self {
        Self("cannot assign to an immutable global")
    }
    static func noGlobalExportWithName(globalName: String, instance: Instance) -> Self {
        Self("no global export with name \(globalName) in a module instance \(instance)")
    }
    static func exportedFunctionNotFound(name: String, instance: Instance) -> Self {
        Self("exported function \(name) not found in instance \(instance)")
    }
    static func unimplemented(feature: String) -> Self {
        Self("\(feature) is not implemented yet")
    }
}

struct ImportError: Error {
    struct Message {
        let text: String

        init(_ text: String) {
            self.text = text
        }
    }

    let message: Message

    init(_ message: Message) {
        self.message = message
    }
}

extension ImportError.Message {
    static func missing(moduleName: String, externalName: String) -> Self {
        Self("unknown import \(moduleName).\(externalName)")
    }
    static func incompatibleType(_ importEntry: Import, entity: InternalExternalValue) -> Self {
        let expected: String
        switch importEntry.descriptor {
        case .function:
            expected = "function"
        case .global:
            expected = "global"
        case .memory:
            expected = "memory"
        case .table:
            expected = "table"
        }
        let got: String
        switch entity {
        case .function:
            got = "function"
        case .global:
            got = "global"
        case .memory:
            got = "memory"
        case .table:
            got = "table"
        }
        return Self("incompatible import type for \(importEntry.module).\(importEntry.name), expected \(expected), got \(got)")
    }
    static func incompatibleFunctionType(_ importEntry: Import, actual: FunctionType, expected: FunctionType) -> Self {
        Self("incompatible import type: function type for \(importEntry.module).\(importEntry.name), expected \(expected), got \(actual)")
    }
    static func incompatibleTableType(_ importEntry: Import, actual: TableType, expected: TableType) -> Self {
        Self("incompatible import type: table type for \(importEntry.module).\(importEntry.name), expected \(expected), got \(actual)")
    }
    static func incompatibleMemoryType(_ importEntry: Import, actual: MemoryType, expected: MemoryType) -> Self {
        Self("incompatible import type: memory type for \(importEntry.module).\(importEntry.name), expected \(expected), got \(actual)")
    }
    static func incompatibleGlobalType(_ importEntry: Import, actual: GlobalType, expected: GlobalType) -> Self {
        Self("incompatible import type: global type for \(importEntry.module).\(importEntry.name), expected \(expected), got \(actual)")
    }
    static func importedEntityFromDifferentStore(_ importEntry: Import) -> Self {
        Self("imported entity from different store: \(importEntry.module).\(importEntry.name)")
    }
    static func moduleInstanceAlreadyRegistered(_ name: String) -> Self {
        Self("a module instance is already registered under a name `\(name)")
    }
}

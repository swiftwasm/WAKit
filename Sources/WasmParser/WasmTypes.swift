import WasmTypes

/// Function code in a module
/// > Note:
/// <https://webassembly.github.io/spec/core/binary/modules.html#binary-code>
public struct Code {
    /// Local variables in the function
    public let locals: [ValueType]
    /// Expression body of the function
    public let expression: ArraySlice<UInt8>

    // Parser state used to parse the expression body lazily
    @usableFromInline
    internal let hasDataCount: Bool
    @usableFromInline
    internal let features: WasmFeatureSet
}

extension Code: Equatable {
    public static func == (lhs: Code, rhs: Code) -> Bool {
        return lhs.locals == rhs.locals && lhs.expression == rhs.expression
    }
}

public struct MemArg: Equatable {
    public let offset: UInt64
    public let align: UInt32

    public init(offset: UInt64, align: UInt32) {
        self.offset = offset
        self.align = align
    }
}

public enum BlockType: Equatable {
    case empty
    case type(ValueType)
    case funcType(UInt32)
}

/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/types.html#limits>
public struct Limits: Equatable {
    public let min: UInt64
    public let max: UInt64?
    public let isMemory64: Bool
    public let shared: Bool

    public init(min: UInt64, max: UInt64?, isMemory64: Bool = false, shared: Bool = false) {
        self.min = min
        self.max = max
        self.isMemory64 = isMemory64
        self.shared = shared
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/types.html#memory-types>
public typealias MemoryType = Limits

/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/types.html#table-types>
public struct TableType: Equatable {
    public let elementType: ReferenceType
    public let limits: Limits

    public init(elementType: ReferenceType, limits: Limits) {
        self.elementType = elementType
        self.limits = limits
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/types.html#global-types>
public enum Mutability: Equatable {
    case constant
    case variable
}

/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/types.html#global-types>
public struct GlobalType: Equatable {
    public let mutability: Mutability
    public let valueType: ValueType

    public init(mutability: Mutability, valueType: ValueType) {
        self.mutability = mutability
        self.valueType = valueType
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/types.html#external-types>
public enum ExternalType {
    case function(FunctionType)
    case table(TableType)
    case memory(MemoryType)
    case global(GlobalType)
}

public enum IEEE754 {
    public struct Float32: Equatable {
        public let bitPattern: UInt32

        public init(bitPattern: UInt32) {
            self.bitPattern = bitPattern
        }
    }
    public struct Float64: Equatable {
        public let bitPattern: UInt64

        public init(bitPattern: UInt64) {
            self.bitPattern = bitPattern
        }
    }
}

public struct BrTable: Equatable {
    public let labelIndices: [UInt32]
    public let defaultIndex: UInt32

    public init(labelIndices: [UInt32], defaultIndex: UInt32) {
        self.labelIndices = labelIndices
        self.defaultIndex = defaultIndex
    }
}

/// A custom section in a module
public struct CustomSection: Equatable {
    public let name: String
    public let bytes: ArraySlice<UInt8>
}

/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/modules.html#syntax-typeidx>

/// Index type for function types within a module
public typealias TypeIndex = UInt32
/// Index type for tables within a module
public typealias FunctionIndex = UInt32
/// Index type for tables within a module
public typealias TableIndex = UInt32
/// Index type for memories within a module
public typealias MemoryIndex = UInt32
/// Index type for globals within a module
public typealias GlobalIndex = UInt32
/// Index type for elements within a module
public typealias ElementIndex = UInt32
/// Index type for data segments within a module
public typealias DataIndex = UInt32

public typealias ConstExpression = [Instruction]

/// Table entry in a module
/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/modules.html#tables>
public struct Table: Equatable {
    public let type: TableType

    public init(type: TableType) {
        self.type = type
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/modules.html#memories>
public struct Memory: Equatable {
    public let type: MemoryType
}

/// Global entry in a module
/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/modules.html#globals>
public struct Global: Equatable {
    public let type: GlobalType
    public let initializer: ConstExpression
}

/// Segment of elements that are initialized in a table
/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/modules.html#element-segments>
public struct ElementSegment: Equatable {
    struct Flag: OptionSet {
        let rawValue: UInt32

        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        var segmentHasElemKind: Bool {
            !contains(.usesExpressions) && rawValue != 0
        }

        var segmentHasRefType: Bool {
            contains(.usesExpressions) && rawValue != 4
        }

        static let isPassiveOrDeclarative = Flag(rawValue: 1 << 0)
        static let isDeclarative = Flag(rawValue: 1 << 1)
        static let hasTableIndex = Flag(rawValue: 1 << 1)
        static let usesExpressions = Flag(rawValue: 1 << 2)
    }

    public enum Mode: Equatable {
        case active(table: UInt32, offset: ConstExpression)
        case declarative
        case passive
    }

    public let type: ReferenceType
    public let initializer: [ConstExpression]
    public let mode: Mode
}

/// Data segment in a module
/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/modules.html#data-segments>
public enum DataSegment: Equatable {
    public struct Active: Equatable {
        public let index: UInt32
        public let offset: ConstExpression
        public let initializer: ArraySlice<UInt8>
    }

    case passive(ArraySlice<UInt8>)
    case active(Active)
}

/// Exported entity in a module
/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/modules.html#exports>
public struct Export: Equatable {
    /// Name of the export
    public let name: String
    /// Descriptor of the export
    public let descriptor: ExportDescriptor

    public init(name: String, descriptor: ExportDescriptor) {
        self.name = name
        self.descriptor = descriptor
    }
}

/// Export descriptor
public enum ExportDescriptor: Equatable {
    /// Function export
    case function(FunctionIndex)
    /// Table export
    case table(TableIndex)
    /// Memory export
    case memory(MemoryIndex)
    /// Global export
    case global(GlobalIndex)
}

/// Import entity in a module
/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/modules.html#imports>
public struct Import: Equatable {
    /// Module name imported from
    public let module: String
    /// Name of the import
    public let name: String
    /// Descriptor of the import
    public let descriptor: ImportDescriptor

    public init(module: String, name: String, descriptor: ImportDescriptor) {
        self.module = module
        self.name = name
        self.descriptor = descriptor
    }
}

/// Import descriptor
public enum ImportDescriptor: Equatable {
    /// Function import
    case function(TypeIndex)
    /// Table import
    case table(TableType)
    /// Memory import
    case memory(MemoryType)
    /// Global import
    case global(GlobalType)
}

@usableFromInline
protocol RawUnsignedInteger: FixedWidthInteger & UnsignedInteger {
    associatedtype Signed: RawSignedInteger where Signed.Unsigned == Self
    init(bitPattern: Signed)
}

@usableFromInline
protocol RawSignedInteger: FixedWidthInteger & SignedInteger {
    associatedtype Unsigned: RawUnsignedInteger where Unsigned.Signed == Self
    init(bitPattern: Unsigned)
}

extension UInt8: RawUnsignedInteger {
    @usableFromInline typealias Signed = Int8
}

extension UInt16: RawUnsignedInteger {
    @usableFromInline typealias Signed = Int16
}

extension UInt32: RawUnsignedInteger {
    @usableFromInline typealias Signed = Int32
}

extension UInt64: RawUnsignedInteger {
    @usableFromInline typealias Signed = Int64
}

extension Int8: RawSignedInteger {}
extension Int16: RawSignedInteger {}
extension Int32: RawSignedInteger {}
extension Int64: RawSignedInteger {}

extension RawUnsignedInteger {
    var signed: Signed {
        .init(bitPattern: self)
    }
}

extension RawSignedInteger {
    var unsigned: Unsigned {
        .init(bitPattern: self)
    }
}

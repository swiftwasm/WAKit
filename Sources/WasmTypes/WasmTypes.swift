/// Type of a WebAssembly function.
///
/// > Note:
/// <https://webassembly.github.io/spec/core/syntax/types.html#function-types>
public struct FunctionType: Equatable, Hashable {
    public init(parameters: [ValueType], results: [ValueType] = []) {
        self.parameters = parameters
        self.results = results
    }

    /// The types of the function parameters.
    public let parameters: [ValueType]
    /// The types of the function results.
    public let results: [ValueType]
}

/// Reference types
public enum ReferenceType: UInt8, Equatable, Hashable {
    /// A nullable reference type to a function.
    case funcRef

    /// A non-nullable reference type to a function
    case funcRefNonNull

    /// A nullable external reference type.
    case externRef

    /// A non-nullable external reference type.
    case externRefNonNull
}

public enum ValueType: Equatable, Hashable {
    /// 32-bit signed or unsigned integer.
    case i32
    /// 64-bit signed or unsigned integer.
    case i64
    /// 32-bit IEEE 754 floating-point number.
    case f32
    /// 64-bit IEEE 754 floating-point number.
    case f64
    /// 128-bit vector of packed integer or floating-point data.
    case v128
    /// Reference value type.
    case ref(ReferenceType)
}

/// Runtime representation of a WebAssembly function reference.
public typealias FunctionAddress = Int
/// Runtime representation of an external entity reference.
public typealias ExternAddress = Int

@available(*, unavailable, message: "Address-based APIs has been removed; use `Table` instead")
public typealias TableAddress = Int
@available(*, unavailable, message: "Address-based APIs has been removed; use `Memory` instead")
public typealias MemoryAddress = Int
@available(*, unavailable, message: "Address-based APIs has been removed; use `Global` instead")
public typealias GlobalAddress = Int
@available(*, unavailable, message: "Address-based APIs has been removed")
public typealias ElementAddress = Int
@available(*, unavailable, message: "Address-based APIs has been removed")
public typealias DataAddress = Int

public enum Reference: Hashable {
    /// A reference to a function.
    case function(FunctionAddress?)
    /// A reference to an external entity.
    case extern(ExternAddress?)
}

/// Runtime representation of a value.
public enum Value: Hashable {
    /// Value of a 32-bit signed or unsigned integer.
    case i32(UInt32)
    /// Value of a 64-bit signed or unsigned integer.
    case i64(UInt64)
    /// Value of a 32-bit IEEE 754 floating-point number.
    case f32(UInt32)
    /// Value of a 64-bit IEEE 754 floating-point number.
    case f64(UInt64)
    /// Reference value.
    case ref(Reference)
}

extension Value {
    /// Create a new value from a signed 32-bit integer.
    public init(signed value: Int32) {
        self = .i32(UInt32(bitPattern: value))
    }

    /// Create a new value from a signed 64-bit integer.
    public init(signed value: Int64) {
        self = .i64(UInt64(bitPattern: value))
    }

    /// Create a new value from a 32-bit floating-point number.
    public static func fromFloat32(_ value: Float32) -> Value {
        return .f32(value.bitPattern)
    }

    /// Create a new value from a 64-bit floating-point number.
    public static func fromFloat64(_ value: Float64) -> Value {
        return .f64(value.bitPattern)
    }

    /// Returns the value as a 32-bit signed integer.
    /// - Precondition: The value is of type `i32`.
    public var i32: UInt32 {
        guard case let .i32(result) = self else { fatalError() }
        return result
    }

    /// Returns the value as a 64-bit signed integer.
    /// - Precondition: The value is of type `i64`.
    public var i64: UInt64 {
        guard case let .i64(result) = self else { fatalError() }
        return result
    }

    /// Returns the value as a 32-bit floating-point number.
    /// - Precondition: The value is of type `f32`.
    public var f32: UInt32 {
        guard case let .f32(result) = self else { fatalError() }
        return result
    }

    /// Returns the value as a 64-bit floating-point number.
    /// - Precondition: The value is of type `f64`.
    public var f64: UInt64 {
        guard case let .f64(result) = self else { fatalError() }
        return result
    }
}

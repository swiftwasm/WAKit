/// A type-erased value that can represent any WebAssembly value type.
///
/// NOTE: This type assumes any non-null references can be represented as a
///       63-bits unsigned integer. This assumption allows us to use the
///       same storage space for all value types.
struct UntypedValue: Equatable, Hashable {
    /// The internal storage of the value.
    let storage: UInt64

    /// The default value of WebAssembly local variables.
    /// This property assumes that the default value of any type has the same
    /// untyped representation.
    static var `default`: UntypedValue {
        UntypedValue(storage: 0)
    }

    /// The mask pattern to check if the value is a null reference.
    private static var isNullMaskPattern: UInt64 { (0x1 << 63) }

    /// Creates a new value from the given signed 32-bit integer.
    init(signed value: Int32) {
        self = .i32(UInt32(bitPattern: value))
    }

    /// Creates a new value from the given signed 64-bit integer.
    init(signed value: Int64) {
        self = .i64(UInt64(bitPattern: value))
    }

    // MARK: - Value Type Constructors

    static func i32(_ value: UInt32) -> UntypedValue {
        return UntypedValue(storage: UInt64(value))
    }
    static func i64(_ value: UInt64) -> UntypedValue {
        return UntypedValue(storage: value)
    }
    static func rawF32(_ value: UInt32) -> UntypedValue {
        return UntypedValue(storage: UInt64(value))
    }
    static func rawF64(_ value: UInt64) -> UntypedValue {
        return UntypedValue(storage: value)
    }
    static func f32(_ value: Float32) -> UntypedValue {
        return rawF32(value.bitPattern)
    }
    static func f64(_ value: Float64) -> UntypedValue {
        return rawF64(value.bitPattern)
    }

    /// Creates a new value from the zero-extended representation of the given
    /// 32-bit storage pattern.
    init(storage32: UInt32) {
        self.storage = UInt64(storage32)
    }

    /// Creates a new value from the given 64-bit storage pattern.
    init(storage: UInt64) {
        self.storage = storage
    }

    /// Creates a new value from the given typed WebAssembly value.
    init(_ value: Value) {
        func encodeOptionalInt(_ value: Int?) -> UInt64 {
            guard let value = value else { return Self.isNullMaskPattern }
            let unsigned = UInt64(bitPattern: Int64(value))
            // Check if the value does not exceed the 63-bits limit.
            precondition(unsigned & Self.isNullMaskPattern == 0)
            return unsigned
        }
        switch value {
        case .i32(let value): self = .i32(value)
        case .i64(let value): self = .i64(value)
        case .f32(let value): self = .rawF32(value)
        case .f64(let value): self = .rawF64(value)
        case .ref(.function(let value)), .ref(.extern(let value)):
            storage = encodeOptionalInt(value)
        }
    }

    // MARK: - Value Accessors

    var i32: UInt32 {
        return UInt32(truncatingIfNeeded: storage & 0x0000_0000_ffff_ffff)
    }

    var i64: UInt64 {
        return storage
    }

    var rawF32: UInt32 {
        return i32
    }

    var rawF64: UInt64 {
        return i64
    }

    var f32: Float32 {
        return Float32(bitPattern: i32)
    }

    var f64: Float64 {
        return Float64(bitPattern: i64)
    }

    var isNullRef: Bool {
        return storage & Self.isNullMaskPattern != 0
    }

    /// Returns the value as a reference of the given type.
    func asReference(_ type: ReferenceType) -> Reference {
        func decodeOptionalInt() -> Int? {
            guard storage & Self.isNullMaskPattern == 0 else { return nil }
            return Int(storage)
        }
        switch type.heapType {
        case .abstract(.funcRef):
            return .function(decodeOptionalInt())
        case .abstract(.externRef):
            return .extern(decodeOptionalInt())
        case .concrete:
            fatalError("heap type other than `func` and `extern` is not implemented yet")
        }
    }

    /// Returns the value as an address offset.
    func asAddressOffset() -> UInt64 {
        // NOTE: It's ok to load address offset as i64 because
        //       it's always evaluated as unsigned and the higher
        //       32-bits of i32 are always zero.
        return i64
    }

    /// Returns the value as an address offset.
    func asAddressOffset(_ isMemory64: Bool) -> UInt64 {
        return asAddressOffset()
    }

    /// Returns the value as a typed WebAssembly value.
    func cast(to type: ValueType) -> Value {
        switch type {
        case .i32: return .i32(i32)
        case .i64: return .i64(i64)
        case .f32: return .f32(rawF32)
        case .f64: return .f64(rawF64)
        case .v128:
            fatalError("v128 value type is not supported yet.")
        case .ref(let referenceType):
            return .ref(asReference(referenceType))
        }
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/exec/runtime.html#stack>
struct StackContext {

    var reachedEndOfExecution: Bool = false
    private var limit: UInt16 { UInt16.max }
    private var valueStack: ValueStack
    private var frames: FixedSizeStack<Frame>
    var currentFrame: Frame!
    let runtime: RuntimeRef

    var frameBase: ExecutionState.FrameBase {
        return ExecutionState.FrameBase(pointer: self.valueStack.frameBase)
    }
    var currentInstance: InternalInstance {
        currentFrame.instance
    }

    init(runtime: RuntimeRef) {
        let limit = UInt16.max
        self.valueStack = ValueStack(capacity: Int(limit))
        self.frames = FixedSizeStack(capacity: Int(limit))
        self.runtime = runtime
    }

    mutating func pushFrame(
        iseq: InstructionSequence,
        instance: InternalInstance,
        numberOfNonParameterLocals: Int,
        returnPC: Pc,
        spAddend: Instruction.Register
    ) throws {
        guard frames.count < limit else {
            throw Trap.callStackExhausted
        }
        let savedFrameBase = valueStack.frameBase
        let frameBase = try valueStack.extend(addend: spAddend, maxStackHeight: iseq.maxStackHeight)
        // Initialize the locals with zeros (all types of value have the same representation)
        frameBase.initialize(repeating: .default, count: numberOfNonParameterLocals)
        let frame = Frame(instance: instance, savedFrameBase: savedFrameBase, returnPC: returnPC)
        frames.push(frame)
        self.currentFrame = frame
    }

    mutating func popFrame() -> InternalInstance {
        let popped = self.frames.pop()
        self.currentFrame = self.frames.peek()
        self.valueStack.frameBase = popped.savedFrameBase
        return popped.instance
    }

    func deallocate() {
        self.valueStack.deallocate()
        self.frames.deallocate()
    }

    func dump(store: Store) throws {
    }
}

struct ValueStack {
    private let values: UnsafeMutableBufferPointer<UntypedValue>
    fileprivate(set) var frameBase: UnsafeMutablePointer<UntypedValue>
    var baseAddress: UnsafeMutablePointer<UntypedValue> {
        values.baseAddress!
    }

    init(capacity: Int) {
        self.values = .allocate(capacity: capacity)
        self.frameBase = self.values.baseAddress!
    }

    func deallocate() {
        self.values.deallocate()
    }

    mutating func extend(addend: Instruction.Register, maxStackHeight: Int) throws -> UnsafeMutablePointer<UntypedValue> {
        let newFrameBase = frameBase.advanced(by: Int(addend))
        guard newFrameBase.advanced(by: maxStackHeight) < values.baseAddress!.advanced(by: values.count) else {
            throw Trap.callStackExhausted
        }
        frameBase = newFrameBase
        return newFrameBase
    }
}

struct FixedSizeStack<Element> {
    private let buffer: UnsafeMutableBufferPointer<Element>
    private var numberOfElements: Int = 0


    var count: Int { numberOfElements }

    init(capacity: Int) {
        self.buffer = .allocate(capacity: capacity)
    }

    mutating func push(_ element: Element) {
        self.buffer[numberOfElements] = element
        self.numberOfElements += 1
    }

    @discardableResult
    mutating func pop() -> Element {
        let element = self.buffer[self.numberOfElements - 1]
        self.numberOfElements -= 1
        return element
    }

    func peek() -> Element! {
        guard self.numberOfElements > 0 else { return nil }
        return self.buffer[self.numberOfElements - 1]
    }

    func deallocate() {
        self.buffer.deallocate()
    }
}

extension FixedSizeStack: Sequence {
    struct Iterator: IteratorProtocol {
        fileprivate var base: UnsafeMutableBufferPointer<Element>.SubSequence.Iterator

        mutating func next() -> Element? {
            base.next()
        }
    }

    func makeIterator() -> Iterator {
        Iterator(base: self.buffer[..<numberOfElements].makeIterator())
    }
}

struct BaseStackAddress {
    /// Locals are placed between `valueFrameIndex..<valueIndex`
    let valueFrameIndex: Int
}

/// > Note:
/// <https://webassembly.github.io/spec/core/exec/runtime.html#frames>
struct Frame {
    let instance: InternalInstance
    let savedFrameBase: UnsafeMutablePointer<UntypedValue>
    let returnPC: Pc

    init(
        instance: InternalInstance,
        savedFrameBase: UnsafeMutablePointer<UntypedValue>,
        returnPC: Pc
    ) {
        self.instance = instance
        self.savedFrameBase = savedFrameBase
        self.returnPC = returnPC
    }
}

extension Frame: Equatable {
    static func == (_ lhs: Frame, _ rhs: Frame) -> Bool {
        lhs.instance == rhs.instance
    }
}

protocol BitPatternRepresentable {
    associatedtype BitPattern
    init(bitPattern: BitPattern)
}

extension Int32: BitPatternRepresentable {
    typealias BitPattern = UInt32
}
extension Int64: BitPatternRepresentable {
    typealias BitPattern = UInt64
}
extension Float32: BitPatternRepresentable {
    typealias BitPattern = UInt32
}
extension Float64: BitPatternRepresentable {
    typealias BitPattern = UInt64
}

struct UntypedValue: Equatable {
    let storage: UInt64

    static var `default`: UntypedValue {
        UntypedValue(storage: 0)
    }

    private static var isNullMaskPattern: UInt64 { (0x1 << 63) }

    init(signed value: Int32) {
        self = .i32(UInt32(bitPattern: value))
    }
    init(signed value: Int64) {
        self = .i64(UInt64(bitPattern: value))
    }
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

    private init(storage: UInt64) {
        self.storage = storage
    }

    init(_ value: Value) {
        func encodeOptionalInt(_ value: Int?) -> UInt64 {
            guard let value = value else { return Self.isNullMaskPattern }
            let unsigned = UInt64(bitPattern: Int64(value))
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

    var i32: UInt32 {
        return UInt32(truncatingIfNeeded: storage & 0x00000000ffffffff)
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

    func asReference(_ type: ReferenceType) -> Reference {
        func decodeOptionalInt() -> Int? {
            guard storage & Self.isNullMaskPattern == 0 else { return nil }
            return Int(storage)
        }
        switch type {
        case .funcRef:
            return .function(decodeOptionalInt())
        case .externRef:
            return .extern(decodeOptionalInt())
        }
    }

    func asAddressOffset() -> UInt64 {
        // NOTE: It's ok to load address offset as i64 because
        //       it's always evaluated as unsigned and the higher
        //       32-bits of i32 are always zero.
        return i64
    }
    func asAddressOffset(_ isMemory64: Bool) -> UInt64 {
        return asAddressOffset()
    }

    func cast(to type: NumericType) -> Value {
        switch type {
        case .int(let type):
            switch type {
            case .i32: return .i32(i32)
            case .i64: return .i64(i64)
            }
        case .float(let type):
            switch type {
            case .f32: return .f32(f32.bitPattern)
            case .f64: return .f64(f64.bitPattern)
            }
        }
    }
    func cast(to type: ValueType) -> Value {
        switch type {
        case .i32: return .i32(i32)
        case .i64: return .i64(i64)
        case .f32: return .f32(rawF32)
        case .f64: return .f64(rawF64)
        case .ref(let referenceType):
            return .ref(asReference(referenceType))
        }
    }
}

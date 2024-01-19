/// > Note:
/// <https://webassembly.github.io/spec/core/exec/runtime.html#stack>

public struct Stack {
    public enum Element: Equatable {
        case value(Value)
        case label(Label)
        case frame(Frame)
    }

    private(set) var limit = UInt16.max
    private var valueStack = ValueStack()
    private var numberOfValues: Int { valueStack.count }
    private var labels = [Label]() {
        didSet {
            self.currentLabel = self.labels.last
        }
    }
    private var frames = [Frame]()
    private var locals = [Value]()
    var currentFrame: Frame!
    var currentLabel: Label!

    var isEmpty: Bool {
        self.frames.isEmpty && self.labels.isEmpty && self.numberOfValues == 0
    }

    mutating func pushLabel(arity: Int, expression: Expression, continuation: Int, exit: Int) -> Label {
        let label = Label(
            arity: arity,
            expression: expression,
            continuation: continuation,
            exit: exit,
            baseValueIndex: self.numberOfValues
        )
        labels.append(label)
        return label
    }

    @discardableResult
    mutating func pushFrame(
        arity: Int, module: ModuleInstance, arguments: ArraySlice<Value>, defaultLocals: [Value], address: FunctionAddress? = nil
    ) throws -> Frame {
        // TODO: Stack overflow check can be done at the entry of expression
        guard (frames.count + labels.count + numberOfValues) < limit else {
            throw Trap.callStackExhausted
        }

        let baseStackAddress = BaseStackAddress(
            valueIndex: self.numberOfValues,
            labelIndex: self.labels.endIndex,
            localIndex: self.locals.endIndex
        )
        let frame = Frame(arity: arity, module: module, baseStackAddress: baseStackAddress, address: address)
        frames.append(frame)
        self.currentFrame = frame
        self.locals.append(contentsOf: arguments)
        self.locals.append(contentsOf: defaultLocals)
        return frame
    }

    func numberOfLabelsInCurrentFrame() -> Int {
        self.labels.count - currentFrame.baseStackAddress.labelIndex
    }

    func numberOfValuesInCurrentLabel() -> Int {
        self.numberOfValues - currentLabel.baseValueIndex
    }

    mutating func exit(label: Label) {
        // labelIndex = 0 means jumping to the current head label
        self.labels.removeLast()
    }

    mutating func exit(frame: Frame) -> Label? {
        if numberOfValuesInCurrentLabel() == frame.arity {
            // Skip pop/push traffic
        } else {
            let results = valueStack.popValues(count: frame.arity)
            self.valueStack.truncate(length: frame.baseStackAddress.valueIndex)
            valueStack.push(values: results)
        }
        let labelToRemove = self.labels[frame.baseStackAddress.labelIndex]
        self.labels.removeLast(self.labels.count - frame.baseStackAddress.labelIndex)
        self.locals.removeLast(self.locals.count - frame.baseStackAddress.localIndex)
        return labelToRemove
    }

    @discardableResult
    mutating func unwindLabels(upto labelIndex: Int) -> Label? {
        if self.labels.count == labelIndex + 1 {
            self.labels.removeAll()
            self.valueStack.truncate(length: 0)
            return nil
        }
        // labelIndex = 0 means jumping to the current head label
        let labelToRemove = self.labels[self.labels.count - labelIndex - 1]
        self.labels.removeLast(labelIndex + 1)
        if self.numberOfValues > labelToRemove.baseValueIndex {
            self.valueStack.truncate(length: labelToRemove.baseValueIndex)
        }
        return labelToRemove
    }

    mutating func discardFrameStack(frame: Frame) -> Label? {
        if frame.baseStackAddress.labelIndex == 0 {
            // The end of top level execution
            self.labels.removeAll()
            self.valueStack.truncate(length: 0)
            return nil
        }
        let labelToRemove = self.labels[frame.baseStackAddress.labelIndex]
        self.labels.removeLast(self.labels.count - frame.baseStackAddress.labelIndex)
        self.valueStack.truncate(length: frame.baseStackAddress.valueIndex)
        return labelToRemove
    }

    mutating func popTopValues() throws -> ArraySlice<Value> {
        guard let currentLabel = self.currentLabel else {
            return self.valueStack.popValues(count: self.valueStack.count)
        }
        guard currentLabel.baseValueIndex < self.numberOfValues else {
            return []
        }
        let values = self.valueStack.popValues(count: self.numberOfValues - currentLabel.baseValueIndex)
        return values
    }

    mutating func popFrame() throws {
        guard let popped = self.frames.popLast() else {
            throw Trap.stackOverflow
        }
        self.currentFrame = self.frames.last
        self.locals.removeLast(self.locals.count - popped.baseStackAddress.localIndex)
        // _ = discardFrameStack(frame: popped)
    }

    func getLabel(index: Int) throws -> Label {
        return self.labels[self.labels.count - index - 1]
    }

    mutating func popValues(count: Int) -> ArraySlice<Value> {
        self.valueStack.popValues(count: count)
    }
    mutating func popValue() throws -> Value {
        self.valueStack.popValue()
    }
    mutating func push(values: some RandomAccessCollection<Value>) {
        self.valueStack.push(values: values)
    }
    mutating func push(value: Value) {
        self.valueStack.push(value: value)
    }

    var topValue: Value {
        self.valueStack.topValue
    }
}

struct ValueStack {
    private var values: [Value] = []
    private var numberOfValues: Int = 0

    var count: Int { numberOfValues }

    var topValue: Value {
        values[numberOfValues - 1]
    }

    mutating func push(value: Value) {
        if self.numberOfValues < self.values.count {
            self.values[self.numberOfValues] = value
        } else {
            self.values.append(value)
        }
        self.numberOfValues += 1
    }

    mutating func push(values: some RandomAccessCollection<Value>) {
        let numberOfReplaceableSlots = self.values.count - self.numberOfValues
        if numberOfReplaceableSlots >= values.count {
            self.values.replaceSubrange(self.numberOfValues..<self.numberOfValues+values.count, with: values)
        } else if numberOfReplaceableSlots > 0 {
            let rangeToReplace = self.numberOfValues..<self.values.count
            self.values.replaceSubrange(rangeToReplace, with: values.prefix(numberOfReplaceableSlots))
            self.values.append(contentsOf: values.dropFirst(numberOfReplaceableSlots))
        } else {
            self.values.append(contentsOf: values)
        }
        self.numberOfValues += values.count
    }

    mutating func popValue() -> Value {
        // TODO: Check too many pop
        let value = self.values[self.numberOfValues-1]
        self.numberOfValues -= 1
        return value
    }

    mutating func truncate(length: Int) {
        self.numberOfValues = length
    }
    mutating func popValues(count: Int) -> ArraySlice<Value> {
        guard count > 0 else { return [] }
        let values = self.values[self.numberOfValues-count..<self.numberOfValues]
        self.numberOfValues -= count
        return values
    }
}

extension ValueStack: Sequence {
    func makeIterator() -> some IteratorProtocol {
        self.values[..<numberOfValues].makeIterator()
    }
}

/// > Note:
/// <https://webassembly.github.io/spec/core/exec/runtime.html#labels>
public struct Label: Equatable {
    let arity: Int

    let expression: Expression

    /// Index of an instruction to jump to when this label is popped off the stack.
    let continuation: Int

    /// The index after the  of the structured control instruction associated with the label
    let exit: Int

    let baseValueIndex: Int
}

struct BaseStackAddress {
    /// The base index of Wasm value stack
    let valueIndex: Int
    /// The base index of Wasm label stack
    let labelIndex: Int

    let localIndex: Int
}

/// > Note:
/// <https://webassembly.github.io/spec/core/exec/runtime.html#frames>
public struct Frame {
    let arity: Int
    let module: ModuleInstance
    let baseStackAddress: BaseStackAddress
    /// An optional function address for debugging/profiling purpose
    let address: FunctionAddress?

    init(arity: Int, module: ModuleInstance, baseStackAddress: BaseStackAddress, address: FunctionAddress? = nil) {
        self.arity = arity
        self.module = module
        self.baseStackAddress = baseStackAddress
        self.address = address
    }
}

extension Frame: Equatable {
    public static func == (_ lhs: Frame, _ rhs: Frame) -> Bool {
        lhs.module === rhs.module && lhs.arity == rhs.arity &&
            lhs.baseStackAddress.localIndex == rhs.baseStackAddress.localIndex
    }
}

extension Stack {
    func localGet(index: UInt32) throws -> Value {
        let base = currentFrame.baseStackAddress.localIndex
        guard base + Int(index) < locals.count else {
            throw Trap.localIndexOutOfRange(index: index)
        }
        return locals[base + Int(index)]
    }

    mutating func localSet(index: UInt32, value: Value) throws {
        let base = currentFrame.baseStackAddress.localIndex
        guard base + Int(index) < locals.count else {
            throw Trap.localIndexOutOfRange(index: index)
        }
        locals[base + Int(index)] = value
    }
}

extension Frame: CustomDebugStringConvertible {
    public var debugDescription: String {
        "[A=\(arity), BA=\(baseStackAddress), F=\(address?.description ?? "nil")]"
    }
}

extension Label: CustomDebugStringConvertible {
    public var debugDescription: String {
        "[A=\(arity), E=\(expression), C=\(continuation), X=\(exit), BVI=\(baseValueIndex)]"
    }
}

extension Stack: CustomDebugStringConvertible {
    public var debugDescription: String {
        var result = ""

        result += "==================================================\n"
        for (index, frame) in frames.enumerated() {
            result += "FRAME[\(index)]: \(frame.debugDescription)\n"
        }
        result += "==================================================\n"

        for (index, label) in labels.enumerated() {
            result += "LABEL[\(index)]: \(label.debugDescription)\n"
        }

        result += "==================================================\n"

        for (index, value) in valueStack.enumerated() {
            result += "VALUE[\(index)]: \(value)\n"
        }
        result += "==================================================\n"

        return result
    }
}

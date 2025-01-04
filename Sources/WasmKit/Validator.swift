import WasmParser

/// Represents an error that occurs during validation
struct ValidationError: Error, CustomStringConvertible {
    /// Represents a validation error message.
    struct Message {
        let text: String

        init(_ text: String) {
            self.text = text
        }
    }

    /// The error message.
    let message: Message

    /// The offset in the input WebAssembly module binary where the error occurred.
    /// NOTE: This field is set when the error is temporarily caught by the ``InstructionTranslator``.
    var offset: Int?

    /// The error description.
    var description: String {
        if let offset = offset {
            return "\(message.text) at offset 0x\(String(offset, radix: 16))"
        } else {
            return message.text
        }
    }

    init(_ message: Message) {
        self.message = message
    }
}

extension ValidationError.Message {
    static func invalidMemArgAlignment(memarg: MemArg, naturalAlignment: Int) -> Self {
        Self("alignment 2**\(memarg.align) is out of limit \(naturalAlignment)")
    }

    static var globalSetConstant: Self {
        Self("cannot set a constant global")
    }

    static var multipleMemoriesNotPermitted: Self {
        Self("multiple memories are not permitted")
    }

    static func startFunctionInvalidParameters() -> Self {
        Self("start function must have no parameters and no results")
    }

    static var memory64FeatureRequired: Self {
        Self("memory64 feature is required for 64-bit memories")
    }

    static func sizeMinimumExceeded(max: UInt64) -> Self {
        Self("size minimum must not be greater than \(max)")
    }

    static func sizeMaximumExceeded(max: UInt64) -> Self {
        Self("size maximum must not be greater than \(max)")
    }

    static var referenceTypesFeatureRequiredForSharedMemories: Self {
        Self("reference-types feature is required for shared memories")
    }

    static var referenceTypesFeatureRequiredForNonFuncrefTables: Self {
        Self("reference-types feature is required for non-funcref tables")
    }

    static var dataCountSectionRequired: Self {
        Self("data count section is required but not found")
    }

    static func indexOutOfBounds<Index: Numeric, Max: Numeric>(_ entity: StaticString, _ index: Index, max: Max) -> Self {
        Self("\(entity) index out of bounds: \(index) (max: \(max))")
    }

    static func tableElementTypeMismatch(tableType: String, elementType: String) -> Self {
        Self("table element type mismatch: \(tableType) != \(elementType)")
    }

    static func expectTypeButGot(expected: String, got: String) -> Self {
        Self("expect \(expected) but got \(got)")
    }

    static var sizeMinimumMustNotExceedMaximum: Self {
        Self("size minimum must not be greater than maximum")
    }

    static func functionIndexNotDeclared(index: FunctionIndex) -> Self {
        Self("function index \(index) is not declared but referenced as a function reference")
    }

    static func duplicateExportName(name: String) -> Self {
        Self("duplicate export name: \(name)")
    }

    static func elementSegmentTypeMismatch(
        elementType: ReferenceType,
        tableElementType: ReferenceType
    ) -> Self {
        Self("element segment type \(elementType) does not match table element type \(tableElementType)")
    }

    static var controlStackEmpty: Self {
        Self("control stack is empty. Instruction cannot be appeared after \"end\" of function")
    }

    static func relativeDepthOutOfRange(relativeDepth: UInt32) -> Self {
        Self("relative depth \(relativeDepth) is out of range")
    }

    static var expectedIfControlFrame: Self {
        Self("expected `if` control frame on top of the stack for `else`")
    }

    static var valuesRemainingAtEndOfBlock: Self {
        Self("values remaining on stack at end of block")
    }

    static func parameterResultTypeMismatch(blockType: FunctionType) -> Self {
        Self("expected the same parameter and result types for `if` block but got \(blockType)")
    }

    static func stackHeightUnderflow(available: Int, required: Int) -> Self {
        Self("stack height underflow: available \(available), required \(required)")
    }

    static func expectedTypeOnStack(expected: ValueType, actual: ValueType) -> Self {
        Self("expected \(expected) on the stack top but got \(actual)")
    }

    static func expectedTypeOnStackButEmpty(expected: ValueType?) -> Self {
        let typeHint = expected.map(String.init(describing:)) ?? "a value"
        return Self("expected \(typeHint) on the stack top but it's empty")
    }

    static func expectedMoreEndInstructions(count: Int) -> Self {
        Self("expect \(count) more `end` instructions")
    }

    static func expectedSameCopyTypes(
        frameCopyTypes: [ValueType],
        defaultFrameCopyTypes: [ValueType]
    ) -> Self {
        Self("expected the same copy types for all branches in `br_table` but got \(frameCopyTypes) and \(defaultFrameCopyTypes)")
    }

    static var cannotSelectOnReferenceTypes: Self {
        Self("cannot `select` on reference types")
    }

    static func typeMismatchOnSelect(expected: ValueType, actual: ValueType) -> Self {
        Self("type mismatch on `select`. Expected \(expected) and \(actual) to be same")
    }

    static var unexpectedGlobalValueType: Self {
        Self("unexpected global value type for element initializer expression")
    }

    static func unexpectedElementInitializer(expression: String) -> Self {
        Self("unexpected element initializer expression: \(expression)")
    }

    static func unexpectedOffsetInitializer(expected: ValueType, got: Value) -> Self {
        Self("expect \(expected) offset but got \(got)")
    }

    static var expectedEndAtOffsetExpression: Self {
        Self("expect `end` at the end of offset expression")
    }

    static func illegalConstExpressionInstruction(_ constInst: WasmParser.Instruction) -> Self {
        Self("illegal const expression instruction: \(constInst)")
    }

    static func inconsistentFunctionAndCodeLength(functionCount: Int, codeCount: Int) -> Self {
        Self("Inconsistent function and code length: \(functionCount) vs \(codeCount)")
    }

    static func inconsistentDataCountAndDataSectionLength(dataCount: UInt32, dataSection: Int) -> Self {
        Self("Inconsistent data count and data section length: \(dataCount) vs \(dataSection)")
    }

    static func typeMismatchOnReturnCall(expected: [ValueType], actual: [ValueType]) -> Self {
        Self("return signatures have inconsistent types: expected \(expected) but got \(actual)")
    }
}

/// Validates instructions within a given context.
struct InstructionValidator<Context: TranslatorContext> {
    let context: Context

    func validateMemArg(_ memarg: MemArg, naturalAlignment: Int) throws {
        if memarg.align > naturalAlignment {
            throw ValidationError(.invalidMemArgAlignment(memarg: memarg, naturalAlignment: naturalAlignment))
        }
    }

    func validateGlobalSet(_ type: GlobalType) throws {
        switch type.mutability {
        case .constant:
            throw ValidationError(.globalSetConstant)
        case .variable:
            break
        }
    }

    func validateTableInit(elemIndex: UInt32, table: UInt32) throws {
        let tableType = try context.tableType(table)
        let elementType = try context.elementType(elemIndex)
        guard tableType.elementType == elementType else {
            throw ValidationError(.tableElementTypeMismatch(tableType: "\(tableType.elementType)", elementType: "\(elementType)"))
        }
    }

    func validateTableCopy(dest: UInt32, source: UInt32) throws {
        let tableType1 = try context.tableType(source)
        let tableType2 = try context.tableType(dest)
        guard tableType1.elementType == tableType2.elementType else {
            throw ValidationError(.tableElementTypeMismatch(tableType: "\(tableType1.elementType)", elementType: "\(tableType2.elementType)"))
        }
    }

    func validateRefFunc(functionIndex: UInt32) throws {
        try context.validateFunctionIndex(functionIndex)
    }

    func validateDataSegment(_ dataIndex: DataIndex) throws {
        guard let dataCount = context.dataCount else {
            throw ValidationError(.dataCountSectionRequired)
        }
        guard dataIndex < dataCount else {
            throw ValidationError(.indexOutOfBounds("data", dataIndex, max: dataCount))
        }
    }

    func validateReturnCallLike(calleeType: FunctionType, callerType: FunctionType) throws {
        guard calleeType.results == callerType.results else {
            throw ValidationError(.typeMismatchOnReturnCall(expected: callerType.results, actual: calleeType.results))
        }
    }
}

/// Validates a WebAssembly module.
struct ModuleValidator {
    let module: Module
    init(module: Module) {
        self.module = module
    }

    func validate() throws {
        if module.memoryTypes.count > 1 {
            throw ValidationError(.multipleMemoriesNotPermitted)
        }
        for memoryType in module.memoryTypes {
            try Self.checkMemoryType(memoryType, features: module.features)
        }
        for tableType in module.tableTypes {
            try Self.checkTableType(tableType, features: module.features)
        }
        try checkStartFunction()
    }

    func checkStartFunction() throws {
        if let startFunction = module.start {
            let type = try module.resolveFunctionType(startFunction)
            guard type.parameters.isEmpty, type.results.isEmpty else {
                throw ValidationError(.startFunctionInvalidParameters())
            }
        }
    }

    static func checkMemoryType(_ type: MemoryType, features: WasmFeatureSet) throws {
        try checkLimit(type)

        if type.isMemory64 {
            guard features.contains(.memory64) else {
                throw ValidationError(.memory64FeatureRequired)
            }
        }

        let hardMax = MemoryEntity.maxPageCount(isMemory64: type.isMemory64)

        if type.min > hardMax {
            throw ValidationError(.sizeMinimumExceeded(max: hardMax))
        }

        if let max = type.max, max > hardMax {
            throw ValidationError(.sizeMaximumExceeded(max: hardMax))
        }

        if type.shared {
            guard features.contains(.threads) else {
                throw ValidationError(.referenceTypesFeatureRequiredForSharedMemories)
            }
        }
    }

    static func checkTableType(_ type: TableType, features: WasmFeatureSet) throws {
        if type.elementType != .funcRef, !features.contains(.referenceTypes) {
            throw ValidationError(.referenceTypesFeatureRequiredForNonFuncrefTables)
        }
        try checkLimit(type.limits)

        if type.limits.isMemory64 {
            guard features.contains(.memory64) else {
                throw ValidationError(.memory64FeatureRequired)
            }
        }

        let hardMax = TableEntity.maxSize(isMemory64: type.limits.isMemory64)

        if type.limits.min > hardMax {
            throw ValidationError(.sizeMinimumExceeded(max: hardMax))
        }

        if let max = type.limits.max, max > hardMax {
            throw ValidationError(.sizeMaximumExceeded(max: hardMax))
        }
    }

    private static func checkLimit(_ limit: Limits) throws {
        guard let max = limit.max else { return }
        if limit.min > max {
            throw ValidationError(.sizeMinimumMustNotExceedMaximum)
        }
    }
}

extension WasmTypes.Reference {
    /// Checks if the reference type matches the expected type.
    func checkType(_ type: WasmTypes.ReferenceType) throws {
        switch (self, type) {
        case (.function, .funcRef): return
        case (.extern, .externRef): return
        default:
            throw ValidationError(.expectTypeButGot(expected: "\(type)", got: "\(self)"))
        }
    }
}

extension Value {
    /// Checks if the value type matches the expected type.
    func checkType(_ type: WasmTypes.ValueType) throws {
        switch (self, type) {
        case (.i32, .i32): return
        case (.i64, .i64): return
        case (.f32, .f32): return
        case (.f64, .f64): return
        case (.ref(let ref), .ref(let refType)):
            try ref.checkType(refType)
        default:
            throw ValidationError(.expectTypeButGot(expected: "\(type)", got: "\(self)"))
        }
    }
}

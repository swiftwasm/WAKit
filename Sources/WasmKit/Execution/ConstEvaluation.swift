import WasmParser

protocol ConstEvaluationContextProtocol {
    func functionRef(_ index: FunctionIndex) throws -> Reference
    func globalValue(_ index: GlobalIndex) throws -> Value
}

struct ConstEvaluationContext: ConstEvaluationContextProtocol {
    let functions: ImmutableArray<InternalFunction>
    var globals: [Value]
    let onFunctionReferenced: ((InternalFunction) -> Void)?

    init(
        functions: ImmutableArray<InternalFunction>,
        globals: [Value],
        onFunctionReferenced: ((InternalFunction) -> Void)? = nil
    ) {
        self.functions = functions
        self.globals = globals
        self.onFunctionReferenced = onFunctionReferenced
    }

    init(instance: InternalInstance, moduleImports: ModuleImports) {
        // Constant expressions can only reference imported globals
        let externalGlobals = instance.globals
            .prefix(moduleImports.numberOfGlobals)
            .map { $0.value }
        self.init(functions: instance.functions, globals: Array(externalGlobals))
    }

    func functionRef(_ index: FunctionIndex) throws -> Reference {
        let function = try self.functions[validating: Int(index)]
        self.onFunctionReferenced?(function)
        return .function(from: function)
    }
    func globalValue(_ index: GlobalIndex) throws -> Value {
        guard index < globals.count else {
            throw GlobalEntity.createOutOfBoundsError(index: Int(index), count: globals.count)
        }
        return self.globals[Int(index)]
    }
}

extension ConstExpression {
    func evaluate<C: ConstEvaluationContextProtocol>(context: C, expectedType: WasmTypes.ValueType) throws -> Value {
        let result = try self._evaluate(context: context)
        try result.checkType(expectedType)
        return result
    }

    private func _evaluate<C: ConstEvaluationContextProtocol>(context: C) throws -> Value {
        guard self.last == .end, self.count == 2 else {
            throw ValidationError(.expectedEndAtOffsetExpression)
        }
        let constInst = self[0]
        switch constInst {
        case .i32Const(let value): return .i32(UInt32(bitPattern: value))
        case .i64Const(let value): return .i64(UInt64(bitPattern: value))
        case .f32Const(let value): return .f32(value.bitPattern)
        case .f64Const(let value): return .f64(value.bitPattern)
        case .globalGet(let globalIndex):
            return try context.globalValue(globalIndex)
        case .refNull(let type):
            switch type {
            case .externRef, .externRefNonNull: return .ref(.extern(nil))
            case .funcRef, .funcRefNonNull: return .ref(.function(nil))
            }
        case .refFunc(let functionIndex):
            return try .ref(context.functionRef(functionIndex))
        default:
            throw ValidationError(.illegalConstExpressionInstruction(constInst))
        }
    }
}

extension WasmParser.ElementSegment {
    func evaluateInits<C: ConstEvaluationContextProtocol>(context: C) throws -> [Reference] {
        return try self.initializer.map { expression -> Reference in
            let result = try Self._evaluateInits(context: context, expression: expression)
            try result.checkType(self.type)
            return result
        }
    }
    static func _evaluateInits<C: ConstEvaluationContextProtocol>(
        context: C, expression: ConstExpression
    ) throws -> Reference {
        switch expression[0] {
        case let .refFunc(index):
            return try context.functionRef(index)
        case .refNull(.funcRef):
            return .function(nil)
        case .refNull(.externRef):
            return .extern(nil)
        case .globalGet(let index):
            let value = try context.globalValue(index)
            switch value {
            case .ref(.function(let addr)):
                return .function(addr)
            default:
                throw ValidationError(.unexpectedGlobalValueType)
            }
        default:
            throw ValidationError(.unexpectedElementInitializer(expression: "\(expression)"))
        }
    }
}

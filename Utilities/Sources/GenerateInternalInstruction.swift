import Foundation

/// A utility to generate internal VM instruction related code.
enum GenerateInternalInstruction {

    struct Immediate {
        let name: String?
        let type: String
    }
    enum RegisterUse {
        case none
        case read
        case write
    }

    struct VirtualRegister: CaseIterable {
        let label: String
        let type: String

        static let sp = VirtualRegister(label: "sp", type: "Sp")
        static let pc = VirtualRegister(label: "pc", type: "Pc")
        static let md = VirtualRegister(label: "md", type: "Md")
        static let ms = VirtualRegister(label: "ms", type: "Ms")

        static var allCases = [sp, pc, md, ms]
    }

    struct Instruction {
        let name: String
        let isControl: Bool
        let mayThrow: Bool
        let mayUpdateFrame: Bool
        let mayUpdateSp: Bool = false
        let useCurrentMemory: RegisterUse
        let immediates: [Immediate]

        init(
            name: String, isControl: Bool = false,
            mayThrow: Bool = false, mayUpdateFrame: Bool = false,
            useCurrentMemory: RegisterUse = .none,
            immediates: [Immediate]
        ) {
            self.name = name
            self.isControl = isControl
            self.mayThrow = mayThrow
            self.mayUpdateFrame = mayUpdateFrame
            self.useCurrentMemory = useCurrentMemory
            self.immediates = immediates
            assert(isControl || !mayUpdateFrame, "non-control instruction should not update frame")
        }

        typealias Parameter = (label: String, type: String, isInout: Bool)
        var parameters: [Parameter] {
            var vregs: [(reg: VirtualRegister, isInout: Bool)] = []
            if self.mayUpdateFrame {
                vregs += [(VirtualRegister.sp, true)]
            } else {
                vregs += [(VirtualRegister.sp, false)]
            }
            if self.isControl {
                vregs += [(VirtualRegister.pc, true)]
            }
            switch useCurrentMemory {
            case .none: break
            case .read:
                vregs += [(VirtualRegister.md, false), (VirtualRegister.ms, false)]
            case .write:
                vregs += [(VirtualRegister.md, true), (VirtualRegister.ms, true)]
            }
            var parameters: [Parameter] = vregs.map { ($0.reg.label, $0.reg.type, $0.isInout) }
            parameters += immediates.map {
                let label = $0.name ?? camelCase(pascalCase: String($0.type.split(separator: ".").last!))
                return (label, $0.type, false)
            }
            return parameters
        }
    }

    struct OpInstruction {
        let op: String
        let inputType: String
        let resultType: String
        let base: Instruction

        static func binop(op: String, type: String) -> OpInstruction {
            let base = Instruction(
                name: "\(type)\(op)", immediates: [Immediate(name: nil, type: "Instruction.BinaryOperand")]
            )
            return OpInstruction(op: op, inputType: type, resultType: type, base: base)
        }
        static func unop(op: String, type: String) -> OpInstruction {
            let base = Instruction(name: "\(type)\(op)", immediates: [Immediate(name: nil, type: "Instruction.UnaryOperand")])
            return OpInstruction(op: op, inputType: type, resultType: type, base: base)
        }
    }

    static let intValueTypes = ["i32", "i64"]
    static let floatValueTypes = ["f32", "f64"]
    static let valueTypes = intValueTypes + floatValueTypes
    static let intBinaryInsts: [OpInstruction] = [
        "Add", "Sub", "Mul",
        "And", "Or", "Xor", "Shl", "ShrS", "ShrU", "Rotl", "Rotr",
        "Eq", "Ne", "LtS", "LtU", "GtS", "GtU", "LeS", "LeU", "GeS", "GeU",
    ].flatMap { op -> [OpInstruction] in
        intValueTypes.map { OpInstruction.binop(op: op, type: $0) }
    }
    static let intUnaryInsts: [OpInstruction] = ["Clz", "Ctz", "Popcnt", "Eqz"].flatMap { op -> [OpInstruction] in
        intValueTypes.map { OpInstruction.unop(op: op, type: $0) }
    }
    static let floatBinaryInsts: [OpInstruction] = [
        "Add", "Sub", "Mul", "Div",
        "Eq", "Ne",
    ].flatMap { op -> [OpInstruction] in
        floatValueTypes.map { OpInstruction.binop(op: op, type: $0) }
    }
    static let numericOtherInsts: [Instruction] = [
        // Numeric
        Instruction(name: "numericConst", immediates: [
            Immediate(name: nil, type: "Instruction.ConstOperand")
        ]),
        Instruction(name: "numericFloatUnary", immediates: [
            Immediate(name: nil, type: "NumericInstruction.FloatUnary"),
            Immediate(name: nil, type: "Instruction.UnaryOperand"),
        ]),
        Instruction(name: "numericIntBinary", mayThrow: true, immediates: [
            Immediate(name: nil, type: "NumericInstruction.IntBinary"),
            Immediate(name: nil, type: "Instruction.BinaryOperand"),
        ]),
        Instruction(name: "numericFloatBinary", immediates: [
            Immediate(name: nil, type: "NumericInstruction.FloatBinary"),
            Immediate(name: nil, type: "Instruction.BinaryOperand"),
        ]),
        Instruction(name: "numericConversion", mayThrow: true, immediates: [
            Immediate(name: nil, type: "NumericInstruction.Conversion"),
            Immediate(name: nil, type: "Instruction.UnaryOperand"),
        ]),
    ]

    struct LoadInstruction {
        let loadAs: String
        let castToValue: String
        let base: Instruction
    }

    static let memoryLoadInsts: [LoadInstruction] = [
        ("i32Load", "UInt32", ".i32($0)"),
        ("i64Load", "UInt64", ".i64($0)"),
        ("f32Load", "UInt32", ".rawF32($0)"),
        ("f64Load", "UInt64", ".rawF64($0)"),
        ("i32Load8S", "Int8", ".init(signed: Int32($0))"),
        ("i32Load8U", "UInt8", ".i32(UInt32($0))"),
        ("i32Load16S", "Int16", ".init(signed: Int32($0))"),
        ("i32Load16U", "UInt16", ".i32(UInt32($0))"),
        ("i64Load8S", "Int8", ".init(signed: Int64($0))"),
        ("i64Load8U", "UInt8", ".i64(UInt64($0))"),
        ("i64Load16S", "Int16", ".init(signed: Int64($0))"),
        ("i64Load16U", "UInt16", ".i64(UInt64($0))"),
        ("i64Load32S", "Int32", ".init(signed: Int64($0))"),
        ("i64Load32U", "UInt32", ".i64(UInt64($0))"),
    ].map { (name, loadAs, castToValue) in
        let base = Instruction(name: name, mayThrow: true, useCurrentMemory: .read, immediates: [Immediate(name: nil, type: "Instruction.LoadOperand")])
        return LoadInstruction(loadAs: loadAs, castToValue: castToValue, base: base)
    }

    struct StoreInstruction {
        let castFromValue: String
        let base: Instruction
    }
    static let memoryStoreInsts: [StoreInstruction] = [
        ("i32Store", "$0.i32"),
        ("i64Store", "$0.i64"),
        ("f32Store", "$0.rawF32"),
        ("f64Store", "$0.rawF64"),
        ("i32Store8", "UInt8(truncatingIfNeeded: $0.i32)"),
        ("i32Store16", "UInt16(truncatingIfNeeded: $0.i32)"),
        ("i64Store8", "UInt8(truncatingIfNeeded: $0.i64)"),
        ("i64Store16", "UInt16(truncatingIfNeeded: $0.i64)"),
        ("i64Store32", "UInt32(truncatingIfNeeded: $0.i64)"),
    ].map { (name, castFromValue) in
        let base = Instruction(name: name, mayThrow: true, useCurrentMemory: .read, immediates: [Immediate(name: nil, type: "Instruction.StoreOperand")])
        return StoreInstruction(castFromValue: castFromValue, base: base)
    }
    static let memoryLoadStoreInsts: [Instruction] = memoryLoadInsts.map(\.base) + memoryStoreInsts.map(\.base)
    static let memoryOpInsts: [Instruction] = [
        Instruction(name: "memorySize", immediates: [Immediate(name: nil, type: "Instruction.MemorySizeOperand")]),
        Instruction(name: "memoryGrow", mayThrow: true, useCurrentMemory: .write, immediates: [
            Immediate(name: nil, type: "Instruction.MemoryGrowOperand"),
        ]),
        Instruction(name: "memoryInit", mayThrow: true, immediates: [
            Immediate(name: nil, type: "Instruction.MemoryInitOperand"),
        ]),
        Instruction(name: "memoryDataDrop", immediates: [Immediate(name: nil, type: "DataIndex")]),
        Instruction(name: "memoryCopy", mayThrow: true, immediates: [
            Immediate(name: nil, type: "Instruction.MemoryCopyOperand"),
        ]),
        Instruction(name: "memoryFill", mayThrow: true, immediates: [
            Immediate(name: nil, type: "Instruction.MemoryFillOperand"),
        ]),
    ]

    static let miscInsts: [Instruction] = [
        // Parametric
        Instruction(name: "select", mayThrow: true, immediates: [Immediate(name: nil, type: "Instruction.SelectOperand")]),
        // Reference
        Instruction(name: "refNull", immediates: [Immediate(name: nil, type: "Instruction.RefNullOperand")]),
        Instruction(name: "refIsNull", immediates: [Immediate(name: nil, type: "Instruction.RefIsNullOperand")]),
        Instruction(name: "refFunc", immediates: [Immediate(name: nil, type: "Instruction.RefFuncOperand")]),
        // Table
        Instruction(name: "tableGet", mayThrow: true, immediates: [Immediate(name: nil, type: "Instruction.TableGetOperand")]),
        Instruction(name: "tableSet", mayThrow: true, immediates: [Immediate(name: nil, type: "Instruction.TableSetOperand")]),
        Instruction(name: "tableSize", immediates: [Immediate(name: nil, type: "Instruction.TableSizeOperand")]),
        Instruction(name: "tableGrow", mayThrow: true, immediates: [Immediate(name: nil, type: "Instruction.TableGrowOperand")]),
        Instruction(name: "tableFill", mayThrow: true, immediates: [Immediate(name: nil, type: "Instruction.TableFillOperand")]),
        Instruction(name: "tableCopy", mayThrow: true, immediates: [Immediate(name: nil, type: "Instruction.TableCopyOperand")]),
        Instruction(name: "tableInit", mayThrow: true, immediates: [Immediate(name: nil, type: "Instruction.TableInitOperand")]),
        Instruction(name: "tableElementDrop", immediates: [Immediate(name: nil, type: "ElementIndex")]),
        // Profiling
        Instruction(name: "onEnter", immediates: [Immediate(name: nil, type: "Instruction.OnEnterOperand")]),
        Instruction(name: "onExit", immediates: [Immediate(name: nil, type: "Instruction.OnExitOperand")]),
    ]

    static let instructions: [Instruction] =
        [
            // Variable
            Instruction(name: "copyStack", immediates: [Immediate(name: nil, type: "Instruction.CopyStackOperand")]),
            Instruction(name: "globalGet", mayThrow: true, immediates: [Immediate(name: nil, type: "Instruction.GlobalGetOperand")]),
            Instruction(name: "globalSet", mayThrow: true, immediates: [Immediate(name: nil, type: "Instruction.GlobalSetOperand")]),
            // Controls
            Instruction(
                name: "call", isControl: true, mayThrow: true, mayUpdateFrame: true, useCurrentMemory: .write,
                immediates: [
                    Immediate(name: nil, type: "Instruction.CallOperand")
                ]),
            Instruction(
                name: "compilingCall", isControl: true, mayThrow: true, mayUpdateFrame: true,
                immediates: [
                    Immediate(name: nil, type: "Instruction.CompilingCallOperand")
                ]),
            Instruction(
                name: "internalCall", isControl: true, mayThrow: true, mayUpdateFrame: true,
                immediates: [
                    Immediate(name: nil, type: "Instruction.InternalCallOperand")
                ]),
            Instruction(
                name: "callIndirect", isControl: true, mayThrow: true, mayUpdateFrame: true, useCurrentMemory: .write,
                immediates: [
                    Immediate(name: nil, type: "Instruction.CallIndirectOperand")
                ]),
            Instruction(name: "unreachable", isControl: true, mayThrow: true, immediates: []),
            Instruction(name: "nop", isControl: true, mayThrow: true, immediates: []),
            Instruction(
                name: "ifThen", isControl: true,
                immediates: [
                    Immediate(name: nil, type: "Instruction.IfOperand")
                ]),
            Instruction(
                name: "br", isControl: true, mayThrow: true, mayUpdateFrame: false,
                immediates: [
                    Immediate(name: "offset", type: "Int32"),
                ]),
            Instruction(
                name: "brIf", isControl: true, mayThrow: true, mayUpdateFrame: false,
                immediates: [
                    Immediate(name: nil, type: "Instruction.BrIfOperand")
                ]),
            Instruction(
                name: "brIfNot", isControl: true, mayThrow: true, mayUpdateFrame: false,
                immediates: [
                    Immediate(name: nil, type: "Instruction.BrIfOperand")
                ]),
            Instruction(
                name: "brTable", isControl: true, mayThrow: true, mayUpdateFrame: false,
                immediates: [
                    Immediate(name: nil, type: "Instruction.BrTableOperand")
                ]),
            Instruction(name: "`return`", isControl: true, mayThrow: true, mayUpdateFrame: true, useCurrentMemory: .write, immediates: []),
            Instruction(name: "endOfExecution", isControl: true, mayThrow: true, mayUpdateFrame: true, immediates: []),
        ]
        + memoryLoadStoreInsts
        + memoryOpInsts
        + numericOtherInsts
        + intBinaryInsts.map(\.base)
        + intUnaryInsts.map(\.base)
        + floatBinaryInsts.map(\.base)
        + miscInsts

    static func camelCase(pascalCase: String) -> String {
        let first = pascalCase.first!.lowercased()
        return first + pascalCase.dropFirst()
    }

    static func generateDispatcher(instructions: [Instruction]) -> String {
        let doExecuteParams: [Instruction.Parameter] =
            [("instruction", "Instruction", false)]
            + VirtualRegister.allCases.map { ($0.label, $0.type, true) }
        var output = """
            extension ExecutionState {
                @inline(__always)
                mutating func doExecute(_ \(doExecuteParams.map { "\($0.label): \($0.isInout ? "inout " : "")\($0.type)" }.joined(separator: ", "))) throws -> Bool {
                    switch instruction {
            """

        for inst in instructions {
            let tryPrefix = inst.mayThrow ? "try " : ""
            let args = inst.parameters.map { label, _, isInout in
                "\(label): \(isInout ? "&" : "")\(label)"
            }
            if inst.immediates.isEmpty {
                output += """

                            case .\(inst.name):
                    """
            } else {
                let labels = inst.immediates.map {
                    $0.name ?? camelCase(pascalCase: String($0.type.split(separator: ".").last!))
                }
                output += """

                            case .\(inst.name)(\(labels.map { "let \($0)" }.joined(separator: ", "))):
                    """
            }
            output += """

                            \(tryPrefix)self.\(inst.name)(\(args.joined(separator: ", ")))
                """
            if inst.isControl {
                output += """

                                return \(!inst.mayUpdateFrame)
                    """
            }
        }
        output += """

                    }
                    pc += 1
                    return true
                }
            }
            """
        return output
    }

    static func generateBasicInstImplementations() -> String {
        var output = """
            extension ExecutionState {
            """

        for inst in intBinaryInsts + floatBinaryInsts {
            output += """

                mutating \(instMethodDecl(inst.base)) {
                    sp[binaryOperand.result] = sp[binaryOperand.lhs].\(inst.inputType).\(inst.op.lowercased())(sp[binaryOperand.rhs].\(inst.inputType)).untyped
                }
            """
        }
        for inst in intUnaryInsts {
            output += """

                mutating \(instMethodDecl(inst.base)) {
                    sp[unaryOperand.result] = sp[unaryOperand.input].\(inst.inputType).\(inst.op.lowercased()).untyped
                }
            """
        }

        for inst in memoryLoadInsts {
            output += """

                mutating \(instMethodDecl(inst.base)) {
                    try memoryLoad(sp: sp, md: md, ms: ms, loadOperand: loadOperand, loadAs: \(inst.loadAs).self, castToValue: { \(inst.castToValue) })
                }
            """
        }
        for inst in memoryStoreInsts {
            output += """

                mutating \(instMethodDecl(inst.base)) {
                    try memoryStore(sp: sp, md: md, ms: ms, storeOperand: storeOperand, castFromValue: { \(inst.castFromValue) })
                }
            """
        }

        output += """

            }

            """
        return output
    }

    static func instMethodDecl(_ inst: Instruction) -> String {
        let throwsKwd = inst.mayThrow ? " throws" : ""
        let args = inst.parameters
        return "func \(inst.name)(\(args.map { "\($0.label): \($0.isInout ? "inout " : "")\($0.type)" }.joined(separator: ", ")))\(throwsKwd)"
    }

    static func generatePrototype(instructions: [Instruction]) -> String {
        var output = """

            extension ExecutionState {
            """
        for inst in instructions {
            output += """

                    mutating \(instMethodDecl(inst)) {
                        fatalError("Unimplemented instruction: \(inst.name)")
                    }
                """
        }
        output += """

            }

            """
        return output
    }

    static func replaceInstMethodSignature(_ inst: Instruction, sourceRoot: URL) throws {
        func tryReplace(file: URL) throws -> Bool {
            var contents = try String(contentsOf: file)
            guard contents.contains("func \(inst.name)(") else {
                return false
            }
            // Replace the found line with the new signature
            var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, line) in lines.enumerated() {
                if let range = line.range(of: "func \(inst.name)(") {
                    lines[i] = lines[i][..<range.lowerBound] + instMethodDecl(inst) + " {"
                    break
                }
            }
            contents = lines.joined(separator: "\n")
            try contents.write(to: file, atomically: true, encoding: .utf8)
            return true
        }

        let files = try FileManager.default.contentsOfDirectory(at: sourceRoot.appendingPathComponent("Sources/WasmKit/Execution/Instructions"), includingPropertiesForKeys: nil)
        for file in files {
            if try tryReplace(file: file) {
                print("Replaced \(inst.name) in \(file.lastPathComponent)")
                return
            }
        }
    }
    static func replaceMethodSignature(instructions: [Instruction], sourceRoot: URL) throws {
        for inst in instructions {
            try replaceInstMethodSignature(inst, sourceRoot: sourceRoot)
        }
    }

    static func generateInstName(instructions: [Instruction]) -> String {
        var output = """
            extension Instruction {
                var name: String {
                    switch self {
            """
        for inst in instructions {
            output += """

                        case .\(inst.name): return "\(inst.name)"
                """
        }
        output += """

                    }
                }
            }

            """
        return output
    }

    static func generateEnumDefinition(instructions: [Instruction]) -> String {
        var output = "enum Instruction: Equatable {\n"
        for inst in instructions {
            output += "    case \(inst.name)"
            if !inst.immediates.isEmpty {
                output += "("
                output += inst.immediates.map { immediate in
                    if let name = immediate.name {
                        return name + ": " + immediate.type
                    } else {
                        return immediate.type
                    }
                }.joined(separator: ", ")
                output += ")"
            }
            output += "\n"
        }
        output += "}\n"
        return output
    }

    static func main(arguments: [String]) throws {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        if arguments.count > 1 {
            switch arguments[1] {
            case "prototype":
                print(generatePrototype(instructions: instructions))
                return
            case "replace":
                try replaceMethodSignature(instructions: instructions, sourceRoot: sourceRoot)
            default: break
            }
        }

        do {
            var output = """
                // This file is generated by Utilities/generate_inst_dispatch.swift

                """

            output += generateDispatcher(instructions: instructions)
            output += "\n\n"
            output += generateInstName(instructions: instructions)
            output += "\n\n"
            output += generateBasicInstImplementations()

            let outputFile = sourceRoot.appending(path: "Sources/WasmKit/Execution/Runtime/InstDispatch.swift")
            try output.write(to: outputFile, atomically: true, encoding: .utf8)
        }

        do {
            let outputFile = sourceRoot.appending(path: "Sources/WasmKit/Execution/Instructions/Instruction.swift")
            let output = generateEnumDefinition(instructions: instructions)
            try output.write(to: outputFile, atomically: true, encoding: .utf8)
        }
        try replaceMethodSignature(instructions: instructions, sourceRoot: sourceRoot)
    }
}

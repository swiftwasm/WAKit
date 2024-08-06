/// > Note:
/// <https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions>
extension ExecutionState {
    typealias Memarg = Instruction.Memarg

    mutating func i32Load(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, loadOperand: Instruction.LoadOperand) throws {
        try memoryLoad(runtime: runtime, stack: stack, currentMemory: currentMemory, loadOperand: loadOperand, loadAs: UInt32.self, castToValue: { .i32($0) })
    }
    mutating func i64Load(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, loadOperand: Instruction.LoadOperand) throws {
        try memoryLoad(runtime: runtime, stack: stack, currentMemory: currentMemory, loadOperand: loadOperand, loadAs: UInt64.self, castToValue: { .i64($0) })
    }
    mutating func f32Load(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, loadOperand: Instruction.LoadOperand) throws {
        try memoryLoad(runtime: runtime, stack: stack, currentMemory: currentMemory, loadOperand: loadOperand, loadAs: UInt32.self, castToValue: { .f32($0) })
    }
    mutating func f64Load(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, loadOperand: Instruction.LoadOperand) throws {
        try memoryLoad(runtime: runtime, stack: stack, currentMemory: currentMemory, loadOperand: loadOperand, loadAs: UInt64.self, castToValue: { .f64($0) })
    }
    mutating func i32Load8S(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, loadOperand: Instruction.LoadOperand) throws {
        try memoryLoad(runtime: runtime, stack: stack, currentMemory: currentMemory, loadOperand: loadOperand, loadAs: Int8.self, castToValue: { .init(signed: Int32($0)) })
    }
    mutating func i32Load8U(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, loadOperand: Instruction.LoadOperand) throws {
        try memoryLoad(runtime: runtime, stack: stack, currentMemory: currentMemory, loadOperand: loadOperand, loadAs: UInt8.self, castToValue: { .i32(UInt32($0)) })
    }
    mutating func i32Load16S(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, loadOperand: Instruction.LoadOperand) throws {
        try memoryLoad(runtime: runtime, stack: stack, currentMemory: currentMemory, loadOperand: loadOperand, loadAs: Int16.self, castToValue: { .init(signed: Int32($0)) })
    }
    mutating func i32Load16U(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, loadOperand: Instruction.LoadOperand) throws {
        try memoryLoad(runtime: runtime, stack: stack, currentMemory: currentMemory, loadOperand: loadOperand, loadAs: UInt16.self, castToValue: { .i32(UInt32($0)) })
    }
    mutating func i64Load8S(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, loadOperand: Instruction.LoadOperand) throws {
        try memoryLoad(runtime: runtime, stack: stack, currentMemory: currentMemory, loadOperand: loadOperand, loadAs: Int8.self, castToValue: { .init(signed: Int64($0)) })
    }
    mutating func i64Load8U(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, loadOperand: Instruction.LoadOperand) throws {
        try memoryLoad(runtime: runtime, stack: stack, currentMemory: currentMemory, loadOperand: loadOperand, loadAs: UInt8.self, castToValue: { .i64(UInt64($0)) })
    }
    mutating func i64Load16S(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, loadOperand: Instruction.LoadOperand) throws {
        try memoryLoad(runtime: runtime, stack: stack, currentMemory: currentMemory, loadOperand: loadOperand, loadAs: Int16.self, castToValue: { .init(signed: Int64($0)) })
    }
    mutating func i64Load16U(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, loadOperand: Instruction.LoadOperand) throws {
        try memoryLoad(runtime: runtime, stack: stack, currentMemory: currentMemory, loadOperand: loadOperand, loadAs: UInt16.self, castToValue: { .i64(UInt64($0)) })
    }
    mutating func i64Load32S(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, loadOperand: Instruction.LoadOperand) throws {
        try memoryLoad(runtime: runtime, stack: stack, currentMemory: currentMemory, loadOperand: loadOperand, loadAs: Int32.self, castToValue: { .init(signed: Int64($0)) })
    }
    mutating func i64Load32U(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, loadOperand: Instruction.LoadOperand) throws {
        try memoryLoad(runtime: runtime, stack: stack, currentMemory: currentMemory, loadOperand: loadOperand, loadAs: UInt32.self, castToValue: { .i64(UInt64($0)) })
    }

    @_transparent
    private mutating func memoryLoad<T: FixedWidthInteger>(
        runtime: Runtime, stack: FrameBase, currentMemory: CurrentMemory, loadOperand: Instruction.LoadOperand, loadAs _: T.Type = T.self, castToValue: (T) -> UntypedValue
    ) throws {
        let memarg = loadOperand.memarg

        let length = UInt64(T.bitWidth) / 8
        let i = stack[loadOperand.pointer].asAddressOffset(loadOperand.isMemory64)
        let (address, isOverflow) = memarg.offset.addingReportingOverflow(i)
        let (endAddress, isEndOverflow) = address.addingReportingOverflow(length)
        guard !isOverflow, !isEndOverflow, endAddress <= currentMemory.count else {
            throw Trap.outOfBoundsMemoryAccess
        }

        let loaded = currentMemory.buffer.loadUnaligned(fromByteOffset: Int(address), as: T.self)
        stack[loadOperand.result] = castToValue(loaded)

    }

    mutating func i32Store(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, storeOperand: Instruction.StoreOperand) throws {
        try memoryStore(runtime: runtime, stack: stack, currentMemory: currentMemory, storeOperand: storeOperand, castFromValue: { $0.i32 })
    }
    mutating func i64Store(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, storeOperand: Instruction.StoreOperand) throws {
        try memoryStore(runtime: runtime, stack: stack, currentMemory: currentMemory, storeOperand: storeOperand, castFromValue: { $0.i64 })
    }
    mutating func f32Store(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, storeOperand: Instruction.StoreOperand) throws {
        try memoryStore(runtime: runtime, stack: stack, currentMemory: currentMemory, storeOperand: storeOperand, castFromValue: { $0.f32 })
    }
    mutating func f64Store(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, storeOperand: Instruction.StoreOperand) throws {
        try memoryStore(runtime: runtime, stack: stack, currentMemory: currentMemory, storeOperand: storeOperand, castFromValue: { $0.f64 })
    }
    mutating func i32Store8(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, storeOperand: Instruction.StoreOperand) throws {
        try memoryStore(runtime: runtime, stack: stack, currentMemory: currentMemory, storeOperand: storeOperand, castFromValue: { UInt8(truncatingIfNeeded: $0.i32) })
    }
    mutating func i32Store16(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, storeOperand: Instruction.StoreOperand) throws {
        try memoryStore(runtime: runtime, stack: stack, currentMemory: currentMemory, storeOperand: storeOperand, castFromValue: { UInt16(truncatingIfNeeded: $0.i32) })
    }
    mutating func i64Store8(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, storeOperand: Instruction.StoreOperand) throws {
        try memoryStore(runtime: runtime, stack: stack, currentMemory: currentMemory, storeOperand: storeOperand, castFromValue: { UInt8(truncatingIfNeeded: $0.i64) })
    }
    mutating func i64Store16(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, storeOperand: Instruction.StoreOperand) throws {
        try memoryStore(runtime: runtime, stack: stack, currentMemory: currentMemory, storeOperand: storeOperand, castFromValue: { UInt16(truncatingIfNeeded: $0.i64) })
    }
    mutating func i64Store32(runtime: Runtime, context: inout StackContext, stack: FrameBase, currentMemory: CurrentMemory, storeOperand: Instruction.StoreOperand) throws {
        try memoryStore(runtime: runtime, stack: stack, currentMemory: currentMemory, storeOperand: storeOperand, castFromValue: { UInt32(truncatingIfNeeded: $0.i64) })
    }

    /// `[type].store[bitWidth]`
    @_transparent
    private mutating func memoryStore<T: FixedWidthInteger>(runtime: Runtime, stack: FrameBase, currentMemory: CurrentMemory, storeOperand: Instruction.StoreOperand, castFromValue: (UntypedValue) -> T) throws {
        let memarg = storeOperand.memarg

        let value = stack[storeOperand.value]

        let address: UInt64
        let endAddress: UInt64
        let length: UInt64
        do {
            let i = stack[storeOperand.pointer].asAddressOffset(storeOperand.isMemory64)
            var isOverflow: Bool
            (address, isOverflow) = memarg.offset.addingReportingOverflow(i)
            guard !isOverflow else {
                throw Trap.outOfBoundsMemoryAccess
            }
            length = UInt64(T.bitWidth) / 8
            (endAddress, isOverflow) = address.addingReportingOverflow(length)
            guard !isOverflow, endAddress <= currentMemory.count else {
                throw Trap.outOfBoundsMemoryAccess
            }
        }

        let toStore = castFromValue(value)
        currentMemory.buffer.baseAddress!.advanced(by: Int(address))
            .bindMemory(to: T.self, capacity: 1).pointee = toStore.littleEndian
    }

    mutating func memorySize(runtime: Runtime, context: inout StackContext, stack: FrameBase, memorySizeOperand: Instruction.MemorySizeOperand) {
        let moduleInstance = currentModule(store: runtime.store, stack: &context)
        let store = runtime.store

        let memoryAddress = moduleInstance.memoryAddresses[0]

        let memoryInstance = store.memories[memoryAddress]
        let pageCount = memoryInstance.data.count / MemoryInstance.pageSize
        let value: Value = memoryInstance.limit.isMemory64 ? .i64(UInt64(pageCount)) : .i32(UInt32(pageCount))
        stack[memorySizeOperand.result] = UntypedValue(value)
    }
    mutating func memoryGrow(runtime: Runtime, context: inout StackContext, stack: FrameBase, memoryGrowOperand: Instruction.MemoryGrowOperand) throws {
        let moduleInstance = currentModule(store: runtime.store, stack: &context)
        let store = runtime.store

        let memoryAddress = moduleInstance.memoryAddresses[0]
        store.withMemory(at: memoryAddress) { memoryInstance in
            let isMemory64 = memoryInstance.limit.isMemory64

            let value = stack[memoryGrowOperand.delta]
            let pageCount: UInt64 = isMemory64 ? value.i64 : UInt64(value.i32)
            let oldPageCount = memoryInstance.grow(by: Int(pageCount))
            stack[memoryGrowOperand.result] = UntypedValue(oldPageCount)
        }
        mayUpdateCurrentInstance(store: store, stack: context)
    }
    mutating func memoryInit(runtime: Runtime, context: inout StackContext, stack: FrameBase, memoryInitOperand: Instruction.MemoryInitOperand) throws {
        let moduleInstance = currentModule(store: runtime.store, stack: &context)
        let store = runtime.store

        let memoryAddress = moduleInstance.memoryAddresses[0]
        try store.withMemory(at: memoryAddress) { memoryInstance in
            let dataAddress = moduleInstance.dataAddresses[Int(memoryInitOperand.segmentIndex)]
            let dataInstance = store.datas[dataAddress]

            let copyCounter = stack[memoryInitOperand.size].i32
            let sourceIndex = stack[memoryInitOperand.sourceOffset].i32
            let destinationIndex = stack[memoryInitOperand.destOffset].asAddressOffset(memoryInstance.limit.isMemory64)

            guard copyCounter > 0 else { return }

            guard
                !sourceIndex.addingReportingOverflow(copyCounter).overflow
                    && !destinationIndex.addingReportingOverflow(UInt64(copyCounter)).overflow
                    && memoryInstance.data.count >= destinationIndex + UInt64(copyCounter)
                    && dataInstance.data.count >= sourceIndex + copyCounter
            else {
                throw Trap.outOfBoundsMemoryAccess
            }

            // FIXME: benchmark if using `replaceSubrange` is faster than this loop
            for i in 0..<copyCounter {
                memoryInstance.data[Int(destinationIndex + UInt64(i))] =
                    dataInstance.data[Int(sourceIndex + i)]
            }
        }
    }
    mutating func memoryDataDrop(runtime: Runtime, context: inout StackContext, stack: FrameBase, dataIndex: DataIndex) {
        let moduleInstance = currentModule(store: runtime.store, stack: &context)
        let store = runtime.store
        let dataAddress = moduleInstance.dataAddresses[Int(dataIndex)]
        store.datas[dataAddress] = DataInstance(data: [])
    }
    mutating func memoryCopy(runtime: Runtime, context: inout StackContext, stack: FrameBase, memoryCopyOperand: Instruction.MemoryCopyOperand) throws {
        let moduleInstance = currentModule(store: runtime.store, stack: &context)
        let store = runtime.store

        let memoryAddress = moduleInstance.memoryAddresses[0]
        try store.withMemory(at: memoryAddress) { memoryInstance in
            let isMemory64 = memoryInstance.limit.isMemory64
            let copyCounter = stack[memoryCopyOperand.size].asAddressOffset(isMemory64)
            let sourceIndex = stack[memoryCopyOperand.sourceOffset].asAddressOffset(isMemory64)
            let destinationIndex = stack[memoryCopyOperand.destOffset].asAddressOffset(isMemory64)

            guard copyCounter > 0 else { return }

            guard
                !sourceIndex.addingReportingOverflow(copyCounter).overflow
                    && !destinationIndex.addingReportingOverflow(copyCounter).overflow
                    && memoryInstance.data.count >= destinationIndex + copyCounter
                    && memoryInstance.data.count >= sourceIndex + copyCounter
            else {
                throw Trap.outOfBoundsMemoryAccess
            }

            if destinationIndex <= sourceIndex {
                for i in 0..<copyCounter {
                    memoryInstance.data[Int(destinationIndex + i)] = memoryInstance.data[Int(sourceIndex + i)]
                }
            } else {
                for i in 1...copyCounter {
                    memoryInstance.data[Int(destinationIndex + copyCounter - i)] = memoryInstance.data[Int(sourceIndex + copyCounter - i)]
                }
            }
        }
    }
    mutating func memoryFill(runtime: Runtime, context: inout StackContext, stack: FrameBase, memoryFillOperand: Instruction.MemoryFillOperand) throws {
        let moduleInstance = currentModule(store: runtime.store, stack: &context)
        let store = runtime.store
        let memoryAddress = moduleInstance.memoryAddresses[0]
        try store.withMemory(at: memoryAddress) { memoryInstance in
            let isMemory64 = memoryInstance.limit.isMemory64
            let copyCounter = Int(stack[memoryFillOperand.size].asAddressOffset(isMemory64))
            let value = stack[memoryFillOperand.value].i32
            let destinationIndex = Int(stack[memoryFillOperand.destOffset].asAddressOffset(isMemory64))

            guard
                !destinationIndex.addingReportingOverflow(copyCounter).overflow
                    && memoryInstance.data.count >= destinationIndex + copyCounter
            else {
                throw Trap.outOfBoundsMemoryAccess
            }

            memoryInstance.data.replaceSubrange(
                destinationIndex..<destinationIndex + copyCounter,
                with: [UInt8](repeating: value.littleEndianBytes[0], count: copyCounter)
            )
        }
    }
}

@testable import WasmKit
import XCTest
import WAT

final class ExecutionTests: XCTestCase {
    func testDropWithRelinkingOptimization() throws {
        let module = try parseWasm(
            bytes: wat2wasm(
            """
            (module
                (func (export "_start") (result i32) (local $x i32)
                    (i32.const 42)
                    (i32.const 0)
                    (i32.eqz)
                    (drop)
                    (local.set $x)
                    (local.get $x)
                )
            )
            """
            )
        )
        let engine = Engine()
        let store = Store(engine: engine)
        let instance = try module.instantiate(store: store)
        let _start = try XCTUnwrap(instance.exports[function: "_start"])
        let results = try _start()
        XCTAssertEqual(results, [.i32(42)])
    }

    func testUpdateCurrentMemoryCacheOnGrow() throws {
        let module = try parseWasm(
            bytes: wat2wasm(
            """
            (module
                (memory 0)
                (func (export "_start") (result i32)
                    (memory.grow (i32.const 1))
                    (i32.store (i32.const 1) (i32.const 42))
                    (i32.load (i32.const 1))
                )
            )
            """
            )
        )
        let engine = Engine()
        let store = Store(engine: engine)
        let instance = try module.instantiate(store: store)
        let _start = try XCTUnwrap(instance.exports[function: "_start"])
        let results = try _start()
        XCTAssertEqual(results, [.i32(42)])
    }
}

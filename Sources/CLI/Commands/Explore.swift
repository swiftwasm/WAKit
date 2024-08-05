import ArgumentParser
import SystemPackage
import WasmKit

struct Explore: ParsableCommand {
    @Argument
    var path: String

    struct Stdout: TextOutputStream {
        func write(_ string: String) {
            print(string, terminator: "")
        }
    }

    func run() throws {
        let module = try parseWasm(filePath: FilePath(path))
        var stdout = Stdout()
        try module._functions(to: &stdout)
    }
}

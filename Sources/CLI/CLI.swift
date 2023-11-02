import ArgumentParser

@main
struct CLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wasmkit",
        abstract: "WebAssembly Runtime written in Swift.",
        version: "0.0.1",
        subcommands: [Run.self]
    )
}

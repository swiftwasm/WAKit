import WasmParser
import WasmTypes

/// A name with its location in the source file
struct Name: Equatable {
    /// The name of the module field declaration specified in $id form
    let value: String
    /// The location of the name in the source file
    let location: Location
}

/// A module field declaration that may have its name
protocol NamedModuleFieldDecl {
    /// The name of the module field declaration specified in $id form
    var id: Name? { get }
}

/// A module field declaration that may be imported from another module
protocol ImportableModuleFieldDecl {
    /// The import names of the module field declaration
    var importNames: WatParser.ImportNames? { get }
}

protocol NameToIndexResolver {
    func resolveIndex(use: Parser.IndexOrId) throws -> Int
}

/// A map of module field declarations indexed by their name
struct NameMapping<Decl: NamedModuleFieldDecl>: NameToIndexResolver {
    private var decls: [Decl] = []
    private var nameToIndex: [String: Int] = [:]

    /// Adds a new declaration to the mapping
    /// - Parameter newDecl: The declaration to add
    /// - Returns: The index of the added declaration
    @discardableResult
    mutating func add(_ newDecl: Decl) throws -> Int {
        let index = decls.count
        decls.append(newDecl)
        if let name = newDecl.id {
            guard nameToIndex[name.value] == nil else {
                throw WatParserError("Duplicate \(name.value) identifier", location: name.location)
            }
            nameToIndex[name.value] = index
        }
        return index
    }

    func resolveIndex(use: Parser.IndexOrId) throws -> Int {
        switch use {
        case .id(let id, _):
            guard let byName = nameToIndex[id.value] else {
                throw WatParserError("Unknown \(Decl.self) \(id)", location: use.location)
            }
            return byName
        case .index(let value, _):
            return Int(value)
        }
    }

    /// Resolves a declaration by its name or index
    /// - Parameter use: The name or index of the declaration
    /// - Returns: The declaration and its index
    func resolve(use: Parser.IndexOrId) throws -> (decl: Decl, index: Int) {
        let index = try resolveIndex(use: use)
        guard index < decls.count else {
            throw WatParserError("Invalid \(Decl.self) index \(index)", location: use.location)
        }
        return (decls[index], index)
    }
}

extension NameMapping: Collection {
    var count: Int { return decls.count }

    var isEmpty: Bool { decls.isEmpty }

    var startIndex: Int { decls.startIndex }
    var endIndex: Int { decls.endIndex }
    func index(after i: Int) -> Int {
        decls.index(after: i)
    }

    subscript(index: Int) -> Decl {
        return decls[index]
    }

    func makeIterator() -> Array<Decl>.Iterator {
        return decls.makeIterator()
    }
}

extension NameMapping where Decl: ImportableModuleFieldDecl {
    /// Returns the declarations that are defined in the module.
    /// The returned declarations are sorted by the order they were added to this mapping.
    func definitions() -> [Decl] {
        decls.filter { $0.importNames == nil }
    }
}

typealias TypesNameMapping = NameMapping<TypesMap.NamedResolvedType>

/// A map of unique function types indexed by their name or type signature
struct TypesMap {
    struct NamedResolvedType: NamedModuleFieldDecl {
        let id: Name?
        let type: WatParser.FunctionType
    }
    private(set) var nameMapping = NameMapping<NamedResolvedType>()
    /// Tracks the earliest index for each function type
    private var indices: [FunctionType: Int] = [:]

    /// Adds a new function type to the mapping
    @discardableResult
    mutating func add(_ decl: NamedResolvedType) throws -> Int {
        try nameMapping.add(decl)
        // Normalize the function type signature without parameter names
        if let existing = indices[decl.type.signature] {
            return existing
        } else {
            let newIndex = nameMapping.count - 1
            indices[decl.type.signature] = newIndex
            return newIndex
        }
    }

    /// Adds a new function type to the mapping without parameter names
    private mutating func addAnonymousSignature(_ signature: FunctionType) throws -> Int {
        if let existing = indices[signature] {
            return existing
        }
        return try add(
            NamedResolvedType(
                id: nil,
                type: WatParser.FunctionType(signature: signature, parameterNames: [])
            )
        )
    }

    private mutating func resolveBlockType(
        results: [ValueType],
        resolveSignatureIndex: (inout TypesMap) throws -> Int
    ) throws -> BlockType {
        if let result = results.first {
            guard results.count > 1 else { return .type(result) }
            return try .funcType(UInt32(resolveSignatureIndex(&self)))
        }
        return .empty
    }
    private mutating func resolveBlockType(
        signature: WasmTypes.FunctionType,
        resolveSignatureIndex: (inout TypesMap) throws -> Int
    ) throws -> BlockType {
        if signature.parameters.isEmpty {
            return try resolveBlockType(results: signature.results, resolveSignatureIndex: resolveSignatureIndex)
        }
        return try .funcType(UInt32(resolveSignatureIndex(&self)))
    }

    /// Resolves a block type from a list of result types
    mutating func resolveBlockType(results: [ValueType]) throws -> BlockType {
        return try resolveBlockType(
            results: results,
            resolveSignatureIndex: {
                let signature = FunctionType(parameters: [], results: results)
                return try $0.addAnonymousSignature(signature)
            })
    }

    /// Resolves a block type from a function type signature
    mutating func resolveBlockType(signature: WasmTypes.FunctionType) throws -> BlockType {
        return try resolveBlockType(
            signature: signature,
            resolveSignatureIndex: {
                return try $0.addAnonymousSignature(signature)
            })
    }

    /// Resolves a block type from a type use
    mutating func resolveBlockType(use: WatParser.TypeUse) throws -> BlockType {
        switch (use.index, use.inline) {
        case let (indexOrId?, inline):
            let (type, index) = try resolveAndCheck(use: indexOrId, inline: inline?.resolve(nameMapping))
            return try resolveBlockType(signature: type.signature, resolveSignatureIndex: { _ in index })
        case (nil, let inline?):
            return try resolveBlockType(signature: inline.resolve(nameMapping).signature)
        case (nil, nil): return .empty
        }
    }

    mutating func resolveIndex(use: WatParser.TypeUse) throws -> Int {
        switch (use.index, use.inline) {
        case let (indexOrId?, _):
            return try nameMapping.resolveIndex(use: indexOrId)
        case (nil, let inline):
            let inline = try inline?.resolve(nameMapping).signature ?? WasmTypes.FunctionType(parameters: [], results: [])
            return try addAnonymousSignature(inline)
        }
    }

    /// Resolves a function type from a type use
    func resolve(use: Parser.IndexOrId) throws -> (decl: WatParser.FunctionType, index: Int) {
        let (decl, index) = try nameMapping.resolve(use: use)
        return (decl.type, index)
    }

    private func resolveAndCheck(use indexOrId: Parser.IndexOrId, inline: WatParser.FunctionType?) throws -> (type: WatParser.FunctionType, index: Int) {
        let (found, index) = try resolve(use: indexOrId)
        if let inline {
            // If both index and inline type, then they must match
            guard found.signature == inline.signature else {
                throw WatParserError("Type mismatch \(found) != \(inline)", location: indexOrId.location)
            }
        }
        return (found, Int(index))
    }

    /// Resolves a function type from a type use with an optional inline type
    mutating func resolve(use: WatParser.TypeUse) throws -> (type: WatParser.FunctionType, index: Int) {
        switch (use.index, use.inline) {
        case let (indexOrId?, inline):
            return try resolveAndCheck(use: indexOrId, inline: inline?.resolve(nameMapping))
        case (nil, let inline):
            // If no index and no inline type, then it's a function type with no parameters or results
            let inline = try inline?.resolve(nameMapping) ?? WatParser.FunctionType(signature: WasmTypes.FunctionType(parameters: [], results: []), parameterNames: [])
            // Check if the inline type already exists
            if let index = indices[inline.signature] {
                return (inline, index)
            }
            // Add inline type to the index space if it doesn't already exist
            let index = try add(NamedResolvedType(id: nil, type: inline))
            return (inline, index)
        }
    }
}

extension TypesMap: Collection {
    var isEmpty: Bool { return nameMapping.isEmpty }

    var startIndex: Int { return nameMapping.startIndex }
    var endIndex: Int { return nameMapping.endIndex }
    func index(after i: Int) -> Int {
        nameMapping.index(after: i)
    }

    subscript(position: Int) -> NamedResolvedType {
        return nameMapping[position]
    }

    func makeIterator() -> NameMapping<NamedResolvedType>.Iterator {
        return nameMapping.makeIterator()
    }
}

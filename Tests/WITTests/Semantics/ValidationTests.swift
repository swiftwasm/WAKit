import XCTest

@testable import WIT

class ValidationTests: XCTestCase {

    func assertDiagnostics(_ text: String, expected: [String], line: UInt = #line) throws {
        let packageResolver = PackageResolver()
        var lexer = Lexer(cursor: .init(input: text))
        let sourceFile = try SourceFileSyntax.parse(lexer: &lexer, fileName: "test.wit")
        let pkg = try packageResolver.register(packageSources: [sourceFile])
        let context = SemanticsContext(rootPackage: pkg, packageResolver: packageResolver)

        let diagnostics = try context.validate(package: pkg)

        XCTAssertEqual(diagnostics.flatMap(\.value).map(\.message), expected, line: line)
    }

    func testInvalidTypeReferences() throws {
        try assertDiagnostics(
            """
            package foo:bar
            interface x {
              type x = invalid1
            }
            world y {
              type y = invalid2
            }
            """,
            expected: [
                "Cannot find type 'invalid1' in scope",
                "Cannot find type 'invalid2' in scope",
            ]
        )
    }

    func testInvalidTypeReferencesInTypeDefinitions() throws {
        try assertDiagnostics(
            """
            package foo:bar
            interface x {
              record r1 {
                f1: invalid1
              }
              variant v1 {
                var-case1(invalid2),
                var-case2,
              }
              union u1 {
                invalid3,
              }
              type h1 = own<invalid4>
            }
            """,
            expected: [
                "Cannot find type 'invalid1' in scope",
                "Cannot find type 'invalid2' in scope",
                "Cannot find type 'invalid3' in scope",
                "Cannot find type 'invalid4' in scope",
            ]
        )
    }

    func testInvalidTypeReferencesInFunctions() throws {
        try assertDiagnostics(
            """
            package foo:bar
            interface x {
              f1: func() -> invalid1
              f2: func(x: invalid2) -> invalid3
              f3: func(a: invalid4, b: invalid5) -> (c: invalid6, d: invalid7)
            }
            """,
            expected: [
                "Cannot find type 'invalid1' in scope",
                "Cannot find type 'invalid2' in scope",
                "Cannot find type 'invalid3' in scope",
                "Cannot find type 'invalid4' in scope",
                "Cannot find type 'invalid5' in scope",
                "Cannot find type 'invalid6' in scope",
                "Cannot find type 'invalid7' in scope",
            ]
        )
    }

    func testInvalidTypeReferencesInUse() throws {
        try assertDiagnostics(
            """
            package foo:bar
            interface types {
              type t1 = u8
            }
            interface x {
              use types.{t1, invalid1}
              use invalid2.{t2}
            }
            """,
            expected: [
                "Cannot find type 'invalid1' in scope",
                "Cannot find interface 'invalid2' in scope",
            ]
        )
    }

    func testValidateInlineInterface() throws {
        try assertDiagnostics(
            """
            package foo:bar
            world x {
              import y: interface {
                type z = invalid1
                type a = u8
                type b = a
              }
              // a shoud not be visible here
              type c = a
            }
            """,
            expected: [
                "Cannot find type 'invalid1' in scope",
                "Cannot find type 'a' in scope",
            ]
        )
        try assertDiagnostics(
            """
            package foo:bar
            world x {
              export y: interface {
                type z = invalid1
                type a = u8
                type b = a
              }
              // a shoud not be visible here
              type c = a
            }
            """,
            expected: [
                "Cannot find type 'invalid1' in scope",
                "Cannot find type 'a' in scope",
            ]
        )
    }

    func testValidateImportExport() throws {
        try assertDiagnostics(
            """
            package foo:bar
            interface ok1 {}
            interface ok2 {}
            world x {
              import ok1
              import invalid1
              export ok2
              export invalid2
            }
            """,
            expected: [
                "Cannot find interface 'invalid1' in scope",
                "Cannot find interface 'invalid2' in scope",
            ]
        )
    }

    func testInvalidTopLevelUse() throws {
        try assertDiagnostics(
            """
            package foo:bar
            use foo:my-pkg/my-iface
            """,
            expected: ["No such package 'foo:my-pkg'"]
        )

        try assertDiagnostics(
            """
            package foo:bar
            use foo
            """,
            expected: ["Cannot find interface 'foo' in scope"]
        )
    }

    func testRecordRedeclaration() throws {
        try assertDiagnostics(
            """
            package foo:bar
            interface x {
              record r1 {
                f1: u8,
                f1: u8,
                f2: u8,
                f2: u32,
              }
            }
            """,
            expected: [
                "Invalid redeclaration of 'f1'",
                "Invalid redeclaration of 'f2'",
            ]
        )
    }

    func testVariantRedeclaration() throws {
        try assertDiagnostics(
            """
            package foo:bar
            interface x {
              variant v1 {
                var-case1,
                var-case1,
                var-case2(u8),
                var-case2(u32),
              }
            }
            """,
            expected: [
                "Invalid redeclaration of 'var-case1'",
                "Invalid redeclaration of 'var-case2'",
            ]
        )
    }
}

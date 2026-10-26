import Testing

@Suite struct CalculatorTests {
    @Test(arguments: [
        ("1+2", 3.0),
        ("2 + 3 * 4", 14),
        ("(2+3)*4", 20),
        ("10 / 4", 2.5),
        ("10 - 4 - 3", 3),
        ("2^3^2", 512),
        ("2**10", 1024),
        ("-2^2", -4),
        ("-(3+4)", -7),
        ("3 * -2", -6),
        ("7 % 3", 1),
        (".5 * 4", 2),
        ("6 × 7", 42),
        ("9 ÷ 3", 3),
        ("sqrt(16) + abs(-2)", 6),
        ("log(1000)", 3),
        ("ln(e)", 1),
        ("cos(0)", 1),
    ])
    func evaluates(input: String, expected: Double) {
        #expect(Calculator.evaluate(input) == expected)
    }

    @Test func usesConstants() throws {
        let value = try #require(Calculator.evaluate("2 * pi"))
        #expect(abs(value - 2 * Double.pi) < 1e-12)
    }

    // Anything that isn't arithmetic must yield nil so app search isn't
    // cluttered: plain words, lone numbers or constants, malformed input,
    // and non-finite results.
    @Test(arguments: ["", "safari", "5", "-5", "pi", "e", "2+", "(1+2", "1+2)", "1/0", "sqrt(-1)", "foo(2)", "2 3"])
    func rejects(input: String) {
        #expect(Calculator.evaluate(input) == nil)
    }

    @Test(arguments: [
        (0.1 + 0.2, "0.3"),
        (1.0 / 3, "0.3333333333"),
        (42, "42"),
        (-4, "-4"),
        (2.5, "2.5"),
        (1e20, "1e+20"),
    ])
    func formats(value: Double, expected: String) {
        #expect(Calculator.format(value) == expected)
    }
}

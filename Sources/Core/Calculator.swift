import Foundation

/// Evaluates arithmetic like `2 * (3 + 4)^2` or `sqrt(2) / pi`.
enum Calculator {
    /// The value of `input`, or nil unless it's a complete expression with at
    /// least one operator or function call and a finite result. Lone numbers
    /// and words don't count, so they're left to app search.
    static func evaluate(_ input: String) -> Double? {
        guard let tokens = tokenize(input) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = try? parser.parse(), parser.sawOperation, value.isFinite else {
            return nil
        }
        return value
    }

    /// Up to ten decimals without float noise (0.1 + 0.2 gives "0.3"), and
    /// scientific notation for very large or small values.
    static func format(_ value: Double) -> String {
        let rounded = Double(String(format: "%.15g", value))!
        if rounded == 0 { return "0" }
        if abs(rounded) >= 1e15 || abs(rounded) < 1e-4 { return String(format: "%.10g", rounded) }
        var string = String(format: "%.10f", rounded)
        while string.hasSuffix("0") { string.removeLast() }
        if string.hasSuffix(".") { string.removeLast() }
        return string
    }

    private enum Token: Equatable {
        case number(Double)
        case name(String)
        case symbol(Character)
    }

    private struct ParseError: Error {}

    private static let functions: [String: (Double) -> Double] = [
        "sqrt": sqrt, "cbrt": cbrt, "abs": abs,
        "sin": sin, "cos": cos, "tan": tan, "asin": asin, "acos": acos, "atan": atan,
        "ln": log, "log": log10, "log2": log2, "exp": exp,
        "floor": floor, "ceil": ceil, "round": { $0.rounded() },
    ]

    private static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E]

    private static let aliases: [Character: Character] = ["−": "-", "×": "*", "÷": "/"]

    private static func tokenize(_ input: String) -> [Token]? {
        let chars = Array(input.replacingOccurrences(of: "**", with: "^"))
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let c = aliases[chars[i]] ?? chars[i]
            if c.isWhitespace {
                i += 1
            } else if isNumeric(c) {
                let end = chars[i...].firstIndex { !isNumeric($0) } ?? chars.count
                guard let value = Double(String(chars[i..<end])) else { return nil }
                tokens.append(.number(value))
                i = end
            } else if c.isLetter {
                let end = chars[i...].firstIndex { !($0.isLetter || $0.isNumber) } ?? chars.count
                tokens.append(.name(String(chars[i..<end]).lowercased()))
                i = end
            } else if "+-*/%^()".contains(c) {
                tokens.append(.symbol(c))
                i += 1
            } else {
                return nil
            }
        }
        return tokens
    }

    private static func isNumeric(_ c: Character) -> Bool {
        c.isASCII && (c.isNumber || c == ".")
    }

    // Precedence, loosest first: + -, then * / %, then unary minus, then ^
    // (right-associative, so 2^3^2 is 512 and -2^2 is -4).
    private struct Parser {
        let tokens: [Token]
        var position = 0
        var sawOperation = false

        mutating func parse() throws -> Double {
            let value = try sum()
            guard position == tokens.count else { throw ParseError() }
            return value
        }

        private mutating func sum() throws -> Double {
            var value = try product()
            while let op = take(oneOf: "+-") {
                let rhs = try product()
                value = op == "+" ? value + rhs : value - rhs
                sawOperation = true
            }
            return value
        }

        private mutating func product() throws -> Double {
            var value = try unary()
            while let op = take(oneOf: "*/%") {
                let rhs = try unary()
                switch op {
                case "*": value *= rhs
                case "/": value /= rhs
                default: value = value.truncatingRemainder(dividingBy: rhs)
                }
                sawOperation = true
            }
            return value
        }

        private mutating func unary() throws -> Double {
            if let op = take(oneOf: "+-") {
                let value = try unary()
                return op == "-" ? -value : value
            }
            return try power()
        }

        private mutating func power() throws -> Double {
            let base = try primary()
            guard take(oneOf: "^") != nil else { return base }
            sawOperation = true
            return pow(base, try unary())
        }

        private mutating func primary() throws -> Double {
            guard position < tokens.count else { throw ParseError() }
            let token = tokens[position]
            position += 1
            switch token {
            case .number(let value):
                return value
            case .symbol("("):
                let value = try sum()
                guard take(oneOf: ")") != nil else { throw ParseError() }
                return value
            case .name(let name):
                if take(oneOf: "(") != nil { return try call(name) }
                guard let value = constants[name] else { throw ParseError() }
                return value
            default:
                throw ParseError()
            }
        }

        private mutating func call(_ name: String) throws -> Double {
            guard let function = functions[name] else { throw ParseError() }
            let argument = try sum()
            guard take(oneOf: ")") != nil else { throw ParseError() }
            sawOperation = true
            return function(argument)
        }

        private mutating func take(oneOf symbols: String) -> Character? {
            guard position < tokens.count else { return nil }
            guard case .symbol(let c) = tokens[position], symbols.contains(c) else { return nil }
            position += 1
            return c
        }
    }
}

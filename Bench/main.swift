import AppKit

/// Median time of `body` over `runs` runs, in milliseconds.
func median(runs: Int, _ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    let times = (0..<runs).map { _ in clock.measure(body) }.sorted()
    let time = times[runs / 2].components
    return Double(time.seconds) * 1e3 + Double(time.attoseconds) / 1e15
}

let index = AppIndex()
index.start()
while index.apps.isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

print("Indexing \(index.apps.count) apps: \(String(format: "%.0f", median(runs: 11) { _ = AppIndex.scan() })) ms")

for query in ["s", "sa", "saf", "safari", "vsc", "xyz"] {
    print("Search \"\(query)\": \(String(format: "%.3f", median(runs: 1001) { _ = index.search(query, limit: 8) })) ms")
}

for expression in ["1+2", "sqrt(2) * (3 + 4)^2 / pi"] {
    let ms = median(runs: 10001) { _ = Calculator.evaluate(expression).map(Calculator.format) }
    print("Math \"\(expression)\": \(String(format: "%.4f", ms)) ms")
}

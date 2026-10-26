import AppKit

/// Median time of `body` over `runs` runs, in milliseconds.
func median(runs: Int, _ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    let times = (0..<runs).map { _ in clock.measure(body) }.sorted()
    let middle = runs / 2
    let time = times[middle].components
    return Double(time.seconds) * 1e3 + Double(time.attoseconds) / 1e15
}

func report(_ label: String, _ milliseconds: Double, decimals: Int) {
    print(label + ": " + String(format: "%.\(decimals)f", milliseconds) + " ms")
}

let index = AppIndex()
index.start()
while index.apps.isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

let indexing = median(runs: 11) { _ = AppIndex.scan() }
report("Indexing \(index.apps.count) apps", indexing, decimals: 0)

for query in ["s", "sa", "saf", "safari", "vsc", "xyz"] {
    let search = median(runs: 1001) { _ = index.search(query, limit: 8) }
    report("Search \"\(query)\"", search, decimals: 3)
}

for expression in ["1+2", "sqrt(2) * (3 + 4)^2 / pi"] {
    let math = median(runs: 10001) { _ = Calculator.evaluate(expression).map(Calculator.format) }
    report("Math \"\(expression)\"", math, decimals: 4)
}

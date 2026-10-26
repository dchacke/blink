import Testing

@Suite struct MatcherTests {
    @Test(arguments: [
        ("saf", "Safari", Match.Tier.prefix),
        ("notes", "Sticky Notes", .wordPrefix),
        ("edit", "TextEdit", .wordPrefix),
        ("vsc", "Visual Studio Code", .initials),
        ("code", "Xcode", .substring),
        ("sfri", "Safari", .fuzzy),
        ("uber", "Über", .prefix),
        ("SAF", "Safari", .prefix),
    ])
    func tiers(query: String, name: String, tier: Match.Tier) {
        #expect(SearchKey(name).match(query)?.tier == tier)
    }

    @Test func ranksTiers() throws {
        let prefix = try #require(SearchKey("Notes").match("note"))
        let word = try #require(SearchKey("Sticky Notes").match("note"))
        let substring = try #require(SearchKey("Keynote").match("note"))
        #expect(prefix > word)
        #expect(word > substring)
    }

    @Test func prefersCloserMatchWithinTier() throws {
        let exact = try #require(SearchKey("Calculator").match("calc"))
        let longer = try #require(SearchKey("Calculator Pro").match("calc"))
        #expect(exact > longer)
    }

    @Test(arguments: [("xyz", "Safari"), ("", "Safari"), ("  ", "Safari"), ("safarix", "Safari")])
    func rejects(query: String, name: String) {
        #expect(SearchKey(name).match(query) == nil)
    }
}

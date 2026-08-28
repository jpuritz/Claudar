import XCTest
@testable import ClaudarCore

/// The usage payload is undocumented and owned by Anthropic, so these tests pin
/// down what the parser does with the shapes we've actually seen — including the
/// awkward ones — and what it does when the shape changes underneath us.
final class UsageParserTests: XCTestCase {

    private func json(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - Limits

    func testParsesTheShapeTheEndpointActuallyReturns() {
        let data = json("""
        {
          "five_hour":  { "utilization": 31, "resets_at": "2026-07-24T20:00:00Z" },
          "seven_day":  { "utilization": 43, "resets_at": "2026-07-27T22:00:00.123Z" },
          "extra_usage": { "utilization": 32 }
        }
        """)
        let limits = UsageParser.limits(from: data)

        XCTAssertEqual(limits.map(\.id), ["five_hour", "seven_day", "extra_usage"])
        XCTAssertEqual(limits[0].label, "Session (5 h)")
        XCTAssertEqual(limits[1].label, "Weekly · all models")
        XCTAssertEqual(limits[0].utilization, 31)
        XCTAssertNotNil(limits[0].resetsAt)
        XCTAssertNil(limits[2].resetsAt, "a limit without resets_at should parse with a nil date")
    }

    func testAppliesPreferredOrderRegardlessOfKeyOrder() {
        // JSON objects are unordered, so the parser must impose the order itself.
        let data = json("""
        {
          "extra_usage": { "utilization": 5 },
          "seven_day_opus": { "utilization": 6 },
          "five_hour": { "utilization": 7 },
          "seven_day": { "utilization": 8 }
        }
        """)
        XCTAssertEqual(
            UsageParser.limits(from: data).map(\.id),
            ["five_hour", "seven_day", "seven_day_opus", "extra_usage"]
        )
    }

    func testUnknownLimitsAppearAutomaticallyWithATidiedLabel() {
        // The whole point of the generic parser: a new limit needs no code change.
        let data = json(#"{ "five_hour": {"utilization": 1}, "three_day_haiku": {"utilization": 2} }"#)
        let limits = UsageParser.limits(from: data)

        XCTAssertEqual(limits.count, 2)
        XCTAssertEqual(limits.first { $0.id == "three_day_haiku" }?.label, "Three Day Haiku")
    }

    func testUnknownLimitsSortStablyAfterKnownOnes() {
        let data = json("""
        { "zebra_limit": {"utilization": 1},
          "alpha_limit": {"utilization": 2},
          "five_hour": {"utilization": 3} }
        """)
        XCTAssertEqual(
            UsageParser.limits(from: data).map(\.id),
            ["five_hour", "alpha_limit", "zebra_limit"]
        )
    }

    func testFindsLimitsNestedUnderAWrapperObject() {
        let data = json(#"{ "usage": { "five_hour": { "utilization": 12 } } }"#)
        XCTAssertEqual(UsageParser.limits(from: data).map(\.id), ["five_hour"])
    }

    func testClampsUtilizationIntoRange() {
        // A bar drawn from an out-of-range number would overflow its track.
        let data = json(#"{ "a": {"utilization": 140}, "b": {"utilization": -8} }"#)
        let byID = Dictionary(uniqueKeysWithValues: UsageParser.limits(from: data).map { ($0.id, $0) })

        XCTAssertEqual(byID["a"]?.utilization, 100)
        XCTAssertEqual(byID["b"]?.utilization, 0)
    }

    func testAcceptsFractionalUtilization() {
        let data = json(#"{ "five_hour": {"utilization": 31.6} }"#)
        XCTAssertEqual(UsageParser.limits(from: data).first?.utilization ?? 0, 31.6, accuracy: 0.0001)
    }

    func testReturnsEmptyRatherThanThrowingOnJunk() {
        // Each of these is a way the endpoint could change or fail on us; none of
        // them should be able to crash the app.
        XCTAssertTrue(UsageParser.limits(from: json("not json at all")).isEmpty)
        XCTAssertTrue(UsageParser.limits(from: json("[]")).isEmpty, "a top-level array")
        XCTAssertTrue(UsageParser.limits(from: Data()).isEmpty, "an empty body")
        XCTAssertTrue(UsageParser.limits(from: json("{}")).isEmpty, "no limits at all")
        XCTAssertTrue(
            UsageParser.limits(from: json(#"{ "five_hour": {"used": 4} }"#)).isEmpty,
            "an object with no utilization key is not a limit"
        )
    }

    func testIgnoresNonNumericUtilization() {
        let data = json(#"{ "five_hour": {"utilization": "31"} }"#)
        XCTAssertTrue(UsageParser.limits(from: data).isEmpty)
    }

    // MARK: - Dates

    func testParsesISODatesWithAndWithoutFractionalSeconds() {
        let plain = UsageParser.isoDate("2026-07-24T20:00:00Z")
        let fractional = UsageParser.isoDate("2026-07-24T20:00:00.123Z")

        XCTAssertNotNil(plain)
        XCTAssertNotNil(fractional, "the API sometimes includes milliseconds")
        XCTAssertEqual(plain!.timeIntervalSince1970,
                       fractional!.timeIntervalSince1970, accuracy: 1.0)
    }

    func testRejectsUnparseableDates() {
        XCTAssertNil(UsageParser.isoDate(""))
        XCTAssertNil(UsageParser.isoDate("tomorrow"))
        XCTAssertNil(UsageParser.isoDate("2026-07-24"))
    }

    // MARK: - Plan label

    func testPlanLabelPrefersTheMostCapablePlan() {
        // An account can carry several capabilities; Max should win over Pro.
        XCTAssertEqual(UsageParser.planLabel(from: ["chat", "claude_pro", "claude_max"]), "Max")
        XCTAssertEqual(UsageParser.planLabel(from: ["chat", "claude_pro"]), "Pro")
        XCTAssertEqual(UsageParser.planLabel(from: ["claude_team"]), "Team")
        XCTAssertEqual(UsageParser.planLabel(from: ["claude_enterprise"]), "Enterprise")
    }

    func testPlanLabelIsNilWhenNoPlanCapabilityIsPresent() {
        XCTAssertNil(UsageParser.planLabel(from: []))
        XCTAssertNil(UsageParser.planLabel(from: ["chat", "claude_something_new"]))
    }

    // MARK: - Org id from cookie

    func testExtractsOrgIDFromCookieHeader() {
        let cookie = "intercom=x; lastActiveOrg=abc-123-def; sessionKey=sk-ant-xyz"
        XCTAssertEqual(UsageParser.orgID(fromCookie: cookie), "abc-123-def")
    }

    func testPercentDecodesOrgID() {
        XCTAssertEqual(
            UsageParser.orgID(fromCookie: "lastActiveOrg=abc%2D123; other=1"),
            "abc-123"
        )
    }

    func testOrgIDToleratesWhitespaceAndPosition() {
        XCTAssertEqual(UsageParser.orgID(fromCookie: "lastActiveOrg=solo"), "solo")
        XCTAssertEqual(UsageParser.orgID(fromCookie: "a=1;   lastActiveOrg=spaced   ;b=2"),
                       "spaced")
    }

    func testOrgIDIsNilWhenAbsentOrEmpty() {
        XCTAssertNil(UsageParser.orgID(fromCookie: "sessionKey=sk-ant-xyz"))
        XCTAssertNil(UsageParser.orgID(fromCookie: ""))
        XCTAssertNil(UsageParser.orgID(fromCookie: "lastActiveOrg=; sessionKey=x"))
    }

    func testOrgIDDoesNotMatchASimilarlyNamedCookie() {
        XCTAssertNil(UsageParser.orgID(fromCookie: "notLastActiveOrgReally=nope"))
    }
}

/// Multi-org support hangs entirely off `/api/organizations`, and a login with
/// two orgs is exactly the case that used to be silently truncated to the first.
final class OrganizationParsingTests: XCTestCase {

    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testReturnsEveryOrgInAPIOrder() {
        let data = json("""
        [
          {"uuid": "aaa", "name": "Jon Puritz", "capabilities": ["chat", "claude_max"]},
          {"uuid": "bbb", "name": "Marine Evo Eco Lab", "capabilities": ["claude_team"]}
        ]
        """)
        let orgs = UsageParser.organizations(from: data)

        XCTAssertEqual(orgs.map(\.id), ["aaa", "bbb"])
        XCTAssertEqual(orgs.map(\.name), ["Jon Puritz", "Marine Evo Eco Lab"])
        XCTAssertEqual(orgs.map(\.plan), ["Max", "Team"])
    }

    func testPlanIsResolvedPerOrgNotGlobally() {
        // The whole point of showing a badge per row: one login, two plans.
        let data = json("""
        [ {"uuid": "a", "name": "Personal", "capabilities": ["claude_pro"]},
          {"uuid": "b", "name": "Work", "capabilities": ["claude_enterprise"]} ]
        """)
        let byID = Dictionary(uniqueKeysWithValues: UsageParser.organizations(from: data).map { ($0.id, $0) })

        XCTAssertEqual(byID["a"]?.plan, "Pro")
        XCTAssertEqual(byID["b"]?.plan, "Enterprise")
    }

    func testSkipsEntriesWithNoUsableUUID() {
        let data = json("""
        [ {"name": "No uuid at all"},
          {"uuid": "", "name": "Empty uuid"},
          {"uuid": "good", "name": "Fine"} ]
        """)
        XCTAssertEqual(UsageParser.organizations(from: data).map(\.id), ["good"])
    }

    func testCollapsesDuplicateOrgs() {
        // A repeated uuid would otherwise produce two identical switcher rows.
        let data = json("""
        [ {"uuid": "dup", "name": "First"}, {"uuid": "dup", "name": "Second"} ]
        """)
        let orgs = UsageParser.organizations(from: data)

        XCTAssertEqual(orgs.count, 1)
        XCTAssertEqual(orgs.first?.name, "First", "the first spelling wins")
    }

    func testFallsBackToAUUIDStubWhenNameIsMissingOrBlank() {
        // Never leave a switcher row with an empty label.
        let data = json("""
        [ {"uuid": "0123456789abcdef"}, {"uuid": "fedcba9876543210", "name": "   "} ]
        """)
        let orgs = UsageParser.organizations(from: data)

        XCTAssertEqual(orgs[0].name, "Org 01234567")
        XCTAssertEqual(orgs[1].name, "Org fedcba98")
    }

    func testTrimsSurroundingWhitespaceInNames() {
        let data = json(#"[ {"uuid": "a", "name": "  Spaced Out  "} ]"#)
        XCTAssertEqual(UsageParser.organizations(from: data).first?.name, "Spaced Out")
    }

    func testPlanIsNilRatherThanInventedWhenCapabilitiesAreMissing() {
        let data = json(#"[ {"uuid": "a", "name": "Plain"} ]"#)
        XCTAssertNil(UsageParser.organizations(from: data).first?.plan)
    }

    func testReturnsEmptyOnJunkOrUnexpectedShapes() {
        XCTAssertTrue(UsageParser.organizations(from: json("not json")).isEmpty)
        XCTAssertTrue(UsageParser.organizations(from: json("{}")).isEmpty, "an object, not an array")
        XCTAssertTrue(UsageParser.organizations(from: json("[]")).isEmpty)
        XCTAssertTrue(UsageParser.organizations(from: Data()).isEmpty)
    }

    func testSingleOrgStillParsesAsOne() {
        // The overwhelmingly common case must keep working unchanged.
        let data = json(#"[ {"uuid": "solo", "name": "Me", "capabilities": ["claude_pro"]} ]"#)
        XCTAssertEqual(UsageParser.organizations(from: data), [OrgInfo(id: "solo", name: "Me", plan: "Pro")])
    }
}

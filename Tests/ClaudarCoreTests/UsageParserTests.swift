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

    // MARK: - Per-model weekly limits

    func testLabelsFableLikeSonnetAndOpus() {
        let data = json("""
        { "seven_day": {"utilization": 40},
          "seven_day_opus": {"utilization": 12},
          "seven_day_fable": {"utilization": 55},
          "seven_day_sonnet": {"utilization": 8} }
        """)
        let byID = Dictionary(uniqueKeysWithValues: UsageParser.limits(from: data).map { ($0.id, $0) })

        XCTAssertEqual(byID["seven_day_fable"]?.label, "Weekly · Fable")
        XCTAssertEqual(byID["seven_day_opus"]?.label, "Weekly · Opus")
        XCTAssertEqual(byID["seven_day_sonnet"]?.label, "Weekly · Sonnet")
        XCTAssertEqual(byID["seven_day"]?.label, "Weekly · all models")
    }

    func testModelLimitsAreLabelledByRuleSoTheExactKeyDoesNotMatter() {
        // The upstream key for a new model isn't announced anywhere, so the label
        // has to come from the shape of the key rather than a hardcoded list.
        XCTAssertEqual(UsageParser.label(for: "seven_day_fable"), "Weekly · Fable")
        XCTAssertEqual(UsageParser.label(for: "seven_day_fable_5"), "Weekly · Fable 5")
        XCTAssertEqual(UsageParser.label(for: "seven_day_haiku"), "Weekly · Haiku")
        XCTAssertEqual(UsageParser.label(for: "seven_day_some_future_model"),
                       "Weekly · Some Future Model")
    }

    func testHandWrittenLabelsStillWinOverTheRule() {
        // "seven_day_oauth_apps" also matches the prefix, and the rule would
        // render it "Oauth Apps".
        XCTAssertEqual(UsageParser.label(for: "seven_day_oauth_apps"), "Weekly · OAuth apps")
        XCTAssertEqual(UsageParser.label(for: "seven_day"), "Weekly · all models")
        XCTAssertEqual(UsageParser.label(for: "five_hour"), "Session (5 h)")
        XCTAssertEqual(UsageParser.label(for: "extra_usage"), "Extra usage")
    }

    func testFableSitsWithTheOtherModelLimits() {
        let data = json("""
        { "extra_usage": {"utilization": 1},
          "seven_day_sonnet": {"utilization": 2},
          "five_hour": {"utilization": 3},
          "seven_day_fable": {"utilization": 4},
          "seven_day": {"utilization": 5},
          "seven_day_opus": {"utilization": 6} }
        """)
        XCTAssertEqual(
            UsageParser.limits(from: data).map(\.id),
            ["five_hour", "seven_day", "seven_day_opus", "seven_day_fable",
             "seven_day_sonnet", "extra_usage"]
        )
    }

    func testAnUnlistedModelLimitStillGroupsWithTheWeeklyOnes() {
        // Ordering falls back to alphabetical, but a seven_day_* key should not
        // end up stranded below "Extra usage".
        let data = json("""
        { "extra_usage": {"utilization": 1},
          "seven_day_unreleased": {"utilization": 2},
          "five_hour": {"utilization": 3},
          "zzz_other": {"utilization": 4} }
        """)
        XCTAssertEqual(
            UsageParser.limits(from: data).map(\.id),
            ["five_hour", "extra_usage", "seven_day_unreleased", "zzz_other"]
        )
    }

    func testFableIsAbsentWhenTheAPIDoesNotReportIt() {
        // "When present" is the whole ask: no phantom row for a model you have
        // no limit for.
        let data = json(#"{ "five_hour": {"utilization": 31}, "seven_day": {"utilization": 43} }"#)
        let ids = UsageParser.limits(from: data).map(\.id)

        XCTAssertEqual(ids, ["five_hour", "seven_day"])
        XCTAssertFalse(ids.contains { $0.contains("fable") })
    }

    // MARK: - The `limits` array (where per-model limits actually live)

    /// Trimmed from a real claude.ai response: the array alongside the legacy
    /// top-level keys and the internal codenames Claude Code doesn't show.
    private var realWorldPayload: Data {
        json("""
        {
          "five_hour":  { "utilization": 63, "resets_at": "2026-08-29T17:39:59.550128+00:00" },
          "seven_day":  { "utilization": 52, "resets_at": "2026-09-01T12:59:59.550151+00:00" },
          "nimbus_quill": { "utilization": 0, "resets_at": null },
          "amber_ladder": null,
          "seven_day_opus": null,
          "extra_usage": { "utilization": 15.15 },
          "member_dashboard_available": false,
          "spend": { "percent": 15, "used": { "amount_minor": 1212 } },
          "limits": [
            { "kind": "session", "group": "session", "percent": 63, "severity": "normal",
              "resets_at": "2026-08-29T17:39:59.550128+00:00", "scope": null },
            { "kind": "weekly_all", "group": "weekly", "percent": 52, "severity": "normal",
              "resets_at": "2026-09-01T12:59:59.550151+00:00", "scope": null },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 100, "severity": "critical",
              "resets_at": "2026-09-01T12:59:59.550349+00:00",
              "scope": { "model": { "display_name": "Fable", "id": null }, "surface": null } }
          ]
        }
        """)
    }

    func testFableComesFromTheLimitsArray() {
        // The regression this whole change exists for: Fable is at 100% in Claude
        // Code but was absent from Claudar, because it only appears in the array.
        let limits = UsageParser.limits(from: realWorldPayload)
        let fable = limits.first { $0.label.contains("Fable") }

        XCTAssertNotNil(fable, "Fable is only in the limits array, not the top-level keys")
        XCTAssertEqual(fable?.label, "Weekly · Fable")
        XCTAssertEqual(fable?.utilization, 100)
        XCTAssertNotNil(fable?.resetsAt)
    }

    func testArrayEntriesMapOntoTheExistingIDVocabulary() {
        // The menu bar looks up "five_hour" by id, and saved alert state is keyed
        // on these. New ids would break both silently.
        let byLabel = Dictionary(uniqueKeysWithValues:
            UsageParser.limits(from: realWorldPayload).map { ($0.label, $0.id) })

        XCTAssertEqual(byLabel["Session (5 h)"], "five_hour")
        XCTAssertEqual(byLabel["Weekly · all models"], "seven_day")
        XCTAssertEqual(byLabel["Weekly · Fable"], "seven_day_fable")
    }

    func testTheArrayDoesNotDuplicateTheLegacyTopLevelKeys() {
        let ids = UsageParser.limits(from: realWorldPayload).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "no id should appear twice")
        XCTAssertEqual(ids.filter { $0 == "five_hour" }.count, 1)
    }

    func testInternalCodenamesAreHiddenWhenTheArrayIsPresent() {
        // nimbus_quill and friends are in the payload at 0% but Claude Code
        // doesn't show them, and neither should we.
        let ids = UsageParser.limits(from: realWorldPayload).map(\.id)
        XCTAssertFalse(ids.contains("nimbus_quill"))
        XCTAssertFalse(ids.contains("spend"))
    }

    func testExtraUsageSurvivesTheArrayBecauseItIsNotInIt() {
        let byID = Dictionary(uniqueKeysWithValues:
            UsageParser.limits(from: realWorldPayload).map { ($0.id, $0) })
        XCTAssertEqual(byID["extra_usage"]?.utilization ?? 0, 15.15, accuracy: 0.001)
    }

    func testFullOrderOnTheRealPayload() {
        XCTAssertEqual(
            UsageParser.limits(from: realWorldPayload).map(\.id),
            ["five_hour", "seven_day", "seven_day_fable", "extra_usage"]
        )
    }

    func testSurfaceScopedLimitsAreNamedToo() {
        let data = json("""
        { "limits": [ { "kind": "weekly_scoped", "percent": 20,
                        "scope": { "surface": { "display_name": "Cowork" } } } ] }
        """)
        let limit = UsageParser.limits(from: data).first
        XCTAssertEqual(limit?.label, "Weekly · Cowork")
        XCTAssertEqual(limit?.id, "seven_day_cowork")
    }

    func testAScopedLimitWithNoNameStillParses() {
        let data = json(#"{ "limits": [ { "kind": "weekly_scoped", "percent": 5, "scope": null } ] }"#)
        XCTAssertEqual(UsageParser.limits(from: data).first?.id, "seven_day_scoped")
    }

    func testUnknownKindKeepsItsOwnIDAndATidyLabel() {
        let data = json(#"{ "limits": [ { "kind": "monthly_something", "percent": 7 } ] }"#)
        let limit = UsageParser.limits(from: data).first
        XCTAssertEqual(limit?.id, "monthly_something")
        XCTAssertEqual(limit?.label, "Monthly Something")
    }

    func testMalformedArrayEntriesAreSkippedNotFatal() {
        let data = json("""
        { "limits": [ {"percent": 10}, {"kind": "session"}, {"kind": "", "percent": 1},
                      {"kind": "weekly_all", "percent": 44} ] }
        """)
        XCTAssertEqual(UsageParser.limits(from: data).map(\.id), ["seven_day"])
    }

    func testFallsBackToTopLevelKeysWhenThereIsNoArray() {
        // Older payloads, and any endpoint that hasn't adopted the array.
        let data = json("""
        { "five_hour": {"utilization": 31}, "seven_day": {"utilization": 43},
          "some_new_limit": {"utilization": 9} }
        """)
        let ids = UsageParser.limits(from: data).map(\.id)
        XCTAssertEqual(ids, ["five_hour", "seven_day", "some_new_limit"],
                       "with no array, unknown keys still appear automatically")
    }

    func testAnEmptyArrayDoesNotSuppressTheTopLevelKeys() {
        let data = json(#"{ "limits": [], "five_hour": {"utilization": 31}, "nimbus_quill": {"utilization": 0} }"#)
        XCTAssertEqual(UsageParser.limits(from: data).map(\.id), ["five_hour", "nimbus_quill"])
    }

    func testArrayPercentIsClamped() {
        let data = json(#"{ "limits": [ {"kind": "session", "percent": 140} ] }"#)
        XCTAssertEqual(UsageParser.limits(from: data).first?.utilization, 100)
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

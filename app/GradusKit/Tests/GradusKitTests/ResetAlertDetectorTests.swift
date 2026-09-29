import Foundation
@testable import GradusKit
import Testing

private let device = "device-A"
private let generation = "8a596d59-294c-4efc-81a3-0caab767abbb"

private func instant(_ minute: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + minute * 60))
}

private func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

private func usage(
    _ provider: String = "Codex", at minute: Int, percent: Double,
    deadline: Int? = 60, windowID: String = "weekly", fresh: Bool = true
) -> ResetUsageObservation {
    ResetUsageObservation(
        providerName: provider, observedAt: instant(minute),
        windows: [ProviderWindow(id: windowID, percentLeft: percent,
                                 resetISO: deadline.map { iso(instant($0)) },
                                 windowHours: nil, paceDelta: nil)], isFresh: fresh
    )
}

private func count(_ number: Int, at minute: Int, generation: String = generation) -> ResetBankedObservation {
    ResetBankedObservation(count: number, generation: generation, observedAt: instant(minute))!
}

@Test func codexSameDeadlineCanRefillTwiceOnlyAfterNewLow() {
    var state = ResetAlertState()
    #expect(ResetAlertDetector.evaluate(
        state: &state, deviceID: device, observation: usage(at: 1, percent: 20)
    ).alerts.isEmpty)
    let first = ResetAlertDetector.evaluate(state: &state, deviceID: device, observation: usage(at: 2, percent: 99))
    #expect(first.alerts == [.usageRefill(providerName: "Codex", windowID: "weekly")])
    #expect(ResetAlertDetector.evaluate(
        state: &state, deviceID: device, observation: usage(at: 3, percent: 100)
    ).alerts.isEmpty)
    #expect(ResetAlertDetector.evaluate(
        state: &state, deviceID: device, observation: usage(at: 4, percent: 10)
    ).alerts.isEmpty)
    let second = ResetAlertDetector.evaluate(state: &state, deviceID: device, observation: usage(at: 5, percent: 97))
    #expect(second.alerts == first.alerts)
    #expect(ResetAlertDetector.evaluate(
        state: &state, deviceID: device, observation: usage(at: 5, percent: 97)
    ).alerts.isEmpty)
}

@Test func refillUsesSourceTimeAndProviderSpecificDeadlineRules() {
    let provider = "Claude"
    var state = ResetAlertState()
    _ = ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                    observation: usage(provider, at: 1, percent: 10))
    // An advanced deadline alone cannot overcome a high observation
    // delivered before the source's old deadline elapsed.
    #expect(ResetAlertDetector.evaluate(
        state: &state, deviceID: device,
        observation: usage(provider, at: 2, percent: 99, deadline: 120)
    ).alerts.isEmpty)
    _ = ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                    observation: usage(provider, at: 61, percent: 8, deadline: 120))
    let eligible = ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                               observation: usage(provider, at: 121, percent: 100, deadline: 180))
    #expect(eligible.alerts == [.usageRefill(providerName: provider, windowID: "weekly")])
}

@Test func nilNewDeadlineIsOneShotOnlyAfterOldDeadline() {
    var state = ResetAlertState()
    _ = ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                    observation: usage("Claude", at: 1, percent: 10))
    let result = ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                             observation: usage("Claude", at: 61, percent: 99, deadline: nil))
    #expect(result.alerts == [.usageRefill(providerName: "Claude", windowID: "weekly")])
    #expect(ResetAlertDetector.evaluate(
        state: &state, deviceID: device,
        observation: usage("Claude", at: 62, percent: 100, deadline: 120)
    ).alerts.isEmpty)
}

@Test func secondNilDeadlineCrossingDoesNotReplayTheOldRollover() {
    var state = ResetAlertState()
    _ = ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                    observation: usage("Claude", at: 1, percent: 10))
    #expect(ResetAlertDetector.evaluate(
        state: &state, deviceID: device,
        observation: usage("Claude", at: 61, percent: 99, deadline: nil)
    ).alerts.count == 1)
    _ = ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                    observation: usage("Claude", at: 62, percent: 10, deadline: nil))
    #expect(ResetAlertDetector.evaluate(
        state: &state, deviceID: device,
        observation: usage("Claude", at: 63, percent: 99, deadline: nil)
    ).alerts.isEmpty)
}

@Test func malformedNewDeadlineCannotMasqueradeAsMissingDeadline() {
    var state = ResetAlertState()
    _ = ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                    observation: usage("Claude", at: 1, percent: 10))
    let malformed = ResetUsageObservation(providerName: "Claude", observedAt: instant(61), windows: [
        ProviderWindow(id: "weekly", percentLeft: 99, resetISO: "invalid",
                       windowHours: nil, paceDelta: nil)
    ])
    #expect(ResetAlertDetector.evaluate(state: &state, deviceID: device, observation: malformed).alerts.isEmpty)
}

@Test func missingBucketAndCarriedUsageCannotCreateRefill() {
    var state = ResetAlertState()
    _ = ResetAlertDetector.evaluate(state: &state, deviceID: device, observation: usage(at: 1, percent: 4))
    _ = ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                    observation: ResetUsageObservation(
                                        providerName: "Codex", observedAt: instant(2), windows: []
                                    ))
    #expect(ResetAlertDetector.evaluate(
        state: &state, deviceID: device, observation: usage(at: 3, percent: 99)
    ).alerts.isEmpty)
    _ = ResetAlertDetector.evaluate(state: &state, deviceID: device, observation: usage(at: 4, percent: 4))
    #expect(ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                        observation: usage(at: 5, percent: 99, fresh: false)).alerts.isEmpty)
    #expect(ResetAlertDetector.evaluate(
        state: &state, deviceID: device, observation: usage(at: 6, percent: 99)
    ).alerts ==
        [.usageRefill(providerName: "Codex", windowID: "weekly")])
}

@Test func bankedCountHasIndependentTimestampAndSurvivesAbsence() {
    var state = ResetAlertState()
    let baseline = ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                               observation: usage(at: 1, percent: 30), banked: count(3, at: 1))
    #expect(baseline.alerts.isEmpty)
    #expect(baseline.bankedStatus == .current(count: 3, observedAt: instant(1)))
    let absent = ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                             observation: usage(at: 2, percent: 31))
    #expect(absent.bankedStatus == .unavailable(lastObservedCount: 3, lastObservedAt: instant(1)))
    let late = ResetAlertDetector.evaluateBankedCount(state: &state, deviceID: device, banked: count(5, at: 2))
    #expect(late.alerts == [.bankedGrant(increase: 2, currentCount: 5)])
    #expect(late.bankedStatus == .current(count: 5, observedAt: instant(2)))
    let replay = ResetAlertDetector.evaluateBankedCount(state: &state, deviceID: device, banked: count(5, at: 2))
    #expect(replay.alerts.isEmpty)
    #expect(replay.bankedStatus == .current(count: 5, observedAt: instant(2)))
    _ = ResetAlertDetector.evaluateBankedCount(state: &state, deviceID: device, banked: count(1, at: 3))
    #expect(ResetAlertDetector.evaluateBankedCount(state: &state, deviceID: device, banked: count(2, at: 4)).alerts ==
        [.bankedGrant(increase: 1, currentCount: 2)])
}

@Test func generationSwitchIsSilentAndClaudeCannotGrant() {
    var state = ResetAlertState()
    _ = ResetAlertDetector.evaluateBankedCount(state: &state, deviceID: device, banked: count(5, at: 1))
    let changed = count(20, at: 2, generation: "3fd110f2-4656-4d85-a163-52464d54a12a")
    #expect(ResetAlertDetector.evaluateBankedCount(state: &state, deviceID: device, banked: changed).alerts.isEmpty)
    let claude = ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                             observation: usage("Claude", at: 3, percent: 5),
                                             banked: count(22, at: 3))
    #expect(claude.alerts.isEmpty)
    #expect(claude.bankedStatus == .unavailable(lastObservedCount: 20, lastObservedAt: instant(2)))
}

@Test func lateCountFromOlderUsageDoesNotLookCurrentForNewerDisplay() {
    var state = ResetAlertState()
    _ = ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                    observation: usage(at: 1, percent: 20), banked: count(2, at: 1))
    let newer = ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                            observation: usage(at: 3, percent: 21), banked: count(5, at: 2))
    #expect(newer.alerts.isEmpty)
    #expect(newer.bankedStatus == .unavailable(lastObservedCount: 2, lastObservedAt: instant(1)))
    let late = ResetAlertDetector.evaluateBankedCount(
        state: &state, deviceID: device, banked: count(5, at: 2), displayedUsageObservedAt: instant(3)
    )
    #expect(late.alerts == [.bankedGrant(increase: 3, currentCount: 5)])
    #expect(late.bankedStatus == .unavailable(lastObservedCount: 5, lastObservedAt: instant(2)))
}

@Test func cursorRoundTripsAndRejectsUnknownVersion() throws {
    var state = ResetAlertState()
    _ = ResetAlertDetector.evaluate(state: &state, deviceID: device,
                                    observation: usage(at: 1, percent: 5), banked: count(2, at: 1))
    let encoded = try JSONEncoder().encode(state)
    var restored = try JSONDecoder().decode(ResetAlertState.self, from: encoded)
    #expect(restored == state)
    #expect(ResetAlertDetector.evaluate(state: &restored, deviceID: device,
                                        observation: usage(at: 2, percent: 98), banked: count(3, at: 2)).alerts ==
            [.usageRefill(providerName: "Codex", windowID: "weekly"), .bankedGrant(increase: 1, currentCount: 3)])
    #expect(throws: ResetAlertStateError.self) {
        _ = try JSONDecoder().decode(ResetAlertState.self, from: Data(#"{"schemaVersion":2,"devices":{}}"#.utf8))
    }
}

@Test func invalidFieldsDoNotAdvanceTheCursor() {
    var state = ResetAlertState()
    #expect(ResetBankedObservation(count: -1, generation: generation, observedAt: instant(1)) == nil)
    #expect(ResetBankedObservation(count: 1, generation: "not-a-uuid", observedAt: instant(1)) == nil)
    _ = ResetAlertDetector.evaluate(state: &state, deviceID: device, observation: usage(at: 1, percent: 4))
    #expect(ResetAlertDetector.evaluate(
        state: &state, deviceID: device, observation: usage(at: 0, percent: 100)
    ).alerts.isEmpty)
    #expect(ResetAlertDetector.evaluate(
        state: &state, deviceID: device, observation: usage(at: 2, percent: 96)
    ).alerts ==
        [.usageRefill(providerName: "Codex", windowID: "weekly")])
}

@Test func weeklyWinsWhenMultipleWindowsCross() {
    var state = ResetAlertState()
    func observation(_ minute: Int, _ percent: Double) -> ResetUsageObservation {
        ResetUsageObservation(providerName: "Claude", observedAt: instant(minute), windows: [
            ProviderWindow(
                id: "five_hour", percentLeft: percent, resetISO: iso(instant(minute == 1 ? 2 : 4)),
                windowHours: 5, paceDelta: nil
            ),
            ProviderWindow(
                id: "weekly", percentLeft: percent, resetISO: iso(instant(minute == 1 ? 2 : 4)),
                windowHours: 168, paceDelta: nil
            )
        ])
    }
    _ = ResetAlertDetector.evaluate(state: &state, deviceID: device, observation: observation(1, 3))
    #expect(ResetAlertDetector.evaluate(state: &state, deviceID: device, observation: observation(3, 100)).alerts ==
        [.usageRefill(providerName: "Claude", windowID: "weekly")])
}

@Test func providerEntryInitializerUsesSourceObservedAt() {
    let entry = ProviderEntry(name: "Codex", ok: true, error: nil, windows: [], data: [:],
                              observedAt: "2026-09-23T10:00:00-04:00")
    #expect(ResetUsageObservation(entry: entry)?.observedAt == ResetAlertDetector.parseInstant("2026-09-23T14:00:00Z"))
}

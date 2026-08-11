import GradusKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import GradusiOS

// Pixel coverage for iPad Option B at real device point sizes, with the full
// provider set. The existing dashboard snapshots are 390x600 -- an iPhone
// viewport -- so nothing in the suite would have shown an iPad regression.
//
// David's original complaint was that he has to scroll to see all his
// providers. That is a claim about a specific device size with a specific
// number of providers, so these fixtures use the real count (8 providers, 14
// windows) at real iPad dimensions rather than a reduced sample. A fixture of
// three providers would fit any layout and prove nothing.

private let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)

/// Every provider in David's actual set, with the window shape each really
/// has (Cursor two pools, Antigravity's split Gemini/Claude quotas, Copilot
/// monthly, Vibe on a monthly bucket).
@MainActor
func fullProviderSet() -> [ProviderStatus] {
    func w(_ id: String, _ percent: Double, _ pace: Double?, _ reset: String?) -> ProviderWindow {
        ProviderWindow(id: id, percentLeft: percent, resetISO: reset, windowHours: 168, paceDelta: pace)
    }
    func p(_ name: String, _ display: String, _ windows: [ProviderWindow]) -> ProviderStatus {
        ProviderStatus(
            providerName: name, providerDisplayName: display, ok: true, errorMessage: nil,
            windows: windows, data: [:],
            observedAt: ISO8601DateFormatter().string(from: fixedNow),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00", publishedAt: fixedNow,
            syncSource: name == "opencode"
                ? SyncSource(computerName: "dm5mbp", userName: "dave") : nil)
    }
    return [
        p("opencode", "OpenCode Go", [
            w("five_hour", 100, 0.30, "2026-07-25T15:05:00-04:00"),
            w("monthly", 7, -0.42, "2026-08-23T21:30:00-04:00"),
            w("weekly", 61, -0.12, "2026-08-01T20:00:00-04:00"),
        ]),
        p("codex", "Codex", [w("weekly", 76, -0.05, "2026-07-28T09:19:00-04:00")]),
        p("antigravity", "Antigravity", [
            w("five_hour", 100, 0.22, "2026-07-25T15:00:00-04:00"),
            w("weekly", 80, 0.04, "2026-07-28T14:16:00-04:00"),
        ]),
        p("claude", "Claude", [
            w("five_hour", 97, 0.18, "2026-07-25T15:00:00-04:00"),
            w("weekly", 99, 0.31, "2026-07-28T21:59:00-04:00"),
        ]),
        p("copilot", "Copilot", [w("premium", 100, 0.44, "2026-08-31T20:00:00-04:00")]),
        p("vibe", "Vibe", [w("billing_cycle", 100, 0.51, "2026-09-01T00:00:00-04:00")]),
        p("antigravity-claude", "Antigravity (Claude)", [
            w("five_hour", 100, 0.28, "2026-07-25T15:24:00-04:00"),
            w("weekly", 0, -0.60, "2026-07-25T13:26:00-04:00"),
        ]),
        // Cursor's real schema-v2 pool ids are "ap"/"ac", not "api"/"auto" --
        // see ProviderWindowLabel. Using the wrong ids here would have quietly
        // exercised the raw-id fallback instead of the real label mapping.
        p("cursor", "Cursor", [
            w("ap", 0, -0.55, "2026-08-12T07:46:00-04:00"),
            w("ac", 0, -0.55, "2026-08-12T07:46:00-04:00"),
        ]),
    ]
}

let pinnedCardColumnPreference = 1 // Small: the largest feasible count for each width.

private let densitySnapshotDisplayScale: CGFloat = 2.0

private enum DensitySnapshotFixture {
    case pad
    case phone

    var traits: [UITraitCollection] {
        switch self {
        case .pad:
            return [
                UITraitCollection(userInterfaceIdiom: .pad),
                UITraitCollection(horizontalSizeClass: .regular),
                UITraitCollection(verticalSizeClass: .regular),
            ]
        case .phone:
            return [
                UITraitCollection(userInterfaceIdiom: .phone),
                UITraitCollection(horizontalSizeClass: .compact),
                UITraitCollection(verticalSizeClass: .regular),
            ]
        }
    }
}

// Opt in only while intentionally refreshing these baselines:
// OTHER_SWIFT_FLAGS='$(inherited) -D DENSITY_SNAPSHOT_RECORD'
private let densitySnapshotRecording: SnapshotTestingConfiguration.Record = {
#if DENSITY_SNAPSHOT_RECORD
    return .all
#else
    return .never
#endif
}()

private func densitySnapshotTraits(
    fixture: DensitySnapshotFixture,
    style: UIUserInterfaceStyle,
    contentSizeCategory: UIContentSizeCategory? = nil
) -> UITraitCollection {
    var traits = fixture.traits + [
        UITraitCollection(displayScale: densitySnapshotDisplayScale),
        UITraitCollection(userInterfaceStyle: style),
    ]
    if let contentSizeCategory {
        traits.append(UITraitCollection(preferredContentSizeCategory: contentSizeCategory))
    }
    return UITraitCollection(traitsFrom: traits)
}

@MainActor
private func makeViewModel() -> DashboardViewModel {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-density-snap-\(UUID().uuidString)", isDirectory: true)
    let cache = FileLocalCacheStore(directory: directory)
    let defaults = UserDefaults(suiteName: "gradus-density-snap-\(UUID().uuidString)")!
    defaults.set(true, forKey: DashboardViewModel.showExhaustedKey)
    defaults.set(pinnedCardColumnPreference, forKey: DashboardViewModel.cardColumnPreferenceKey)
    let providers = fullProviderSet()
    let windows = providers.flatMap(\.windows)
    #expect(windows.contains { ($0.paceDelta ?? 0) > 0 })
    #expect(windows.contains { ($0.paceDelta ?? 0) < 0 })
    #expect(windows.contains { $0.percentLeft == 0 })
    #expect(windows.contains { $0.percentLeft == 100 })
    try? cache.saveCachedStatuses(providers, syncedAt: fixedNow)
    let viewModel = DashboardViewModel(cache: cache, userDefaults: defaults)
    // The initializer treats an unversioned stored value as a legacy direct
    // column count. Set the current slider stop after initialization so every
    // snapshot actually exercises the pinned candidate rather than Auto.
    viewModel.cardColumnPreference = pinnedCardColumnPreference
    return viewModel
}

@MainActor
private func denseDashboard(density: DashboardDensity? = nil) -> some View {
    DashboardContent(
        viewModel: makeViewModel(), now: fixedNow, layout: .denseGrid, density: density)
}

/// Semantic snapshot companion for the standard and XXXL image fixtures below.
/// Keeping the bucket identifiers explicit here means a contrast/layout edit
/// cannot make a baseline look plausible while silently replacing one of the
/// named windows with its raw schema id.
@MainActor
@Test func densityLabelFixturesKeepEveryNamedBucketAtStandardAndXXXL() {
    let expected = [
        ("five_hour", "5 Hour"),
        ("weekly", "Weekly"),
        ("monthly", "Monthly"),
        ("premium", "Monthly"),
        ("billing_cycle", "Monthly"),
        ("ac", "Auto"),
        ("ap", "API"),
    ]
    let windows = expected.map { id, _ in
        ProviderWindow(
            id: id, percentLeft: 47, resetISO: "2026-08-01T20:00:00-04:00", windowHours: 168,
            paceDelta: nil)
    }
    let fixture = ProviderStatus(
        providerName: "label-fixture", providerDisplayName: "Label fixture", ok: true,
        errorMessage: nil, windows: windows, data: [:],
        observedAt: ISO8601DateFormatter().string(from: fixedNow),
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00", publishedAt: fixedNow)

    for dynamicTypeSize in [DynamicTypeSize.large, .xxxLarge] {
        let rows = fixture.windows.map {
            WindowRow(window: $0, now: fixedNow, showsReset: false, metrics: .standard)
        }
        #expect(rows.count == expected.count)
        for ((id, label), row) in zip(expected, rows) {
            #expect(ProviderWindowLabel.label(for: id) == label)
            #expect(row.spokenLabel.hasPrefix("\(label),"))
            let renderedWidth = UIHostingController(
                rootView: row.environment(\.dynamicTypeSize, dynamicTypeSize)
                    .fixedSize(horizontal: true, vertical: false)
            ).sizeThatFits(in: CGSize(width: 2_000, height: 200)).width
            #expect(renderedWidth >= 1, "\(label) rendered no measurable row at \(dynamicTypeSize)")
        }
    }
}

// iPad 11" portrait. The pinned Small preference resolves to the largest
// feasible compact-solver count at this width; all 8 providers and all 14
// windows are on screen at once, which is the whole point of Option B.
@MainActor
@Test func densePadPortraitLight() {
    assertSnapshot(
        of: denseDashboard(),
        as: .image(
            layout: .fixed(width: 834, height: 1194),
            traits: densitySnapshotTraits(fixture: .pad, style: .light)),
        record: densitySnapshotRecording,
        testName: "densePadPortraitLight")
}

@MainActor
@Test func densePadPortraitDark() {
    assertSnapshot(
        of: denseDashboard(),
        as: .image(
            layout: .fixed(width: 834, height: 1194),
            traits: densitySnapshotTraits(fixture: .pad, style: .dark)),
        record: densitySnapshotRecording,
        testName: "densePadPortraitDark")
}

// Landscape resolves to a larger feasible compact-solver count than portrait.
// Fixed low-column layouts stretch cards across the full width, which is the
// wasted horizontal space this layout exists to remove.
@MainActor
@Test func densePadLandscapeDark() {
    assertSnapshot(
        of: denseDashboard(),
        as: .image(
            layout: .fixed(width: 1194, height: 834),
            traits: densitySnapshotTraits(fixture: .pad, style: .dark)),
        record: densitySnapshotRecording,
        testName: "densePadLandscapeDark")
}

// MARK: - density (TASKS row 24)

// One baseline per density at the same device size, so the three are directly
// comparable and a metrics edit shows up as a diff on exactly the density it
// touched.
//
// iPad 11" portrait is the deliberate choice: it is where the column count
// actually changes between densities (two at compact and standard, one at
// large, since large's 460pt minimum cannot seat two columns in 802pt of
// content). A device size where all three densities resolved to the same
// column count would hide the layout consequence and record only spacing.
//
// The fixture is `fullProviderSet()` — 8 providers with 1, 2 or 3 windows
// each. The uneven window counts matter: they are what makes the ragged-row
// behavior visible (TASKS row 23), which `.large` makes worse because taller
// cards mean a taller `LazyVGrid` row. These baselines are expected to show
// that, and fixing it is that row's job, not this one's.

// There is deliberately no `.compact` baseline here.
//
// `densePadPortraitLight` above already *is* it: with no override, density
// comes from the stored preference, which defaults to `.compact`. Recording a
// second one produced a byte-identical PNG (verified 2026-08-06,
// sha256 31a41f0a…), and a duplicate baseline cannot fail on its own — both
// copies would move together under any metrics edit, so it would read as
// coverage without adding any. The wiring property it appeared to test —
// that asking for compact explicitly resolves the same as not asking —
// is asserted directly in
// `DensityLayoutTests.explicitCompactResolvesTheSameAsTheDefault`.

@MainActor
@Test func densityStandardPadPortraitLight() {
    assertSnapshot(
        of: denseDashboard(density: .standard),
        as: .image(
            layout: .fixed(width: 834, height: 1194),
            traits: densitySnapshotTraits(fixture: .pad, style: .light)),
        record: densitySnapshotRecording,
        testName: "densityStandardPadPortraitLight")
}

@MainActor
@Test func densityLargePadPortraitLight() {
    assertSnapshot(
        of: denseDashboard(density: .large),
        as: .image(
            layout: .fixed(width: 834, height: 1194),
            traits: densitySnapshotTraits(fixture: .pad, style: .light)),
        record: densitySnapshotRecording,
        testName: "densityLargePadPortraitLight")
}

/// Large density *and* the text-size slider at its top notch — the combination
/// a user who cannot read small type will actually be in, since picking large
/// cards and turning system text up are the same intent expressed twice.
///
/// `.extraExtraExtraLarge` rather than an accessibility size on purpose: it is
/// the ceiling of Settings > Display & Brightness > Text Size, so it is reachable
/// without enabling Larger Text, which makes it the realistic worst case rather
/// than the theoretical one.
///
/// This is the pairing the row's fixed columns are least equipped for. `resetWidth`
/// is 130 points of *fixed* width holding a `.footnote` that Dynamic Type is free
/// to scale past it; `labelWidth` and `percentWidth` have the same shape. The
/// mismatch predates density — every density has it, and so did 1.6.0 — but
/// scaling the fonts up moves it closer to the edge, so it belongs on the record
/// with a picture rather than as a worry. What this baseline shows today is
/// tracked in TASKS; the test's job is that the next change to it is visible.
@MainActor
@Test func densityLargePadPortraitExtraExtraExtraLarge() {
    assertSnapshot(
        of: denseDashboard(density: .large),
        as: .image(
            layout: .fixed(width: 834, height: 1194),
            traits: densitySnapshotTraits(
                fixture: .pad, style: .light, contentSizeCategory: .extraExtraExtraLarge)),
        record: densitySnapshotRecording,
        testName: "densityLargePadPortraitExtraExtraExtraLarge")
}

/// The same text size at `.compact`, which is 1.6.0's shipped geometry.
///
/// This one exists to keep the record straight rather than to cover a new
/// surface: it shows the truncation above is inherited, not introduced. Every
/// density pairs fixed column widths with fonts Dynamic Type is free to scale,
/// and compact — having the least width to give — truncates hardest. Without
/// this picture, the `.large` baseline would read as a cost of the density
/// feature, and the fix would get scoped to the wrong place.
@MainActor
@Test func densityCompactPadPortraitExtraExtraExtraLarge() {
    assertSnapshot(
        of: denseDashboard(density: .compact),
        as: .image(
            layout: .fixed(width: 834, height: 1194),
            traits: densitySnapshotTraits(
                fixture: .pad, style: .light, contentSizeCategory: .extraExtraExtraLarge)),
        record: densitySnapshotRecording,
        testName: "densityCompactPadPortraitExtraExtraExtraLarge")
}

/// Large on a phone, which is the case INV-12 forces to exist: the density
/// control cannot be iPad-only, because a setting present on one size class and
/// absent on the other is precisely the divergence that invariant was written
/// after. An iPad in Slide Over is at compact width too, so "iPad-only" has no
/// coherent rule behind it either.
///
/// The thing to look at here is the reset column's *absence*. It stays dropped
/// at compact width regardless of density, because affording it is a width
/// question — 98 + 50 + 130 of columns would leave the bar nothing on a phone.
@MainActor
@Test func densityLargePhoneDark() {
    assertSnapshot(
        of: DashboardContent(
            viewModel: makeViewModel(), now: fixedNow,
            layout: .denseSingleColumn, density: .large),
        as: .image(
            layout: .fixed(width: 393, height: 852),
            traits: densitySnapshotTraits(fixture: .phone, style: .dark)),
        record: densitySnapshotRecording,
        testName: "densityLargePhoneDark")
}

/// The first Larger Text accessibility rung on the compact phone layout.
/// This is the narrowest dashboard case where the percent column must keep a
/// whole `100%` instead of clipping the final digit.
@MainActor
@Test func densityCompactPhoneAccessibility1() {
    assertSnapshot(
        of: DashboardContent(
            viewModel: makeViewModel(), now: fixedNow,
            layout: .denseSingleColumn, density: .compact),
        as: .image(
            layout: .fixed(width: 393, height: 852),
            traits: densitySnapshotTraits(
                fixture: .phone, style: .light, contentSizeCategory: .accessibilityMedium)),
        record: densitySnapshotRecording,
        testName: "densityCompactPhoneAccessibility1")
}

@MainActor
@Test func densityCompactPhoneAccessibility5() {
    assertSnapshot(
        of: DashboardContent(
            viewModel: makeViewModel(), now: fixedNow,
            layout: .denseSingleColumn, density: .compact),
        as: .image(
            layout: .fixed(width: 393, height: 852),
            traits: densitySnapshotTraits(
                fixture: .phone, style: .light, contentSizeCategory: .accessibilityExtraExtraExtraLarge)),
        record: densitySnapshotRecording,
        testName: "densityCompactPhoneAccessibility5")
}

@MainActor
@Test func densityLargePadPortraitAccessibility1() {
    assertSnapshot(
        of: denseDashboard(density: .large),
        as: .image(
            layout: .fixed(width: 834, height: 1194),
            traits: densitySnapshotTraits(
                fixture: .pad, style: .light, contentSizeCategory: .accessibilityMedium)),
        record: densitySnapshotRecording,
        testName: "densityLargePadPortraitAccessibility1")
}

@MainActor
@Test func densityLargePadPortraitAccessibility5() {
    assertSnapshot(
        of: denseDashboard(density: .large),
        as: .image(
            layout: .fixed(width: 834, height: 1194),
            traits: densitySnapshotTraits(
                fixture: .pad, style: .light, contentSizeCategory: .accessibilityExtraExtraExtraLarge)),
        record: densitySnapshotRecording,
        testName: "densityLargePadPortraitAccessibility5")
}

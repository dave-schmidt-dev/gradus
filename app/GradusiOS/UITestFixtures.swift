import Foundation

/// Deterministic, test-only launch states for the UI suite. The fixture is
/// accepted only through a process environment variable supplied by
/// `XCUIApplication`; it is never persisted by normal launches and never
/// changes a production recovery path.
enum GradusUITestFixture: String {
    static let environmentKey = "GRADUS_UITEST_FIXTURE"
    static let cardColumnsEnvironmentKey = "GRADUS_UITEST_CARD_COLUMNS"

    case freshAccountDiscovery = "fresh-account-discovery"
    case legacyAwaitingConfirmation = "legacy-awaiting-confirmation"
    case temporaryRetry = "temporary-retry"
    case noAccount = "no-account"
    case restricted
    case warningAlertsOff = "warning-alerts-off"
    case warningAlertsRequesting = "warning-alerts-requesting"
    case warningAlertsDenied = "warning-alerts-denied"
    case warningAlertsAllowed = "warning-alerts-allowed"
    case sampleEntryInProgress = "sample-entry-in-progress"

    static var current: Self? {
        ProcessInfo.processInfo.environment[environmentKey].flatMap(Self.init(rawValue:))
    }

    var warningAlertsEnabled: Bool {
        switch self {
        case .warningAlertsRequesting, .warningAlertsDenied, .warningAlertsAllowed:
            true
        default:
            false
        }
    }

    var notificationAuthorization: NotificationAuthorization {
        switch self {
        case .warningAlertsDenied: .denied
        case .warningAlertsAllowed: .authorized
        default: .notDetermined
        }
    }

    var startsWarningAlertRequest: Bool {
        self == .warningAlertsRequesting
    }

    var startsSampleEntryInProgress: Bool {
        self == .sampleEntryInProgress
    }

    @MainActor
    func prepare(defaults: UserDefaults) {
        // Each UI-test process starts from a known app-preference state. This
        // test-only reset prevents a previous fixture from leaking into the
        // next independent workflow; ordinary app launches never enter here.
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleIdentifier)
        }
        defaults.removeObject(forKey: DashboardViewModel.syncEnabledKey)
        defaults.removeObject(forKey: DashboardViewModel.requiredICloudModeKey)
        defaults.removeObject(forKey: DashboardViewModel.requiredICloudModeVersionKey)
        defaults.set(warningAlertsEnabled, forKey: DashboardViewModel.notificationsEnabledKey)

        if self == .legacyAwaitingConfirmation {
            // The migration sees exactly the historical opt-out and converts
            // it into the required-iCloud confirmation state.
            defaults.set(false, forKey: DashboardViewModel.syncEnabledKey)
        }
    }

    @MainActor
    func apply(to viewModel: DashboardViewModel) {
        if let rawColumns = ProcessInfo.processInfo.environment[Self.cardColumnsEnvironmentKey],
           let columns = Int(rawColumns), columns > 1 {
            viewModel.setAvailableCardColumns(columns)
        }
        switch self {
        case .temporaryRetry:
            viewModel.accountAvailabilityCheckFailed()
        case .noAccount:
            viewModel.updateAccountStatus(.noAccount)
        case .restricted:
            viewModel.updateAccountStatus(.restricted)
        default:
            break
        }
    }
}

struct GradusUITestAuthSource: NotificationAuthorizationSource {
    let authorization: NotificationAuthorization

    func currentAuthorization() async -> NotificationAuthorization {
        authorization
    }
}

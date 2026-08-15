/// Serializes live lifecycle work with the local sample transition.
///
/// The epoch invalidates a suspended operation before it can start its next
/// seam call. The active-operation count lets sample entry wait for a call
/// already in flight to return before the sample UI becomes visible.
@MainActor
final class LiveLifecycleGate {
    typealias Epoch = UInt64

    private(set) var isSuspended: Bool
    private var epoch: Epoch = 0
    private var activeOperations = 0
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []

    init(initiallySuspended: Bool = false) {
        isSuspended = initiallySuspended
    }

    var isLive: Bool {
        !isSuspended
    }

    func begin() -> Epoch? {
        guard !isSuspended else { return nil }
        activeOperations += 1
        return epoch
    }

    func finish() {
        guard activeOperations > 0 else { return }
        activeOperations -= 1
        guard activeOperations == 0 else { return }
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func isCurrent(_ operationEpoch: Epoch) -> Bool {
        !isSuspended && operationEpoch == epoch
    }

    func withOperation<T>(_ operation: (Epoch) async -> T) async -> T? {
        guard let operationEpoch = begin() else { return nil }
        defer { finish() }
        return await operation(operationEpoch)
    }

    /// Invalidates new work immediately, then waits for calls that started
    /// before this transition to finish. The caller may safely present local
    /// sample data after this returns.
    func suspend() async {
        if isSuspended {
            guard activeOperations > 0 else { return }
            await withCheckedContinuation { continuation in
                quiescenceWaiters.append(continuation)
            }
            return
        }
        isSuspended = true
        epoch &+= 1
        guard activeOperations > 0 else { return }
        await withCheckedContinuation { continuation in
            quiescenceWaiters.append(continuation)
        }
    }

    func resume() {
        isSuspended = false
        epoch &+= 1
    }
}

enum CloudKitRuntimeConfiguration {
    /// CloudKit is available on a simulator only when that simulator build
    /// carries the container entitlement. The current generated debug
    /// simulator app does not, so its launch must stay on the offline path.
    static func shouldUseCloudKit(isSimulator: Bool, hasCloudKitEntitlement: Bool) -> Bool {
        !isSimulator || hasCloudKitEntitlement
    }

    /// Device/release builds are signed with `GradusiOS.entitlements`; the
    /// generated simulator debug app is intentionally treated as offline.
    static var currentValue: Bool {
        #if targetEnvironment(simulator)
            return shouldUseCloudKit(isSimulator: true, hasCloudKitEntitlement: false)
        #else
            return shouldUseCloudKit(isSimulator: false, hasCloudKitEntitlement: true)
        #endif
    }
}

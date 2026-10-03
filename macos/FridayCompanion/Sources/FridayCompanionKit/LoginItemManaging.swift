import Foundation
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// The configuration boundary P2-M1 establishes for future automatic
/// startup (`docs/PHASE-2-...` P2-M1 §13) — abstracted behind a protocol
/// specifically so tests never touch the real login-item registry
/// (§13: "Tests must not modify the developer machine's permanent login
/// configuration. Use safe/testable abstractions").
public protocol LoginItemManaging: Sendable {
    /// Whether FRIDAY Companion is currently registered to launch at
    /// login.
    func isRegistered() -> Bool
    /// Registers (or unregisters) the login item. Throws if the OS
    /// refuses (e.g., user declined in System Settings).
    func setRegistered(_ enabled: Bool) throws
}

/// The real implementation, backed by `SMAppService` (macOS 13+) — the
/// native mechanism `docs/PHASE-2-ARCHITECTURE.md` §3 specifies, in
/// place of a Terminal-launched developer process.
@available(macOS 13.0, *)
public struct SMAppServiceLoginItemManager: LoginItemManaging {
    public init() {}

    public func isRegistered() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setRegistered(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// A deterministic, in-memory fake — the ONLY `LoginItemManaging`
/// implementation any automated test in this package is permitted to
/// use, per §13's explicit safety constraint.
public final class FakeLoginItemManager: LoginItemManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var registered: Bool
    public var registerError: Error?

    public init(initiallyRegistered: Bool = false) {
        self.registered = initiallyRegistered
    }

    public func isRegistered() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return registered
    }

    public func setRegistered(_ enabled: Bool) throws {
        if let registerError { throw registerError }
        lock.lock()
        registered = enabled
        lock.unlock()
    }
}

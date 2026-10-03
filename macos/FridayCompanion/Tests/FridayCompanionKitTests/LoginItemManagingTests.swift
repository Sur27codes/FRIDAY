import Testing
@testable import FridayCompanionKit

/// Uses ONLY `FakeLoginItemManager` — this test suite must never touch
/// the real macOS login-item registry (`docs/PHASE-2-...` P2-M1 §13:
/// "Tests must not modify the developer machine's permanent login
/// configuration"). There is deliberately no test here that constructs
/// `SMAppServiceLoginItemManager`.
@Suite struct LoginItemManagingTests {

    @Test func fake_defaultsToUnregistered() {
        let manager = FakeLoginItemManager()
        #expect(!manager.isRegistered())
    }

    @Test func fake_setRegistered_roundTrips() throws {
        let manager = FakeLoginItemManager()
        try manager.setRegistered(true)
        #expect(manager.isRegistered())
        try manager.setRegistered(false)
        #expect(!manager.isRegistered())
    }

    @Test func fake_propagatesInjectedError_withoutMutatingState() {
        let manager = FakeLoginItemManager(initiallyRegistered: false)
        manager.registerError = NSErrorStub()
        #expect(throws: (any Error).self) { try manager.setRegistered(true) }
        #expect(!manager.isRegistered(), "a failed registration attempt must not be recorded as successful")
    }
}

private struct NSErrorStub: Error {}

import Foundation

/// P2-M5-FINAL-CLOSURE-R1 §1.2 — the Chatterbox tier's lazy lifecycle
/// wrapper. Wraps any `SpeechSynthesizing` (in production, a
/// `LocalChatterboxSpeechSynthesizer`) with a "make sure the local
/// service is actually running first" step, so that:
///   - NOTHING happens at login (the ~1GB Turbo model is not loaded, the
///     Python service is not started) — this wrapper is completely inert
///     until `speak(...)` is called AND a prior tier has already failed.
///   - the FIRST time the cascade genuinely needs local speech, the
///     service is started on demand (once), the model loads lazily
///     inside it on that first request, and synthesis proceeds.
///   - if the service cannot be started (no venv, no Python, no script —
///     e.g. a machine where the local voice was never set up), this
///     wrapper throws `NotAvailableError` and the cascade advances to
///     Samantha, exactly as if the socket had simply been absent.
///
/// Model unloading is deliberately NOT implemented here: the current
/// `chatterbox_service.py` exposes no safe unload API (it keeps a loaded
/// model warm for its own process lifetime). Inventing one is out of
/// scope — this is reported as a known limitation, not silently worked
/// around. The only lifecycle guarantee made is "no eager load."
public final class LazyLocalVoiceTier: SpeechSynthesizing, @unchecked Sendable {
    public struct NotAvailableError: Error, CustomStringConvertible {
        public let reason: String
        public var description: String { "LazyLocalVoiceTier: local voice service unavailable — \(reason)" }
    }

    private let underlying: SpeechSynthesizing
    private let socketPath: String
    private let socketExists: @Sendable (String) -> Bool
    /// Best-effort: start the local service and return true once its
    /// socket is reachable, false if it could not be started. Bounded —
    /// must not block indefinitely. Injected so tests never spawn a
    /// real process.
    private let ensureServiceRunning: @Sendable () -> Bool

    private let lock = NSLock()
    private var startAttempted = false

    public var engineIdentifier: String { "lazy(\(underlying.engineIdentifier))" }

    public init(
        underlying: SpeechSynthesizing,
        socketPath: String,
        socketExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        ensureServiceRunning: @escaping @Sendable () -> Bool
    ) {
        self.underlying = underlying
        self.socketPath = socketPath
        self.socketExists = socketExists
        self.ensureServiceRunning = ensureServiceRunning
    }

    public func speak(_ text: String, category: SpeechResponseCategory, onFinished: @escaping @Sendable (SpeechSynthesisOutcome) -> Void) throws {
        if !socketExists(socketPath) {
            lock.lock()
            let alreadyTried = startAttempted
            startAttempted = true
            lock.unlock()
            // Only ONE start attempt per process lifetime — a machine
            // that can't run the local service shouldn't re-spawn on
            // every fallback.
            if alreadyTried && !socketExists(socketPath) {
                throw NotAvailableError(reason: "service was already attempted and is still not reachable")
            }
            guard ensureServiceRunning(), socketExists(socketPath) else {
                throw NotAvailableError(reason: "local Chatterbox service could not be started (venv/Python/script missing, or start timed out)")
            }
        }
        try underlying.speak(text, category: category, onFinished: onFinished)
    }

    public func stop() {
        underlying.stop()
    }
}

/// Spawns `chatterbox_service.py` from the repository's own
/// `.venv-chatterbox` and waits (bounded) for its socket. Returns a
/// closure suitable for `LazyLocalVoiceTier.ensureServiceRunning`.
/// Resolves the service directory from, in order: an explicit
/// `serviceDirectoryOverride`, `$FRIDAY_CHATTERBOX_SERVICE_DIR`, or a
/// bundled `Contents/Resources/chatterbox-speech` directory. If none
/// resolves, the returned closure always returns false (→ Samantha).
public func makeChatterboxServiceLauncher(
    socketPath: String,
    serviceDirectoryOverride: String? = nil,
    startupTimeout: TimeInterval = 25,
    socketExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> @Sendable () -> Bool {
    let resolvedDir: String? = {
        if let serviceDirectoryOverride { return serviceDirectoryOverride }
        if let env = ProcessInfo.processInfo.environment["FRIDAY_CHATTERBOX_SERVICE_DIR"] { return env }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("chatterbox-speech").path,
           FileManager.default.fileExists(atPath: bundled) { return bundled }
        return nil
    }()

    return { @Sendable in
        guard let dir = resolvedDir else { return false }
        let serviceDir = URL(fileURLWithPath: dir)
        let script = serviceDir.appendingPathComponent("chatterbox_service.py")
        // The venv lives one level above the service dir in the repo
        // layout (repo-root/.venv-chatterbox, repo-root/services/chatterbox-speech).
        let venvPython = serviceDir.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".venv-chatterbox/bin/python3")
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: venvPython.path), fm.fileExists(atPath: script.path) else { return false }

        let process = Process()
        process.executableURL = venvPython
        process.arguments = [script.path, socketPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }

        let deadline = Date().addingTimeInterval(startupTimeout)
        while Date() < deadline {
            if socketExists(socketPath) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return socketExists(socketPath)
    }
}

import Foundation
import Testing

/// Shared real-`go build` helper for every integration test suite in
/// this package (`SupervisorIntegrationTests`, `RuntimeClientIntegrationTests`)
/// — extracted so the deadlock-safe pipe-draining fix (see P2-M1's
/// disclosed bug: draining stderr before `waitUntilExit()`, not after)
/// exists in exactly one place, not copy-pasted per suite.
enum GoBinaryBuilder {
    /// Walks up from this source file to the repository root
    /// (`macos/FridayCompanion/Tests/FridayCompanionKitTests/<file>.swift`
    /// -> repo root), where `services/` lives directly underneath.
    static func repoRoot(fromFile file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // (filename) -> FridayCompanionKitTests
            .deletingLastPathComponent() // FridayCompanionKitTests -> Tests
            .deletingLastPathComponent() // Tests -> FridayCompanion
            .deletingLastPathComponent() // FridayCompanion -> macos
            .deletingLastPathComponent() // macos -> FRIDAY (repo root)
    }

    static func build(moduleDir: URL, packagePath: String, output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["go", "build", "-o", output.path, packagePath]
        process.currentDirectoryURL = moduleDir
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        // MUST drain before waiting — see P2-M1's disclosed 45-minute
        // Process/Pipe deadlock fix in the traceability record for why.
        let errData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errOutput = String(data: errData, encoding: .utf8) ?? ""
            Issue.record("go build failed for \(packagePath): \(errOutput)")
        }
    }
}

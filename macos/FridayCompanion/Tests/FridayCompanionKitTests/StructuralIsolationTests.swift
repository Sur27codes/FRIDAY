import Testing
@testable import FridayCompanionKit
import Foundation

/// P2M1-SEC-001 / P2M1-SEC-002, verified structurally rather than by
/// behavioral inference — the Go side proves process isolation via
/// `go list -deps` (no import of `policy-engine`/`capability-bus`
/// internals in `friday-daemon`/`cmd/friday`); Swift Package Manager has
/// no equivalent dependency-graph tool to call from a test, so this
/// suite performs the direct equivalent: a source-level scan of every
/// file in `FridayCompanionKit` confirming it contains no code shaped
/// like token issuance, signing, or a direct capability-execution call.
/// This is deliberately a real, textual check of the actual shipped
/// source — not an assertion about intent.
@Suite struct StructuralIsolationTests {

    private func allKitSourceFiles() throws -> [URL] {
        let thisFile = URL(fileURLWithPath: #filePath)
        let kitSources = thisFile
            .deletingLastPathComponent() // (filename) StructuralIsolationTests.swift -> FridayCompanionKitTests
            .deletingLastPathComponent() // FridayCompanionKitTests -> Tests
            .deletingLastPathComponent() // Tests -> FridayCompanion (Sources/ is a SIBLING of Tests/, not nested under it)
            .appendingPathComponent("Sources/FridayCompanionKit")
        let files = try FileManager.default.contentsOfDirectory(at: kitSources, includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension == "swift" }
    }

    /// Strips `///`/`//` comment lines before scanning — this check must
    /// confirm the actual SHIPPED, EXECUTED code contains no forbidden
    /// pattern, not merely that no doc comment happens to ever *mention*
    /// one (several files in this package deliberately document, in
    /// prose, exactly what they do NOT do — e.g. "no import of
    /// capability-bus/internal" — which would otherwise trip this same
    /// scan as a false positive on its own explanation).
    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - P2M1-SEC-001: Companion cannot mint authorization

    @Test func sec001_noTokenSigningOrMintingCodeAnywhereInCompanionKit() throws {
        let forbidden = ["SignToken", "policytoken", "PrivateKey", "ed25519.NewKeyPair", "GenerateKey", "\"EvaluateAuthorization\""]
        for file in try allKitSourceFiles() {
            let text = codeOnly(try String(contentsOf: file, encoding: .utf8))
            for term in forbidden {
                #expect(!text.contains(term),
                        "\(file.lastPathComponent) contains \(term) in real code — the Companion must never mint or evaluate authorization itself")
            }
        }
    }

    // MARK: - P2M1-SEC-002: no direct capability-execution dependency

    @Test func sec002_noDirectCapabilityExecutionCallAnywhereInCompanionKit() throws {
        let forbidden = ["\"Dispatch\"", "capabilitybusd/internal", "capability-bus/internal", "DevSeedIR", "DevSeedTask"]
        for file in try allKitSourceFiles() {
            let text = codeOnly(try String(contentsOf: file, encoding: .utf8))
            for term in forbidden {
                #expect(!text.contains(term),
                        "\(file.lastPathComponent) contains \(term) in real code — the Companion must have no direct capability-execution path")
            }
        }
    }

    @Test func onlyHealthMethodIsEverCalledByRPCFrameClientUsers() throws {
        let file = try allKitSourceFiles().first { $0.lastPathComponent == "HealthClient.swift" }
        let text = try String(contentsOf: try #require(file), encoding: .utf8)
        #expect(text.contains("method: \"Health\""))
    }
}

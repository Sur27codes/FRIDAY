// swift-tools-version: 5.10
// P2-M1 — macOS Companion & Supervisor Foundation.
//
// Split into a library target (FridayCompanionKit — all supervision/
// lifecycle/health-check logic, fully unit- and integration-testable via
// `swift test`, no AppKit dependency) and a thin executable target
// (FridayCompanion — the actual menu-bar app shell, which only wires
// FridayCompanionKit to AppKit). This mirrors the same "keep the tested
// logic separate from the untestable shell" discipline the Go side
// already uses (orchestrator vs. cmd/friday).
//
// P2-M3C adds `CSherpaOnnx`, a systemLibrary target binding the
// vendored, prebuilt sherpa-onnx C API dylibs under
// `Vendor/sherpa-onnx/lib` (see that directory's THIRD_PARTY_NOTICES.md)
// so `SherpaOnnxWakeWordDetector` can implement the real "Hey Friday"
// wake-word path. The library path is resolved from this manifest's own
// location via `#filePath` so the build works regardless of where the
// repo is checked out; this is local-dev linking (absolute rpath into
// the checkout), not yet real .app-bundle packaging — see
// docs/W-adr-backlog.md ADR-007 for the disclosed follow-up.
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let sherpaLibDir = packageDir.appendingPathComponent("Vendor/sherpa-onnx/lib").path

// P2-PROD-BOOTSTRAP-R2 §3.3 — a real installed FRIDAY.app must NOT depend
// on the development checkout staying at a fixed absolute path. Two
// rpaths are baked in, tried by dyld in order:
//   1. `@executable_path/../Resources/sherpa-onnx-lib` — where
//      `Scripts/build-and-install-app.sh` places the vendored dylibs
//      inside the .app bundle (`Contents/MacOS/` -> `../Resources/...`).
//      This is the ONLY path the installed product uses.
//   2. the absolute dev `Vendor/sherpa-onnx/lib` — for `swift run` /
//      `swift test` binaries under `.build/`, which have no sibling
//      `../Resources/sherpa-onnx-lib`, so dyld falls through to this.
// `-L` still points at the dev dir purely for LINK-time symbol
// resolution (it does not affect runtime lookup).
let bundledSherpaRPath = "@executable_path/../Resources/sherpa-onnx-lib"

let sherpaLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L", sherpaLibDir,
        "-Xlinker", "-rpath", "-Xlinker", bundledSherpaRPath,
        "-Xlinker", "-rpath", "-Xlinker", sherpaLibDir,
    ])
]

// P2-M4: `SFSpeechRecognizer.requestAuthorization` (and, per Apple's TCC
// enforcement, `AVCaptureDevice.requestAccess` for a fresh, not-yet-decided
// microphone grant) require the calling process to declare
// `NSSpeechRecognitionUsageDescription`/`NSMicrophoneUsageDescription` in an
// Info.plist — without one, TCC does not show a normal denial, it
// terminates the process (confirmed directly in this environment: a bare
// `swift` ad hoc script requesting speech-recognition authorization
// crashes with `TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION`). A plain SwiftPM
// `.executableTarget` produces a Mach-O binary with no bundle/Info.plist
// by default, so one is embedded directly into the binary via the
// standard `__TEXT,__info_plist` section technique (no Xcode project
// needed) — real, working, and the correct fix for exactly this failure
// mode, not a workaround.
let companionPlistPath = packageDir.appendingPathComponent("Sources/FridayCompanion/Info.plist").path
let companionInfoPlistLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", companionPlistPath])
]

let package = Package(
    name: "FridayCompanion",
    platforms: [.macOS(.v13)], // SMAppService requires macOS 13+
    targets: [
        .systemLibrary(name: "CSherpaOnnx"),
        .target(
            name: "FridayCompanionKit",
            dependencies: ["CSherpaOnnx"],
            resources: [.copy("Resources/sherpa-onnx-kws-model")]
        ),
        .executableTarget(
            name: "FridayCompanion",
            dependencies: ["FridayCompanionKit"],
            exclude: ["Info.plist"], // embedded directly via linker flags below, not SwiftPM's resource pipeline
            linkerSettings: sherpaLinkerSettings + companionInfoPlistLinkerSettings
        ),
        // P2-M3C evaluation-only tool (not shipped, not part of the
        // Companion app): drives the real `SherpaOnnxWakeWordDetector`
        // against on-disk WAV fixtures to produce actual false-accept/
        // false-reject and latency measurements — see
        // docs/E-traceability-matrix.md's P2-M3C section for results.
        .executableTarget(
            name: "WakeEvalTool",
            dependencies: ["FridayCompanionKit"],
            linkerSettings: sherpaLinkerSettings + companionInfoPlistLinkerSettings
        ),
        // P2-M5V developer-only voice-audition tool (not shipped, not
        // part of the Companion app, no runtime/security behavior of
        // its own): enumerates real installed `AVSpeechSynthesisVoice`s
        // and speaks a fixed evaluation script through each tasteful
        // candidate under a few prosody profiles, so the OWNER can
        // listen and choose — see docs/E-traceability-matrix.md's
        // P2-M5V section. Needs no sherpa-onnx/Info.plist linker
        // settings: it only uses `AVSpeechSynthesizer`, which (unlike
        // microphone/speech-recognition access) requires no TCC
        // authorization at all.
        .executableTarget(
            name: "VoiceAuditionTool",
            dependencies: ["FridayCompanionKit"],
            // This tool itself never calls into sherpa-onnx (it only
            // speaks TTS) — but it links `FridayCompanionKit` whole,
            // which DOES contain `SherpaOnnxWakeWordDetector`'s
            // compiled references to the vendored C API, so the final
            // executable still needs the same library search path to
            // resolve those symbols at link time (the same reason
            // `WakeEvalTool` below needs it despite mostly exercising
            // STT, not wake detection).
            linkerSettings: sherpaLinkerSettings
        ),
        .testTarget(
            name: "FridayCompanionKitTests",
            dependencies: ["FridayCompanionKit"],
            resources: [.copy("Resources/wake-eval")],
            linkerSettings: sherpaLinkerSettings + companionInfoPlistLinkerSettings
        ),
    ]
)

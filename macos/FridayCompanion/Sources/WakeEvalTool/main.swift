import FridayCompanionKit
import Foundation

// P2-M4 §5 research: does requesting Speech-Recognition authorization
// from THIS properly-Info.plist-embedded binary avoid the
// TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION crash observed from a bare `swift
// script.swift` (which has no Info.plist at all)? Real evidence either
// way is recorded in docs/E-traceability-matrix.md's P2-M4 section.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "speechauth" {
    let permission = RealSpeechRecognitionPermission()
    print("authorizationStatus before request: \(permission.currentStatus())")
    let result = await permission.requestAccess()
    print("requestAuthorization returned: \(result)")
    exit(0)
}

/// Plain, lock-protected result holder — isolates the blocking
/// `DispatchSemaphore.wait` and the cross-thread mutation into ordinary
/// synchronous methods, the same "extract a synchronous helper" pattern
/// `FakeMicrophonePermission.resolveRequestSynchronously()` already uses
/// to satisfy Swift's newer concurrency checking around blocking calls
/// and closure captures made from an async context.
final class STTResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private let sem = DispatchSemaphore(value: 0)
    private(set) var outcome: SpeechTranscriptionOutcome?

    func deliver(_ result: SpeechTranscriptionOutcome) {
        lock.lock(); outcome = result; lock.unlock()
        sem.signal()
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        sem.wait(timeout: timeout)
    }
}

// P2-M4 §21: real STT evaluation mode. Feeds real WAV fixtures through
// the real, production `AppleSpeechTranscriber` and reports the actual
// transcript/latency for each — no hidden marker injection, no scripted
// results. Requires real Speech-Recognition authorization; in this
// coding environment that authorization crashes when freshly requested
// from a non-`.app`-bundled binary (see docs/E-traceability-matrix.md's
// P2-M4 section for the full, disclosed evidence) — this mode still
// checks status first and reports clearly rather than assuming success,
// since the owner's own Mac may behave differently.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "stteval" {
    let permission = RealSpeechRecognitionPermission()
    let status = permission.currentStatus()
    print("Speech recognition authorization status: \(status)")
    if status != .authorized {
        print("Not authorized — real STT evaluation cannot proceed. On a normal Mac, granting this the first time")
        print("shows a system permission prompt; in this coding environment requesting it crashes the process")
        print("(TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION) even from this properly Info.plist-embedded binary — a real,")
        print("disclosed finding, not assumed. Run this on the owner's own Mac to get a real result.")
        exit(1)
    }

    guard CommandLine.arguments.count >= 3 else {
        print("usage: WakeEvalTool stteval <fixtures-root-dir>")
        exit(1)
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[2])
    let commandsDir = root.appendingPathComponent("commands")
    let files = try FileManager.default.contentsOfDirectory(at: commandsDir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

    for file in files {
        let (samples, sampleRate) = try WakeAudioFixture.loadMonoInt16PCM(from: file)
        let padded = samples + [Int16](repeating: 0, count: Int(sampleRate * 2)) // trailing silence so the endpointer finalizes
        let transcriber = AppleSpeechTranscriber()
        let box = STTResultBox()
        let start = DispatchTime.now()
        do {
            try transcriber.startSession(onResult: { result in box.deliver(result) })
        } catch {
            print("\(file.lastPathComponent): FAILED TO START — \(error)")
            continue
        }
        let frameSize = 1024
        var offset = 0
        while offset < padded.count {
            let end = min(offset + frameSize, padded.count)
            transcriber.append(AudioFrame(samples: Array(padded[offset..<end]), sampleRate: sampleRate, channelCount: 1))
            offset = end
        }
        let waitResult = box.wait(timeout: .now() + 15)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        if waitResult == .timedOut {
            print("\(file.lastPathComponent): TIMED OUT waiting for a result (\(Int(elapsedMs))ms)")
            transcriber.cancelSession()
        } else {
            switch box.outcome {
            case .finalized(let text): print("\(file.lastPathComponent): \"\(text)\" (\(Int(elapsedMs))ms)")
            case .failed(let reason): print("\(file.lastPathComponent): FAILED — \(reason) (\(Int(elapsedMs))ms)")
            case .none: print("\(file.lastPathComponent): no outcome")
            }
        }
    }
    exit(0)
}

/// P2-M3C evaluation harness — NOT part of the shipped Companion app.
/// Feeds real WAV fixtures through the real `SherpaOnnxWakeWordDetector`
/// (the same type `AppDelegate` wires up as the default detector) and
/// prints actual false-accept/false-reject counts and per-trigger
/// latency. No hidden marker injection anywhere in this file — trigger
/// decisions come only from the detector's own `WakeEvent?` return
/// value, exactly as `WakeCoordinator` consumes it in production.
/// WAV loading and frame-feeding are shared with
/// `SherpaOnnxWakeWordDetectorTests` via `WakeAudioFixture`.

struct TrialResult {
    let name: String
    let expectedPositive: Bool
    let triggered: Bool
    let computeLatencyMs: Double?
    /// Milliseconds of *audio* (not wall-clock compute time) consumed
    /// before the trigger fired, counted from the start of the
    /// utterance's own audio (including the trailing-silence padding
    /// `WakeAudioFixture.runDetection` adds). This is the number that
    /// maps to perceived real-mic latency, since live frames arrive at
    /// real-time cadence (~64ms per 1024-sample frame @16kHz) —
    /// `computeLatencyMs` instead reflects raw CPU decode cost from
    /// feeding frames back-to-back as fast as possible, a different
    /// (much smaller) number.
    let audioLatencyMs: Double?
}

func runTrial(_ url: URL, expectedPositive: Bool, config: SherpaOnnxWakeWordConfig) throws -> TrialResult {
    let (samples, sampleRate) = try WakeAudioFixture.loadMonoInt16PCM(from: url)
    let detector = SherpaOnnxWakeWordDetector(config: config)
    let startClock = DispatchTime.now()
    let result = try WakeAudioFixture.runDetection(samples: samples, sampleRate: sampleRate, detector: detector)
    let computeLatencyMs = result.triggered
        ? Double(DispatchTime.now().uptimeNanoseconds - startClock.uptimeNanoseconds) / 1_000_000.0
        : nil
    return TrialResult(
        name: url.lastPathComponent, expectedPositive: expectedPositive, triggered: result.triggered,
        computeLatencyMs: computeLatencyMs, audioLatencyMs: result.audioMsAtTrigger
    )
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return .nan }
    let idx = min(sorted.count - 1, Int(Double(sorted.count - 1) * p))
    return sorted[idx]
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: WakeEvalTool <fixtures-root-dir> [keywords_score] [keywords_threshold] [max_active_paths]")
    print("       WakeEvalTool soak <seconds>        -- P2-M3C §17 CPU/memory soak: one persistent")
    print("                                             detector fed real-time-paced silence frames,")
    print("                                             wrap this invocation in /usr/bin/time -l")
    print("       WakeEvalTool livecapture <seconds> -- P2-M3D §4: real AVAudioEngine capture through")
    print("                                             the actual production RealAudioCaptureEngine,")
    print("                                             printing WakeDiagnosticsSnapshot lines so real")
    print("                                             callback/RMS evidence can be observed directly")
    exit(1)
}

// P2-M3D §4/§11: prove real AVAudioEngine callbacks arrive through the
// exact production `RealAudioCaptureEngine`, independent of the sherpa
// detector entirely — isolates capture-boundary evidence from
// detector-boundary evidence. Prints only counts/levels/format info,
// never raw audio (§3).
if args[1] == "livecapture" {
    let seconds = args.count >= 3 ? (Double(args[2]) ?? 10) : 10
    let diagnostics = WakeDiagnosticsRecorder()
    let capture = RealAudioCaptureEngine(diagnostics: diagnostics)
    let independentCallbackCounter = WakeDiagnosticsRecorder()
    try capture.start(onFrame: { _ in independentCallbackCounter.recordAudioCallback(sampleCount: 0, rms: 0, peak: 0) })
    let deadline = Date().addingTimeInterval(seconds)
    var lastPrint = Date.distantPast
    while Date() < deadline {
        if Date().timeIntervalSince(lastPrint) >= 1.0 {
            print(WakeDiagnosticsFormatter.render(diagnostics.snapshot()))
            print("---")
            lastPrint = Date()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    capture.stop()
    let finalSnapshot = diagnostics.snapshot()
    print("FINAL: \(WakeDiagnosticsFormatter.render(finalSnapshot))")
    print("onFrame callback invocations (measured independently of the RealAudioCaptureEngine's own recorder): \(independentCallbackCounter.snapshot().audioCallbackCount)")
    exit(0)
}

// P2-M3D §16: the exact real production chain — real `RealAudioCaptureEngine`,
// real `SherpaOnnxWakeWordDetector`, real `WakeCoordinator`, real
// `RealMicrophonePermission` — with no fakes anywhere. Proves E (frames
// forwarded to sherpa), F (sherpa accepts them without crashing), and H
// (WakeCoordinator would receive a WakeEvent, if one fires) end to end.
// This run alone does NOT prove phrase detection unless a person actually
// says "Hey Friday" while it runs — that remains the owner's own retest.
if args[1] == "fullchain" {
    let seconds = args.count >= 3 ? (Double(args[2]) ?? 10) : 10
    let diagnostics = WakeDiagnosticsRecorder()
    let sherpaConfig = try SherpaOnnxWakeWordConfig.bundledDefault()
    let detector = SherpaOnnxWakeWordDetector(config: sherpaConfig, diagnostics: diagnostics)
    let capture = RealAudioCaptureEngine(diagnostics: diagnostics)
    let permission = RealMicrophonePermission()
    let coordinator = WakeCoordinator(capture: capture, detector: detector, permission: permission, diagnostics: diagnostics)

    final class EventBox: @unchecked Sendable {
        let lock = NSLock()
        var events: [String] = []
        func add(_ s: String) { lock.lock(); events.append(s); lock.unlock() }
    }
    let box = EventBox()
    await coordinator.onWakeEvent { event in box.add("\(event.eventID) phrase=\(event.phraseID) at=\(event.detectedAt)") }
    await coordinator.enable()

    print("Say \"Hey Friday\" now if you want to test detection during this \(Int(seconds))s window.")
    let deadline = Date().addingTimeInterval(seconds)
    var lastPrint = Date.distantPast
    while Date() < deadline {
        if Date().timeIntervalSince(lastPrint) >= 1.0 {
            print(WakeDiagnosticsFormatter.render(diagnostics.snapshot()))
            print("Coordinator state: \(await coordinator.state)")
            print("---")
            lastPrint = Date()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    await coordinator.disable()
    print("FINAL: \(WakeDiagnosticsFormatter.render(diagnostics.snapshot()))")
    print("Wake events received by WakeCoordinator's own handler: \(box.events)")
    exit(0)
}

// P2-M3C §17: CPU/memory measurement mode. Mirrors exactly what
// `WakeCoordinator` does during real WAKE_ONLY listening — one
// `start()`, then `process()` once per real-time-paced 1024-sample
// frame (64ms @16kHz, the same frame size `RealAudioCaptureEngine`
// uses), then `stop()`. Feeds silence (no positive fixture should ever
// fire during a soak run — if one does, that's a real bug, not
// something to hide). Run this under `/usr/bin/time -l` to capture peak
// RSS and CPU seconds; see docs/E-traceability-matrix.md's P2-M3C
// section for the actual recorded numbers.
if args[1] == "soak" {
    let seconds = args.count >= 3 ? (Double(args[2]) ?? 30) : 30
    let config = try SherpaOnnxWakeWordConfig.bundledDefault()
    let detector = SherpaOnnxWakeWordDetector(config: config)
    try detector.start()
    let frame = AudioFrame(samples: [Int16](repeating: 0, count: 1024), sampleRate: 16000, channelCount: 1)
    let frameInterval = 1024.0 / 16000.0
    let deadline = Date().addingTimeInterval(seconds)
    var framesProcessed = 0
    var unexpectedTriggers = 0
    while Date() < deadline {
        let stamped = AudioFrame(samples: frame.samples, sampleRate: frame.sampleRate, channelCount: 1, capturedAt: Date())
        if detector.process(stamped, sessionID: "soak") != nil { unexpectedTriggers += 1 }
        framesProcessed += 1
        try? await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
    }
    detector.stop()
    print("soak complete: \(framesProcessed) frames over \(seconds)s, unexpected triggers on silence: \(unexpectedTriggers)")
    exit(0)
}

let root = URL(fileURLWithPath: args[1])
let positiveDir = root.appendingPathComponent("positive")
let negativeDir = root.appendingPathComponent("negative")

var config = try SherpaOnnxWakeWordConfig.bundledDefault()
if args.count >= 4, let score = Float(args[2]), let threshold = Float(args[3]) {
    let maxActivePaths = args.count >= 5 ? (Int32(args[4]) ?? config.maxActivePaths) : config.maxActivePaths
    config = SherpaOnnxWakeWordConfig(
        encoderPath: config.encoderPath, decoderPath: config.decoderPath, joinerPath: config.joinerPath,
        tokensPath: config.tokensPath, keywordTokens: config.keywordTokens, phraseID: config.phraseID,
        numThreads: config.numThreads, keywordsScore: score, keywordsThreshold: threshold,
        sampleRate: config.sampleRate, featureDim: config.featureDim, maxActivePaths: maxActivePaths
    )
}
print("config: keywords_score=\(config.keywordsScore) keywords_threshold=\(config.keywordsThreshold) max_active_paths=\(config.maxActivePaths)")

let fm = FileManager.default
let positiveFiles = try fm.contentsOfDirectory(at: positiveDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
let negativeFiles = try fm.contentsOfDirectory(at: negativeDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

var results: [TrialResult] = []
for f in positiveFiles { results.append(try runTrial(f, expectedPositive: true, config: config)) }
for f in negativeFiles { results.append(try runTrial(f, expectedPositive: false, config: config)) }

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

print("==== P2-M3C sherpa-onnx wake detector evaluation ====")
print(pad("file", 45) + pad("expected", 10) + pad("actual", 10) + pad("audio_ms", 10) + "compute_ms")
for r in results {
    let expected = r.expectedPositive ? "WAKE" : "no-wake"
    let actual = r.triggered ? "WAKE" : "no-wake"
    let audioLat = r.audioLatencyMs.map { String(format: "%.1f", $0) } ?? "-"
    let computeLat = r.computeLatencyMs.map { String(format: "%.1f", $0) } ?? "-"
    print(pad(r.name, 45) + pad(expected, 10) + pad(actual, 10) + pad(audioLat, 10) + computeLat)
}

let truePositives = results.filter { $0.expectedPositive && $0.triggered }
let falseRejects = results.filter { $0.expectedPositive && !$0.triggered }
let trueNegatives = results.filter { !$0.expectedPositive && !$0.triggered }
let falseAccepts = results.filter { !$0.expectedPositive && $0.triggered }

print("")
print("==== Summary ====")
print("positive fixtures: \(positiveFiles.count), negative fixtures: \(negativeFiles.count)")
print("true positives: \(truePositives.count) / \(positiveFiles.count)")
print("false rejects:  \(falseRejects.count) / \(positiveFiles.count) -> \(falseRejects.map { $0.name })")
print("true negatives: \(trueNegatives.count) / \(negativeFiles.count)")
print("false accepts:  \(falseAccepts.count) / \(negativeFiles.count) -> \(falseAccepts.map { $0.name })")

func report(_ label: String, _ values: [Double]) {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return }
    let median = percentile(sorted, 0.5)
    let p95 = percentile(sorted, 0.95)
    let maxLat = sorted.max() ?? .nan
    print(String(format: "%@: median=%.1f p95=%.1f max=%.1f n=%d", label, median, p95, maxLat, sorted.count))
}

print("")
print("==== Latency (true positives only) ====")
report("audio-time-to-trigger (ms, maps to real-mic latency)", truePositives.compactMap { $0.audioLatencyMs })
report("raw compute latency (ms, back-to-back frame feed, not real-time paced)", truePositives.compactMap { $0.computeLatencyMs })

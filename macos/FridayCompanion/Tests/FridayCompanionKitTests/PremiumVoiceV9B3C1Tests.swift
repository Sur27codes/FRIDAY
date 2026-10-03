import Testing
@testable import FridayCompanionKit
import Foundation

/// P2-M5V9-B.3C.1 — REST-A reliability-fix regression coverage. Targets
/// ONLY the new, testable pieces added to close the extended parity
/// harness's silent-failure gap: `CartesiaRESTFetchDiagnostics`, the
/// `sendWithDiagnostics` protocol requirement + default extension, and
/// `CartesiaRESTReferenceClient.fetchReferenceWithDiagnostics`. The
/// harness's own fail-closed/retry/pacing/file-verification orchestration
/// lives as private free functions inside the `VoiceAuditionTool`
/// executable's `main.swift` (no test target exists for it, matching the
/// established precedent set by `chatterbox-audible-audition` and
/// `friday-voice-ab`, which also compose already-tested primitives
/// without their own dedicated unit tests) — that behavior is instead
/// verified by direct smoke-test evidence in the mission report.
@Suite struct PremiumVoiceV9B3C1Tests {
    private func makeRequest() -> (text: String, modelID: String, voiceID: String, apiKey: String, apiVersion: String?, locale: String?) {
        ("Hi, thanks for calling Cartesia. How can I help you today?", "sonic-3.6", "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4", "dummy-key", "2026-08-14", "en-US")
    }

    // MARK: - Default extension (conformers implementing only `send`)

    @Test func sendWithDiagnostics_defaultExtension_forwardsSuccessAndComputesByteCount_whenOnlySendIsImplemented() {
        final class SendOnlyFake: CartesiaRESTRequesting, @unchecked Sendable {
            func send(requestBody: Data, endpoint: URL, apiKey: String, apiVersion: String?, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
                completion(.success(Data(repeating: 0x2A, count: 17)))
            }
        }
        let fake = SendOnlyFake()
        var capturedResult: Result<Data, Error>?
        var capturedDiagnostics: CartesiaRESTFetchDiagnostics?
        fake.sendWithDiagnostics(requestBody: Data(), endpoint: URL(string: "https://api.cartesia.ai/tts/bytes")!, apiKey: "k", apiVersion: nil) { result, diagnostics in
            capturedResult = result
            capturedDiagnostics = diagnostics
        }
        guard case .success(let data) = capturedResult else { Issue.record("expected success"); return }
        #expect(data.count == 17)
        #expect(capturedDiagnostics?.byteCount == 17, "byte count must be derivable even from a fake that only implements the older `send`")
        #expect(capturedDiagnostics?.httpStatus == nil, "a plain fake with no HTTP layer must report no HTTP metadata, never a fabricated status")
        #expect(capturedDiagnostics?.contentType == nil)
        #expect(capturedDiagnostics?.retryAfterSeconds == nil)
    }

    @Test func sendWithDiagnostics_defaultExtension_reportsZeroByteCount_onFailure() {
        final class FailingFake: CartesiaRESTRequesting, @unchecked Sendable {
            func send(requestBody: Data, endpoint: URL, apiKey: String, apiVersion: String?, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
                completion(.failure(NSError(domain: "CartesiaREST", code: 500, userInfo: nil)))
            }
        }
        let fake = FailingFake()
        var capturedDiagnostics: CartesiaRESTFetchDiagnostics?
        var failed = false
        fake.sendWithDiagnostics(requestBody: Data(), endpoint: URL(string: "https://api.cartesia.ai/tts/bytes")!, apiKey: "k", apiVersion: nil) { result, diagnostics in
            if case .failure = result { failed = true }
            capturedDiagnostics = diagnostics
        }
        #expect(failed)
        #expect(capturedDiagnostics?.byteCount == 0)
    }

    // MARK: - `fetchReferenceWithDiagnostics` propagation

    @Test func fetchReferenceWithDiagnostics_success_propagatesActualDataUnaltered() {
        final class CapturingRequester: CartesiaRESTRequesting, @unchecked Sendable {
            func send(requestBody: Data, endpoint: URL, apiKey: String, apiVersion: String?, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
                Issue.record("fetchReferenceWithDiagnostics must call sendWithDiagnostics, never the plain send")
            }
            func sendWithDiagnostics(requestBody: Data, endpoint: URL, apiKey: String, apiVersion: String?, completion: @escaping @Sendable (Result<Data, Error>, CartesiaRESTFetchDiagnostics) -> Void) {
                completion(.success(Data([1, 2, 3, 4])), CartesiaRESTFetchDiagnostics(httpStatus: 200, contentType: "audio/wav", retryAfterSeconds: nil, byteCount: 4))
            }
        }
        let client = CartesiaRESTReferenceClient(requester: CapturingRequester())
        let fixture = makeRequest()
        var capturedResult: Result<Data, Error>?
        var capturedDiagnostics: CartesiaRESTFetchDiagnostics?
        client.fetchReferenceWithDiagnostics(text: fixture.text, modelID: fixture.modelID, voiceID: fixture.voiceID, apiKey: fixture.apiKey, apiVersion: fixture.apiVersion, locale: fixture.locale, sampleRate: 44100, encoding: "pcm_s16le", container: "wav") { result, diagnostics in
            capturedResult = result
            capturedDiagnostics = diagnostics
        }
        guard case .success(let data) = capturedResult else { Issue.record("expected success"); return }
        #expect(data == Data([1, 2, 3, 4]))
        #expect(capturedDiagnostics?.httpStatus == 200)
        #expect(capturedDiagnostics?.contentType == "audio/wav")
        #expect(capturedDiagnostics?.byteCount == 4)
    }

    @Test func fetchReferenceWithDiagnostics_failure_preservesHTTPStatusContentTypeAndRetryAfter() {
        final class RateLimitedRequester: CartesiaRESTRequesting, @unchecked Sendable {
            func send(requestBody: Data, endpoint: URL, apiKey: String, apiVersion: String?, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {}
            func sendWithDiagnostics(requestBody: Data, endpoint: URL, apiKey: String, apiVersion: String?, completion: @escaping @Sendable (Result<Data, Error>, CartesiaRESTFetchDiagnostics) -> Void) {
                let diagnostics = CartesiaRESTFetchDiagnostics(httpStatus: 429, contentType: "application/json", retryAfterSeconds: 3.5, byteCount: 0)
                completion(.failure(NSError(domain: "CartesiaREST", code: 429, userInfo: [NSLocalizedDescriptionKey: "HTTP 429"])), diagnostics)
            }
        }
        let client = CartesiaRESTReferenceClient(requester: RateLimitedRequester())
        let fixture = makeRequest()
        var capturedResult: Result<Data, Error>?
        var capturedDiagnostics: CartesiaRESTFetchDiagnostics?
        client.fetchReferenceWithDiagnostics(text: fixture.text, modelID: fixture.modelID, voiceID: fixture.voiceID, apiKey: fixture.apiKey, apiVersion: fixture.apiVersion, locale: fixture.locale, sampleRate: 44100, encoding: "pcm_s16le", container: "wav") { result, diagnostics in
            capturedResult = result
            capturedDiagnostics = diagnostics
        }
        guard case .failure = capturedResult else { Issue.record("expected failure"); return }
        #expect(capturedDiagnostics == CartesiaRESTFetchDiagnostics(httpStatus: 429, contentType: "application/json", retryAfterSeconds: 3.5, byteCount: 0), "the real HTTP status/content-type/Retry-After must reach the caller unchanged — this is exactly what B.3C.1 needed to stop collapsing every REST failure into one generic message")
    }

    @Test func fetchReferenceWithDiagnostics_neverPlacesAPIKeyInTheRequestBody() {
        final class CapturingRequester: CartesiaRESTRequesting, @unchecked Sendable {
            private(set) var lastBody: Data?
            func send(requestBody: Data, endpoint: URL, apiKey: String, apiVersion: String?, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {}
            func sendWithDiagnostics(requestBody: Data, endpoint: URL, apiKey: String, apiVersion: String?, completion: @escaping @Sendable (Result<Data, Error>, CartesiaRESTFetchDiagnostics) -> Void) {
                lastBody = requestBody
                completion(.success(Data()), CartesiaRESTFetchDiagnostics(httpStatus: 200, contentType: nil, retryAfterSeconds: nil, byteCount: 0))
            }
        }
        let requester = CapturingRequester()
        let client = CartesiaRESTReferenceClient(requester: requester)
        let secretMarker = "THIS-IS-THE-SECRET-KEY-VALUE"
        let fixture = makeRequest()
        client.fetchReferenceWithDiagnostics(text: fixture.text, modelID: fixture.modelID, voiceID: fixture.voiceID, apiKey: secretMarker, apiVersion: fixture.apiVersion, locale: fixture.locale, sampleRate: 44100, encoding: "pcm_s16le", container: "wav") { _, _ in }
        let bodyString = requester.lastBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(!bodyString.contains(secretMarker), "the API key must travel ONLY in a header, never in the JSON body — unchanged by the diagnostics-returning path")
    }

    // MARK: - WAV validation edge cases (§8's "invalid WAV rejected" / "empty Data rejected")

    @Test func wavFileWriter_extractPCM_rejectsEmptyData() {
        #expect(WAVFileWriter.extractPCMFromCanonicalWAV(Data()) == nil)
    }

    @Test func wavFileWriter_extractPCM_rejectsDataShorterThanCanonicalHeader() {
        #expect(WAVFileWriter.extractPCMFromCanonicalWAV(Data(repeating: 0, count: 40)) == nil, "44 bytes is the canonical header size — anything shorter can never be a valid WAV")
    }

    @Test func wavFileWriter_extractPCM_rejectsNonRIFFData() {
        let notAWav = Data("this is not a wav file at all, just some bytes".utf8)
        #expect(WAVFileWriter.extractPCMFromCanonicalWAV(notAWav) == nil)
    }
}

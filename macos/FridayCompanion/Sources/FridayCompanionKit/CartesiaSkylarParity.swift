import Foundation

/// P2-M5V9-B.3C.1 — sanitized, non-secret HTTP-level diagnostics for a
/// single REST fetch attempt. Never carries request/response headers
/// themselves (only the two harmless, already-public ones a developer
/// needs to distinguish failure categories) and never carries body
/// content — just enough to tell "unauthorized" from "rate limited" from
/// "empty body" from "malformed WAV" instead of one generic message.
public struct CartesiaRESTFetchDiagnostics: Sendable, Equatable {
    public let httpStatus: Int?
    public let contentType: String?
    public let retryAfterSeconds: Double?
    public let byteCount: Int

    public init(httpStatus: Int?, contentType: String?, retryAfterSeconds: Double?, byteCount: Int) {
        self.httpStatus = httpStatus
        self.contentType = contentType
        self.retryAfterSeconds = retryAfterSeconds
        self.byteCount = byteCount
    }
}

/// P2-M5V9-B.3C §1 — the gold-reference REST client (`POST /tts/bytes`).
/// Explicitly a DIAGNOSTIC/parity path, never FRIDAY's production
/// conversational path (that stays realtime WebSocket via
/// `CartesiaSpeechStreamProvider`, unchanged by this file). Mirrors the
/// established "protocol + real URLSession implementation, fakeable in
/// tests" shape every other provider in this codebase already uses.
public protocol CartesiaRESTRequesting: Sendable {
    func send(requestBody: Data, endpoint: URL, apiKey: String, apiVersion: String?, completion: @escaping @Sendable (Result<Data, Error>) -> Void)
    /// Same request as `send`, but also reports `CartesiaRESTFetchDiagnostics`
    /// alongside the result — added in P2-M5V9-B.3C.1 for developer-tool
    /// callers that need the REAL failure reason. Mirrors the established
    /// `LocalIPCTransport.requestWithTiming` pattern: a protocol
    /// requirement with a default extension, so every existing conformer
    /// (including test fakes that only implement `send`) keeps compiling
    /// unchanged and gets a best-effort (no HTTP metadata) default.
    func sendWithDiagnostics(requestBody: Data, endpoint: URL, apiKey: String, apiVersion: String?, completion: @escaping @Sendable (Result<Data, Error>, CartesiaRESTFetchDiagnostics) -> Void)
}

public extension CartesiaRESTRequesting {
    func sendWithDiagnostics(requestBody: Data, endpoint: URL, apiKey: String, apiVersion: String?, completion: @escaping @Sendable (Result<Data, Error>, CartesiaRESTFetchDiagnostics) -> Void) {
        send(requestBody: requestBody, endpoint: endpoint, apiKey: apiKey, apiVersion: apiVersion) { result in
            let byteCount = (try? result.get())?.count ?? 0
            completion(result, CartesiaRESTFetchDiagnostics(httpStatus: nil, contentType: nil, retryAfterSeconds: nil, byteCount: byteCount))
        }
    }
}

public struct URLSessionCartesiaRESTRequester: CartesiaRESTRequesting {
    public init() {}

    public func send(requestBody: Data, endpoint: URL, apiKey: String, apiVersion: String?, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        sendWithDiagnostics(requestBody: requestBody, endpoint: endpoint, apiKey: apiKey, apiVersion: apiVersion) { result, _ in completion(result) }
    }

    /// The real implementation — `send` above simply delegates here and
    /// discards the diagnostics, so both methods are guaranteed to behave
    /// byte-identically (same status logic, same success/failure split).
    /// Never surfaces request headers or their values (the API key is set
    /// on the outgoing request but never read back out or logged).
    public func sendWithDiagnostics(requestBody: Data, endpoint: URL, apiKey: String, apiVersion: String?, completion: @escaping @Sendable (Result<Data, Error>, CartesiaRESTFetchDiagnostics) -> Void) {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = requestBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key") // never logged/printed anywhere
        if let apiVersion { request.setValue(apiVersion, forHTTPHeaderField: "Cartesia-Version") }
        URLSession.shared.dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            let contentType = http?.value(forHTTPHeaderField: "Content-Type")
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            if let error {
                let diagnostics = CartesiaRESTFetchDiagnostics(httpStatus: http?.statusCode, contentType: contentType, retryAfterSeconds: retryAfter, byteCount: data?.count ?? 0)
                completion(.failure(error), diagnostics)
                return
            }
            guard let http, (200...299).contains(http.statusCode) else {
                let code = http?.statusCode ?? -1
                let diagnostics = CartesiaRESTFetchDiagnostics(httpStatus: code, contentType: contentType, retryAfterSeconds: retryAfter, byteCount: data?.count ?? 0)
                completion(.failure(NSError(domain: "CartesiaREST", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])), diagnostics)
                return
            }
            let body = data ?? Data()
            let diagnostics = CartesiaRESTFetchDiagnostics(httpStatus: http.statusCode, contentType: contentType, retryAfterSeconds: retryAfter, byteCount: body.count)
            completion(.success(body), diagnostics)
        }.resume()
    }
}

/// P2-M5V9-B.3C §1/§4 — fetches the canonical Skylar reference rendering.
/// Uses `SkylarCanonicalBase` for `speed`/`volume` — the SAME source of
/// truth `CartesiaSpeechStreamProvider` uses for its own realtime
/// request, so the two paths can never accidentally diverge on those
/// fields (§3: "compare REST reference request vs realtime WebSocket
/// request field by field").
public struct CartesiaRESTReferenceClient {
    public static let defaultRESTEndpoint = URL(string: "https://api.cartesia.ai/tts/bytes")!

    private let requester: CartesiaRESTRequesting
    public let endpoint: URL

    public init(requester: CartesiaRESTRequesting = URLSessionCartesiaRESTRequester(), endpoint: URL = CartesiaRESTReferenceClient.defaultRESTEndpoint) {
        self.requester = requester
        self.endpoint = endpoint
    }

    private struct WireVoice: Encodable { let mode = "id"; let id: String }
    private struct WireOutputFormat: Encodable { let container: String; let encoding: String; let sample_rate: Int }
    private struct WireRequest: Encodable {
        let model_id: String
        let transcript: String
        let voice: WireVoice
        let output_format: WireOutputFormat
        let language: String?
        let speed: Double
        let volume: Double
    }

    private func buildRequestBody(text: String, modelID: String, voiceID: String, locale: String?, sampleRate: Int, encoding: String, container: String) -> Data? {
        let wireRequest = WireRequest(
            model_id: modelID, transcript: text, voice: WireVoice(id: voiceID),
            output_format: WireOutputFormat(container: container, encoding: encoding, sample_rate: sampleRate),
            language: locale, speed: SkylarCanonicalBase.speed, volume: SkylarCanonicalBase.volume
        )
        return try? JSONEncoder().encode(wireRequest)
    }

    /// - Parameters:
    ///   - container: `"wav"` for the true gold reference (a self-describing
    ///     file, per the owner's own reference shape); `"raw"` for
    ///     REFERENCE C (§6 — "REST rendered at the realtime path's exact
    ///     audio format", directly comparable to the WebSocket path's own
    ///     headerless raw PCM).
    public func fetchReference(
        text: String, modelID: String, voiceID: String, apiKey: String, apiVersion: String?, locale: String?,
        sampleRate: Int, encoding: String, container: String, completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        guard let body = buildRequestBody(text: text, modelID: modelID, voiceID: voiceID, locale: locale, sampleRate: sampleRate, encoding: encoding, container: container) else {
            completion(.failure(NSError(domain: "CartesiaREST", code: -1, userInfo: [NSLocalizedDescriptionKey: "could not encode request"])))
            return
        }
        requester.send(requestBody: body, endpoint: endpoint, apiKey: apiKey, apiVersion: apiVersion, completion: completion)
    }

    /// Same request as `fetchReference`, but also reports sanitized
    /// HTTP-level diagnostics (P2-M5V9-B.3C.1) so a developer-tool caller
    /// can distinguish "unauthorized" from "rate limited" from "empty
    /// body" from "malformed WAV" instead of one generic failure message.
    public func fetchReferenceWithDiagnostics(
        text: String, modelID: String, voiceID: String, apiKey: String, apiVersion: String?, locale: String?,
        sampleRate: Int, encoding: String, container: String, completion: @escaping @Sendable (Result<Data, Error>, CartesiaRESTFetchDiagnostics) -> Void
    ) {
        guard let body = buildRequestBody(text: text, modelID: modelID, voiceID: voiceID, locale: locale, sampleRate: sampleRate, encoding: encoding, container: container) else {
            completion(.failure(NSError(domain: "CartesiaREST", code: -1, userInfo: [NSLocalizedDescriptionKey: "could not encode request"])), CartesiaRESTFetchDiagnostics(httpStatus: nil, contentType: nil, retryAfterSeconds: nil, byteCount: 0))
            return
        }
        requester.sendWithDiagnostics(requestBody: body, endpoint: endpoint, apiKey: apiKey, apiVersion: apiVersion, completion: completion)
    }
}

/// P2-M5V9-B.3C §9 — writes a correct WAV header for a temporary,
/// developer-only fixture file. Never transcodes or alters the signal —
/// the PCM payload passed in is written byte-for-byte; only a standard
/// RIFF/WAVE header is prepended.
public enum WAVFileWriter {
    public static func makeWAVData(pcmS16LE: Data, sampleRate: Int, channelCount: Int) -> Data {
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate * channelCount * Int(bitsPerSample) / 8)
        let blockAlign = UInt16(channelCount * Int(bitsPerSample) / 8)
        let dataSize = UInt32(pcmS16LE.count)
        let riffChunkSize = UInt32(36 + pcmS16LE.count)

        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.appendLE(riffChunkSize)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.appendLE(UInt32(16)) // fmt chunk size (PCM)
        header.appendLE(UInt16(1)) // audio format: 1 = PCM
        header.appendLE(UInt16(channelCount))
        header.appendLE(UInt32(sampleRate))
        header.appendLE(byteRate)
        header.appendLE(blockAlign)
        header.appendLE(bitsPerSample)
        header.append(contentsOf: Array("data".utf8))
        header.appendLE(dataSize)
        return header + pcmS16LE
    }

    /// Strips a WAV file's own header and returns just the PCM payload —
    /// used when REFERENCE A's `container: "wav"` response needs its raw
    /// samples for statistics (§10). P2-M5V9-B.3C.2: this used to assume
    /// the common, canonical 44-byte header layout (RIFF/WAVE/fmt /data,
    /// no extra chunks, `data` always at byte 44) — real Cartesia REST
    /// responses are NOT guaranteed to match that exact shape (an 18-byte
    /// `fmt ` chunk, or an ancillary `LIST`/`JUNK`/`fact` chunk before
    /// `data`, both shift `data` to a different offset and are still
    /// perfectly valid WAV). Now routes through `WAVContainerParser`, the
    /// one real, bounded RIFF/WAVE chunk walker both `cartesia-skylar-parity`
    /// and `cartesia-skylar-parity-extended` share — no more silent
    /// rejection of a structurally valid, non-canonical-offset WAV.
    public static func extractPCMFromCanonicalWAV(_ wav: Data) -> Data? {
        switch WAVContainerParser.parse(wav) {
        case .success(let parsed): return parsed.pcm
        case .failure: return nil
        }
    }
}

/// P2-M5V9-B.3C.2 §1/§4 — one chunk found while walking a RIFF/WAVE
/// container: its FourCC, its own declared size (payload only, not
/// counting the 8-byte chunk header), and its byte offset (of the FourCC
/// itself, relative to the start of the RIFF file). Sanitized diagnostic
/// data only — never carries the chunk's own payload bytes.
public struct WAVChunkInfo: Sendable, Equatable {
    public let fourCC: String
    public let declaredSize: Int
    public let byteOffset: Int
    /// P2-M5V9-B.3C.3 — true when `declaredSize` was NOT read literally
    /// off the wire but resolved from the `0xFFFFFFFF` unknown-length
    /// streaming-WAV sentinel against the actual received buffer size.
    public let isStreamingResolved: Bool
}

/// P2-M5V9-B.3C.2 §4 — the decoded `fmt ` fields FRIDAY actually cares
/// about, plus where/how big the `data` chunk turned out to be (which,
/// for a real-world WAV, is NOT guaranteed to be at byte 44).
public struct WAVFormatInfo: Sendable, Equatable {
    /// Already resolved from the WAVE_FORMAT_EXTENSIBLE SubFormat GUID
    /// when present — never the raw 0xFFFE tag itself.
    public let audioFormatCode: Int
    public let channelCount: Int
    public let sampleRate: Int
    public let byteRate: Int
    public let blockAlign: Int
    public let bitsPerSample: Int
    public let dataOffset: Int
    public let dataSize: Int
}

/// P2-M5V9-B.3C.2 §7 — every distinct way a provider "WAV" response can
/// fail to be usable, so a caller can report the REAL reason instead of
/// one generic "invalid WAV". `unsupportedSampleRate`/`unsupportedChannelCount`/
/// `unsupportedBitDepth` mean the container itself parsed perfectly fine —
/// it's just not the specific PCM shape FRIDAY requires (§7: "container
/// structurally valid but format unexpected" is a DIFFERENT case from a
/// malformed container).
public enum WAVValidationFailure: Error, Sendable, Equatable {
    case invalidRIFFSignature
    case invalidWAVEForm
    case truncatedChunk(fourCC: String)
    case missingFmtChunk
    case missingDataChunk
    case unsupportedCodec(formatCode: Int)
    case unsupportedSampleRate(Int)
    case unsupportedChannelCount(Int)
    case unsupportedBitDepth(Int)

    /// A short, sanitized, non-secret phrase — never includes raw bytes.
    public var sanitizedDescription: String {
        switch self {
        case .invalidRIFFSignature: return "invalid RIFF signature"
        case .invalidWAVEForm: return "invalid WAVE form type"
        case .truncatedChunk(let fourCC): return "truncated chunk (\(fourCC))"
        case .missingFmtChunk: return "missing fmt chunk"
        case .missingDataChunk: return "missing data chunk"
        case .unsupportedCodec(let code): return "unsupported codec (format code \(code))"
        case .unsupportedSampleRate(let rate): return "unsupported sample rate (\(rate)Hz)"
        case .unsupportedChannelCount(let count): return "unsupported channel count (\(count))"
        case .unsupportedBitDepth(let bits): return "unsupported bit depth (\(bits)-bit)"
        }
    }
}

/// P2-M5V9-B.3C.2 — a real, bounded RIFF/WAVE chunk walker. This is the
/// ONE shared parser both `cartesia-skylar-parity` and
/// `cartesia-skylar-parity-extended` route through (directly, or via
/// `WAVFileWriter.extractPCMFromCanonicalWAV` above) — there is no
/// second, stricter "canonical 44-byte" validator left anywhere in this
/// codebase. Never requires `data` to start at any particular offset;
/// never assumes chunk ordering beyond RIFF/WAVE itself; tolerates
/// unknown ancillary chunks (`LIST`/`JUNK`/`fact`/`bext`/...) anywhere
/// before `data`; respects RIFF's even-byte chunk padding; safe against
/// truncated, out-of-bounds, or overflow-sized chunk declarations (never
/// crashes, never hangs, never reads past the buffer).
public enum WAVContainerParser {
    /// Walks every top-level chunk after the RIFF/WAVE header. Returns
    /// `.failure` the instant the container itself is structurally
    /// unsound; otherwise returns every chunk found, unknown ones
    /// included, in file order.
    ///
    /// P2-M5V9-B.3C.3 §2/§3 — real Cartesia REST responses are a
    /// streaming WAV: the RIFF chunk's own declared size (bytes 4..<8)
    /// legitimately arrives as the `0xFFFFFFFF` "unknown length" sentinel
    /// (never a request to actually read 4GB). That sentinel is handled
    /// with ZERO special-casing here, because this walker never reads or
    /// enforces the RIFF chunk's own size field at all — the received
    /// `Data`'s own `endIndex` is already the one source of truth for
    /// where the container ends. The SAME sentinel on the `data` chunk
    /// gets one narrow, explicit resolution rule below; every other
    /// chunk (including a second, duplicate `data`) claiming the
    /// sentinel is refused rather than guessed at, and a normal, FINITE
    /// declared size that exceeds the actual buffer still fails as
    /// truncated exactly as before — this does not weaken that check.
    public static func walkChunks(_ data: Data) -> Result<[WAVChunkInfo], WAVValidationFailure> {
        let start = data.startIndex
        let end = data.endIndex
        guard end - start >= 12 else { return .failure(.invalidRIFFSignature) }
        guard data[start..<(start + 4)] == Data("RIFF".utf8) else { return .failure(.invalidRIFFSignature) }
        guard data[(start + 8)..<(start + 12)] == Data("WAVE".utf8) else { return .failure(.invalidWAVEForm) }

        var chunks: [WAVChunkInfo] = []
        var offset = start + 12
        var sawDataChunk = false
        while end - offset >= 8 {
            let fourCC = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let sizeBytes = data[(offset + 4)..<(offset + 8)]
            // `loadUnaligned`, not `load`: after an odd-sized preceding
            // chunk (even WITH RIFF's even-byte padding applied), a chunk
            // header can land on a byte offset that's 2-byte- but not
            // 4-byte-aligned. `.load(as:)` requires natural alignment and
            // traps ("misaligned raw pointer") in exactly that case —
            // caught live by this milestone's own odd-sized-ancillary-chunk
            // test fixture (§9 case E) crashing the whole test process.
            let rawLE = sizeBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let declaredSizeRaw = UInt32(littleEndian: rawLE)
            let chunkDataStart = offset + 8

            if declaredSizeRaw == UInt32.max {
                // The unknown-length streaming sentinel is recognized
                // ONLY for a `data` chunk, and only the FIRST one — never
                // for an ancillary chunk (§3: "unknown-size non-data
                // ancillary chunk => reject unless explicitly proven
                // valid", and there is no proven-safe resolution for
                // anything but `data`), and never a second `data` (which
                // would prove the first one was NOT actually the file's
                // terminal audio chunk after all).
                guard fourCC == "data", !sawDataChunk, chunkDataStart <= end else {
                    return .failure(.truncatedChunk(fourCC: fourCC))
                }
                sawDataChunk = true
                let effectiveSize = end - chunkDataStart // an already-fully-received HTTP body has nothing "after" its own end
                chunks.append(WAVChunkInfo(fourCC: fourCC, declaredSize: effectiveSize, byteOffset: offset - start, isStreamingResolved: true))
                offset = end // terminal by construction — the loop ends naturally on the next check
                continue
            }

            if fourCC == "data" {
                guard !sawDataChunk else { return .failure(.truncatedChunk(fourCC: fourCC)) }
                sawDataChunk = true
            }

            let declaredSize = Int(declaredSizeRaw)
            // Bounds/overflow-safe: rejects a chunk that claims more bytes
            // than actually remain, instead of reading past the buffer.
            // This is the ORDINARY finite-size path — completely
            // unaffected by the sentinel handling above, so a normal
            // truncated/corrupt response still fails exactly as before.
            guard chunkDataStart <= end, (end - chunkDataStart) >= declaredSize else {
                return .failure(.truncatedChunk(fourCC: fourCC))
            }
            chunks.append(WAVChunkInfo(fourCC: fourCC, declaredSize: declaredSize, byteOffset: offset - start, isStreamingResolved: false))
            var nextOffset = chunkDataStart + declaredSize
            if declaredSize % 2 == 1 { nextOffset += 1 } // RIFF even-byte chunk padding
            offset = nextOffset
        }
        return .success(chunks)
    }

    /// Locates `fmt `/`data` wherever they actually are, decodes the
    /// format fields (resolving WAVE_FORMAT_EXTENSIBLE's SubFormat GUID
    /// rather than trusting the raw 0xFFFE tag), and returns the RAW PCM
    /// bytes completely UNALTERED — no resampling, no gain change, no
    /// transcoding of any kind, regardless of what format is found.
    public static func parse(_ data: Data) -> Result<(format: WAVFormatInfo, pcm: Data, chunks: [WAVChunkInfo]), WAVValidationFailure> {
        switch walkChunks(data) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let chunks):
            let start = data.startIndex
            guard let fmtChunk = chunks.first(where: { $0.fourCC == "fmt " }) else { return .failure(.missingFmtChunk) }
            guard let dataChunk = chunks.first(where: { $0.fourCC == "data" }) else { return .failure(.missingDataChunk) }
            guard fmtChunk.declaredSize >= 16 else { return .failure(.truncatedChunk(fourCC: "fmt ")) }

            let fmtStart = start + fmtChunk.byteOffset + 8
            // `loadUnaligned` for the same reason as in `walkChunks` — the
            // `fmt ` chunk's own byte offset is only guaranteed even, not
            // 4-byte-aligned, once any odd-sized chunk precedes it.
            func u16(_ relativeOffset: Int) -> Int {
                let raw = data[(fmtStart + relativeOffset)..<(fmtStart + relativeOffset + 2)].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
                return Int(UInt16(littleEndian: raw))
            }
            func u32(_ relativeOffset: Int) -> Int {
                let raw = data[(fmtStart + relativeOffset)..<(fmtStart + relativeOffset + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                return Int(UInt32(littleEndian: raw))
            }

            var audioFormatCode = u16(0)
            let channelCount = u16(2)
            let sampleRate = u32(4)
            let byteRate = u32(8)
            let blockAlign = u16(12)
            let bitsPerSample = u16(14)

            if audioFormatCode == 0xFFFE { // WAVE_FORMAT_EXTENSIBLE — resolve the REAL codec from the SubFormat GUID, never assume PCM from the tag alone.
                guard fmtChunk.declaredSize >= 40 else { return .failure(.unsupportedCodec(formatCode: audioFormatCode)) }
                audioFormatCode = u16(24) // first 2 bytes of the 16-byte SubFormat GUID carry the real format code (e.g. KSDATAFORMAT_SUBTYPE_PCM)
            }
            guard audioFormatCode == 1 else { return .failure(.unsupportedCodec(formatCode: audioFormatCode)) }

            let dataStart = start + dataChunk.byteOffset + 8
            let pcm = Data(data[dataStart..<(dataStart + dataChunk.declaredSize)])

            // §2/§6 test F: a streaming-resolved payload (size taken from
            // "however many bytes are actually left", not a wire-declared
            // value) must still cleanly divide into whole audio frames —
            // a partial trailing frame means the response was cut off
            // mid-sample, not a clean stream end. This check is scoped to
            // the streaming case only; an ordinary finite `data` size is
            // the provider's own explicit declaration and is left as-is.
            if dataChunk.isStreamingResolved, blockAlign > 0, pcm.count % blockAlign != 0 {
                return .failure(.truncatedChunk(fourCC: "data"))
            }

            let format = WAVFormatInfo(audioFormatCode: audioFormatCode, channelCount: channelCount, sampleRate: sampleRate, byteRate: byteRate, blockAlign: blockAlign, bitsPerSample: bitsPerSample, dataOffset: dataChunk.byteOffset + 8, dataSize: dataChunk.declaredSize)
            return .success((format, pcm, chunks))
        }
    }

    /// FRIDAY's specific playback requirement: decoded audio equivalent to
    /// PCM signed 16-bit little-endian, mono, at `expectedSampleRate`. A
    /// container that parses perfectly but doesn't match (stereo, wrong
    /// rate, wrong bit depth) is a DIFFERENT, explicit failure from a
    /// malformed container (§7) — never silently accepted, never
    /// resampled/downmixed to force a match.
    public static func extractPCM16LEMono(_ data: Data, expectedSampleRate: Int) -> Result<(pcm: Data, format: WAVFormatInfo), WAVValidationFailure> {
        switch parse(data) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let parsed):
            guard parsed.format.sampleRate == expectedSampleRate else { return .failure(.unsupportedSampleRate(parsed.format.sampleRate)) }
            guard parsed.format.channelCount == 1 else { return .failure(.unsupportedChannelCount(parsed.format.channelCount)) }
            guard parsed.format.bitsPerSample == 16 else { return .failure(.unsupportedBitDepth(parsed.format.bitsPerSample)) }
            return .success((parsed.pcm, parsed.format))
        }
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

/// P2-M5V9-B.3C §10 — objective PCM statistics, debugging evidence ONLY.
/// Explicitly never used to claim/disprove speaker identity — only the
/// owner's own ears determine that (§10's own instruction).
public struct PCMAudioStatistics: Sendable, Equatable {
    public let frameCount: Int
    public let durationSec: Double
    public let peakAmplitude: Double // 0...1, normalized
    public let rms: Double // 0...1, normalized
    public let clippedSampleCount: Int
    public let dcOffset: Double // -1...1, normalized

    public static func measure(pcmS16LE: Data, sampleRate: Int, channelCount: Int) -> PCMAudioStatistics? {
        guard sampleRate > 0, channelCount > 0, !pcmS16LE.isEmpty, pcmS16LE.count % 2 == 0 else { return nil }
        let sampleCount = pcmS16LE.count / 2
        var peak: Double = 0
        var sumSquares: Double = 0
        var sum: Double = 0
        var clipped = 0
        pcmS16LE.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                let normalized = Double(samples[i]) / Double(Int16.max)
                let magnitude = abs(normalized)
                if magnitude > peak { peak = magnitude }
                if samples[i] == Int16.max || samples[i] == Int16.min { clipped += 1 }
                sumSquares += normalized * normalized
                sum += normalized
            }
        }
        let frameCount = sampleCount / channelCount
        return PCMAudioStatistics(
            frameCount: frameCount, durationSec: Double(frameCount) / Double(sampleRate),
            peakAmplitude: peak, rms: (sumSquares / Double(sampleCount)).squareRoot(),
            clippedSampleCount: clipped, dcOffset: sum / Double(sampleCount)
        )
    }
}
